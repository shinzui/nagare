-- | Native Kubernetes components of a live-volume data fence. This module
-- observes accepted writers, the database shutdown, and exact PVC/PV state.
-- The restore mode supplies its own recovered-content verification.
module Nagare.Inventory.DataFence.KubernetesExclusion
  ( KubernetesExclusion
  , mkKubernetesExclusion
  , kubectlKubernetesExclusion
  , kubernetesDataFenceControls
  , kubernetesMaintenanceFenceControls
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
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Database (Engine, engineToken)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence (DataFenceControls (..), WriterReleaseState (..))
import Nagare.Inventory.DataFence.DatabaseShutdown
import Nagare.Inventory.DataFence.CompletedJob
import Nagare.Inventory.DataFence.DeploymentWriter qualified as Deployment
import Nagare.Inventory.DataFence.GuardAuthority
import Nagare.Inventory.DataFence.KubernetesIntent
import Nagare.Inventory.DataFence.MountGuard
  (MountGuard, guardClaimName, guardNamespaceName)
import Nagare.Inventory.DataFence.MountGuardRuntime
import Nagare.Inventory.DataFence.MaintenanceNetwork
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
  , exclusionGuardAccessTransport :: !GuardAccessTransport
  , exclusionVolumeTransport :: !VolumeTransport
  , exclusionWriterTransport :: !StatefulWriterTransport
  , exclusionDeploymentTransport :: !Deployment.DeploymentWriterTransport
  , exclusionServiceTransport :: !ServiceTransport
  , exclusionScheduleTransport :: !ScheduledWriterTransport
  , exclusionCompletedJobTransport :: !CompletedJobTransport
  , exclusionShutdownTransport :: !DatabaseShutdownTransport
  }

mkKubernetesExclusion :: ContextId -> Map ScopeId ScopeRevision
  -> [Declaration] -> Map ResourceId (ManagedResource, ByteString)
  -> MountGuardTransport -> GuardAccessTransport -> VolumeTransport
  -> StatefulWriterTransport
  -> Deployment.DeploymentWriterTransport -> ServiceTransport
  -> ScheduledWriterTransport -> CompletedJobTransport
  -> DatabaseShutdownTransport
  -> KubernetesExclusion
mkKubernetesExclusion = KubernetesExclusion

kubectlKubernetesExclusion :: KubernetesRuntimeConfig
  -> Map ScopeId ScopeRevision -> [Declaration]
  -> Map ResourceId (ManagedResource, ByteString)
  -> KubernetesExclusion
kubectlKubernetesExclusion config accepted declarations native =
  mkKubernetesExclusion (runtimeContext config) accepted declarations native
    (kubectlMountGuardTransport config) (kubectlGuardAccessTransport config)
    (kubectlVolumeTransport config)
    (kubectlStatefulWriterTransport config)
    (Deployment.kubectlDeploymentWriterTransport config)
    (kubectlServiceTransport config)
    (kubectlScheduledWriterTransport config)
    (kubectlCompletedJobTransport config)
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

-- | Online maintenance keeps the reviewed database server alive
-- for one client inside its Pod. The shared durable fence still owns admission;
-- these callbacks replace only its native access policy.
kubernetesMaintenanceFenceControls :: KubernetesExclusion
  -> MaintenanceNetworkTransport -> Engine
  -> (Text -> Text -> Text -> IO (Either Text Bool))
  -> MaintenanceNetworkPin
  -> (DataFenceRecord -> IO (Either Text Bool)) -> DataFenceControls
kubernetesMaintenanceFenceControls exclusion network engine observeClients pin verify = DataFenceControls
  { validateFenceInputs = \record -> do
      checked <- validateKubernetesExclusion exclusion record
      case checked of
        Left reason -> pure (Left reason)
        Right () -> case maintenanceIntent exclusion engine pin record of
          Left reason -> pure (Left reason)
          Right (intent, root, image) -> do
            pod <- observeMaintenancePod exclusion engine pin root image
            authority <- observeProtectedMaintenancePolicy exclusion intent network pin
            pure $ do
              pod
              allowed <- authority
              unless allowed (Left "maintenance network policy is editable by a managed writer")
  , stopFenceWriters = stopMaintenanceWriters exclusion network engine pin
  , observeFencePhysical = \record -> do
      physical <- observeKubernetesPhysical exclusion record
      case (physical, maintenanceIntent exclusion engine pin record) of
        (Left reason, _) -> pure (Left reason)
        (_, Left reason) -> pure (Left reason)
        (Right identities, Right (_, root, image)) -> do
          pod <- observeMaintenancePod exclusion engine pin root image
          pure (identities <$ pod)
  , observeWritersExcluded = observeMaintenanceExcluded exclusion network engine observeClients pin
  , verifyRecoveredData = verify
  , restoreFenceWriters = releaseMaintenanceWriters exclusion network engine pin
  , observeWritersReleased = observeMaintenanceRelease exclusion network engine pin
  , forwardRecoverPartlyReleased = Just
      (releaseMaintenanceWriters exclusion network engine pin)
  }

