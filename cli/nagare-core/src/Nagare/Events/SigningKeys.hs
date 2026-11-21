{-# LANGUAGE OverloadedStrings #-}

-- | Signing keys read from inside the cluster (EP-235): the lifecycle
-- worker's ServiceAccount reads named Secret fields through the Kubernetes
-- API, with the projected token and the cluster CA, never a subprocess. It
-- returns the field's value with the Secret's UID, so a caller binds the key
-- to the recorded incarnation. Values never reach a log or an error.
module Nagare.Events.SigningKeys
  ( SecretRead
  , inClusterSecrets
  , secretFieldFrom
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteArray.Encoding (Base (Base64), convertFromBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Default (def)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.X509.CertificateStore (readCertificateStore)
import Nagare.Dsl.Prelude
import Network.Connection qualified as NC
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Types (statusCode)
import Network.TLS qualified as TLS
import Network.TLS.Extra.Cipher qualified as TLS
import System.Environment (lookupEnv)

-- | Read one field of a named Secret: its decoded value and the Secret's UID.
type SecretRead = Text -> Text -> Text -> IO (Either Text (ByteString, Text))

-- | The in-cluster reader, from the ServiceAccount's mounted token and CA
-- and the API server's address in the environment.
inClusterSecrets :: IO (Either Text SecretRead)
inClusterSecrets = do
  hostVar <- lookupEnv "KUBERNETES_SERVICE_HOST"
  portVar <- lookupEnv "KUBERNETES_SERVICE_PORT"
  let directory = "/var/run/secrets/kubernetes.io/serviceaccount"
  store <- readCertificateStore (directory <> "/ca.crt")
  case (hostVar, portVar, store) of
    (Just host, Just port, Just ca) -> do
      let client =
            (TLS.defaultParamsClient host "")
              { TLS.clientShared = def {TLS.sharedCAStore = ca}
              , TLS.clientSupported = def {TLS.supportedCiphers = TLS.ciphersuite_default}
              }
      manager <- HTTP.newManager (mkManagerSettings (NC.TLSSettings client) Nothing)
      pure . Right $ \namespace name field -> do
        token <- BS.readFile (directory <> "/token")
        result <- try $ do
          initial <- HTTP.parseRequest ("https://" <> host <> ":" <> port <> "/api/v1/namespaces/" <> T.unpack namespace <> "/secrets/" <> T.unpack name)
          HTTP.httpLbs initial {HTTP.requestHeaders = [("Authorization", "Bearer " <> BS.takeWhile (/= 10) token), ("Accept", "application/json")]} manager
        pure $ case result of
          Left (_ :: SomeException) -> Left "the Kubernetes API could not be reached"
          Right response
            | statusCode (HTTP.responseStatus response) == 200 -> secretFieldFrom field (LBS.toStrict (HTTP.responseBody response))
            | statusCode (HTTP.responseStatus response) == 404 -> Left ("Secret " <> namespace <> "/" <> name <> " does not exist")
            | statusCode (HTTP.responseStatus response) == 403 -> Left ("the worker may not read Secret " <> namespace <> "/" <> name)
            | otherwise -> Left ("the Kubernetes API answered " <> T.pack (show (statusCode (HTTP.responseStatus response))))
    _ -> pure (Left "not inside a cluster: no Kubernetes service address, token or CA")

-- | One field of a Secret document, decoded, and the Secret's UID.
secretFieldFrom :: Text -> ByteString -> Either Text (ByteString, Text)
secretFieldFrom field bytes = do
  value <- first (const "the Secret is not JSON") (eitherDecodeStrict bytes)
  case value of
    Object root
      | Just (Object metadata) <- KM.lookup "metadata" root
      , Just (String uid) <- KM.lookup "uid" metadata
      , Just (Object fields) <- KM.lookup "data" root ->
          case KM.lookup (Key.fromText field) fields of
            Just (String encoded) -> (\decoded -> (decoded, uid)) <$> first (const "the Secret field is not base64") (convertFromBase Base64 (TE.encodeUtf8 encoded))
            _ -> Left ("the Secret has no field " <> field)
    _ -> Left "the Secret has no UID or data"
