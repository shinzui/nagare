-- | Read-only evidence for an exact Kubernetes PVC and its bound volume.
-- This evidence is useful only while a separately observed admission guard
-- prevents new mounts and identity mutations.
module Nagare.Inventory.DataFence.VolumeState
  ( VolumeBacking (..)
  , VolumeEvidence (..)
  , VolumeTransport (..)
  , kubectlVolumeTransport
  , observeVolumeState
  , observeGuardedVolumeExcluded
  , parseVolumeEvidence
  , volumeHasNoConsumers
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (..)
  )
import Nagare.Inventory.DataFence.MountGuard
import Nagare.Inventory.DataFence.MountGuardRuntime
  ( MountGuardTransport
  , observeMountGuard
  )
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data VolumeBacking
  = CsiVolume !Text !Text
  | LocalVolume !Text !Text
  deriving stock (Eq, Show)

data VolumeEvidence = VolumeEvidence
  { volumePodConsumers :: ![Text]
  , volumeAttachmentConsumers :: ![Text]
  }
  deriving stock (Eq, Show)

data VolumeTransport = VolumeTransport
  { readClaim :: !(Text -> Text -> IO (Either Text Value))
  , readVolume :: !(Text -> IO (Either Text Value))
  , listNamespacePods :: !(Text -> IO (Either Text Value))
  , listVolumeAttachments :: !(IO (Either Text Value))
  }

observeVolumeState ::
  VolumeTransport ->
  MountGuard ->
  VolumeBacking ->
  IO (Either Text VolumeEvidence)
observeVolumeState transport mountGuard backing = do
  let namespace = guardNamespaceName mountGuard
      claim = guardClaimName mountGuard
      volume = guardVolumeName mountGuard
  claimResult <- readClaim transport namespace claim
  volumeResult <- readVolume transport volume
  podsResult <- listNamespacePods transport namespace
  attachmentsResult <- listVolumeAttachments transport
  pure $ do
    currentClaim <- claimResult
    currentVolume <- volumeResult
    currentPods <- podsResult
    currentAttachments <- attachmentsResult
    parseVolumeEvidence
      mountGuard
      backing
      currentClaim
      currentVolume
      currentPods
      currentAttachments

-- | Guard observation brackets the volume reads. A false or uncertain guard
-- never becomes exclusion proof, even when no consumer was listed.
observeGuardedVolumeExcluded ::
  MountGuardTransport ->
  VolumeTransport ->
  MountGuard ->
  VolumeBacking ->
  IO (Either Text Bool)
observeGuardedVolumeExcluded guardTransport volumeTransport mountGuard backing = do
  before <- observeMountGuard guardTransport mountGuard
  case before of
    Left reason -> pure (Left reason)
    Right False -> pure (Right False)
    Right True -> do
      volume <- observeVolumeState volumeTransport mountGuard backing
      case volume of
        Left reason -> pure (Left reason)
        Right evidence -> do
          after <- observeMountGuard guardTransport mountGuard
          pure ((volumeHasNoConsumers evidence &&) <$> after)

-- | Existing Pod objects are counted even when terminating. A matching
-- VolumeAttachment is counted even when it reports detached, because the
-- attachment intent may be reconciled again until the object disappears.
volumeHasNoConsumers :: VolumeEvidence -> Bool
volumeHasNoConsumers evidence =
  null (volumePodConsumers evidence)
    && null (volumeAttachmentConsumers evidence)

parseVolumeEvidence ::
  MountGuard ->
  VolumeBacking ->
  Value ->
  Value ->
  Value ->
  Value ->
  Either Text VolumeEvidence