maintenanceIntent :: KubernetesExclusion -> Engine -> MaintenanceNetworkPin
  -> DataFenceRecord -> Either Text
       (KubernetesFenceIntent, StatefulWriterPin, Text)
maintenanceIntent exclusion engine pin record = do
  intent <- validatedIntent exclusion record
  unless (fenceSession record == networkSession pin
      && kubernetesDatabaseEngine intent == Just engine)
    (Left "maintenance fence session or engine changed")
  root <- maybe (Left "maintenance database root is not a saved writer") Right
    (lookup (kubernetesDependencyRoot intent) (kubernetesStatefulWriters intent))
  unless (writerNamespace root == networkNamespace pin
      && writerName root == networkDatabase pin
      && networkPodName pin == writerName root <> "-0"
      && writerSavedReplicas root == 1)
    (Left "maintenance fence does not name the single reviewed database Pod")
  unless (all ((== networkNamespace pin) . writerNamespace . snd)
        (kubernetesStatefulWriters intent)
      && all ((== networkNamespace pin) . Deployment.writerNamespace . snd)
        (kubernetesDeploymentWriters intent)
      && all ((== networkNamespace pin) . scheduleNamespace . snd)
        (kubernetesScheduledWriters intent)
      && all ((== networkNamespace pin) . completedJobNamespace . snd)
        (kubernetesCompletedJobs intent))
    (Left "maintenance policy cannot protect a writer in another namespace")
  accepted <- acceptedDatabaseServer exclusion intent
  image <- case accepted of
    Just (acceptedEngine, value) | acceptedEngine == engine -> Right value
    _ -> Left ("maintenance accepted " <> engineToken engine
      <> " server image is unavailable")
  pure (intent, root, image)

observeMaintenancePod :: KubernetesExclusion -> Engine -> MaintenanceNetworkPin
  -> StatefulWriterPin -> Text
  -> IO (Either Text ())
observeMaintenancePod exclusion engine pin root image = do
  let volume = exclusionVolumeTransport exclusion
  current <- observeDatabasePod volume root engine image
  listing <- listNamespacePods volume (networkNamespace pin)
  pure $ do
    (name, uid) <- current
    unless (name == networkPodName pin && uid == networkPodUid pin)
      (Left "maintenance database Pod incarnation changed")
    pods <- listing
    maintenancePodSelected pin pods

observeProtectedMaintenancePolicy :: KubernetesExclusion -> KubernetesFenceIntent
  -> MaintenanceNetworkTransport -> MaintenanceNetworkPin
  -> IO (Either Text Bool)
observeProtectedMaintenancePolicy exclusion intent network pin = case
  protectedNetworkPrincipals exclusion intent of
  Left reason -> pure (Left reason)
  Right principals -> observeMaintenancePolicyAuthority
    (exclusionGuardAccessTransport exclusion) network principals controllers pin
  where
    controllers =
      [("apps", "statefulsets", writerName selected)
        | (_, selected) <- kubernetesStatefulWriters intent]
      <> [("apps", "deployments", Deployment.writerName selected)
        | (_, selected) <- kubernetesDeploymentWriters intent]
      <> [("batch", "cronjobs", scheduleName selected)
        | (_, selected) <- kubernetesScheduledWriters intent]
      <> [("batch", "jobs", completedJobName selected)
        | (_, selected) <- kubernetesCompletedJobs intent]

stopMaintenanceWriters :: KubernetesExclusion -> MaintenanceNetworkTransport
  -> Engine -> MaintenanceNetworkPin -> DataFenceRecord -> IO (Either Text ())
