-- | Strict decoding of the private, reviewed Kubernetes fence intent.
-- Provider callbacks reconstruct this value from durable history after a
-- restart; no observation or mutation may use an unvalidated raw JSON field.
module Nagare.Inventory.DataFence.KubernetesIntent
  ( KubernetesFenceIntent (..)
  , decodeKubernetesFenceIntent
  , parseAcceptedDatabaseEngine
  , parseObservedDatabaseServer
  , validateReviewedDatabaseEngine
  , validateKubernetesWriterInventory
  ) where

import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value (..), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Database (Engine, engineImage, engineToken, mkEngineVersion, parseEngine)
import Nagare.Dsl.Prelude
import Nagare.Inventory.DataFence.DeploymentWriter qualified as Deployment
import Nagare.Inventory.DataFence.MountGuard
import Nagare.Inventory.DataFence.ServiceState
import Nagare.Inventory.DataFence.ScheduledWriter
import Nagare.Inventory.DataFence.StatefulWriter
import Nagare.Inventory.DataFence.VolumeState (VolumeBacking (..))
import Nagare.Inventory.DataFence.WriterInventory
import Nagare.Inventory.Store (DataFenceRecord (..))
import Nagare.Resource.Types

data KubernetesFenceIntent = KubernetesFenceIntent
  { kubernetesCluster :: !ResourceId
  , kubernetesDependencyRoot :: !ResourceId
  , kubernetesDatabaseEngine :: !(Maybe Engine)
  , kubernetesVolumeResource :: !ResourceId
  , kubernetesMountGuard :: !MountGuard
  , kubernetesReleaseMountGuard :: !MountGuard
  , kubernetesVolumeBacking :: !VolumeBacking
  , kubernetesStatefulWriters :: ![(ResourceId, StatefulWriterPin)]
  , kubernetesDeploymentWriters :: ![(ResourceId, Deployment.DeploymentWriterPin)]
  , kubernetesScheduledWriters :: ![(ResourceId, ScheduledWriterPin)]
  , kubernetesWriterMountsTarget :: !(Map.Map ResourceId Bool)
  , kubernetesService :: !(Maybe ServicePin)
  , kubernetesGuardPrincipals :: ![Text]
  }
  deriving stock (Eq, Show)

data RawVolume = RawVolume
  { rawResource :: !ResourceId
  , rawNamespace :: !Text
  , rawClaim :: !Text
  , rawClaimUid :: !Text
  , rawPv :: !Text
  , rawPvUid :: !Text
  , rawBacking :: !VolumeBacking
  }

data RawWriter = RawWriter
  { rawWriterNamespace :: !Text
  , rawWriterName :: !Text
  , rawWriterUid :: !Text
  , rawWriterReplicas :: !Int
  , rawWriterSpecDigest :: !ContentDigest
  , rawWriterMountsTarget :: !Bool
  }

data RawSchedule = RawSchedule
  { rawScheduleNamespace :: !Text
  , rawScheduleName :: !Text
  , rawScheduleUid :: !Text
  , rawScheduleSuspend :: !(Maybe Bool)
  , rawScheduleSpecDigest :: !ContentDigest
  , rawScheduleMountsTarget :: !Bool
  }

data RawDeploymentWriter = RawDeploymentWriter
  { rawDeploymentNamespace :: !Text
  , rawDeploymentName :: !Text
  , rawDeploymentUid :: !Text
  , rawDeploymentReplicas :: !Int
  , rawDeploymentSpecDigest :: !ContentDigest
  , rawDeploymentSelector :: !(Map.Map Text Text)
  , rawDeploymentMountsTarget :: !Bool
  , rawDeploymentReplicaSet :: !(Maybe RawReplicaSet)
  }

data RawReplicaSet = RawReplicaSet
  { rawReplicaSetName :: !Text
  , rawReplicaSetUid :: !Text
  }

data RawSavedWriter
  = RawStateful !RawWriter
  | RawDeployment !RawDeploymentWriter
  | RawScheduled !RawSchedule

