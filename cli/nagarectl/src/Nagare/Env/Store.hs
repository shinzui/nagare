-- | Per-app, per-scope environment and secret store (EP-24).
--
-- A small, tested library any command can use to read, merge or replace, and
-- write the key/value store backing an app's environment variables. Non-secret
-- values live in a Kubernetes ConfigMap (plaintext @data@); secret values live
-- in a Kubernetes Secret (base64-encoded @data@, type @Opaque@). The resource
-- names come from EP-23's IP2 helpers so they match what the rendered Knative
-- Service references via @envFrom@.
--
-- SECURITY CAVEAT: ConfigMap values are plaintext. Secret values are base64 —
-- an encoding, not encryption: anyone holding the bytes can decode them. The
-- base64 is only the Kubernetes Secret wire format. Real protection
-- (encryption-at-rest, RBAC) is cluster configuration and is OUT OF SCOPE here.
--
-- The pure layer (reconcile, render, extract) is separated from the thin
-- @kubectl@ IO layer, mirroring "Nagare.Static.Release", so the schema is
-- unit-testable without a cluster.
module Nagare.Env.Store
  ( ReconcileMode (..)
  , reconcile
  , renderEnvConfigMap
  , renderEnvSecret
  , extractConfigMapData
  , extractSecretData
  , readEnvStore
  , readSecretStore
  , writeEnvStore
  , writeSecretStore
  )
where

import Cradle
import Data.Aeson
  ( eitherDecodeStrict
  , encode
  , object
  , (.=)
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (Base64), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Deploy (applyManifests)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Render (managedConfigMapName, managedSecretName) -- EP-23 IP2
import Nagare.Dsl.Types (EnvScope (..)) -- EP-23 IP2
import System.Exit (ExitCode (..))

-- | How an incoming key/value set is combined with the existing one.
data ReconcileMode
  = -- | Union; incoming wins on collision; existing-only keys are kept.
    Merge
  | -- | The incoming set becomes the whole store; existing-only keys are dropped.
    ReconcileExact
  deriving stock (Eq, Show)

-- | Compute the desired store from the existing store and the incoming entries.
--
-- A single-key /set/ is @reconcile Merge existing (Map.singleton k v)@. A
-- /delete/ is expressed by passing the post-deletion map as the incoming set
-- with 'ReconcileExact' (i.e. @reconcile ReconcileExact existing (Map.delete k
-- existing)@). 'Merge' is the intended conservative default for the EP-25 CLI;
-- 'ReconcileExact' is the destructive, opt-in mode.
reconcile :: ReconcileMode -> Map Text Text -> Map Text Text -> Map Text Text
reconcile Merge existing incoming = Map.union incoming existing -- left-biased: incoming wins
reconcile ReconcileExact _existing incoming = incoming

-- | Render the ConfigMap (JSON bytes that @kubectl apply -f@ accepts) holding
-- @kvs@ as plaintext for @app@ in @ns@ at @scope@, named per IP2.
renderEnvConfigMap :: Text -> Text -> EnvScope -> Map Text Text -> ByteString
renderEnvConfigMap app ns scope kvs =
  LBS.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("ConfigMap" :: Text)
      , "metadata"
          .= object
            [ "name" .= managedConfigMapName app scope
            , "namespace" .= ns
            ]
      , "data" .= dataObject id kvs
      ]

-- | Render the Secret (JSON bytes) holding @kvs@ base64-encoded for @app@ in
-- @ns@ at @scope@, type @Opaque@, named per IP2.
renderEnvSecret :: Text -> Text -> EnvScope -> Map Text Text -> ByteString
renderEnvSecret app ns scope kvs =
  LBS.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Secret" :: Text)
      , "type" .= ("Opaque" :: Text)
      , "metadata"
          .= object
            [ "name" .= managedSecretName app scope
            , "namespace" .= ns
            ]
      , "data" .= dataObject b64encode kvs
      ]