stopMaintenanceWriters exclusion network engine pin record = case
  maintenanceIntent exclusion engine pin record of
  Left reason -> pure (Left reason)
  Right (intent, root, image) -> do
    physical <- observeExactPhysical exclusion intent
    pod <- observeMaintenancePod exclusion engine pin root image
    case (,) <$> physical <*> pod of
      Left reason -> pure (Left reason)
      Right ((), ()) -> do
        let guard = kubernetesMountGuard intent
        installed <- installMountGuard (exclusionGuardTransport exclusion) guard
        enforcing <- observeProtectedMountGuard exclusion intent guard
        case (,) <$> installed <*> enforcing of
          Left reason -> pure (Left reason)
          Right (_, False) -> pure (Left "maintenance mount guard is not enforcing")
          Right (_, True) -> do
            authority <- observeProtectedMaintenancePolicy exclusion intent network pin
            case authority of
              Left reason -> pure (Left reason)
              Right False -> pure (Left "maintenance network policy is editable")
              Right True -> do
                policy <- installMaintenancePolicy network pin
                case policy of
                  Left reason -> pure (Left reason)
                  Right _ -> stopClients intent
  where
    stopClients intent = do
      schedules <- forM (kubernetesScheduledWriters intent) $ \(_, selected) ->
        stopScheduledWriter (exclusionScheduleTransport exclusion) selected
      case sequence_ schedules of
        Left reason -> pure (Left reason)
        Right () -> do
          deployments <- forM (kubernetesDeploymentWriters intent) $ \(_, selected) ->
            Deployment.stopDeploymentWriter
              (exclusionDeploymentTransport exclusion) selected
          case sequence_ deployments of
            Left reason -> pure (Left reason)
            Right () -> do
              let clients = [(resource, selected)
                    | (resource, selected) <- kubernetesStatefulWriters intent
                    , resource /= kubernetesDependencyRoot intent]
              stopped <- forM clients $ \(_, selected) ->
                stopStatefulWriter (exclusionWriterTransport exclusion) selected
              case sequence_ stopped of
                Left reason -> pure (Left reason)
                Right () -> do
                  quiet <- observeDatabaseClientsDrained exclusion intent clients
                  pure $ case quiet of
                    Right True -> Right ()
                    Right False -> Left "maintenance clients have not drained"
                    Left reason -> Left reason

observeMaintenanceExcluded :: KubernetesExclusion -> MaintenanceNetworkTransport
  -> Engine -> (Text -> Text -> Text -> IO (Either Text Bool))
  -> MaintenanceNetworkPin
  -> DataFenceRecord -> IO (Either Text Bool)
observeMaintenanceExcluded exclusion network engine observeClients pin record = case
  maintenanceIntent exclusion engine pin record of
  Left reason -> pure (Left reason)
  Right (intent, root, image) -> do
    let guard = kubernetesMountGuard intent
    beforeGuard <- observeProtectedMountGuard exclusion intent guard
    beforePolicy <- observeMaintenancePolicy network pin
    beforeAuthority <- observeProtectedMaintenancePolicy exclusion intent network pin
    case (,,) <$> beforeGuard <*> beforePolicy <*> beforeAuthority of
      Left reason -> pure (Left reason)
      Right (False, _, _) -> pure (Left "maintenance mount guard is not enforcing")
      Right (_, Nothing, _) -> pure (Left "maintenance ingress policy is absent")
      Right (_, _, False) -> pure (Left "maintenance policy authority is unproved")
      Right (True, Just _, True) -> do
        pod <- observeMaintenancePod exclusion engine pin root image
        rootReady <- observeStatefulWriterRelease
          (exclusionWriterTransport exclusion) root
        let clients = [selected | (resource, selected) <- kubernetesStatefulWriters intent
              , resource /= kubernetesDependencyRoot intent]
        stateful <- traverse (observeStatefulWriterStopped
          (exclusionWriterTransport exclusion)) clients
        deployments <- traverse (Deployment.observeDeploymentWriterStopped
          (exclusionDeploymentTransport exclusion))
          (map snd (kubernetesDeploymentWriters intent))
        schedules <- traverse (observeScheduledWriterStopped
          (exclusionScheduleTransport exclusion))
          (map snd (kubernetesScheduledWriters intent))
        volume <- observeVolumeState (exclusionVolumeTransport exclusion)
          guard (kubernetesVolumeBacking intent)
        completed <- traverse (observeCompletedJob
          (exclusionCompletedJobTransport exclusion) . snd)
          (kubernetesCompletedJobs intent)
        observedClients <- observeClients (networkNamespace pin)
          (networkPodName pin) (networkPodUid pin)
        afterGuard <- observeProtectedMountGuard exclusion intent guard
        afterPolicy <- observeMaintenancePolicy network pin
        afterAuthority <- observeProtectedMaintenancePolicy exclusion intent network pin
        pure $ do
          _ <- pod
          ready <- rootReady
          stopped <- sequence stateful
          deploymentStopped <- sequence deployments
          scheduleStopped <- sequence schedules
          evidence <- volume
          terminalConsumers <- concat <$> sequence completed
          clientsGone <- observedClients
          guarded <- afterGuard
          policy <- afterPolicy
          authority <- afterAuthority
          unless (ready == WritersFullyReleased)
            (Left "maintenance database StatefulSet is not ready")
          unless (and stopped && and deploymentStopped && and scheduleStopped)
            (Left "maintenance managed clients are not stopped")
          unless (sort (volumePodConsumers evidence)
              == sort ((networkPodName pin <> "/" <> networkPodUid pin)
                : terminalConsumers)
              && null (volumeAttachmentConsumers evidence))
            (Left "maintenance PVC has another Pod or attachment consumer")
          unless clientsGone
            (Left "maintenance database clients remain")
          unless (guarded && isJust policy && authority)
            (Left "maintenance mount or network exclusion changed during observation")
          pure True