data WriterPin
  = PinnedStateful !StatefulWriterPin
  | PinnedDeployment !Deployment.DeploymentWriterPin !(Maybe RawReplicaSet)
  | PinnedScheduled !ScheduledWriterPin

data RawRestoreJob = RawRestoreJob
  { rawJobName :: !Text
  , rawJobUid :: !Text
  , rawJobPrincipal :: !Text
  }

data RawService = RawService
  { rawServiceResource :: !ResourceId
  , rawServiceNamespace :: !Text
  , rawServiceName :: !Text
  , rawServiceUid :: !Text
  , rawServiceClusterIP :: !Text
  , rawServiceSelector :: !(Map.Map Text Text)
  }

decodeKubernetesFenceIntent :: DataFenceRecord
  -> Either Text KubernetesFenceIntent
decodeKubernetesFenceIntent record = do
  source <- maybe (Left "data fence lacks Kubernetes provider intent") Right
    (fenceProviderIntent record)
  (cluster, root, volume, controllerPrincipal, replicaSetPrincipal, rawEngine,
    restoreJob, rawService) <- first T.pack
    (parseEither parseProvider source)
  databaseEngine <- traverse (\token -> maybe
    (Left "reviewed database engine is unsupported") Right (parseEngine token)) rawEngine
  service <- traverse (\raw -> mkServicePin (rawServiceResource raw)
    (rawServiceNamespace raw) (rawServiceName raw) (rawServiceUid raw)
    (rawServiceClusterIP raw) (rawServiceSelector raw)) rawService
  unless (Set.member root (Set.union (fenceTargets record)
      (fenceAffected record)))
    (Left "Kubernetes dependency root is outside the fenced target and writers")
  unless (fenceTargets record == Set.singleton (rawResource volume))
    (Left "Kubernetes fence target differs from its reviewed PVC")
  unless (fmap physicalIdentityText
      (Map.lookup (rawResource volume) (fencePhysical record))
        == Just (rawClaimUid volume))
    (Left "Kubernetes fence PVC UID differs from durable physical identity")
  writers <- forM (Map.toAscList (fenceSavedWriters record)) $ \(resource, value) -> do
    raw <- first T.pack (parseEither parseSavedWriter value)
    let uid = case raw of
          RawStateful writer -> rawWriterUid writer
          RawDeployment deployment -> rawDeploymentUid deployment
          RawScheduled schedule -> rawScheduleUid schedule
    unless (fmap physicalIdentityText (Map.lookup resource (fencePhysical record))
        == Just uid)
      (Left "Kubernetes writer UID differs from durable physical identity")
    case raw of
      RawStateful writer -> do
        pin <- mkStatefulWriterPin (rawWriterNamespace writer) (rawWriterName writer)
          (rawWriterUid writer) (rawWriterReplicas writer)
          (rawWriterSpecDigest writer)
        unless (not (rawWriterMountsTarget writer)
            || rawWriterNamespace writer == rawNamespace volume)
          (Left "Kubernetes PVC writer belongs to another namespace")
        pure (resource, PinnedStateful pin, rawWriterMountsTarget writer)
      RawDeployment deployment -> do
        pin <- Deployment.mkDeploymentWriterPin
          (rawDeploymentNamespace deployment) (rawDeploymentName deployment)
          (rawDeploymentUid deployment) (rawDeploymentReplicas deployment)
          (rawDeploymentSpecDigest deployment)
          (rawDeploymentSelector deployment)
        unless (not (rawDeploymentMountsTarget deployment)
            || rawDeploymentNamespace deployment == rawNamespace volume)
          (Left "Kubernetes PVC writer belongs to another namespace")
        let replicaSet = rawDeploymentReplicaSet deployment
        unless (if rawDeploymentMountsTarget deployment
            && rawDeploymentReplicas deployment > 0
          then maybe False (const True) replicaSet
          else isNothing replicaSet)
          (Left "reviewed PVC-mounting Deployment lacks an exact ReplicaSet")
        pure (resource, PinnedDeployment pin replicaSet,
          rawDeploymentMountsTarget deployment)
      RawScheduled schedule -> do
        pin <- mkScheduledWriterPin (rawScheduleNamespace schedule)
          (rawScheduleName schedule) (rawScheduleUid schedule)
          (rawScheduleSuspend schedule) (rawScheduleSpecDigest schedule)
        unless (not (rawScheduleMountsTarget schedule)
            || rawScheduleNamespace schedule == rawNamespace volume)
          (Left "Kubernetes PVC writer belongs to another namespace")
        pure (resource, PinnedScheduled pin, rawScheduleMountsTarget schedule)
  let statefulWriters = [(resource, pin)
        | (resource, PinnedStateful pin, _) <- writers]
      deploymentWriters = [(resource, pin)
        | (resource, PinnedDeployment pin _, _) <- writers]
      scheduledWriters = [(resource, pin)
        | (resource, PinnedScheduled pin, _) <- writers]
  let serviceIds = maybe Set.empty (Set.singleton . serviceResource) service
  unless (Set.null (Set.intersection serviceIds
      (Set.union (fenceTargets record) (fenceAffected record))))
    (Left "Kubernetes Service overlaps a fenced target or writer")
  unless (maybe True (\pin -> fmap physicalIdentityText
      (Map.lookup (serviceResource pin) (fencePhysical record))
        == Just (serviceUid pin)) service)
    (Left "Kubernetes Service UID differs from durable physical identity")
  unless (Map.keysSet (fenceSavedWriters record) == fenceAffected record
      && Map.keysSet (fencePhysical record)
        == Set.unions [fenceTargets record, fenceAffected record, serviceIds])
    (Left "Kubernetes fence does not bind exactly every target, writer, and Service")
  restorePermit <- traverse (\job -> mkPodOwnerPermit "Job" (rawJobName job)
    (rawJobUid job) (rawJobPrincipal job)) restoreJob
  -- A saved StatefulSet must not be permitted here: a foreign scale-up could
  -- recreate its Pod during recovery. It may mount only after verified release
  -- removes this guard.
  volumeGuard <- mkMountGuard (fenceSession record)
    (rawNamespace volume) (rawClaim volume) (rawClaimUid volume)
    (rawPv volume) (rawPvUid volume)
    (maybe [] (: []) restorePermit)
  writerGuard <- withGuardedStatefulSets volumeGuard
    [(writerNamespace pin, writerName pin, writerUid pin)
      | (_, pin) <- statefulWriters]
  deploymentGuard <- withGuardedDeployments writerGuard
    [(Deployment.writerNamespace pin, Deployment.writerName pin,
      Deployment.writerUid pin, Deployment.writerSelector pin)
      | (_, pin) <- deploymentWriters]
  scheduleGuard <- withGuardedSchedules deploymentGuard
    [(scheduleNamespace pin, scheduleName pin, scheduleUid pin)
      | (_, pin) <- scheduledWriters]
  mountGuard <- maybe (Right scheduleGuard) (\pin -> withGuardedService scheduleGuard
    (serviceNamespace pin) (serviceName pin) (serviceUid pin)) service
  releasePermits <- traverse (\(_, pin) -> mkPodOwnerPermit "StatefulSet"
    (writerName pin) (writerUid pin) controllerPrincipal) statefulWriters
  replicaSetPermits <- forM
    [replicaSet | (_, PinnedDeployment _ (Just replicaSet), True) <- writers]
    $ \replicaSet -> do
      principal <- maybe
        (Left "PVC-mounting Deployment lacks a ReplicaSet controller principal")
        Right replicaSetPrincipal
      mkPodOwnerPermit "ReplicaSet" (rawReplicaSetName replicaSet)
        (rawReplicaSetUid replicaSet) principal
  let releaseGuard = releaseMountGuard mountGuard
        (releasePermits <> replicaSetPermits)
      guardPrincipals = Set.toAscList (Set.fromList
        ([controllerPrincipal]
          <> maybe [] (pure . rawJobPrincipal) restoreJob
          <> maybe [] pure replicaSetPrincipal))
  validateBacking (rawBacking volume)
  pure (KubernetesFenceIntent cluster root databaseEngine (rawResource volume)
    mountGuard releaseGuard (rawBacking volume)
    statefulWriters deploymentWriters scheduledWriters
    (Map.fromList [(resource, mounted) | (resource, _, mounted) <- writers])
    service guardPrincipals)

