-- | Webhook responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Webhook
  ( webhookTests
  )
where

import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Static.Webhook
  ( CheckoutSpec (CheckoutSpec)
  , DeployAction (DeployPreview, DeployProduction)
  , GitHubEvent
    ( OtherEvent
    , PullRequestEvent
    , PushEvent
    , baseRepoFullName
    , checkout
    )
  , WebhookConfig (WebhookConfig, productionBranch, secret)
  , WebhookOutcome (Ignored, Rejected, Triggered)
  , decideWebhook
  , parseGitHubEvent
  , previewNameForPr
  , reviewedSiteArgs
  , routeEvent
  , verifySignature
  )
import Test.Tasty (TestTree)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

-- ---------------------------------------------------------------------------
-- Webhook

webhookTests :: [TestTree]
webhookTests =
  [ testCase "verifySignature accepts the known HMAC-SHA256 test vector" $
      -- HMAC-SHA256(key="key", "The quick brown fox jumps over the lazy dog")
      assertBool "valid signature accepted" $
        verifySignature
          "key"
          "The quick brown fox jumps over the lazy dog"
          "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
  , testCase "verifySignature rejects a wrong signature" $
      assertBool "wrong signature rejected" $
        not (verifySignature "key" "body" "sha256=00000000")
  , testCase "decideWebhook rejects a missing signature" $
      case decideWebhook cfg (Just "push") Nothing pushMain of
        Rejected 401 _ -> pure ()
        other -> assertFailure ("expected Rejected 401, got: " <> show other)
  , testCase "decideWebhook rejects an invalid signature" $
      case decideWebhook cfg (Just "push") (Just "sha256=bad") pushMain of
        Rejected 401 _ -> pure ()
        other -> assertFailure ("expected Rejected 401, got: " <> show other)
  , testCase "decideWebhook acks a signed ping" $
      case decideWebhook cfg (Just "ping") (Just (sign "topsecret" ping)) ping of
        Ignored _ -> pure ()
        other -> assertFailure ("expected Ignored, got: " <> show other)
  , testCase "decideWebhook triggers production for a push to main" $
      case decideWebhook cfg (Just "push") (Just (sign "topsecret" pushMain)) pushMain of
        Triggered (DeployProduction co) -> co ^. #repoFullName @?= "o/x"
        other -> assertFailure ("expected DeployProduction, got: " <> show other)
  , testCase "decideWebhook ignores a push to a non-production branch" $
      case decideWebhook cfg (Just "push") (Just (sign "topsecret" pushDev)) pushDev of
        Ignored _ -> pure ()
        other -> assertFailure ("expected Ignored, got: " <> show other)
  , testCase "decideWebhook triggers a preview for a PR opened" $
      case decideWebhook cfg (Just "pull_request") (Just (sign "topsecret" prOpened)) prOpened of
        Triggered (DeployPreview name _) -> name @?= "pr-7"
        other -> assertFailure ("expected DeployPreview pr-7, got: " <> show other)
  , testCase "decideWebhook ignores a PR closed" $
      case decideWebhook cfg (Just "pull_request") (Just (sign "topsecret" prClosed)) prClosed of
        Ignored _ -> pure ()
        other -> assertFailure ("expected Ignored, got: " <> show other)
  , testCase "parseGitHubEvent push extracts branch and sha" $
      case parseGitHubEvent "push" pushMain of
        Right (PushEvent b co) -> do
          b @?= "main"
          co ^. #sha @?= "deadbeef"
        other -> assertFailure ("expected PushEvent, got: " <> show other)
  , testCase "parseGitHubEvent of an unknown type is OtherEvent" $
      parseGitHubEvent "issues" "{}" @?= Right (OtherEvent "issues")
  , testCase "previewNameForPr is pr-<n>" $
      previewNameForPr 42 @?= "pr-42"
  , testCase "webhook submits production and preview through reviewed site CLI options" $ do
      let checkout =
            CheckoutSpec
              "https://example.test/site.git"
              "main"
              "0123456789abcdef"
              "owner/site"
          common =
            [ "--file"
            , "/work/nagare/Config.hs"
            , "--project-dir"
            , "/work"
            , "--base-domain"
            , "example.test"
            , "--skip-build"
            , "--tag"
            , "0123456789ab"
            , "--image-resource"
            , "publication:image"
            , "--source"
            , "0123456789abcdef"
            ]
      reviewedSiteArgs
        "local"
        "/work/nagare/Config.hs"
        "/work"
        "example.test"
        "publication:image"
        []
        (DeployProduction checkout)
        @?= ["--context", "local", "site", "deploy"] <> common
      reviewedSiteArgs
        "local"
        "/work/nagare/Config.hs"
        "/work"
        "example.test"
        "publication:image"
        ["runtime", "runtime-secret", "preview", "preview-secret"]
        (DeployPreview "pr-7" checkout)
        @?= ["--context", "local", "site", "preview", "deploy", "--name", "pr-7"]
          <> common
          <> concatMap
            (\resourceId -> ["--preview-env-resource", resourceId])
            ["runtime", "runtime-secret", "preview", "preview-secret"]
  , -- The fork gate. GitHub delivers a fork's pull_request event to the base
    -- repository's webhook signed with the BASE repository's secret, so the
    -- HMAC check passes and cannot help here. Everything below pins the
    -- decision that stops it.
    testCase "decideWebhook ignores a correctly signed fork pull request" $
      case decideWebhook cfg (Just "pull_request") (Just (sign "topsecret" prForkOpened)) prForkOpened of
        Ignored reason -> do
          assertBool ("reason mentions fork: " <> show reason) ("fork" `T.isInfixOf` reason)
          assertBool ("reason names the head repo: " <> show reason) ("attacker/x" `T.isInfixOf` reason)
        other -> assertFailure ("expected Ignored (fork), got: " <> show other)
  , testCase "routeEvent on a fork pull request is Left" $
      case parseGitHubEvent "pull_request" prForkOpened of
        Right ev -> case routeEvent cfg ev of
          Left _ -> pure ()
          Right action -> assertFailure ("expected Left for a fork PR, got: " <> show action)
        other -> assertFailure ("expected a parsed event, got: " <> show other)
  , testCase "routeEvent on a same-repo pull request is Right DeployPreview" $
      case parseGitHubEvent "pull_request" prOpened of
        Right ev -> case routeEvent cfg ev of
          Right (DeployPreview name _) -> name @?= "pr-7"
          other -> assertFailure ("expected Right DeployPreview, got: " <> show other)
        other -> assertFailure ("expected a parsed event, got: " <> show other)
  , testCase "parseGitHubEvent extracts baseRepoFullName" $
      case parseGitHubEvent "pull_request" prForkOpened of
        Right PullRequestEvent {baseRepoFullName, checkout} -> do
          baseRepoFullName @?= "o/x"
          checkout ^. #repoFullName @?= "attacker/x"
        other -> assertFailure ("expected PullRequestEvent, got: " <> show other)
  , testCase "a PR payload without a base object is rejected 400" $
      case decideWebhook cfg (Just "pull_request") (Just (sign "topsecret" prNoBase)) prNoBase of
        Rejected 400 _ -> pure ()
        other -> assertFailure ("expected Rejected 400, got: " <> show other)
  , testCase "routeEvent names the branch when ignoring a non-production push" $
      case parseGitHubEvent "push" pushDev of
        Right ev -> case routeEvent cfg ev of
          Left reason -> assertBool ("reason names the branch: " <> show reason) ("dev" `T.isInfixOf` reason)
          Right action -> assertFailure ("expected Left, got: " <> show action)
        other -> assertFailure ("expected a parsed event, got: " <> show other)
  ]
  where
    cfg = WebhookConfig {secret = "topsecret", productionBranch = "main"}

