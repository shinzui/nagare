-- | Native Kubernetes components of a live-volume data fence. This module
-- observes accepted StatefulSet writers and exact PVC/PV state; database
-- connection exclusion and recovered-content verification remain separate
-- requirements before these controls can release a complete data fence.
module Nagare.Inventory.DataFence.KubernetesExclusion
  ( KubernetesExclusion
  , mkKubernetesExclusion
  , kubectlKubernetesExclusion
  , validateKubernetesExclusion
  , stopKubernetesWriters
  , observeKubernetesPhysical
  , observeKubernetesExcluded
  , releaseKubernetesWriters
  , observeKubernetesRelease
  ) where

import Control.Monad (forM, unless)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence (WriterReleaseState (..))
import Nagare.Inventory.DataFence.KubernetesIntent
import Nagare.Inventory.DataFence.MountGuard (guardClaimName)
import Nagare.Inventory.DataFence.MountGuardRuntime
import Nagare.Inventory.DataFence.ServiceState
import Nagare.Inventory.DataFence.StatefulWriter
import Nagare.Inventory.DataFence.VolumeState
import Nagare.Inventory.DataFence.WriterInventory
import Nagare.Inventory.Store (DataFenceRecord (..), ScopeRevision)
import Nagare.Resource.Inventory (Declaration, ManagedResource (..))
import Nagare.Resource.Types

data KubernetesExclusion = KubernetesExclusion
  { exclusionContext :: !ContextId
  , exclusionAccepted :: !(Map ScopeId ScopeRevision)
  , exclusionDeclarations :: ![Declaration]
  , exclusionNative :: !(Map ResourceId (ManagedResource, ByteString))
  , exclusionGuardTransport :: !MountGuardTransport
  , exclusionVolumeTransport :: !VolumeTransport
  , exclusionWriterTransport :: !StatefulWriterTransport
  , exclusionServiceTransport :: !ServiceTransport
  }

mkKubernetesExclusion :: ContextId -> Map ScopeId ScopeRevision
  -> [Declaration] -> Map ResourceId (ManagedResource, ByteString)
  -> MountGuardTransport -> VolumeTransport -> StatefulWriterTransport
  -> ServiceTransport
  -> KubernetesExclusion
mkKubernetesExclusion = KubernetesExclusion

kubectlKubernetesExclusion :: KubernetesRuntimeConfig
  -> Map ScopeId ScopeRevision -> [Declaration]
  -> Map ResourceId (ManagedResource, ByteString)
  -> KubernetesExclusion
kubectlKubernetesExclusion config accepted declarations native =
  mkKubernetesExclusion (runtimeContext config) accepted declarations native
    (kubectlMountGuardTransport config) (kubectlVolumeTransport config)
    (kubectlStatefulWriterTransport config) (kubectlServiceTransport config)

validatedIntent :: KubernetesExclusion -> DataFenceRecord
  -> Either Text KubernetesFenceIntent
validatedIntent exclusion record = do
  let ContextBinding context _ = fenceContext record
  unless (context == exclusionContext exclusion
      && fenceAccepted record == exclusionAccepted exclusion)
    (Left "Kubernetes fence context or accepted revisions changed")
  intent <- decodeKubernetesFenceIntent record
  validateServiceAssociation exclusion intent
  candidates <- discoverWriterCandidatesForRoutes
    (kubernetesDependencyRoot intent)
    (maybe [] (pure . serviceResource) (kubernetesService intent))
    (kubernetesCluster intent)
    (guardClaimName (kubernetesMountGuard intent))
    (exclusionDeclarations exclusion) (exclusionNative exclusion)
  validateKubernetesWriterInventory intent candidates
  pure intent

validateServiceAssociation :: KubernetesExclusion -> KubernetesFenceIntent
  -> Either Text ()
