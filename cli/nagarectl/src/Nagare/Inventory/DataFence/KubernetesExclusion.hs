-- | Native Kubernetes components of a live-volume data fence. This module
-- observes accepted writers, the database shutdown, and exact PVC/PV state.
-- The restore mode supplies its own recovered-content verification.
module Nagare.Inventory.DataFence.KubernetesExclusion
  ( KubernetesExclusion
  , mkKubernetesExclusion
  , kubectlKubernetesExclusion
  , kubernetesDataFenceControls
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
import Nagare.Dsl.Database (Engine)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence (DataFenceControls (..), WriterReleaseState (..))
import Nagare.Inventory.DataFence.DatabaseShutdown
import Nagare.Inventory.DataFence.DeploymentWriter qualified as Deployment
import Nagare.Inventory.DataFence.KubernetesIntent
import Nagare.Inventory.DataFence.MountGuard (guardClaimName)
import Nagare.Inventory.DataFence.MountGuardRuntime
import Nagare.Inventory.DataFence.ServiceState
import Nagare.Inventory.DataFence.ScheduledWriter
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
  , exclusionDeploymentTransport :: !Deployment.DeploymentWriterTransport
  , exclusionServiceTransport :: !ServiceTransport
  , exclusionScheduleTransport :: !ScheduledWriterTransport
  , exclusionShutdownTransport :: !DatabaseShutdownTransport
  }

mkKubernetesExclusion :: ContextId -> Map ScopeId ScopeRevision
  -> [Declaration] -> Map ResourceId (ManagedResource, ByteString)
  -> MountGuardTransport -> VolumeTransport -> StatefulWriterTransport
  -> Deployment.DeploymentWriterTransport -> ServiceTransport
  -> ScheduledWriterTransport -> DatabaseShutdownTransport
  -> KubernetesExclusion
mkKubernetesExclusion = KubernetesExclusion

kubectlKubernetesExclusion :: KubernetesRuntimeConfig
  -> Map ScopeId ScopeRevision -> [Declaration]
  -> Map ResourceId (ManagedResource, ByteString)
  -> KubernetesExclusion
kubectlKubernetesExclusion config accepted declarations native =
  mkKubernetesExclusion (runtimeContext config) accepted declarations native
    (kubectlMountGuardTransport config) (kubectlVolumeTransport config)
    (kubectlStatefulWriterTransport config)
    (Deployment.kubectlDeploymentWriterTransport config)
    (kubectlServiceTransport config)
    (kubectlScheduledWriterTransport config)
    (kubectlDatabaseShutdownTransport config)

-- | Bind every shared fence callback to the same reviewed Kubernetes
-- provider and exact native evidence. A restore mode supplies its own
-- recovered-content verifier; the provider cannot infer data correctness
-- from a stopped controller or an empty Service route.
kubernetesDataFenceControls :: KubernetesExclusion
  -> (DataFenceRecord -> IO (Either Text Bool)) -> DataFenceControls
kubernetesDataFenceControls exclusion verify = DataFenceControls
  { validateFenceInputs = validateKubernetesExclusion exclusion
  , stopFenceWriters = stopKubernetesWriters exclusion
  , observeFencePhysical = observeKubernetesPhysical exclusion
  , observeWritersExcluded = observeKubernetesExcluded exclusion
  , verifyRecoveredData = verify
  , restoreFenceWriters = releaseKubernetesWriters exclusion
  , observeWritersReleased = observeKubernetesRelease exclusion
  , forwardRecoverPartlyReleased = Just (releaseKubernetesWriters exclusion)
  }

validatedIntent :: KubernetesExclusion -> DataFenceRecord
  -> Either Text KubernetesFenceIntent
validatedIntent exclusion record = do
  let ContextBinding context _ = fenceContext record
  unless (context == exclusionContext exclusion
      && fenceAccepted record == exclusionAccepted exclusion)
    (Left "Kubernetes fence context or accepted revisions changed")
  intent <- decodeKubernetesFenceIntent record
  validateServiceAssociation exclusion intent
  validateEngineAssociation exclusion intent
  candidates <- discoverWriterCandidatesForRoutes
    (kubernetesDependencyRoot intent)
    (maybe [] (pure . serviceResource) (kubernetesService intent))
    (kubernetesCluster intent)
    (guardClaimName (kubernetesMountGuard intent))
    (exclusionDeclarations exclusion) (exclusionNative exclusion)
  validateKubernetesWriterInventory intent candidates
  pure intent

validateEngineAssociation :: KubernetesExclusion -> KubernetesFenceIntent
  -> Either Text ()
