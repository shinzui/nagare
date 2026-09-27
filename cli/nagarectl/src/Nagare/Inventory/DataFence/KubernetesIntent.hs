-- | Strict decoding of the private, reviewed Kubernetes fence intent.
-- Provider callbacks reconstruct this value from durable history after a
-- restart; no observation or mutation may use an unvalidated raw JSON field.
module Nagare.Inventory.DataFence.KubernetesIntent
  ( KubernetesFenceIntent (..)
  , decodeKubernetesFenceIntent
  , validateKubernetesWriterInventory
  ) where

import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value (..), withObject, (.:), (.:?))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
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
  , kubernetesVolumeResource :: !ResourceId
  , kubernetesMountGuard :: !MountGuard
  , kubernetesVolumeBacking :: !VolumeBacking
  , kubernetesStatefulWriters :: ![(ResourceId, StatefulWriterPin)]
  , kubernetesScheduledWriters :: ![(ResourceId, ScheduledWriterPin)]
  , kubernetesWriterMountsTarget :: !(Map.Map ResourceId Bool)
  , kubernetesService :: !(Maybe ServicePin)
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
  , rawWriterPrincipal :: !Text
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

data RawSavedWriter = RawStateful !RawWriter | RawScheduled !RawSchedule

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
  (cluster, root, volume, restoreJob, rawService) <- first T.pack
    (parseEither parseProvider source)
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
          RawScheduled schedule -> rawScheduleUid schedule
    unless (fmap physicalIdentityText (Map.lookup resource (fencePhysical record))
        == Just uid)
      (Left "Kubernetes writer UID differs from durable physical identity")
    case raw of
      RawStateful writer -> do
        pin <- mkStatefulWriterPin (rawWriterNamespace writer) (rawWriterName writer)
          (rawWriterUid writer) (rawWriterReplicas writer)
          (rawWriterSpecDigest writer)
        _ <- mkPodOwnerPermit "StatefulSet" (rawWriterName writer)
          (rawWriterUid writer) (rawWriterPrincipal writer)
        unless (not (rawWriterMountsTarget writer)
            || rawWriterNamespace writer == rawNamespace volume)
          (Left "Kubernetes PVC writer belongs to another namespace")
        pure (resource, Left pin, rawWriterMountsTarget writer)
      RawScheduled schedule -> do
        pin <- mkScheduledWriterPin (rawScheduleNamespace schedule)
          (rawScheduleName schedule) (rawScheduleUid schedule)
          (rawScheduleSuspend schedule) (rawScheduleSpecDigest schedule)
        unless (not (rawScheduleMountsTarget schedule)
            || rawScheduleNamespace schedule == rawNamespace volume)
          (Left "Kubernetes PVC writer belongs to another namespace")
        pure (resource, Right pin, rawScheduleMountsTarget schedule)
  let statefulWriters = [(resource, pin) | (resource, Left pin, _) <- writers]
      scheduledWriters = [(resource, pin) | (resource, Right pin, _) <- writers]
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
  scheduleGuard <- withGuardedSchedules writerGuard
    [(scheduleNamespace pin, scheduleName pin, scheduleUid pin)
      | (_, pin) <- scheduledWriters]
  mountGuard <- maybe (Right scheduleGuard) (\pin -> withGuardedService scheduleGuard
    (serviceNamespace pin) (serviceName pin) (serviceUid pin)) service
  validateBacking (rawBacking volume)
  pure (KubernetesFenceIntent cluster root (rawResource volume)
    mountGuard (rawBacking volume)
    statefulWriters scheduledWriters
    (Map.fromList [(resource, mounted) | (resource, _, mounted) <- writers]) service)

-- | Reconcile the saved writer pins with the complete accepted native
-- discovery before any provider mutation. Dependency clients and direct PVC
-- mounts must be represented by the same exact Kubernetes controllers.
validateKubernetesWriterInventory :: KubernetesFenceIntent
  -> [WriterCandidate] -> Either Text ()
validateKubernetesWriterInventory intent candidates = do
  let pinned = Map.fromList ([(resource, Left pin)
        | (resource, pin) <- kubernetesStatefulWriters intent]
        <> [(resource, Right pin)
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
        Left stateful -> candidateKind candidate == StatefulSetWriter
          && matchesWriterAddress intent stateful (candidateAddress candidate)
        Right scheduled -> candidateKind candidate == CronJobWriter
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

parseProvider :: Value
  -> Parser (ResourceId, ResourceId, RawVolume, Maybe RawRestoreJob, Maybe RawService)
parseProvider = withObject "Kubernetes fence intent" $ \o -> do
  onlyKeys ["version", "provider", "cluster", "dependencyRoot", "volume", "restoreJob", "service"] o
  version <- o .: "version" :: Parser Int
  unless (version == 1) (fail "unsupported Kubernetes fence intent version")
  provider <- o .: "provider" :: Parser Text
  unless (provider == "kubernetes") (fail "data fence provider is not Kubernetes")
  (,,,,) <$> o .: "cluster" <*> o .: "dependencyRoot"
    <*> (o .: "volume" >>= parseVolume)
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
      onlyKeys ["kind", "namespace", "name", "uid", "replicas", "specDigest", "controllerPrincipal", "mountsTarget"] o
      RawStateful <$> (RawWriter <$> o .: "namespace" <*> o .: "name"
        <*> o .: "uid" <*> o .: "replicas" <*> o .: "specDigest"
        <*> o .: "controllerPrincipal"
        <*> o .: "mountsTarget")
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

onlyKeys :: [Key] -> KM.KeyMap Value -> Parser ()
onlyKeys allowed fields = unless (all (`elem` allowed) (KM.keys fields))
  (fail "Kubernetes fence intent has an unknown field")