validateServiceAssociation exclusion intent = do
  let root = kubernetesDependencyRoot intent
      rootWriter = lookup root (kubernetesStatefulWriters intent)
  case (rootWriter, kubernetesService intent) of
    (Just _, Nothing) -> Left "fenced StatefulSet lacks a reviewed Service route"
    (Nothing, Nothing) -> Right ()
    (_, Just pin) -> do
      (member, bytes) <- maybe (Left "fenced Service lacks accepted native evidence")
        Right (Map.lookup (serviceResource pin) (exclusionNative exclusion))
      unless (matchesServiceAddress intent pin (address member))
        (Left "fenced Service address differs from accepted native evidence")
      selector <- nativeField "selector" =<< nativeSpec bytes
      actualSelector <- textMap selector
      unless (actualSelector == serviceSelector pin)
        (Left "fenced Service selector differs from accepted native evidence")
      case rootWriter of
        Nothing -> Right ()
        Just writer -> do
          (_, writerBytes) <- maybe (Left "fenced StatefulSet lacks accepted native evidence")
            Right (Map.lookup root (exclusionNative exclusion))
          spec <- nativeSpec writerBytes
          observedServiceName <- nativeText "serviceName" spec
          unless (observedServiceName == serviceName pin
              && writerNamespace writer == serviceNamespace pin)
            (Left "fenced StatefulSet Service route differs from accepted native evidence")

matchesServiceAddress :: KubernetesFenceIntent -> ServicePin -> ProviderAddress -> Bool
matchesServiceAddress intent pin (Kubernetes cluster "" kind namespace name) =
  cluster == kubernetesCluster intent
    && nameText kind == "service"
    && fmap nameText namespace == Just (serviceNamespace pin)
    && nameText name == serviceName pin
matchesServiceAddress _ _ _ = False

