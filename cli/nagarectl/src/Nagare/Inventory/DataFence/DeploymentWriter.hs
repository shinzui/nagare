-- | Exact, replay-aware Deployment replica control for a fenced data target.
-- Scaling to zero is only one component of exclusion: callers must also
-- observe the mount guard, Pods, attachments, and other managed clients.
module Nagare.Inventory.DataFence.DeploymentWriter
  ( DeploymentWriterPin
  , mkDeploymentWriterPin
  , writerNamespace
  , writerName
  , writerUid
  , writerSavedReplicas
  , writerSpecDigest
  , digestDeploymentWriterSpec
  , DeploymentWriterTransport (..)
  , kubectlDeploymentWriterTransport
  , stopDeploymentWriter
  , observeDeploymentWriterIdentity
  , observeDeploymentWriterStopped
  , restoreDeploymentWriter
  , observeDeploymentWriterRelease
  , parseDeploymentDrain
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', encode, fromJSON, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence (WriterReleaseState (..))
import Nagare.Inventory.DataFence.MountGuard (validUid)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types (ContentDigest, mkName)
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data DeploymentWriterPin = DeploymentWriterPin
  { writerNamespace :: !Text
  , writerName :: !Text
  , writerUid :: !Text
  , writerSavedReplicas :: !Int
  , writerSpecDigest :: !ContentDigest
  }
  deriving stock (Eq, Show)

mkDeploymentWriterPin :: Text -> Text -> Text -> Int -> ContentDigest
  -> Either Text DeploymentWriterPin
mkDeploymentWriterPin namespace name uid replicas specDigest = do
  _ <- mkName namespace
  _ <- mkName name
  unless (validUid uid) (Left "fenced Deployment UID is not a Kubernetes UUID")
  unless (replicas >= 0) (Left "saved Deployment replicas are negative")
  pure (DeploymentWriterPin namespace name uid replicas specDigest)

-- | Preserve the reviewed live controller spec while allowing only the
-- replica count to move through the fenced stop and release phases.
digestDeploymentWriterSpec :: Value -> Either Text ContentDigest
digestDeploymentWriterSpec (Object root) = do
  spec <- jsonObject "spec" root
  bytes <- canonicalValue (Object (KM.delete "replicas" spec))
  pure (contentDigest bytes)
digestDeploymentWriterSpec _ = Left "Deployment observation is not an object"

data DeploymentWriterTransport = DeploymentWriterTransport
  { readDeploymentWriter :: !(Text -> Text -> IO (Either Text Value))
  , patchDeploymentWriter :: !(Text -> Text -> Value -> IO (Either Text ()))
  , listDeploymentReplicaSets :: !(Text -> IO (Either Text Value))
  , listDeploymentPods :: !(Text -> IO (Either Text Value))
  }

-- | UID and resourceVersion tests make the scale effect conditional at the
-- API server. A lost acknowledgement leaves durable fence recovery to a new
-- observation; it does not authorize blindly repeating the patch.
stopDeploymentWriter :: DeploymentWriterTransport -> DeploymentWriterPin
  -> IO (Either Text ())
stopDeploymentWriter transport pin = do
  current <- readDeploymentWriter transport (writerNamespace pin) (writerName pin)
  case current >>= observedWriter pin of
    Left reason -> pure (Left reason)
    Right writer
      | observedReplicas writer == 0 -> pure (Right ())
      | observedReplicas writer /= writerSavedReplicas pin ->
          pure (Left "Deployment replicas changed since the reviewed writer intent")
      | otherwise -> patchDeploymentWriter transport (writerNamespace pin)
          (writerName pin) (replicaPatch pin writer 0)

observeDeploymentWriterIdentity :: DeploymentWriterTransport -> DeploymentWriterPin
  -> IO (Either Text ())
observeDeploymentWriterIdentity transport pin = do
  current <- readDeploymentWriter transport (writerNamespace pin) (writerName pin)
  pure (() <$ (current >>= observedWriter pin))

observeDeploymentWriterStopped :: DeploymentWriterTransport -> DeploymentWriterPin
  -> IO (Either Text Bool)
observeDeploymentWriterStopped transport pin = do
  current <- readDeploymentWriter transport (writerNamespace pin) (writerName pin)
  replicasets <- listDeploymentReplicaSets transport (writerNamespace pin)
  pods <- listDeploymentPods transport (writerNamespace pin)
  pure $ do
    writer <- current >>= observedWriter pin
    currentReplicaSets <- replicasets
    currentPods <- pods
    drained <- parseDeploymentDrain pin (observedSelector writer)
      currentReplicaSets currentPods
    pure (observedReplicas writer == 0
      && observedStatusReplicas writer == 0
      && observedReadyReplicas writer == 0
      && observedGeneration writer <= observedStatusGeneration writer
      && drained)

restoreDeploymentWriter :: DeploymentWriterTransport -> DeploymentWriterPin
  -> IO (Either Text ())
restoreDeploymentWriter transport pin = do
  current <- readDeploymentWriter transport (writerNamespace pin) (writerName pin)
  case current >>= observedWriter pin of
    Left reason -> pure (Left reason)
    Right writer
      | observedReplicas writer == writerSavedReplicas pin -> pure (Right ())
      | observedReplicas writer /= 0 ->
          pure (Left "Deployment replica intent is partially released")
      | otherwise -> do
          stopped <- observeDeploymentWriterStopped transport pin
          case stopped of
            Left reason -> pure (Left reason)
            Right False -> pure (Left "Deployment has not finished stopping")
            Right True -> patchDeploymentWriter transport (writerNamespace pin)
              (writerName pin) (replicaPatch pin writer (writerSavedReplicas pin))

observeDeploymentWriterRelease :: DeploymentWriterTransport -> DeploymentWriterPin
  -> IO (Either Text WriterReleaseState)
observeDeploymentWriterRelease transport pin = do
  current <- readDeploymentWriter transport (writerNamespace pin) (writerName pin)
  replicasets <- listDeploymentReplicaSets transport (writerNamespace pin)
  pods <- listDeploymentPods transport (writerNamespace pin)
  pure $ do
    writer <- current >>= observedWriter pin
    currentReplicaSets <- replicasets
    currentPods <- pods
    drained <- parseDeploymentDrain pin (observedSelector writer)
      currentReplicaSets currentPods
    pure $ if observedReplicas writer == writerSavedReplicas pin
        && observedReadyReplicas writer == writerSavedReplicas pin
        && observedStatusReplicas writer == writerSavedReplicas pin
        && observedGeneration writer <= observedStatusGeneration writer
      then WritersFullyReleased
      else if observedReplicas writer == 0
        && observedStatusReplicas writer == 0
        && observedReadyReplicas writer == 0
        && observedGeneration writer <= observedStatusGeneration writer
        && drained
      then WritersStillExcluded
      else WritersPartlyReleased

data ObservedWriter = ObservedWriter
  { observedRevision :: !Text
  , observedGeneration :: !Integer
  , observedStatusGeneration :: !Integer
  , observedReplicas :: !Int
  , observedStatusReplicas :: !Int
  , observedReadyReplicas :: !Int
  , observedSelector :: !(Map Text Text)
  }

observedWriter :: DeploymentWriterPin -> Value -> Either Text ObservedWriter
observedWriter pin (Object root) = do
  metadata <- jsonObject "metadata" root
  unless (jsonText "namespace" metadata == Right (writerNamespace pin)
      && jsonText "name" metadata == Right (writerName pin)
      && jsonText "uid" metadata == Right (writerUid pin))
    (Left "Deployment identity changed")
  revision <- jsonText "resourceVersion" metadata
  generation <- jsonInteger "generation" metadata
  observedDigest <- digestDeploymentWriterSpec (Object root)
  unless (observedDigest == writerSpecDigest pin)
    (Left "Deployment template or spec differs from reviewed writer intent")
  spec <- jsonObject "spec" root
  replicas <- jsonInt "replicas" spec
  selector <- jsonObject "selector" spec
  unless (not (KM.member "matchExpressions" selector))
    (Left "Deployment selector expressions lack a drain proof")
  labels <- jsonObject "matchLabels" selector
  selectorLabels <- Map.fromList <$> forM (KM.toList labels) (\(key, value) ->
    case value of
      String selected | not (T.null selected) -> Right (Key.toText key, selected)
      _ -> Left "Deployment selector has a malformed label")
  unless (not (Map.null selectorLabels))
    (Left "Deployment selector has no exact labels")
  status <- jsonObject "status" root
  statusGeneration <- jsonInteger "observedGeneration" status
  statusReplicas <- jsonOptionalInt "replicas" status
  readyReplicas <- jsonOptionalInt "readyReplicas" status
  pure (ObservedWriter revision generation statusGeneration replicas
    statusReplicas readyReplicas selectorLabels)
observedWriter _ _ = Left "Deployment observation is not an object"

-- | Deployment status excludes terminating Pods. Check every owned
-- ReplicaSet and all nonterminal Pods with the reviewed selector or an owned
-- ReplicaSet reference before calling the writer drained.
parseDeploymentDrain :: DeploymentWriterPin -> Map Text Text
  -> Value -> Value -> Either Text Bool
parseDeploymentDrain pin selector replicaSets pods = do
  replicaSetItems <- listItems "ReplicaSetList" replicaSets
  ownedSets <- forM replicaSetItems $ \item -> do
    root <- asObject "ReplicaSet" item
    metadata <- jsonObject "metadata" root
    unless (jsonText "namespace" metadata == Right (writerNamespace pin))
      (Left "ReplicaSet list contains another namespace")
    references <- optionalArray "ownerReferences" metadata
    if not (any (ownedBy "Deployment" (writerName pin) (writerUid pin)) references)
      then pure Nothing
      else do
        name <- jsonText "name" metadata
        uid <- jsonText "uid" metadata
        spec <- jsonObject "spec" root
        desired <- jsonInt "replicas" spec
        status <- jsonObject "status" root
        current <- jsonOptionalInt "replicas" status
        pure (Just (name, uid, desired, current))
  podItems <- listItems "PodList" pods
  activePods <- forM podItems $ \item -> do
    root <- asObject "Pod" item
    metadata <- jsonObject "metadata" root
    unless (jsonText "namespace" metadata == Right (writerNamespace pin))
      (Left "Pod list contains another namespace")
    references <- optionalArray "ownerReferences" metadata
    labels <- optionalLabels metadata
    let selected = all (\(key, value) -> Map.lookup key labels == Just value)
          (Map.toList selector)
        owned = any (\ref -> any (\(name, uid, _, _) ->
          ownedBy "ReplicaSet" name uid ref)
          [replicaSet | Just replicaSet <- ownedSets]) references
        generated = any (replicaSetPrefix (writerName pin)) references
    if not (selected || owned || generated)
      then pure False
      else do
        status <- jsonObject "status" root
        pure (KM.lookup "phase" status `notElem`
          [Just (String "Succeeded"), Just (String "Failed")])
  pure (all (maybe True (\(_, _, desired, current) ->
    desired == 0 && current == 0)) ownedSets && not (or activePods))

replicaSetPrefix :: Text -> Value -> Bool
replicaSetPrefix deployment (Object reference) =
  KM.lookup "kind" reference == Just (String "ReplicaSet")
    && case KM.lookup "name" reference of
      Just (String name) -> (deployment <> "-") `T.isPrefixOf` name
      _ -> False
replicaSetPrefix _ _ = False

ownedBy :: Text -> Text -> Text -> Value -> Bool
ownedBy kind name uid (Object reference) =
  KM.lookup "kind" reference == Just (String kind)
    && KM.lookup "name" reference == Just (String name)
    && KM.lookup "uid" reference == Just (String uid)
ownedBy _ _ _ _ = False

listItems :: Text -> Value -> Either Text [Value]
listItems label value = do
  root <- asObject label value
  case KM.lookup "items" root of
    Just (Array items) -> Right (V.toList items)
    _ -> Left (label <> " lacks items")

asObject :: Text -> Value -> Either Text (KM.KeyMap Value)
asObject _ (Object root) = Right root
asObject label _ = Left (label <> " is not an object")

optionalArray :: Text -> KM.KeyMap Value -> Either Text [Value]
optionalArray field root = case KM.lookup (Key.fromText field) root of
  Nothing -> Right []
  Just (Array items) -> Right (V.toList items)
  _ -> Left ("Deployment observation has malformed " <> field)

optionalLabels :: KM.KeyMap Value -> Either Text (Map Text Text)
optionalLabels metadata = case KM.lookup "labels" metadata of
  Nothing -> Right Map.empty
  Just (Object labels) -> Map.fromList <$> forM (KM.toList labels)
    (\(key, value) -> case value of
      String label -> Right (Key.toText key, label)
      _ -> Left "Deployment Pod labels are malformed")
  _ -> Left "Deployment Pod labels are malformed"

replicaPatch :: DeploymentWriterPin -> ObservedWriter -> Int -> Value
replicaPatch pin observed replicas = toJSON
  [ object ["op" .= ("test" :: Text), "path" .= ("/metadata/uid" :: Text),
      "value" .= writerUid pin]
  , object ["op" .= ("test" :: Text), "path" .= ("/metadata/resourceVersion" :: Text),
      "value" .= observedRevision observed]
  , object ["op" .= ("test" :: Text), "path" .= ("/spec/replicas" :: Text),
      "value" .= observedReplicas observed]
  , object ["op" .= ("replace" :: Text), "path" .= ("/spec/replicas" :: Text),
      "value" .= replicas]
  ]

jsonObject :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
jsonObject field root = case KM.lookup (Key.fromText field) root of
  Just (Object value) -> Right value
  _ -> Left ("Deployment observation lacks " <> field)

jsonText :: Text -> KM.KeyMap Value -> Either Text Text
jsonText field root = case KM.lookup (Key.fromText field) root of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("Deployment observation lacks " <> field)

jsonInteger :: Text -> KM.KeyMap Value -> Either Text Integer
jsonInteger field root = case KM.lookup (Key.fromText field) root of
  Just value | Success number <- (fromJSON value :: Result Int)
    , number >= 0 -> Right (toInteger number)
  _ -> Left ("Deployment observation lacks " <> field)

jsonInt :: Text -> KM.KeyMap Value -> Either Text Int
jsonInt field root = do
  number <- jsonInteger field root
  if number <= toInteger (maxBound :: Int)
    then Right (fromInteger number)
    else Left ("Deployment " <> field <> " exceeds Int")

jsonOptionalInt :: Text -> KM.KeyMap Value -> Either Text Int
jsonOptionalInt field root = case KM.lookup (Key.fromText field) root of
  Nothing -> Right 0
  Just _ -> jsonInt field root

kubectlDeploymentWriterTransport :: KubernetesRuntimeConfig
  -> DeploymentWriterTransport
kubectlDeploymentWriterTransport config = DeploymentWriterTransport
  readOne patchOne listReplicaSets listPods
  where
    invoke arguments input = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          result <- try (readProcessWithExitCode "kubectl"
            (["--context", T.unpack (runtimeKubectlContext config),
              "--request-timeout=10s"] <> arguments) input)
          pure $ case result of
            Left (_ :: IOException) -> Left "could not invoke kubectl"
            Right output -> Right output
    readOne namespace name = do
      result <- invoke ["--namespace", T.unpack namespace, "get", "deployment",
        T.unpack name, "-o", "json"] ""
      pure $ case result of
        Left reason -> Left reason
        Right (ExitFailure _, _, _) -> Left "could not read fenced Deployment"
        Right (ExitSuccess, output, _) -> first T.pack
          (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
    patchOne namespace name patch = do
      result <- invoke ["--namespace", T.unpack namespace, "patch", "deployment",
        T.unpack name, "--type=json", "-p",
        T.unpack (TE.decodeUtf8 (BL.toStrict (encode patch)))] ""
      pure $ case result of
        Left reason -> Left reason
        Right (ExitFailure _, _, _) -> Left "conditional Deployment replica patch failed"
        Right (ExitSuccess, _, _) -> Right ()
    listReplicaSets namespace = listOne namespace "replicasets"
    listPods namespace = listOne namespace "pods"
    listOne namespace kind = do
      result <- invoke ["--namespace", T.unpack namespace, "get", kind,
        "-o", "json"] ""
      pure $ case result of
        Left reason -> Left reason
        Right (ExitFailure _, _, _) -> Left "could not list Deployment Pods or ReplicaSets"
        Right (ExitSuccess, output, _) -> first T.pack
          (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