-- | Reconcile the saved writer pins with the complete accepted native
-- discovery before any provider mutation. Dependency clients and direct PVC
-- mounts must be represented by the same exact Kubernetes controllers.
validateKubernetesWriterInventory :: KubernetesFenceIntent
  -> [WriterCandidate] -> Either Text ()
validateKubernetesWriterInventory intent candidates = do
  let pinned = Map.fromList ([(resource, PinnedStateful pin)
        | (resource, pin) <- kubernetesStatefulWriters intent]
        <> [(resource, PinnedDeployment pin Nothing)
        | (resource, pin) <- kubernetesDeploymentWriters intent]
        <> [(resource, PinnedScheduled pin)
        | (resource, pin) <- kubernetesScheduledWriters intent])
      discovered = Map.fromList [(candidateResource candidate, candidate)
        | candidate <- candidates]
  unless (length candidates == Map.size discovered
      && Map.keysSet pinned == Map.keysSet discovered)
    (Left "accepted writer discovery differs from reviewed fence writers")
  forM_ (Map.toAscList pinned) $ \(resource, pin) -> do
    candidate <- maybe (Left "accepted writer is missing") Right
      (Map.lookup resource discovered)
    unless (case pin of
        PinnedStateful stateful -> candidateKind candidate == StatefulSetWriter
          && matchesWriterAddress intent stateful (candidateAddress candidate)
        PinnedDeployment deployment _ -> candidateKind candidate == DeploymentWriter
          && matchesDeploymentAddress intent deployment (candidateAddress candidate)
        PinnedScheduled scheduled -> candidateKind candidate == CronJobWriter
          && matchesScheduleAddress intent scheduled (candidateAddress candidate))
      (Left "accepted writer controller differs from reviewed fence writer")
    unless (Map.lookup resource (kubernetesWriterMountsTarget intent)
        == Just (candidateByMount candidate))
      (Left "accepted PVC mount differs from reviewed writer intent")