nativeSpec :: ByteString -> Either Text (KM.KeyMap Value)
nativeSpec bytes = do
  value <- first T.pack (eitherDecodeStrict' bytes)
  case value of
    Object root -> nativeField "spec" root
    _ -> Left "accepted Kubernetes native evidence is not an object"

nativeField :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
nativeField key object = case KM.lookup (Key.fromText key) object of
  Just (Object value) -> Right value
  _ -> Left ("accepted Kubernetes native evidence lacks " <> key)

nativeText :: Text -> KM.KeyMap Value -> Either Text Text
nativeText key object = case KM.lookup (Key.fromText key) object of
  Just (String value) -> Right value
  _ -> Left ("accepted Kubernetes native evidence lacks " <> key)

textMap :: KM.KeyMap Value -> Either Text (Map Text Text)
textMap entries = Map.fromList <$> traverse one (KM.toList entries)
  where
    one (key, String value) = Right (Key.toText key, value)
    one _ = Left "accepted Service selector is malformed"

-- | Check exact live identities before admission reserves the fence. The
-- volume may still have consumers at this point; quiescence is proved later.
validateKubernetesExclusion :: KubernetesExclusion -> DataFenceRecord
  -> IO (Either Text ())
validateKubernetesExclusion exclusion record = do
  physical <- observeKubernetesPhysical exclusion record
  pure (() <$ physical)

-- | Guard admission before scaling any reviewed controller. A lost scale
-- acknowledgement leaves the durable acquiring phase available for a fresh
-- process to reobserve and resume, without an unfenced retry.
stopKubernetesWriters :: KubernetesExclusion -> DataFenceRecord
  -> IO (Either Text ())
stopKubernetesWriters exclusion record = case validatedIntent exclusion record of
  Left reason -> pure (Left reason)
  Right intent -> do
    physical <- observeExactPhysical exclusion intent
    case physical of
      Left reason -> pure (Left reason)
      Right () -> do
        installed <- installMountGuard (exclusionGuardTransport exclusion)
          (kubernetesMountGuard intent)
        case installed of
          Left reason -> pure (Left reason)
          Right () -> do
            enforcing <- observeMountGuard (exclusionGuardTransport exclusion)
              (kubernetesMountGuard intent)
            case enforcing of
              Left reason -> pure (Left reason)
              Right False -> pure (Left "Kubernetes mount admission guard is not enforcing")
              Right True -> do
                stopped <- forM (kubernetesStatefulWriters intent) $ \(_, pin) ->
                  stopStatefulWriter (exclusionWriterTransport exclusion) pin
                pure (sequence_ stopped)

-- | The returned identities are the durable reviewed map only after current
-- PVC/PV/backing and every StatefulSet UID have been checked natively.
observeKubernetesPhysical :: KubernetesExclusion -> DataFenceRecord
  -> IO (Either Text (Map ResourceId PhysicalIdentity))
observeKubernetesPhysical exclusion record = case validatedIntent exclusion record of
  Left reason -> pure (Left reason)
  Right intent -> do
    checked <- observeExactPhysical exclusion intent
    pure (fencePhysical record <$ checked)

observeExactPhysical :: KubernetesExclusion -> KubernetesFenceIntent
  -> IO (Either Text ())
observeExactPhysical exclusion intent = do
  volume <- observeVolumeState (exclusionVolumeTransport exclusion)
    (kubernetesMountGuard intent) (kubernetesVolumeBacking intent)
  writers <- forM (kubernetesStatefulWriters intent) $ \(_, pin) ->
    observeStatefulWriterIdentity (exclusionWriterTransport exclusion) pin
  service <- traverse (observeServiceState (exclusionServiceTransport exclusion))
    (kubernetesService intent)
  pure $ do
    _ <- volume
    sequence_ writers
    case service of
      Nothing -> Right ()
      Just observed -> () <$ observed

-- | All saved StatefulSets must have converged to zero, and the exact volume
-- must have no Pod or VolumeAttachment consumers while the guard is observed
-- both before and after those reads. Engine-native writes are not covered.
observeKubernetesExcluded :: KubernetesExclusion -> DataFenceRecord
  -> IO (Either Text Bool)
observeKubernetesExcluded exclusion record = case validatedIntent exclusion record of
  Left reason -> pure (Left reason)
  Right intent -> do
    let mountGuard = kubernetesMountGuard intent
        guardTransport = exclusionGuardTransport exclusion
    before <- observeMountGuard guardTransport mountGuard
    case before of
      Left reason -> pure (Left reason)
      Right False -> pure (Right False)
      Right True -> do
        writers <- forM (kubernetesStatefulWriters intent) $ \(_, pin) ->
          observeStatefulWriterStopped (exclusionWriterTransport exclusion) pin
        volume <- observeVolumeState (exclusionVolumeTransport exclusion)
          mountGuard (kubernetesVolumeBacking intent)
        service <- case kubernetesService intent of
          Nothing -> pure (Right True)
          Just pin -> fmap (fmap serviceHasNoEndpoints)
            (observeServiceState (exclusionServiceTransport exclusion) pin)
        after <- observeMountGuard guardTransport mountGuard
        pure $ do
          stopped <- sequence writers
          evidence <- volume
          serviceEmpty <- service
          guarded <- after
          pure (and stopped && volumeHasNoConsumers evidence
            && serviceEmpty && guarded)

-- | Called only from the durable verified-release phase. The acquisition
-- guard never permits the original StatefulSet Pods to mount the PVC; remove
-- it only after verification, before restoring saved replicas. Both effects
-- are conditional and restart-safe. A partial response remains visible for
-- the separately reviewed forward-recovery operation.
releaseKubernetesWriters :: KubernetesExclusion -> DataFenceRecord
  -> IO (Either Text ())
releaseKubernetesWriters exclusion record = case validatedIntent exclusion record of
  Left reason -> pure (Left reason)
  Right intent -> do
    physical <- observeExactPhysical exclusion intent
    case physical of
      Left reason -> pure (Left reason)
      Right () -> do
        removed <- removeMountGuard (exclusionGuardTransport exclusion)
          (kubernetesMountGuard intent)
        case removed of
          Left reason -> pure (Left reason)
          Right () -> do
            restored <- forM (kubernetesStatefulWriters intent) $ \(_, pin) ->
              restoreStatefulWriter (exclusionWriterTransport exclusion) pin
            pure (sequence_ restored)

observeKubernetesRelease :: KubernetesExclusion -> DataFenceRecord
  -> IO (Either Text WriterReleaseState)
observeKubernetesRelease exclusion record = case validatedIntent exclusion record of
  Left reason -> pure (Left reason)
  Right intent -> do
    physical <- observeExactPhysical exclusion intent
    case physical of
      Left reason -> pure (Left reason)
      Right () -> do
        writers <- forM (kubernetesStatefulWriters intent) $ \(_, pin) ->
          observeStatefulWriterRelease (exclusionWriterTransport exclusion) pin
        let mountGuard = kubernetesMountGuard intent
            transport = exclusionGuardTransport exclusion
        intact <- observeMountGuard transport mountGuard
        absent <- observeMountGuardAbsent transport mountGuard
        pure $ do
          states <- sequence writers
          guarded <- intact
          removed <- absent
          pure $ if all (== WritersFullyReleased) states && removed
            then WritersFullyReleased
            else if all (== WritersStillExcluded) states && guarded
              then WritersStillExcluded
              else WritersPartlyReleased