sign :: ByteString -> ByteString -> ByteString
sign secret body =
  BC.pack ("sha256=" <> show (hmacGetDigest (hmac secret body :: HMAC SHA256)))

ping :: ByteString
ping = "{\"zen\":\"hi\"}"

pushMain :: ByteString
pushMain =
  "{\"ref\":\"refs/heads/main\",\"after\":\"deadbeef\",\"repository\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}"

pushDev :: ByteString
pushDev =
  "{\"ref\":\"refs/heads/dev\",\"after\":\"abc\",\"repository\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}"

-- | A same-repo PR: head repo and base repo are both @o/x@, so it is a genuine
-- branch of the watched repository and previews are allowed.
prOpened :: ByteString
prOpened =
  "{\"action\":\"opened\",\"number\":7,\"pull_request\":{\"head\":{\"ref\":\"feature\",\"sha\":\"cafe\",\"repo\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}},\"base\":{\"repo\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}}}"

prClosed :: ByteString
prClosed =
  "{\"action\":\"closed\",\"number\":7,\"pull_request\":{\"head\":{\"ref\":\"feature\",\"sha\":\"cafe\",\"repo\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}},\"base\":{\"repo\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}}}"

-- | A FORK PR: GitHub signs this with the base repository's secret exactly like
-- the same-repo one above, but the head repo (and clone URL) belong to a
-- stranger. Deploying it would execute the fork's nagare/Config.hs on this host.
prForkOpened :: ByteString
prForkOpened =
  "{\"action\":\"opened\",\"number\":7,\"pull_request\":{\"head\":{\"ref\":\"feature\",\"sha\":\"cafe\",\"repo\":{\"clone_url\":\"https://e/attacker-x.git\",\"full_name\":\"attacker/x\"}},\"base\":{\"repo\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}}}"

-- | A PR payload with no @base@ object at all — the parser must reject it
-- rather than defaulting the base repo to anything permissive.
prNoBase :: ByteString
prNoBase =
  "{\"action\":\"opened\",\"number\":7,\"pull_request\":{\"head\":{\"ref\":\"feature\",\"sha\":\"cafe\",\"repo\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}}}"