releaseMaintenanceWriters :: KubernetesExclusion -> MaintenanceNetworkTransport
  -> Engine -> MaintenanceNetworkPin -> DataFenceRecord -> IO (Either Text ())
releaseMaintenanceWriters exclusion network engine pin record = case
  maintenanceIntent exclusion engine pin record of
  Left reason -> pure (Left reason)
  Right (_, root, image) -> do
    pod <- observeMaintenancePod exclusion engine pin root image
    case pod of
      Left reason -> pure (Left reason)
      Right () -> do
        restored <- releaseKubernetesWriters exclusion record
        case restored of
          Left reason -> pure (Left reason)
          Right () -> removeMaintenancePolicy network pin

observeMaintenanceRelease :: KubernetesExclusion -> MaintenanceNetworkTransport
  -> Engine -> MaintenanceNetworkPin -> DataFenceRecord -> IO (Either Text WriterReleaseState)
observeMaintenanceRelease exclusion network engine pin record = case
  maintenanceIntent exclusion engine pin record of
  Left reason -> pure (Left reason)
  Right (_, root, image) -> do
    pod <- observeMaintenancePod exclusion engine pin root image
    writers <- observeKubernetesRelease exclusion record
    policy <- observeMaintenancePolicy network pin
    pure $ do
      _ <- pod
      state <- writers
      present <- policy
      pure $ if isJust present && state == WritersFullyReleased
        then WritersPartlyReleased else state

-- | Admission behavior and policy-edit authority are separate proof parts.
-- The checked principals come from the private intent and accepted native
-- workload templates;
-- an authorized policy editor invalidates exclusion even if a Pod dry-run
-- happens to be denied at this instant.
observeProtectedMountGuard :: KubernetesExclusion -> KubernetesFenceIntent
  -> MountGuard -> IO (Either Text Bool)
observeProtectedMountGuard exclusion intent mountGuard = do
  enforcing <- observeMountGuard (exclusionGuardTransport exclusion) mountGuard
  case enforcing of
    Left reason -> pure (Left reason)
    Right False -> pure (Right False)
    Right True -> case protectedGuardPrincipals exclusion intent of
      Left reason -> pure (Left reason)
      Right principals -> observeGuardAuthority
        (exclusionGuardAccessTransport exclusion) principals mountGuard

-- | Accepted native Pod templates fix the managed workload identities whose
-- Kubernetes RBAC must not permit changes to guard policies or bindings.
protectedGuardPrincipals :: KubernetesExclusion -> KubernetesFenceIntent
  -> Either Text [Text]
protectedGuardPrincipals exclusion intent = do
  workloads <- protectedWorkloadPrincipals exclusion intent
  pure (Set.toAscList (Set.fromList
    (kubernetesGuardPrincipals intent <> workloads)))

-- Network ingress exclusion must be uneditable by accepted workloads. The
-- reviewed controller principals operate those workloads and are trusted by
-- the mount guard; Kubernetes necessarily grants them Pod creation rights.
protectedWorkloadPrincipals :: KubernetesExclusion -> KubernetesFenceIntent
  -> Either Text [Text]