validateEngineAssociation exclusion intent = do
  (_, bytes) <- maybe (Left "database dependency root lacks accepted native evidence")
    Right (Map.lookup (kubernetesDependencyRoot intent) (exclusionNative exclusion))
  validateReviewedDatabaseEngine (kubernetesDatabaseEngine intent) bytes
  case kubernetesDatabaseEngine intent of
    Nothing -> Right ()
    Just _ -> unless (maybe False (const True)
      (lookup (kubernetesDependencyRoot intent) (kubernetesStatefulWriters intent)))
      (Left "managed database root lacks a reviewed StatefulSet writer")

acceptedDatabaseServer :: KubernetesExclusion -> KubernetesFenceIntent
  -> Either Text (Maybe (Engine, Text))
acceptedDatabaseServer exclusion intent = do
  (_, bytes) <- maybe
    (Left "database dependency root lacks accepted native evidence") Right
    (Map.lookup (kubernetesDependencyRoot intent) (exclusionNative exclusion))
  value <- first T.pack (eitherDecodeStrict' bytes)
  parseObservedDatabaseServer value

observeLiveDatabaseEngine :: KubernetesExclusion -> KubernetesFenceIntent
  -> IO (Either Text ())
observeLiveDatabaseEngine exclusion intent =
  case kubernetesDatabaseEngine intent of
    Nothing -> pure (Right ())
    Just expected -> case lookup (kubernetesDependencyRoot intent)
        (kubernetesStatefulWriters intent) of
      Nothing -> pure (Left "managed database root lacks a reviewed StatefulSet writer")
      Just pin -> do
        observed <- readStatefulWriter (exclusionWriterTransport exclusion)
          (writerNamespace pin) (writerName pin)
        pure $ do
          accepted <- acceptedDatabaseServer exclusion intent
          current <- observed
          actual <- parseObservedDatabaseServer current
          unless (actual == accepted && fmap fst actual == Just expected)
            (Left "live database server image differs from reviewed accepted engine")

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
                schedules <- forM (kubernetesScheduledWriters intent) $ \(_, pin) ->
                  stopScheduledWriter (exclusionScheduleTransport exclusion) pin
                case sequence_ schedules of
                  Left reason -> pure (Left reason)
                  Right () -> do
                    let databaseRoot = case kubernetesDatabaseEngine intent of
                          Nothing -> Nothing
                          Just _ -> Just (kubernetesDependencyRoot intent)
                        clients = [(resource, pin)
                          | (resource, pin) <- kubernetesStatefulWriters intent
                          , Just resource /= databaseRoot]
                        roots = [(resource, pin)
                          | (resource, pin) <- kubernetesStatefulWriters intent
                          , Just resource == databaseRoot]
                    deployments <- forM (kubernetesDeploymentWriters intent)
                      $ \(_, pin) -> Deployment.stopDeploymentWriter
                        (exclusionDeploymentTransport exclusion) pin
                    case sequence_ deployments of
                      Left reason -> pure (Left reason)
                      Right () -> do
                        clientStops <- forM clients $ \(_, pin) ->
                          stopStatefulWriter (exclusionWriterTransport exclusion) pin
                        case sequence_ clientStops of
                          Left reason -> pure (Left reason)
                          Right () -> do
                            quiet <- observeDatabaseClientsDrained exclusion intent clients
                            case quiet of
                              Left reason -> pure (Left reason)
                              Right False -> pure (Left "managed database clients have not drained")
                              Right True -> do
                                shutdown <- requestReviewedDatabaseShutdown exclusion intent roots
                                case shutdown of
                                  Left reason -> pure (Left reason)
                                  Right () -> do
                                    stopped <- forM roots $ \(_, pin) ->
                                      stopStatefulWriter
                                        (exclusionWriterTransport exclusion) pin
                                    pure (sequence_ stopped)

observeDatabaseClientsDrained :: KubernetesExclusion -> KubernetesFenceIntent
  -> [(ResourceId, StatefulWriterPin)] -> IO (Either Text Bool)
observeDatabaseClientsDrained exclusion intent clients =
  case kubernetesDatabaseEngine intent of
    Nothing -> pure (Right True)
    Just _ -> do
      stateful <- forM clients $ \(_, pin) ->
        observeStatefulWriterStopped (exclusionWriterTransport exclusion) pin
      deployments <- forM (kubernetesDeploymentWriters intent) $ \(_, pin) ->
        Deployment.observeDeploymentWriterStopped
          (exclusionDeploymentTransport exclusion) pin
      schedules <- forM (kubernetesScheduledWriters intent) $ \(_, pin) ->
        observeScheduledWriterStopped (exclusionScheduleTransport exclusion) pin
      pure $ do
        stopped <- sequence stateful
        deploymentStopped <- sequence deployments
        scheduleStopped <- sequence schedules
        pure (and stopped && and deploymentStopped && and scheduleStopped)

requestReviewedDatabaseShutdown :: KubernetesExclusion -> KubernetesFenceIntent
  -> [(ResourceId, StatefulWriterPin)] -> IO (Either Text ())
requestReviewedDatabaseShutdown exclusion intent roots =
  case (kubernetesDatabaseEngine intent, roots,
      acceptedDatabaseServer exclusion intent) of
    (Nothing, [], _) -> pure (Right ())
    (Just engine, [(_, pin)], Right (Just (_, image))) ->
      requestDatabaseShutdown (exclusionVolumeTransport exclusion)
        (exclusionShutdownTransport exclusion) pin engine image
    (_, _, Left reason) -> pure (Left reason)
    _ -> pure (Left "reviewed database server shutdown intent is incomplete")

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
  engine <- observeLiveDatabaseEngine exclusion intent
  volume <- observeVolumeState (exclusionVolumeTransport exclusion)
    (kubernetesMountGuard intent) (kubernetesVolumeBacking intent)
  writers <- forM (kubernetesStatefulWriters intent) $ \(_, pin) ->
    observeStatefulWriterIdentity (exclusionWriterTransport exclusion) pin
  deployments <- forM (kubernetesDeploymentWriters intent) $ \(_, pin) ->
    Deployment.observeDeploymentWriterIdentity
      (exclusionDeploymentTransport exclusion) pin
  schedules <- forM (kubernetesScheduledWriters intent) $ \(_, pin) ->
    observeScheduledWriterIdentity (exclusionScheduleTransport exclusion) pin
  service <- traverse (observeServiceState (exclusionServiceTransport exclusion))
    (kubernetesService intent)
  pure $ do
    _ <- engine
    _ <- volume
    sequence_ writers
    sequence_ deployments
    sequence_ schedules
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
        engine <- observeLiveDatabaseEngine exclusion intent
        writers <- forM (kubernetesStatefulWriters intent) $ \(_, pin) ->
          observeStatefulWriterStopped (exclusionWriterTransport exclusion) pin
        deployments <- forM (kubernetesDeploymentWriters intent) $ \(_, pin) ->
          Deployment.observeDeploymentWriterStopped
            (exclusionDeploymentTransport exclusion) pin
        schedules <- forM (kubernetesScheduledWriters intent) $ \(_, pin) ->
          observeScheduledWriterStopped (exclusionScheduleTransport exclusion) pin
        volume <- observeVolumeState (exclusionVolumeTransport exclusion)
          mountGuard (kubernetesVolumeBacking intent)
        service <- case kubernetesService intent of
          Nothing -> pure (Right True)
          Just pin -> fmap (fmap serviceHasNoEndpoints)
            (observeServiceState (exclusionServiceTransport exclusion) pin)
        after <- observeMountGuard guardTransport mountGuard
        pure $ do
          _ <- engine
          stopped <- sequence writers
          deploymentStopped <- sequence deployments
          suspended <- sequence schedules
          evidence <- volume
          serviceEmpty <- service
          guarded <- after
          pure (and stopped && and deploymentStopped && and suspended
            && volumeHasNoConsumers evidence
            && serviceEmpty && guarded)

-- | The release overlay is observed before acquisition-guard cleanup and
-- remains active until the exact saved writer intent is ready. A restart can
-- reenter after a lost acknowledgement without opening foreign PVC mounts.
releaseKubernetesWriters :: KubernetesExclusion -> DataFenceRecord
  -> IO (Either Text ())
releaseKubernetesWriters exclusion record = case validatedIntent exclusion record of
  Left reason -> pure (Left reason)
  Right intent -> do
    physical <- observeExactPhysical exclusion intent
    case physical of
      Left reason -> pure (Left reason)
      Right () -> do
        let guardTransport = exclusionGuardTransport exclusion
            mountGuard = kubernetesMountGuard intent
            releaseGuard = kubernetesReleaseMountGuard intent
        acquisition <- observeMountGuard guardTransport mountGuard
        releasing <- observeMountGuard guardTransport releaseGuard
        case (,) <$> acquisition <*> releasing of
          Left reason -> pure (Left reason)
          Right (False, False) -> do
            acquisitionAbsent <- observeMountGuardAbsent guardTransport mountGuard
            ready <- observeSavedKubernetesWritersReady exclusion intent
            case (,) <$> acquisitionAbsent <*> ready of
              Left reason -> pure (Left reason)
              Right (True, True) -> removeMountGuard guardTransport releaseGuard
              Right _ -> pure (Left
                "Kubernetes mount admission guard is not enforcing before release")
          Right _ -> do
            installed <- installMountGuard guardTransport releaseGuard
            case installed of
              Left reason -> pure (Left reason)
              Right () -> do
                overlay <- observeMountGuard guardTransport releaseGuard
                case overlay of
                  Left reason -> pure (Left reason)
                  Right False -> pure (Left
                    "Kubernetes release mount guard is not enforcing")
                  Right True -> do
                    removed <- removeMountGuard guardTransport mountGuard
                    case removed of
                      Left reason -> pure (Left reason)
                      Right () -> do
                        restored <- restoreKubernetesWriterIntent exclusion intent
                        case restored of
                          Left reason -> pure (Left reason)
                          Right () -> do
                            ready <- observeSavedKubernetesWritersReady exclusion intent
                            case ready of
                              Left reason -> pure (Left reason)
                              Right False -> pure (Left
                                "saved Kubernetes writer intent is not ready for guard release")
                              Right True -> removeMountGuard guardTransport releaseGuard

restoreKubernetesWriterIntent :: KubernetesExclusion -> KubernetesFenceIntent
  -> IO (Either Text ())
restoreKubernetesWriterIntent exclusion intent = do
  restored <- forM (kubernetesStatefulWriters intent) $ \(_, pin) ->
    restoreStatefulWriter (exclusionWriterTransport exclusion) pin
  case sequence_ restored of
    Left reason -> pure (Left reason)
    Right () -> do
      deployments <- forM (kubernetesDeploymentWriters intent)
        $ \(_, pin) -> Deployment.restoreDeploymentWriter
          (exclusionDeploymentTransport exclusion) pin
      case sequence_ deployments of
        Left reason -> pure (Left reason)
        Right () -> do
          ready <- forM (kubernetesStatefulWriters intent) $ \(_, pin) ->
            observeStatefulWriterRelease (exclusionWriterTransport exclusion) pin
          deploymentReady <- forM (kubernetesDeploymentWriters intent)
            $ \(_, pin) -> Deployment.observeDeploymentWriterRelease
              (exclusionDeploymentTransport exclusion) pin
          case (,) <$> sequence ready <*> sequence deploymentReady of
            Left reason -> pure (Left reason)
            Right (states, deploymentStates)
              | not (all (== WritersFullyReleased)
                  (states <> deploymentStates)) ->
                  pure (Left "database workloads are not ready for schedule release")
            Right _ -> do
              schedules <- forM (kubernetesScheduledWriters intent) $ \(_, pin) ->
                restoreScheduledWriter (exclusionScheduleTransport exclusion) pin
              pure (sequence_ schedules)

observeSavedKubernetesWritersReady :: KubernetesExclusion
  -> KubernetesFenceIntent -> IO (Either Text Bool)
observeSavedKubernetesWritersReady exclusion intent = do
  stateful <- forM (kubernetesStatefulWriters intent) $ \(_, pin) ->
    observeStatefulWriterRelease (exclusionWriterTransport exclusion) pin
  deployments <- forM (kubernetesDeploymentWriters intent) $ \(_, pin) ->
    Deployment.observeDeploymentWriterRelease
      (exclusionDeploymentTransport exclusion) pin
  schedules <- forM (kubernetesScheduledWriters intent) $ \(_, pin) ->
    observeScheduledWriterRelease (exclusionScheduleTransport exclusion) pin
  pure $ all (== WritersFullyReleased)
    <$> (sequence (stateful <> deployments <> schedules))

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
        deployments <- forM (kubernetesDeploymentWriters intent) $ \(_, pin) ->
          Deployment.observeDeploymentWriterRelease
            (exclusionDeploymentTransport exclusion) pin
        schedules <- forM (kubernetesScheduledWriters intent) $ \(_, pin) ->
          observeScheduledWriterRelease (exclusionScheduleTransport exclusion) pin
        let mountGuard = kubernetesMountGuard intent
            releaseGuard = kubernetesReleaseMountGuard intent
            transport = exclusionGuardTransport exclusion
        intact <- observeMountGuard transport mountGuard
        absent <- observeMountGuardAbsent transport mountGuard
        releaseAbsent <- observeMountGuardAbsent transport releaseGuard
        pure $ do
          states <- sequence writers
          deploymentStates <- sequence deployments
          scheduledStates <- sequence schedules
          guarded <- intact
          removed <- absent
          overlayRemoved <- releaseAbsent
          let scheduledExcluded = and
                [ state == WritersStillExcluded
                    || (scheduleSavedSuspend pin == Just True
                      && state == WritersFullyReleased)
                | ((_, pin), state) <- zip (kubernetesScheduledWriters intent)
                    scheduledStates]
          pure $ if all (== WritersFullyReleased) (states <> deploymentStates)
              && all (== WritersFullyReleased) scheduledStates
              && removed && overlayRemoved
            then WritersFullyReleased
            else if all (== WritersStillExcluded) (states <> deploymentStates)
              && scheduledExcluded && guarded
              then WritersStillExcluded
              else WritersPartlyReleased