parseVolumeEvidence mountGuard backing claim volume pods attachments = do
  claimRoot <- asObject "PVC" claim
  claimMeta <- objectField "metadata" claimRoot
  exactIdentity
    "PVC"
    claimMeta
    (guardNamespaceName mountGuard)
    (guardClaimName mountGuard)
    (guardClaimIdentity mountGuard)
  claimSpec <- objectField "spec" claimRoot
  unless
    (textField "volumeName" claimSpec == Right (guardVolumeName mountGuard))
    (Left "fenced PVC is not bound to the reviewed PV")
  claimStatus <- objectField "status" claimRoot
  unless
    (textField "phase" claimStatus == Right "Bound")
    (Left "fenced PVC is not Bound")
  supportedAccess "PVC" claimSpec

  volumeRoot <- asObject "PV" volume
  volumeMeta <- objectField "metadata" volumeRoot
  exactIdentity
    "PV"
    volumeMeta
    ""
    (guardVolumeName mountGuard)
    (guardVolumeIdentity mountGuard)
  volumeSpec <- objectField "spec" volumeRoot
  supportedAccess "PV" volumeSpec
  volumeStatus <- objectField "status" volumeRoot
  unless
    (textField "phase" volumeStatus == Right "Bound")
    (Left "fenced PV is not Bound")
  claimRef <- objectField "claimRef" volumeSpec
  unless
    ( textField "namespace" claimRef == Right (guardNamespaceName mountGuard)
        && textField "name" claimRef == Right (guardClaimName mountGuard)
        && textField "uid" claimRef == Right (guardClaimIdentity mountGuard)
    )
    (Left "fenced PV claim reference changed")
  checkBacking backing volumeSpec

  podConsumers <- parsePodConsumers mountGuard pods
  attachmentConsumers <- parseAttachmentConsumers mountGuard attachments
  pure (VolumeEvidence podConsumers attachmentConsumers)

exactIdentity :: Text -> KM.KeyMap Value -> Text -> Text -> Text -> Either Text ()
exactIdentity label metadata namespace name uid = do
  unless
    ( textField "name" metadata == Right name
        && textField "uid" metadata == Right uid
        && (T.null namespace || textField "namespace" metadata == Right namespace)
    )
    (Left (label <> " name, namespace, or UID changed"))

supportedAccess :: Text -> KM.KeyMap Value -> Either Text ()
supportedAccess label spec = do
  modes <- arrayField "accessModes" spec
  values <- traverse (asText (label <> " access mode")) modes
  unless
    ( not (null values)
        && all (`elem` ["ReadWriteOnce", "ReadWriteOncePod"]) values
    )
    (Left (label <> " access mode does not prove a single-node or single-Pod volume"))

checkBacking :: VolumeBacking -> KM.KeyMap Value -> Either Text ()
checkBacking (CsiVolume driver handle) spec = do
  csi <- objectField "csi" spec
  unless
    ( textField "driver" csi == Right driver
        && textField "volumeHandle" csi == Right handle
    )
    (Left "fenced CSI driver or volume handle changed")
checkBacking (LocalVolume path node) spec = do
  local <- objectField "local" spec
  unless
    (textField "path" local == Right path)
    (Left "fenced local path changed")
  affinity <- objectField "nodeAffinity" spec
  required <- objectField "required" affinity
  terms <- arrayField "nodeSelectorTerms" required
  case terms of
    [Object term] -> do
      expressions <- arrayField "matchExpressions" term
      case expressions of
        [Object expression] -> do
          values <- arrayField "values" expression
          unless
            ( textField "key" expression == Right "kubernetes.io/hostname"
                && textField "operator" expression == Right "In"
                && values == [String node]
                && not (KM.member "matchFields" term)
            )
            (Left "fenced local PV node affinity changed")
        _ -> Left "fenced local PV node affinity is ambiguous"
    _ -> Left "fenced local PV has no unique node affinity"

