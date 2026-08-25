{-# LANGUAGE OverloadedRecordDot #-}

-- | Adapter from en authorization checks to nagare-access decisions.
module Nagare.Access.En
  ( authorizeWithEn
  , authorizeWithEnClient
  , authorizationFromClientResult
  , buildCheckRequest
  , checkResponseToDecision
  , enClientEnvFromAuthPlane
  )
where

import Control.Exception (try)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import En.Client
  ( CaveatContextWire (..)
  , CheckDecisionWire (..)
  , CheckRequestWire (..)
  , CheckResponseWire (..)
  , ConsistencyWire (..)
  , EnClient (..)
  , EnResult (..)
  , ObjectRefWire (..)
  , SubjectWire (..)
  , enClient
  )
import En.Servant.Seam (ErrorEnvelopeWire (..))
import Nagare.Access.Auth (AuthenticatedUser (..))
import Nagare.Access.Config (AuthPlaneConfig (..))
import Nagare.Access.DecisionCache (AccessDecision (..), AuthorizationResult (..))
import Network.HTTP.Client qualified as HC
import Servant.Client
  ( BaseUrl
  , ClientEnv
  , ClientError
  , InvalidBaseUrlException
  , mkClientEnv
  , parseBaseUrl
  , runClientM
  )

authorizeWithEn :: ClientEnv -> AuthenticatedUser -> Text -> IO AuthorizationResult
authorizeWithEn =
  authorizeWithEnClient enClient

authorizeWithEnClient :: EnClient -> ClientEnv -> AuthenticatedUser -> Text -> IO AuthorizationResult
authorizeWithEnClient client env user host =
  authorizationFromClientResult <$> runClientM (client.check (buildCheckRequest user host)) env

-- | Classify a servant client result without weakening fail-closed authorization.
-- A real refusal is an 'EnOk' carrying 'DeniedWire'. Transport failures and every
-- error envelope mean en did not answer, so they become a 503-producing outage.
authorizationFromClientResult :: Either ClientError (EnResult CheckResponseWire) -> AuthorizationResult
authorizationFromClientResult = \case
  Left transportError -> AuthorizationUnavailable (Text.pack (show transportError))
  Right (EnOk response) -> AuthorizationDecision (checkResponseToDecision response)
  Right (EnClientError envelope) -> AuthorizationUnavailable (envelopeMessage envelope)
  Right (EnPreconditionFailed envelope) -> AuthorizationUnavailable (envelopeMessage envelope)
  Right (EnUnprocessable envelope) -> AuthorizationUnavailable (envelopeMessage envelope)
  Right (EnUnavailable envelope) -> AuthorizationUnavailable (envelopeMessage envelope)

envelopeMessage :: ErrorEnvelopeWire -> Text
envelopeMessage envelope = envelope.code <> ": " <> envelope.message

buildCheckRequest :: AuthenticatedUser -> Text -> CheckRequestWire
buildCheckRequest user host =
  CheckRequestWire
    { consistency = MinimizeLatencyWire
    , context = CaveatContextWire Map.empty
    , subject = SubjectIdWire ObjectRefWire {objectType = "user", objectId = userSubject user}
    , permission = "access"
    , object = ObjectRefWire {objectType = "app", objectId = host}
    }

checkResponseToDecision :: CheckResponseWire -> AccessDecision
checkResponseToDecision response =
  case response.decision of
    AllowedWire -> AccessAllowed
    DeniedWire -> AccessDenied
    ConditionalWire _ -> AccessConditional

enClientEnvFromAuthPlane :: HC.Manager -> AuthPlaneConfig -> IO (Either Text ClientEnv)
enClientEnvFromAuthPlane manager cfg = do
  parsed <- try (parseBaseUrl (Text.unpack (enUrl cfg)) :: IO BaseUrl)
  pure $ case parsed of
    Left (err :: InvalidBaseUrlException) ->
      Left ("could not parse en URL: " <> Text.pack (show err))
    Right baseUrl ->
      Right (mkClientEnv manager baseUrl)
