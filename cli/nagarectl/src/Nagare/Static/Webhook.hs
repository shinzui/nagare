{-# LANGUAGE PackageImports #-}

-- | Pure GitHub-webhook logic (EP-16 Milestone 2): HMAC-SHA256 signature
-- verification, event parsing, and branch/PR routing. No IO, so the
-- security-sensitive decisions are fully unit-testable without a live provider.
--
-- The @nagared@ service (the executable) reads the HTTP request, calls
-- 'decideWebhook' to get a 'WebhookOutcome', and — only for 'Triggered' — checks
-- out the repository and invokes the shared deploy path
-- ('Nagare.Static.Deploy'). An unsigned or mis-signed request never reaches the
-- deploy path.
module Nagare.Static.Webhook
  ( -- * Signature verification
    verifySignature

    -- * Events
  , CheckoutSpec (..)
  , GitHubEvent (..)
  , parseGitHubEvent

    -- * Routing
  , WebhookConfig (..)
  , DeployAction (..)
  , routeEvent
  , previewNameForPr

    -- * Top-level decision
  , WebhookOutcome (..)
  , decideWebhook
  ) where

import Nagare.Dsl.Prelude

import "crypton" Crypto.Hash (SHA256)
import "crypton" Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Aeson (eitherDecodeStrict, withObject, (.:))
import Data.Aeson.Types (Parser, Value, parseEither)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

-- ---------------------------------------------------------------------------
-- Signature verification

-- | Verify a GitHub @X-Hub-Signature-256@ header against the request body using
-- the shared secret. The header has the form @"sha256=<hex>"@. The comparison is
-- constant-time ('BA.constEq') to avoid leaking the digest through timing.
verifySignature :: ByteString -> ByteString -> ByteString -> Bool
verifySignature secret body header =
  BA.constEq expected header
  where
    mac = hmac secret body :: HMAC SHA256
    -- show (Digest SHA256) is the lowercase hex digest GitHub uses.
    expected = "sha256=" <> BC.pack (show (hmacGetDigest mac))

-- ---------------------------------------------------------------------------
-- Events

-- | Where and what to deploy: enough to clone/fetch a repo at an exact commit.
data CheckoutSpec = CheckoutSpec
  { cloneUrl :: !Text
  , gitRef :: !Text
  , sha :: !Text
  , repoFullName :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | The GitHub events @nagared@ cares about. Anything else is 'OtherEvent'.
data GitHubEvent
  = PushEvent {branch :: !Text, checkout :: !CheckoutSpec}
  | PullRequestEvent {action :: !Text, prNumber :: !Int, headRef :: !Text, checkout :: !CheckoutSpec}
  | PingEvent
  | OtherEvent !Text
  deriving stock (Generic, Eq, Show)

-- | Parse a GitHub event from the @X-GitHub-Event@ header value and the JSON
-- body. Unknown event types are 'OtherEvent'; malformed JSON for a known type is
-- a 'Left'.
parseGitHubEvent :: ByteString -> ByteString -> Either Text GitHubEvent
parseGitHubEvent eventType body =
  case eventType of
    "ping" -> Right PingEvent
    "push" -> decodeWith parsePush
    "pull_request" -> decodeWith parsePullRequest
    other -> Right (OtherEvent (TE.decodeUtf8 other))
  where
    decodeWith p = do
      v <- mapErr (eitherDecodeStrict body)
      mapErr (parseEither p v)
    mapErr = either (Left . T.pack) Right

parsePush :: Value -> Parser GitHubEvent
parsePush = withObject "push" $ \o -> do
  ref <- o .: "ref"
  after <- o .: "after"
  repo <- o .: "repository"
  (clone, full) <- repoFields repo
  pure
    PushEvent
      { branch = stripRefsHeads ref
      , checkout =
          CheckoutSpec {cloneUrl = clone, gitRef = ref, sha = after, repoFullName = full}
      }

parsePullRequest :: Value -> Parser GitHubEvent
parsePullRequest = withObject "pull_request" $ \o -> do
  act <- o .: "action"
  num <- o .: "number"
  pr <- o .: "pull_request"
  (hRef, hSha, hClone, full) <- withObject "pull_request.body" prFields pr
  pure
    PullRequestEvent
      { action = act
      , prNumber = num
      , headRef = hRef
      , checkout =
          CheckoutSpec {cloneUrl = hClone, gitRef = "refs/heads/" <> hRef, sha = hSha, repoFullName = full}
      }
  where
    prFields o = do
      headObj <- o .: "head"
      withObject "pull_request.head" headFields headObj
    headFields h = do
      hRef <- h .: "ref"
      hSha <- h .: "sha"
      repo <- h .: "repo"
      (clone, full) <- repoFields repo
      pure (hRef, hSha, clone, full)

repoFields :: Value -> Parser (Text, Text)
repoFields = withObject "repository" $ \o -> do
  clone <- o .: "clone_url"
  full <- o .: "full_name"
  pure (clone, full)

stripRefsHeads :: Text -> Text
stripRefsHeads r = fromMaybe r (T.stripPrefix "refs/heads/" r)

-- ---------------------------------------------------------------------------
-- Routing

-- | Per-site webhook configuration: the shared secret and which branch is
-- production.
data WebhookConfig = WebhookConfig
  { secret :: !ByteString
  , productionBranch :: !Text
  }

-- | What an accepted event maps to.
data DeployAction
  = DeployProduction !CheckoutSpec
  | DeployPreview !Text !CheckoutSpec
  deriving stock (Generic, Eq, Show)

-- | Route a parsed event to a deploy action, or 'Nothing' when the event is not
-- a deploy trigger (a push to a non-production branch, or a PR action other than
-- opened/synchronize/reopened).
routeEvent :: WebhookConfig -> GitHubEvent -> Maybe DeployAction
routeEvent cfg = \case
  PushEvent {branch, checkout}
    | branch == productionBranch cfg -> Just (DeployProduction checkout)
    | otherwise -> Nothing
  PullRequestEvent {action, prNumber, checkout}
    | action `elem` ["opened", "synchronize", "reopened"] ->
        Just (DeployPreview (previewNameForPr prNumber) checkout)
    | otherwise -> Nothing
  _ -> Nothing

-- | The deterministic preview name for a pull request: @"pr-<number>"@.
previewNameForPr :: Int -> Text
previewNameForPr n = "pr-" <> T.pack (show n)

-- ---------------------------------------------------------------------------
-- Top-level decision

-- | The decision for one webhook request, before any deploy is run.
data WebhookOutcome
  = -- | reject with this HTTP status and reason (bad signature, bad body)
    Rejected !Int !Text
  | -- | accepted but a no-op (ping, non-production branch, non-deploy PR action)
    Ignored !Text
  | -- | a deploy should run
    Triggered !DeployAction
  deriving stock (Generic, Eq, Show)

-- | Decide what to do with a webhook request from its event header, signature
-- header, and body. Signature is verified first: a missing or invalid signature
-- is 'Rejected' 401 before the body is even parsed as an event.
decideWebhook ::
  WebhookConfig ->
  Maybe ByteString ->
  Maybe ByteString ->
  ByteString ->
  WebhookOutcome
decideWebhook cfg mEvent mSignature body =
  case mSignature of
    Nothing -> Rejected 401 "missing X-Hub-Signature-256 header"
    Just sig
      | not (verifySignature (secret cfg) body sig) -> Rejected 401 "invalid signature"
      | otherwise -> case parseGitHubEvent (fromMaybe "" mEvent) body of
          Left err -> Rejected 400 ("could not parse event: " <> err)
          Right PingEvent -> Ignored "pong"
          Right ev -> case routeEvent cfg ev of
            Just action -> Triggered action
            Nothing -> Ignored "event is not a deploy trigger"
