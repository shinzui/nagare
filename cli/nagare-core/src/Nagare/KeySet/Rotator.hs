-- | One run of a key set's rotator (EP-286 M2). It reads the key set's
-- Secret and public ConfigMap, applies 'rotateStep', and writes what changed:
-- the ConfigMap first, then the Secret, each replaced only at the
-- resourceVersion it read.
--
-- The order makes every crash harmless. A crash between the writes leaves
-- verifiers knowing a key no signer holds, and the next run rebuilds the
-- public file from the Secret, which is the only source of the state. A
-- conflict on either write ends the run; the next one starts again.
module Nagare.KeySet.Rotator
  ( KubeObjects (..)
  , WriteFailure (..)
  , RotationRun (..)
  , keySetSecretName
  , keySetPublicName
  , keySetFieldManager
  , privateFileKey
  , publicFileKey
  , policyFileKey
  , rotateOnce
  , generateKeyPair
  , keyPairFromSeed
  , inClusterObjects
  , decodePolicy
  , encodePolicy
  )
where

import Control.Exception (SomeException, try)
import Crypto.ECC.Edwards25519 qualified as Edwards25519
import Crypto.Error (eitherCryptoError)
import Crypto.Hash (SHA512 (..), hashWith)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (..), eitherDecodeStrict, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.Bits ((.&.), (.|.))
import Data.ByteArray.Encoding (Base (Base16, Base64), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Default (def)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.X509.CertificateStore (readCertificateStore)
import Nagare.Dsl.KeySet (KeySetName, RotationPolicy, keySetNameText, minutesInt, mkMinutes, mkRotationPolicy)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.KeySet
import Network.Connection qualified as NC
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Types (statusCode)
import Network.TLS qualified as TLS
import Network.TLS.Extra.Cipher qualified as TLS
import System.Environment (lookupEnv)

-- | The two object reads and replacements the rotator needs, by resource
-- (@configmaps@ or @secrets@), namespace and name. A read of an absent object
-- is 'Nothing'.
data KubeObjects = KubeObjects
  { readObject :: !(Text -> Text -> Text -> IO (Either Text (Maybe Value)))
  , replaceObject :: !(Text -> Text -> Text -> Value -> IO (Either WriteFailure ()))
  }

data WriteFailure
  = -- | The object changed since it was read.
    WriteConflict
  | WriteRefused !Text
  deriving stock (Eq, Show)

data RotationRun
  = -- | Nothing to do: the state and the public file are current.
    Unchanged
  | -- | Only the public file was rewritten from the Secret.
    PublicRestored
  | Rotated ![RotationEvent]
  deriving stock (Eq, Show)

keySetSecretName :: KeySetName -> Text
keySetSecretName name = "nagare-keyset-" <> keySetNameText name

keySetPublicName :: KeySetName -> Text
keySetPublicName name = keySetSecretName name <> "-public"

-- | The field manager the rotator writes as. The inventory adapter accepts
-- this manager owning exactly the key file of each object, and nothing else.
keySetFieldManager :: Text
keySetFieldManager = "nagare-keyset"

-- | The Secret's one key, the private file.
privateFileKey :: Text
privateFileKey = "private.json"

-- | The ConfigMap's key data, written by the rotator.
publicFileKey :: Text
publicFileKey = "public.json"

-- | The ConfigMap's reviewed part, written by nagarectl.
policyFileKey :: Text
policyFileKey = "policy.json"

encodePolicy :: RotationPolicy -> Text
encodePolicy policy =
  TE.decodeUtf8 . LBS.toStrict . Aeson.encode $
    object ["periodMinutes" .= minutesInt (policy ^. #period), "overlapMinutes" .= minutesInt (policy ^. #overlap)]

decodePolicy :: Text -> Either Text RotationPolicy
decodePolicy raw = do
  value <- first T.pack (eitherDecodeStrict (TE.encodeUtf8 raw) :: Either String Value)
  (period', overlap') <- first T.pack (parseEither (withObject "policy" (\o -> (,) <$> o .: "periodMinutes" <*> o .: "overlapMinutes")) value)
  periodMinutes <- mkMinutes period'
  overlapMinutes <- mkMinutes overlap'
  mkRotationPolicy periodMinutes overlapMinutes

-- | One run at @now@ with fresh keys. It fails without writing when the
-- ConfigMap is absent or carries no valid policy, and when the Secret is
-- absent or holds a private file that does not decode: a run never replaces
-- keys it cannot read.
rotateOnce :: KubeObjects -> UTCTime -> [KeyPair] -> Text -> KeySetName -> IO (Either Text RotationRun)
rotateOnce kube now fresh namespace name = do
  configMap <- readObject kube "configmaps" namespace (keySetPublicName name)
  secret <- readObject kube "secrets" namespace (keySetSecretName name)
  case (configMap, secret) of
    (Left reason, _) -> pure (Left reason)
    (_, Left reason) -> pure (Left reason)
    (Right Nothing, _) -> pure (Left ("ConfigMap " <> namespace <> "/" <> keySetPublicName name <> " does not exist"))
    (_, Right Nothing) -> pure (Left ("Secret " <> namespace <> "/" <> keySetSecretName name <> " does not exist"))
    (Right (Just publicObject), Right (Just secretObject)) -> case plan publicObject secretObject of
      Left reason -> pure (Left reason)
      Right (policy, state, published) -> do
        let (state', events) = rotateStep now policy fresh state
            publicFile = TE.decodeUtf8 (LBS.toStrict (encodePublicKeySet policy state'))
            changed = state' /= state
        if not changed && published == Just publicFile
          then pure (Right Unchanged)
          else do
            written <- replaceObject kube "configmaps" namespace (keySetPublicName name) (withField False publicFileKey publicFile publicObject)
            case written of
              Left failure -> pure (Left (describe "ConfigMap" failure))
              Right ()
                | not changed -> pure (Right PublicRestored)
                | otherwise -> do
                    let privateFile = TE.decodeUtf8 (LBS.toStrict (encodePrivateKeySet policy state'))
                    stored <- replaceObject kube "secrets" namespace (keySetSecretName name) (withField True privateFileKey privateFile secretObject)
                    pure (either (Left . describe "Secret") (const (Right (Rotated events))) stored)
  where
    describe kind = \case
      WriteConflict -> kind <> " changed while the rotator ran; the next run retries"
      WriteRefused reason -> kind <> " was not written: " <> reason
    plan publicObject secretObject = do
      rawPolicy <- maybe (Left "the ConfigMap has no policy.json") Right (field False policyFileKey publicObject)
      policy <- first ("the ConfigMap's policy is invalid: " <>) (decodePolicy rawPolicy)
      state <- case field True privateFileKey secretObject of
        Nothing -> Right emptyKeySet
        Just raw -> first ("the Secret's private file does not decode: " <>) (decodeKeySet (TE.encodeUtf8 raw))
      pure (policy, state, field False publicFileKey publicObject)

-- | A data field of an object, base64-decoded for a Secret.
field :: Bool -> Text -> Value -> Maybe Text
field encoded name = \case
  Object root
    | Just (Object fields) <- KM.lookup "data" root
    , Just (String value) <- KM.lookup (Key.fromText name) fields ->
        if encoded
          then either (const Nothing) (Just . TE.decodeUtf8) (convertFromBase Base64 (TE.encodeUtf8 value) :: Either String ByteString)
          else Just value
  _ -> Nothing

-- | The object as read, with one data field set: it keeps its
-- resourceVersion, so the replacement is refused if the object moved.
withField :: Bool -> Text -> Text -> Value -> Value
withField encoded name value = \case
  Object root ->
    let fields = case KM.lookup "data" root of
          Just (Object existing) -> existing
          _ -> KM.empty
        stored = if encoded then TE.decodeUtf8 (convertToBase Base64 (TE.encodeUtf8 value)) else value
     in Object (KM.insert "data" (Object (KM.insert (Key.fromText name) (String stored) fields)) root)
  other -> other

-- | A fresh Ed25519 key: the public key and the 32-byte seed.
generateKeyPair :: IO KeyPair
generateKeyPair = do
  seed <- getRandomBytes 32
  either (ioError . userError . T.unpack) pure (keyPairFromSeed seed)

-- | The key pair of a 32-byte seed, as RFC 8032 section 5.1.5 derives it:
-- the low half of SHA-512(seed), clamped, is the scalar, and the public key
-- is the encoded point. It is written with crypton's polymorphic encoders so
-- that no byte-array class is named: the Nix build's crypton is built on
-- @memory@ and the cabal build's on @ram@, and their classes differ.
keyPairFromSeed :: ByteString -> Either Text KeyPair
keyPairFromSeed seed = do
  when (BS.length seed /= 32) (Left "an Ed25519 seed has 32 bytes")
  digest <- first T.pack (convertFromBase Base16 (TE.encodeUtf8 (T.pack (show (hashWith SHA512 seed)))) :: Either String ByteString)
  let low = BS.take 32 digest
      clamped = BS.pack (zipWith clamp [0 :: Int ..] (BS.unpack low))
      clamp index byte
        | index == 0 = byte .&. 248
        | index == 31 = (byte .&. 127) .|. 64
        | otherwise = byte
  scalar <- first (T.pack . show) (eitherCryptoError (Edwards25519.scalarDecodeLong clamped))
  pure (KeyPair (Edwards25519.pointEncode (Edwards25519.toPoint scalar)) seed)

-- | The in-cluster client, from the ServiceAccount's mounted token and CA.
inClusterObjects :: IO (Either Text KubeObjects)
inClusterObjects = do
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
      let call method resource namespace name body = do
            token <- BS.readFile (directory <> "/token")
            try $ do
              initial <- HTTP.parseRequest ("https://" <> host <> ":" <> port <> "/api/v1/namespaces/" <> T.unpack namespace <> "/" <> T.unpack resource <> "/" <> T.unpack name <> (if method == "PUT" then "?fieldManager=" <> T.unpack keySetFieldManager else ""))
              HTTP.httpLbs
                initial
                  { HTTP.method = method
                  , HTTP.requestHeaders = [("Authorization", "Bearer " <> BS.takeWhile (/= 10) token), ("Accept", "application/json"), ("Content-Type", "application/json")]
                  , HTTP.requestBody = maybe mempty (HTTP.RequestBodyLBS . Aeson.encode) body
                  }
                manager
          status = statusCode . HTTP.responseStatus
      pure . Right $
        KubeObjects
          { readObject = \resource namespace name ->
              call "GET" resource namespace name Nothing <&> \case
                Left (_ :: SomeException) -> Left "the Kubernetes API could not be reached"
                Right response
                  | status response == 200 -> first (const "the object is not JSON") (Just <$> eitherDecodeStrict (LBS.toStrict (HTTP.responseBody response)))
                  | status response == 404 -> Right Nothing
                  | otherwise -> Left ("the Kubernetes API answered " <> T.show (status response) <> " to a read of " <> resource <> "/" <> name)
          , replaceObject = \resource namespace name value ->
              call "PUT" resource namespace name (Just value) <&> \case
                Left (_ :: SomeException) -> Left (WriteRefused "the Kubernetes API could not be reached")
                Right response
                  | status response == 200 -> Right ()
                  | status response == 409 -> Left WriteConflict
                  | otherwise -> Left (WriteRefused ("the Kubernetes API answered " <> T.show (status response)))
          }
    _ -> pure (Left "not inside a cluster: no Kubernetes service address, token or CA")