matchesWriterAddress :: KubernetesFenceIntent -> StatefulWriterPin
  -> ProviderAddress -> Bool
matchesWriterAddress intent pin (Kubernetes cluster "apps" kind namespace name) =
  cluster == kubernetesCluster intent
    && nameText kind == "statefulset"
    && fmap nameText namespace == Just (writerNamespace pin)
    && nameText name == writerName pin
matchesWriterAddress _ _ _ = False

matchesDeploymentAddress :: KubernetesFenceIntent
  -> Deployment.DeploymentWriterPin -> ProviderAddress -> Bool
matchesDeploymentAddress intent pin (Kubernetes cluster "apps" kind namespace name) =
  cluster == kubernetesCluster intent
    && nameText kind == "deployment"
    && fmap nameText namespace == Just (Deployment.writerNamespace pin)
    && nameText name == Deployment.writerName pin
matchesDeploymentAddress _ _ _ = False

matchesScheduleAddress :: KubernetesFenceIntent -> ScheduledWriterPin
  -> ProviderAddress -> Bool
matchesScheduleAddress intent pin (Kubernetes cluster "batch" kind namespace name) =
  cluster == kubernetesCluster intent
    && nameText kind == "cronjob"
    && fmap nameText namespace == Just (scheduleNamespace pin)
    && nameText name == scheduleName pin
matchesScheduleAddress _ _ _ = False

validateBacking :: VolumeBacking -> Either Text ()
validateBacking (CsiVolume driver handle) =
  unless (not (T.null driver) && not (T.null handle)
    && T.all (>= ' ') driver && T.all (>= ' ') handle)
    (Left "Kubernetes CSI driver or handle is empty or malformed")
validateBacking (LocalVolume path node) = do
  unless ("/" `T.isPrefixOf` path && T.all (>= ' ') path)
    (Left "Kubernetes local PV path is not absolute")
  _ <- mkName node
  pure ()

