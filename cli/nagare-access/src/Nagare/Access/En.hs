{-# LANGUAGE OverloadedRecordDot #-}

-- | Adapter from en authorization checks to nagare-access decisions.
module Nagare.Access.En
  ( authorizeWithEn
  , authorizeWithEnClient
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
import Nagare.Access.DecisionCache (AccessDecision (..))
import Network.HTTP.Client qualified as HC
import Servant.Client
  ( BaseUrl
  , ClientEnv
  , InvalidBaseUrlException
  , mkClientEnv
  , parseBaseUrl
  , runClientM
  )

authorizeWithEn :: ClientEnv -> AuthenticatedUser -> Text -> IO AccessDecision
authorizeWithEn =
  authorizeWithEnClient enClient

authorizeWithEnClient :: EnClient -> ClientEnv -> AuthenticatedUser -> Text -> IO AccessDecision
authorizeWithEnClient client env user host = do
  checked <- runClientM (client.check (buildCheckRequest user host)) env
  pure $ case checked of
    Left _ -> AccessDenied
    Right response -> checkResponseToDecision response

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
