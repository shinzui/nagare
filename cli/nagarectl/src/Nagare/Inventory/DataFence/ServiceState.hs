-- | Read-only evidence for the exact Service routing a fenced database.
-- Every EndpointSlice endpoint and legacy Endpoints address is counted,
-- including unready or terminating entries, until the route is empty.
module Nagare.Inventory.DataFence.ServiceState
  ( ServicePin (..)
  , mkServicePin
  , ServiceEvidence (..)
  , ServiceTransport (..)
  , kubectlServiceTransport
  , observeServiceState
  , serviceHasNoEndpoints
  , parseServiceEvidence
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence.MountGuard (validUid)
import Nagare.Resource.Types (ResourceId, mkName)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data ServicePin = ServicePin
  { serviceResource :: !ResourceId
  , serviceNamespace :: !Text
  , serviceName :: !Text
  , serviceUid :: !Text
  , serviceClusterIP :: !Text
  , serviceSelector :: !(Map Text Text)
  }
  deriving stock (Eq, Show)

mkServicePin :: ResourceId -> Text -> Text -> Text -> Text
  -> Map Text Text -> Either Text ServicePin
mkServicePin resource namespace name uid clusterIP selector = do
  _ <- mkName namespace
  _ <- mkName name
  unless (validUid uid) (Left "fenced Service UID is not a Kubernetes UUID")
  unless (not (T.null clusterIP) && T.all (>= ' ') clusterIP)
    (Left "fenced Service clusterIP is invalid")
  unless (not (Map.null selector)
      && all (\(key, value) -> not (T.null key) && not (T.null value)
        && T.all (>= ' ') key && T.all (>= ' ') value)
        (Map.toList selector))
    (Left "fenced Service selector is empty or malformed")
  pure (ServicePin resource namespace name uid clusterIP selector)

data ServiceEvidence = ServiceEvidence
  { serviceSliceEndpoints :: ![Text]
  , serviceLegacyEndpoints :: ![Text]
  }
  deriving stock (Eq, Show)

data ServiceTransport = ServiceTransport
  { readService :: !(Text -> Text -> IO (Either Text Value))
  , listEndpointSlices :: !(Text -> IO (Either Text Value))
  , readLegacyEndpoints :: !(Text -> Text -> IO (Either Text (Maybe Value)))
  }

observeServiceState :: ServiceTransport -> ServicePin
  -> IO (Either Text ServiceEvidence)
observeServiceState transport pin = do
  service <- readService transport (serviceNamespace pin) (serviceName pin)
  slices <- listEndpointSlices transport (serviceNamespace pin)
  legacy <- readLegacyEndpoints transport (serviceNamespace pin) (serviceName pin)
  pure $ do
    current <- service
    currentSlices <- slices
    currentLegacy <- legacy
    parseServiceEvidence pin current currentSlices currentLegacy

serviceHasNoEndpoints :: ServiceEvidence -> Bool
serviceHasNoEndpoints evidence = null (serviceSliceEndpoints evidence)
  && null (serviceLegacyEndpoints evidence)

parseServiceEvidence :: ServicePin -> Value -> Value -> Maybe Value
  -> Either Text ServiceEvidence
parseServiceEvidence pin service slices legacy = do
  serviceRoot <- asObject "Service" service
  metadata <- objectField "metadata" serviceRoot
  unless (textField "namespace" metadata == Right (serviceNamespace pin)
      && textField "name" metadata == Right (serviceName pin)
      && textField "uid" metadata == Right (serviceUid pin))
    (Left "fenced Service identity changed")
  spec <- objectField "spec" serviceRoot
  unless (textField "clusterIP" spec == Right (serviceClusterIP pin))
    (Left "fenced Service clusterIP changed")
  selector <- stringMapField "selector" spec
  unless (selector == serviceSelector pin)
    (Left "fenced Service selector changed")

  sliceRoot <- asObject "EndpointSliceList" slices
  sliceItems <- arrayField "items" sliceRoot
  sliceEndpoints <- forM sliceItems $ \item -> do
    slice <- asObject "EndpointSlice" item
    sliceMeta <- objectField "metadata" slice
    unless (textField "namespace" sliceMeta == Right (serviceNamespace pin))
      (Left "EndpointSlice list contains another namespace")
    labels <- optionalStringMapField "labels" sliceMeta
    if Map.lookup "kubernetes.io/service-name" labels /= Just (serviceName pin)
      then pure []
      else do
        name <- textField "name" sliceMeta
        uid <- textField "uid" sliceMeta
        endpoints <- optionalArrayField "endpoints" slice
        pure [name <> "/" <> uid <> "/" <> T.pack (show position)
          | position <- [0 :: Int .. length endpoints - 1]]

  legacyEndpoints <- case legacy of
    Nothing -> Right []
    Just value -> do
      endpoint <- asObject "Endpoints" value
      endpointMeta <- objectField "metadata" endpoint
      unless (textField "namespace" endpointMeta == Right (serviceNamespace pin)
          && textField "name" endpointMeta == Right (serviceName pin))
        (Left "fenced legacy Endpoints identity changed")
      subsets <- optionalArrayField "subsets" endpoint
      fmap concat $ forM subsets $ \entry -> do
        subset <- asObject "Endpoints subset" entry
        ready <- optionalArrayField "addresses" subset
        unready <- optionalArrayField "notReadyAddresses" subset
        pure ["legacy/" <> T.pack (show position)
          | position <- [0 :: Int .. length ready + length unready - 1]]
  pure (ServiceEvidence (concat sliceEndpoints) legacyEndpoints)

asObject :: Text -> Value -> Either Text (KM.KeyMap Value)
asObject _ (Object value) = Right value
asObject label _ = Left (label <> " is not an object")

objectField :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
objectField key root = case KM.lookup (Key.fromText key) root of
  Just (Object value) -> Right value
  _ -> Left ("Service evidence lacks " <> key)

textField :: Text -> KM.KeyMap Value -> Either Text Text
textField key root = case KM.lookup (Key.fromText key) root of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("Service evidence lacks " <> key)

arrayField :: Text -> KM.KeyMap Value -> Either Text [Value]
arrayField key root = case KM.lookup (Key.fromText key) root of
  Just (Array value) -> Right (V.toList value)
  _ -> Left ("Service evidence lacks " <> key)

optionalArrayField :: Text -> KM.KeyMap Value -> Either Text [Value]
optionalArrayField key root = case KM.lookup (Key.fromText key) root of
  Nothing -> Right []
  Just Null -> Right []
  Just _ -> arrayField key root

stringMapField :: Text -> KM.KeyMap Value -> Either Text (Map Text Text)
stringMapField key root = do
  object <- objectField key root
  pairs <- forM (KM.toList object) $ \(entry, value) -> case value of
    String content -> Right (Key.toText entry, content)
    _ -> Left ("Service " <> key <> " has a non-string value")
  pure (Map.fromList pairs)

optionalStringMapField :: Text -> KM.KeyMap Value -> Either Text (Map Text Text)
optionalStringMapField key root = case KM.lookup (Key.fromText key) root of
  Nothing -> Right Map.empty
  Just Null -> Right Map.empty
  Just _ -> stringMapField key root

kubectlServiceTransport :: KubernetesRuntimeConfig -> ServiceTransport
kubectlServiceTransport config = ServiceTransport service slices legacy
  where
    service namespace name = fmap (>>= decodeValue) $ invoke
      ["--namespace", T.unpack namespace,
        "get", "service", T.unpack name, "-o", "json"]
    slices namespace = fmap (>>= decodeValue) $ invoke
      ["--namespace", T.unpack namespace,
        "get", "endpointslices.discovery.k8s.io", "-o", "json"]
    legacy namespace name = do
      result <- invoke ["--namespace", T.unpack namespace,
        "get", "endpoints", T.unpack name, "-o", "json", "--ignore-not-found"]
      pure $ do
        output <- result
        if T.null (T.strip output) then Right Nothing
          else Just <$> decodeValue output
    decodeValue = first T.pack . eitherDecodeStrict' . TE.encodeUtf8
    invoke arguments = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          result <- try (readProcessWithExitCode "kubectl"
            (["--context", T.unpack (runtimeKubectlContext config),
              "--request-timeout=10s"] <> arguments) "")
          pure $ case result of
            Left (_ :: IOException) -> Left "could not invoke kubectl"
            Right (ExitFailure _, _, _) -> Left "could not read fenced Service endpoints"
            Right (ExitSuccess, output, _) -> Right (T.pack output)