parsePodConsumers :: MountGuard -> Value -> Either Text [Text]
parsePodConsumers mountGuard listing = do
  root <- asObject "PodList" listing
  items <- arrayField "items" root
  matches <- forM items $ \item -> do
    pod <- asObject "Pod" item
    metadata <- objectField "metadata" pod
    namespace <- textField "namespace" metadata
    unless
      (namespace == guardNamespaceName mountGuard)
      (Left "Pod list contains an object from another namespace")
    name <- textField "name" metadata
    uid <- textField "uid" metadata
    spec <- objectField "spec" pod
    volumes <- case KM.lookup "volumes" spec of
      Nothing -> Right []
      Just (Array entries) -> Right (V.toList entries)
      _ -> Left "Pod volumes are malformed"
    usesClaim <- any id <$> traverse (usesClaimName (guardClaimName mountGuard)) volumes
    pure [name <> "/" <> uid | usesClaim]
  pure (concat matches)

usesClaimName :: Text -> Value -> Either Text Bool
usesClaimName claim value = do
  volume <- asObject "Pod volume" value
  case KM.lookup "persistentVolumeClaim" volume of
    Nothing -> Right False
    Just (Object source) -> (== claim) <$> textField "claimName" source
    _ -> Left "Pod PVC volume is malformed"

parseAttachmentConsumers :: MountGuard -> Value -> Either Text [Text]
parseAttachmentConsumers mountGuard listing = do
  root <- asObject "VolumeAttachmentList" listing
  items <- arrayField "items" root
  matches <- forM items $ \item -> do
    attachment <- asObject "VolumeAttachment" item
    metadata <- objectField "metadata" attachment
    name <- textField "name" metadata
    uid <- textField "uid" metadata
    spec <- objectField "spec" attachment
    source <- objectField "source" spec
    target <- case KM.lookup "persistentVolumeName" source of
      Just (String value) -> Right (Just value)
      Nothing | KM.member "inlineVolumeSpec" source -> Right Nothing
      _ -> Left "VolumeAttachment source is malformed"
    pure [name <> "/" <> uid | target == Just (guardVolumeName mountGuard)]
  pure (concat matches)

asObject :: Text -> Value -> Either Text (KM.KeyMap Value)
asObject _ (Object value) = Right value
asObject label _ = Left (label <> " is not an object")

objectField :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
objectField key root = case KM.lookup (Key.fromText key) root of
  Just (Object value) -> Right value
  _ -> Left ("volume evidence lacks " <> key)

arrayField :: Text -> KM.KeyMap Value -> Either Text [Value]
arrayField key root = case KM.lookup (Key.fromText key) root of
  Just (Array values) -> Right (V.toList values)
  _ -> Left ("volume evidence lacks " <> key)

textField :: Text -> KM.KeyMap Value -> Either Text Text
textField key root = case KM.lookup (Key.fromText key) root of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("volume evidence lacks " <> key)

asText :: Text -> Value -> Either Text Text
asText _ (String value) = Right value
asText label _ = Left (label <> " is malformed")

kubectlVolumeTransport :: KubernetesRuntimeConfig -> VolumeTransport
kubectlVolumeTransport config = VolumeTransport claim volume pods attachments
  where
    claim namespace name =
      invoke
        [ "--namespace"
        , T.unpack namespace
        , "get"
        , "persistentvolumeclaim"
        , T.unpack name
        , "-o"
        , "json"
        ]
    volume name = invoke ["get", "persistentvolume", T.unpack name, "-o", "json"]
    pods namespace =
      invoke
        [ "--namespace"
        , T.unpack namespace
        , "get"
        , "pods"
        , "-o"
        , "json"
        ]
    attachments = invoke ["get", "volumeattachments.storage.k8s.io", "-o", "json"]
    invoke arguments = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          result <-
            try
              ( readProcessWithExitCode
                  "kubectl"
                  ( [ "--context"
                    , T.unpack (runtimeKubectlContext config)
                    , "--request-timeout=10s"
                    ]
                      <> arguments
                  )
                  ""
              )
          pure $ case result of
            Left (_ :: IOException) -> Left "could not invoke kubectl"
            Right (ExitFailure _, _, _) -> Left "could not read live volume state"
            Right (ExitSuccess, output, _) ->
              first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