protectedWorkloadPrincipals exclusion intent = do
  stateful <- traverse (\(resource, pin) -> acceptedPrincipal resource
    (writerNamespace pin) ["template", "spec"])
    (kubernetesStatefulWriters intent)
  deployments <- traverse (\(resource, pin) -> acceptedPrincipal resource
    (Deployment.writerNamespace pin) ["template", "spec"])
    (kubernetesDeploymentWriters intent)
  schedules <- traverse (\(resource, pin) -> acceptedPrincipal resource
    (scheduleNamespace pin) ["jobTemplate", "spec", "template", "spec"])
    (kubernetesScheduledWriters intent)
  jobs <- traverse (\(resource, pin) -> acceptedPrincipal resource
    (completedJobNamespace pin) ["template", "spec"])
    (kubernetesCompletedJobs intent)
  let targetDefault = "system:serviceaccount:"
        <> guardNamespaceName (kubernetesMountGuard intent) <> ":default"
  pure (Set.toAscList (Set.fromList
    (targetDefault : stateful <> deployments <> schedules <> jobs)))
  where
    acceptedPrincipal resource namespace path = do
      (_, bytes) <- maybe
        (Left "fenced workload lacks accepted native evidence") Right
        (Map.lookup resource (exclusionNative exclusion))
      value <- first T.pack (eitherDecodeStrict' bytes)
      workloadServiceAccountPrincipal namespace ("spec" : path) value

-- A workload in the database namespace or a declared route-dependent client
-- may reach the database, including a Knative Service without a PVC mount.
-- Its identity must not be able to add an allowing policy or start a local
-- or host-network client. Unrelated platform controllers remain trusted.
protectedNetworkPrincipals :: KubernetesExclusion -> KubernetesFenceIntent
  -> Either Text [Text]
protectedNetworkPrincipals exclusion intent = do
  selected <- protectedWorkloadPrincipals exclusion intent
  let roots = Set.fromList
        (kubernetesDependencyRoot intent :
          maybe [] (pure . serviceResource) (kubernetesService intent))
      connected = dependentClosure roots (exclusionDeclarations exclusion)
      targetNamespace = guardNamespaceName (kubernetesMountGuard intent)
  others <- traverse principal
    [(namespace, path, bytes)
      | (resource, (member, bytes)) <- Map.toAscList (exclusionNative exclusion)
      , Kubernetes cluster group kind (Just name) _ <- [address member]
      , cluster == kubernetesCluster intent
      , Just path <- [templatePath group (nameText kind)]
      , let namespace = nameText name
      , namespace == targetNamespace || Set.member resource connected]
  pure (Set.toAscList (Set.fromList (selected <> others)))
  where
    principal (namespace, path, bytes) = do
      value <- first T.pack (eitherDecodeStrict' bytes)
      workloadServiceAccountPrincipal namespace path value
    templatePath "apps" kind
      | kind `elem` ["statefulset", "deployment", "daemonset", "replicaset"] =
          Just ["spec", "template", "spec"]
    templatePath "batch" "job" = Just ["spec", "template", "spec"]
    templatePath "batch" "cronjob" =
      Just ["spec", "jobTemplate", "spec", "template", "spec"]
    templatePath "serving.knative.dev" "service" =
      Just ["spec", "template", "spec"]
    templatePath "" "pod" = Just ["spec"]
    templatePath _ _ = Nothing

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
  candidates <- (if kubernetesNetworkExcluded intent
      then discoverWriterCandidatesForIsolatedNetwork
      else discoverWriterCandidatesForRoutes)
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
            enforcing <- observeProtectedMountGuard exclusion intent
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
  completed <- forM (kubernetesCompletedJobs intent) $ \(_, pin) ->
    observeCompletedJob (exclusionCompletedJobTransport exclusion) pin
  service <- traverse (observeServiceState (exclusionServiceTransport exclusion))
    (kubernetesService intent)
  pure $ do
    _ <- engine
    _ <- volume
    sequence_ writers
    sequence_ deployments
    sequence_ schedules
    sequence_ completed
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
    before <- observeProtectedMountGuard exclusion intent mountGuard
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
        completed <- forM (kubernetesCompletedJobs intent) $ \(_, pin) ->
          observeCompletedJob (exclusionCompletedJobTransport exclusion) pin
        volume <- observeVolumeState (exclusionVolumeTransport exclusion)
          mountGuard (kubernetesVolumeBacking intent)
        service <- case kubernetesService intent of
          Nothing -> pure (Right True)
          Just pin -> fmap (fmap serviceHasNoEndpoints)
            (observeServiceState (exclusionServiceTransport exclusion) pin)
        after <- observeProtectedMountGuard exclusion intent mountGuard
        pure $ do
          _ <- engine
          stopped <- sequence writers
          deploymentStopped <- sequence deployments
          suspended <- sequence schedules
          terminalConsumers <- concat <$> sequence completed
          evidence <- volume
          serviceEmpty <- service
          guarded <- after
          pure (and stopped && and deploymentStopped && and suspended
            && sort (volumePodConsumers evidence) == sort terminalConsumers
            && null (volumeAttachmentConsumers evidence)
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
        acquisition <- observeProtectedMountGuard exclusion intent mountGuard
        releasing <- observeProtectedMountGuard exclusion intent releaseGuard
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
                overlay <- observeProtectedMountGuard exclusion intent releaseGuard
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
        intact <- observeProtectedMountGuard exclusion intent mountGuard
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
