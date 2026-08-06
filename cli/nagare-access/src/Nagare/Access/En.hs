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
  , ObjectRefWire (..)
  , SubjectWire (..)
  , enClient
  )
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

-- | Classify a servant client result. Every 'Left' here is transport-level —
-- connection refused, timeout, DNS failure, a non-2xx status, an undecodable
-- body — because en expresses a genuine refusal as
-- @Right (CheckResponseWire DeniedWire)@. So mapping all 'Left's to
-- 'AuthorizationUnavailable' is exact, not lenient: it never turns a real
-- denial into an outage.
authorizationFromClientResult :: Either ClientError CheckResponseWire -> AuthorizationResult
authorizationFromClientResult =
  either
    (AuthorizationUnavailable . Text.pack . show)
    (AuthorizationDecision . checkResponseToDecision)

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
