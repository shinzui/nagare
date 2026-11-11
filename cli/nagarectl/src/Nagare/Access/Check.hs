-- | The operator's effective-access diagnostic (MasterPlan 27, EP-188 M1):
-- one fully consistent En check of one user on one protected host, for the
-- permission the enforcer evaluates, reported as En answered it. It never
-- lists or expands relationships to guess, and an error is an unavailable
-- answer, never a decision.
module Nagare.Access.Check
  ( CheckDecision (..)
  , CheckReport (..)
  , CheckRequest (..)
  , CheckResult (..)
  , Obligation (..)
  , checkDecided
  , checkPath
  , checkRequest
  , effectiveAccess
  , effectiveAccessThrough
  , parseCheckResponse
  , renderCheckReport
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, eitherDecodeStrict, pairs, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encoding (pair)
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))

-- | A caveat En could not evaluate: the decision stands only if the named
-- context is supplied, which the gateway never does.
data Obligation = Obligation
  { caveat :: !Text
  , missingContext :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON Obligation where
  parseJSON = withObject "obligation" $ \o -> Obligation <$> o .: "caveat" <*> o .: "missingContext"

instance ToJSON Obligation where
  toJSON obligation = Aeson.object ["caveat" .= (obligation ^. #caveat), "missingContext" .= (obligation ^. #missingContext)]

data CheckDecision
  = CheckAllowed
  | CheckDenied
  | CheckConditional ![Obligation]
  deriving stock (Generic, Eq, Show)

-- | What En said, with the snapshot it said it at; or why it could not say.
data CheckResult
  = Decided
      { decision :: !CheckDecision
      , checkedAt :: !Text
      -- ^ The consistency token of the snapshot, not a timestamp.
      , grantGeneration :: !(Maybe Text)
      -- ^ En's grant generation when it reports one; also not a timestamp.
      }
  | Unavailable !Text
  deriving stock (Generic, Eq, Show)

data CheckReport = CheckReport
  { host :: !Text
  , subject :: !Text
  , result :: !CheckResult
  , inheritedFrom :: !(Maybe Text)
  -- ^ EP-250: the delegation whose grant allowed it, when the host's own
  -- grants did not.
  }
  deriving stock (Generic, Eq, Show)

-- | Denied is a valid answer; only an unavailable service or invalid input
-- fails the command.
checkDecided :: CheckReport -> Bool
checkDecided report = case report ^. #result of
  Decided {} -> True
  Unavailable _ -> False

instance ToJSON CheckReport where
  toJSON report =
    Aeson.object
      ( ["host" .= (report ^. #host), "subject" .= (report ^. #subject), "permission" .= ("access" :: Text)]
          <> case report ^. #result of
            Decided {decision, checkedAt, grantGeneration} ->
              [ "decision" .= decisionText decision
              , "checkedAt" .= checkedAt
              ]
                <> ["obligations" .= obligations | CheckConditional obligations <- [decision]]
                <> ["grantGeneration" .= generation | Just generation <- [grantGeneration]]
                <> ["inheritedFrom" .= Aeson.object ["delegation" .= delegation] | Just delegation <- [report ^. #inheritedFrom]]
            Unavailable diagnostic -> ["decision" .= ("unavailable" :: Text), "diagnostic" .= diagnostic]
      )

decisionText :: CheckDecision -> Text
decisionText = \case
  CheckAllowed -> "allowed"
  CheckDenied -> "denied"
  CheckConditional _ -> "conditional"

-- | The check En receives, in its own field order: a fully consistent
-- snapshot, no caveat context (the gateway supplies none), the user subject,
-- permission @access@ on @app:<host>@.
-- | The object type (@app@, or @delegation@ for EP-250), its id, and the subject.
data CheckRequest = CheckRequest !Text !Text !Text
  deriving stock (Eq, Show)

checkRequest :: Text -> Text -> CheckRequest
checkRequest = CheckRequest "app"

instance ToJSON CheckRequest where
  toJSON (CheckRequest objectType host subject) =
    Aeson.object
      [ "consistency" .= Aeson.object ["mode" .= ("fullyConsistent" :: Text)]
      , "context" .= Aeson.object ["values" .= Aeson.object []]
      , "subject" .= Aeson.object ["kind" .= ("id" :: Text), "objectType" .= ("user" :: Text), "objectId" .= subject]
      , "permission" .= ("access" :: Text)
      , "object" .= Aeson.object ["objectType" .= objectType, "objectId" .= host]
      ]
  toEncoding (CheckRequest objectType host subject) =
    pairs
      ( pair "consistency" (pairs ("mode" .= ("fullyConsistent" :: Text)))
          <> pair "context" (pairs (pair "values" (pairs mempty)))
          <> pair "subject" (pairs ("kind" .= ("id" :: Text) <> "objectType" .= ("user" :: Text) <> "objectId" .= subject))
          <> "permission" .= ("access" :: Text)
          <> pair "object" (pairs ("objectType" .= objectType <> "objectId" .= host))
      )

checkPath :: Text
checkPath = "/v1/check"

-- | Decode En's answer. Anything that is not a well-formed decision is an
-- unavailable answer: the caller must not read a parse failure as denial.
parseCheckResponse :: ByteString -> Either Text CheckResult
parseCheckResponse bytes = do
  value <- first (const "malformed en check response") (eitherDecodeStrict bytes)
  first (const "malformed en check response") (parseEither response value)
  where
    response :: Value -> Parser CheckResult
    response = withObject "check response" $ \o -> do
      decisionValue <- o .: "decision"
      decision <-
        withObject
          "decision"
          ( \d ->
              d .: "result" >>= \case
                ("allowed" :: Text) -> pure CheckAllowed
                "denied" -> pure CheckDenied
                "conditional" -> CheckConditional <$> d .: "obligations"
                other -> fail ("unknown decision " <> T.unpack other)
          )
          decisionValue
      checkedAt <- o .: "checkedAt"
      grantGeneration <- o .:? "grantGeneration"
      pure Decided {decision, checkedAt, grantGeneration}

-- | One check through a caller-supplied transport: @call path body@ returns
-- En's status and body, or a transport failure. The diagnostic of an
-- unavailable answer names the status and En's problem code and detail when
-- it sent one; it never echoes a request, a header, or a raw body.
effectiveAccess :: (Text -> CheckRequest -> IO (Either Text (Int, ByteString))) -> Text -> Text -> IO CheckReport
effectiveAccess call host subject = effectiveAccessThrough call host subject Nothing

-- | EP-250: as the enforcer decides, the host's own grants first, then, only
-- when they refuse and the host belongs to a delegation, the delegation's.
effectiveAccessThrough :: (Text -> CheckRequest -> IO (Either Text (Int, ByteString))) -> Text -> Text -> Maybe Text -> IO CheckReport
effectiveAccessThrough call host subject delegation = do
  direct <- checked (checkRequest host subject)
  inherited <- case (direct, delegation) of
    (Decided {decision = CheckDenied}, Just name) -> do
      viaDelegation <- checked (CheckRequest "delegation" name subject)
      pure $ case viaDelegation of
        Decided {decision = CheckAllowed} -> Just (viaDelegation, name)
        Decided {} -> Nothing
        Unavailable _ -> Just (viaDelegation, name)
    _ -> pure Nothing
  pure $ case inherited of
    Just (result@Decided {}, name) -> CheckReport {host, subject, result, inheritedFrom = Just name}
    Just (result, _) -> CheckReport {host, subject, result, inheritedFrom = Nothing}
    Nothing -> CheckReport {host, subject, result = direct, inheritedFrom = Nothing}
  where
    checked request = do
      answer <- call checkPath request
      pure $ case answer of
        Left reason -> Unavailable ("en transport failed: " <> reason)
        Right (200, bytes) -> either Unavailable id (parseCheckResponse bytes)
        Right (status, bytes) -> Unavailable (statusDiagnostic status bytes)

statusDiagnostic :: Int -> ByteString -> Text
statusDiagnostic status bytes =
  "en answered HTTP " <> T.pack (show status) <> case problem of
    Just (code, detail) -> " " <> T.take 200 (code <> ": " <> detail)
    Nothing -> " without a problem detail"
  where
    problem = either (const Nothing) Just (eitherDecodeStrict bytes >>= parseEither (withObject "problem" (\o -> (,) <$> o .: "code" <*> o .: "detail")))

-- | The plain rendering: the answer, its snapshot, and the one caveat an
-- operator must know: the gateway may still serve its cached decision for
-- up to its TTL after a change.
renderCheckReport :: CheckReport -> Text
renderCheckReport report =
  T.unlines
    ( [ "host: " <> report ^. #host
      , "subject: user:" <> report ^. #subject
      , "permission: access (fully consistent en check)"
      ]
        <> case report ^. #result of
          Decided {decision, checkedAt, grantGeneration} ->
            [ "decision: " <> decisionLine decision
            , "checked at: " <> checkedAt
            ]
              <> ["grant generation: " <> generation | Just generation <- [grantGeneration]]
              <> ["inherited from: delegation " <> delegation <> " (the host has no grant of its own for this user)" | Just delegation <- [report ^. #inheritedFrom]]
              <> ["note: the gateway may serve its cached decision for up to NAGARE_ACCESS_DECISION_TTL seconds (default 30) after a change; this check read en directly"]
          Unavailable diagnostic -> ["decision: unavailable (" <> diagnostic <> ")", "note: unavailable is not a denial; retry once en answers"]
    )
  where
    decisionLine = \case
      CheckAllowed -> "allowed"
      CheckDenied -> "denied"
      CheckConditional obligations ->
        "conditional; the enforcer refuses it ("
          <> T.intercalate "; " [o ^. #caveat <> " needs " <> T.intercalate ", " (o ^. #missingContext) | o <- obligations]
          <> ")"