-- | Build a stable, sorted @data@ JSON object, mapping each value through @f@.
-- Sorted key order (via 'Map.toAscList') keeps the byte output deterministic.
dataObject :: (Text -> Text) -> Map Text Text -> Aeson.Value
dataObject f kvs =
  object [Key.fromText k .= f v | (k, v) <- Map.toAscList kvs]

-- | Parse @kubectl get configmap ... -o json@ into a plaintext map. Missing
-- @data@ yields an empty map; a JSON decode failure is 'Left'.
extractConfigMapData :: ByteString -> Either Text (Map Text Text)
extractConfigMapData = extractData Right

-- | Parse @kubectl get secret ... -o json@ into a map, base64-DECODING values.
-- Missing @data@ yields empty; a JSON or base64 decode failure is 'Left'.
extractSecretData :: ByteString -> Either Text (Map Text Text)
extractSecretData = extractData b64decode

-- | Shared extractor: decode the outer object, read the @data@ map of string
-- values, and run each value through @f@ (identity for ConfigMap, base64-decode
-- for Secret). Strict: non-string values or a failing @f@ are 'Left'.
extractData :: (Text -> Either Text Text) -> ByteString -> Either Text (Map Text Text)
extractData f bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode resource JSON: " <> T.pack e)
    Right v -> case dataMap v of
      Nothing -> Right Map.empty
      Just kvs -> traverse f kvs
  where
    dataMap :: Aeson.Value -> Maybe (Map Text Text)
    dataMap val = do
      Aeson.Object o <- Just val
      case KeyMap.lookup (Key.fromText "data") o of
        Just (Aeson.Object d) ->
          Just (Map.fromList [(Key.toText k, s) | (k, Aeson.String s) <- KeyMap.toList d])
        _ -> Nothing

-- base64 helpers (isolate the codec choice behind these two functions). We use
-- 'Data.ByteArray.Encoding' from the @memory@ package, already a dependency of
-- nagarectl, rather than adding @base64@/@base64-bytestring@ — see Decision Log.
b64encode :: Text -> Text
b64encode t = TE.decodeUtf8 (convertToBase Base64 (TE.encodeUtf8 t))

b64decode :: Text -> Either Text Text
b64decode t =
  case convertFromBase Base64 (TE.encodeUtf8 t) :: Either String ByteString of
    Left e -> Left ("could not base64-decode secret value: " <> T.pack e)
    Right bs ->
      case TE.decodeUtf8' bs of
        Left _ -> Left "secret value is not valid UTF-8 after base64 decoding"
        Right value -> Right value

-- ---------------------------------------------------------------------------
-- kubectl IO (thin shell; mirrors Nagare.Static.Release.read/writeReleaseLog)

-- | Read the ConfigMap-backed env store for @app@/@scope@ in @ns@. A missing
-- ConfigMap (non-zero exit) is an empty map; a present-but-malformed one is
-- 'Left'.
readEnvStore :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
readEnvStore app ns scope =
  readStore "configmap" (managedConfigMapName app scope) ns extractConfigMapData

-- | Read the Secret-backed store, base64-decoding values. Missing ⇒ empty map.
readSecretStore :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
readSecretStore app ns scope =
  readStore "secret" (managedSecretName app scope) ns extractSecretData

readStore ::
  String ->
  Text ->
  Text ->
  (ByteString -> Either Text (Map Text Text)) ->
  IO (Either Text (Map Text Text))
readStore kind name ns extract = do
  (exitCode, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs ["get", kind, T.unpack name, "-n", T.unpack ns, "-o", "json"]
        & silenceStderr
  pure $ case exitCode of
    ExitFailure _ -> Right Map.empty
    ExitSuccess -> extract out

-- | Persist the ConfigMap-backed store by applying the rendered manifest.
writeEnvStore :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
writeEnvStore app ns scope kvs = applyManifests [renderEnvConfigMap app ns scope kvs]

-- | Persist the Secret-backed store by applying the rendered manifest.
writeSecretStore :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
writeSecretStore app ns scope kvs = applyManifests [renderEnvSecret app ns scope kvs]