-- | A managed database marker must resolve to exactly one supported server
-- image and a pinned version. A generic StatefulSet without that marker is a
-- volume writer, not a database engine. Replayed intent checks these accepted
-- native bytes again before any provider effect.
parseAcceptedDatabaseEngine :: ByteString -> Either Text (Maybe Engine)
parseAcceptedDatabaseEngine bytes = do
  value <- first T.pack (eitherDecodeStrict' bytes)
  fmap fst <$> parseObservedDatabaseServer value

-- | Use the same strict engine check for accepted bytes and a live
-- StatefulSet observation. A captured live spec digest alone can pin a
-- drifted server image rather than the accepted engine.
parseObservedDatabaseServer :: Value -> Either Text (Maybe (Engine, Text))
parseObservedDatabaseServer observed = do
  root <- requiredObjectValue "accepted StatefulSet" observed
  case KM.lookup "metadata" root of
    Nothing -> Right Nothing
    Just metadataValue -> do
      metadata <- requiredObjectValue "accepted StatefulSet metadata" metadataValue
      case KM.lookup "labels" metadata of
        Nothing -> Right Nothing
        Just labelsValue -> do
          labels <- requiredObjectValue "accepted StatefulSet labels" labelsValue
          case KM.lookup "nagare.dev/database" labels of
            Nothing -> Right Nothing
            Just (String database) | not (T.null database) -> do
              kind <- requiredText "kind" root
              unless (kind == "StatefulSet")
                (Left "accepted managed database is not a StatefulSet")
              spec <- requiredObject "spec" root
              template <- requiredObject "template" spec
              pod <- requiredObject "spec" template
              containers <- requiredArray "containers" pod
              container <- case containers of
                [containerValue] -> requiredObjectValue "managed database container" containerValue
                _ -> Left "managed database must have exactly one server container"
              name <- requiredText "name" container
              engine <- maybe (Left "managed database engine is unsupported") Right
                (parseEngine name)
              image <- requiredText "image" container
              version <- maybe (Left "managed database image differs from its engine")
                Right (T.stripPrefix (engineImage engine <> ":") image)
              _ <- mkEngineVersion engine version
              unless (name == engineToken engine)
                (Left "managed database container differs from its engine")
              pure (Just (engine, image))
            Just _ -> Left "managed database label is malformed"
  where
    requiredObject key fields = maybe
      (Left ("accepted managed database lacks " <> key))
      (requiredObjectValue ("accepted managed database " <> key))
      (KM.lookup (Key.fromText key) fields)
    requiredObjectValue _ (Object fields) = Right fields
    requiredObjectValue label _ = Left (label <> " is not an object")
    requiredText key fields = case KM.lookup (Key.fromText key) fields of
      Just (String value) | not (T.null value) -> Right value
      _ -> Left ("accepted managed database lacks " <> key)
    requiredArray key fields = case KM.lookup (Key.fromText key) fields of
      Just (Array values) -> Right (V.toList values)
      _ -> Left ("accepted managed database lacks " <> key)

validateReviewedDatabaseEngine :: Maybe Engine -> ByteString -> Either Text ()
validateReviewedDatabaseEngine reviewed bytes = do
  accepted <- parseAcceptedDatabaseEngine bytes
  unless (accepted == reviewed)
    (Left "reviewed database engine differs from accepted native evidence")

parseProvider :: Value
  -> Parser (ResourceId, ResourceId, RawVolume, Text, Maybe Text, Maybe Text,
      Maybe RawRestoreJob, Maybe RawService)
parseProvider = withObject "Kubernetes fence intent" $ \o -> do
  onlyKeys ["version", "provider", "cluster", "dependencyRoot", "volume",
    "statefulControllerPrincipal", "replicaSetControllerPrincipal",
    "databaseEngine", "restoreJob", "service"] o
  version <- o .: "version" :: Parser Int
  unless (version == 3) (fail "unsupported Kubernetes fence intent version")
  provider <- o .: "provider" :: Parser Text
  unless (provider == "kubernetes") (fail "data fence provider is not Kubernetes")
  (,,,,,,,) <$> o .: "cluster" <*> o .: "dependencyRoot"
    <*> (o .: "volume" >>= parseVolume)
    <*> o .: "statefulControllerPrincipal"
    <*> o .:? "replicaSetControllerPrincipal"
    <*> o .:? "databaseEngine"
    <*> (o .:? "restoreJob" >>= traverse parseJob)
    <*> (o .:? "service" >>= traverse parseService)

parseService :: Value -> Parser RawService
parseService = withObject "Kubernetes fence Service" $ \o -> do
  onlyKeys ["resource", "namespace", "name", "uid", "clusterIP", "selector"] o
  RawService <$> o .: "resource" <*> o .: "namespace" <*> o .: "name"
    <*> o .: "uid" <*> o .: "clusterIP" <*> o .: "selector"

parseVolume :: Value -> Parser RawVolume
parseVolume = withObject "Kubernetes fence volume" $ \o -> do
  onlyKeys ["resource", "namespace", "claim", "claimUid", "pv", "pvUid", "backing"] o
  RawVolume <$> o .: "resource" <*> o .: "namespace" <*> o .: "claim"
    <*> o .: "claimUid" <*> o .: "pv" <*> o .: "pvUid"
    <*> (o .: "backing" >>= parseBacking)

parseBacking :: Value -> Parser VolumeBacking
parseBacking = withObject "Kubernetes volume backing" $ \o -> do
  kind <- o .: "kind" :: Parser Text
  case kind of
    "csi" -> do
      onlyKeys ["kind", "driver", "handle"] o
      CsiVolume <$> o .: "driver" <*> o .: "handle"
    "local" -> do
      onlyKeys ["kind", "path", "node"] o
      LocalVolume <$> o .: "path" <*> o .: "node"
    _ -> fail "unsupported Kubernetes volume backing"

parseSavedWriter :: Value -> Parser RawSavedWriter
parseSavedWriter = withObject "saved Kubernetes writer" $ \o -> do
  kind <- o .: "kind" :: Parser Text
  case kind of
    "StatefulSet" -> do
      onlyKeys ["kind", "namespace", "name", "uid", "replicas", "specDigest", "mountsTarget"] o
      RawStateful <$> (RawWriter <$> o .: "namespace" <*> o .: "name"
        <*> o .: "uid" <*> o .: "replicas" <*> o .: "specDigest"
        <*> o .: "mountsTarget")
    "Deployment" -> do
      onlyKeys ["kind", "namespace", "name", "uid", "replicas", "specDigest",
        "selector", "mountsTarget", "replicaSet"] o
      RawDeployment <$> (RawDeploymentWriter <$> o .: "namespace"
        <*> o .: "name" <*> o .: "uid" <*> o .: "replicas"
        <*> o .: "specDigest" <*> o .: "selector"
        <*> o .: "mountsTarget"
        <*> (o .:? "replicaSet" >>= traverse parseReplicaSet))
    "CronJob" -> do
      onlyKeys ["kind", "namespace", "name", "uid", "suspend", "specDigest", "mountsTarget"] o
      RawScheduled <$> (RawSchedule <$> o .: "namespace" <*> o .: "name"
        <*> o .: "uid" <*> o .:? "suspend" <*> o .: "specDigest"
        <*> o .: "mountsTarget")
    _ -> fail "Kubernetes writer has no implemented stop control"

parseJob :: Value -> Parser RawRestoreJob
parseJob = withObject "Kubernetes restore Job" $ \o -> do
  onlyKeys ["name", "uid", "controllerPrincipal"] o
  RawRestoreJob <$> o .: "name" <*> o .: "uid"
    <*> o .: "controllerPrincipal"

parseReplicaSet :: Value -> Parser RawReplicaSet
parseReplicaSet = withObject "reviewed Deployment ReplicaSet" $ \o -> do
  onlyKeys ["name", "uid"] o
  RawReplicaSet <$> o .: "name" <*> o .: "uid"

onlyKeys :: [Key] -> KM.KeyMap Value -> Parser ()
onlyKeys allowed fields = unless (all (`elem` allowed) (KM.keys fields))
  (fail "Kubernetes fence intent has an unknown field")
