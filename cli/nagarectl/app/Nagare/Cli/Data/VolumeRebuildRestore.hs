-- | EP-183 M4: `storage restore-rebuilt` saves the review that restores a
-- rebuilt application volume from the manual snapshot its rebuild named. The
-- snapshot is verified from the object store (or an offline copy) against the
-- inventory's record of it, so the lost cluster's completed snapshot Pod is not
-- needed. Executable-private CLI boundary.
module Nagare.Cli.Data.VolumeRebuildRestore
  ( runVolumeRebuildRestorePlan
  , recordedVolumeSnapshot
  , recordedVolumeRun
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Data.SigningKeyEscrow (withRecoveryStore)
import Nagare.Cli.Inventory.Adapters (inventoryKubernetesAdapter)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Cluster.GcsJob (StoreBackend (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Identity (checkedPhysical, requireAccepted)
import Nagare.Inventory.Lineage (RebuildSource (FromRecoveryPoint), RecoveryPointKind (ScheduledVolumeRecoveryPoint, VolumeSnapshotRecoveryPoint))
import Nagare.Inventory.LineageHistory (memberLineage)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Inventory.VolumeRebuildRestore (VolumeRebuildRestoreRequest (..), compileVolumeRebuildRestoreScope)
import Nagare.Inventory.VolumeRestoreSource (verifyIngestedVolumeRun, verifyRecordedVolumeSnapshot)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Storage.Discover (pvcName)
import Nagare.Target (contextNameText)

-- | The accepted manual snapshot of one claim, by the receipt its rebuild names
-- or by its snapshot ID.
recordedVolumeSnapshot :: ResourceInventory.ScopeSnapshot -> Resource.ResourceId -> (Map.Map Text Text -> Bool) -> Either Text ResourceInventory.ScopeDeclaration
recordedVolumeSnapshot snapshot claim selected =
  case [ scope
       | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
       , let fields = ResourceInventory.scopeOverrides scope
       , Map.lookup "volume-backup.source.pvc" fields == Just (Resource.resourceIdText claim)
       , selected fields
       ] of
    [single] -> Right single
    _ -> Left "the claim has no unique accepted manual snapshot with that receipt or ID"

-- | The accepted, unpruned scheduled volume run of one claim (EP-183 M3), by
-- the receipt its rebuild names or by its run ID.
recordedVolumeRun :: ResourceInventory.ScopeSnapshot -> Resource.ResourceId -> (Map.Map Text Text -> Bool) -> Either Text ResourceInventory.ScopeDeclaration
recordedVolumeRun snapshot claim selected =
  case [ scope
       | scope <- scopes
       , let fields = ResourceInventory.scopeOverrides scope
       , Map.lookup "scheduled.backup.source.kind" fields == Just "volume"
       , Map.lookup "scheduled.backup.source.pvc" fields == Just (Resource.resourceIdText claim)
       , selected fields
       , Resource.scopeIdText (ResourceInventory.scopeId scope) `notElem` pruned
       ] of
    [single] -> Right single
    _ -> Left "the claim has no unique accepted, unpruned scheduled volume run with that receipt or ID"
  where
    scopes = map snd (Map.elems (ResourceInventory.snapshotScopes snapshot))
    pruned = [backup | scope <- scopes, Just backup <- [Map.lookup "scheduled.prune.backup.scope" (ResourceInventory.scopeOverrides scope)]]

runVolumeRebuildRestorePlan :: Maybe String -> Text -> Text -> Text -> Text -> Maybe String -> Maybe (String, FilePath) -> FilePath -> IO ()
runVolumeRebuildRestorePlan mctx app volume namespaceName restoreKey bucketArg offline output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  pvcAddress <- either dieT pure (Resource.kubernetesAddress cluster "v1" "PersistentVolumeClaim" (Just namespaceName) (pvcName app volume))
  (targetScope, pvc) <- case [ (scope, member)
                             | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
                             , bundle <- ResourceInventory.scopeBundles scope
                             , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                             , member ^. #address == pvcAddress
                             ] of
    [single] -> pure single
    _ -> dieT "a volume rebuild restore requires one accepted claim at the selected address"
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  let headValue = InventoryPlan.historyHead history
  lineage <-
    memberLineage store headValue (pvc ^. #identity)
      >>= either dieT pure
      >>= maybe (dieT "the claim's recorded incarnation was not created by a converged rebuild; a snapshot restores into it only through a scratch restore") pure
  point <- case lineage ^. #proof . #source of
    FromRecoveryPoint selected
      | selected ^. #kind `elem` [VolumeSnapshotRecoveryPoint, ScheduledVolumeRecoveryPoint] -> pure selected
    _ -> dieT "the claim's rebuild names no volume recovery point"
  -- A manual snapshot is checked against its snapshot record; a scheduled run
  -- against its ingestion record (EP-183 M3).
  (recoveryScope, verifyRecovery) <- either dieT pure $ case point ^. #kind of
    ScheduledVolumeRecoveryPoint ->
      (,verifyIngestedVolumeRun) <$> recordedVolumeRun snapshot (pvc ^. #identity) ((== Just (point ^. #receipt)) . Map.lookup "scheduled.backup.receipt")
    _ ->
      (,verifyRecordedVolumeSnapshot) <$> recordedVolumeSnapshot snapshot (pvc ^. #identity) ((== Just (point ^. #receipt)) . Map.lookup "volume-backup.receipt")
  targetRevision <- case Map.lookup (ResourceInventory.scopeId targetScope) (InventoryPlan.historyAccepted history) of
    Just (revision, accepted) | accepted == targetScope -> pure revision
    _ -> dieT "the claim's scope differs from accepted history"
  backend <- resolveStoreBackend mctx bucketArg
  credential <- case backend of
    GcsBackend {} -> pure Nothing
    MinioBackend ref -> do
      address <- either dieT pure (Resource.kubernetesAddress cluster "v1" "Secret" (Just namespaceName) (ref ^. #secretName))
      case [ member
           | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
           , bundle <- ResourceInventory.scopeBundles scope
           , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
           , member ^. #address == address
           ] of
        [single] -> pure (Just single)
        _ -> dieT "a local volume restore requires one accepted store credential Secret"
  inventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <- InventoryStatus.loadAcceptedNative store history inventory >>= either dieT pure
  let targetIds = pvc ^. #identity : [member ^. #identity | Just member <- [credential]]
      targetNative = Map.restrictKeys acceptedNative (Set.fromList targetIds)
  unless (Map.size targetNative == length targetIds) (dieT "the claim or its store credential lacks accepted private native evidence")
  adapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "volume target observation does not use a cache key"))
      targetNative
  observed <- InventoryAdapter.adapterObserve adapter targetIds >>= either dieT pure
  let live resource = case Map.lookup resource (InventoryAdapter.observationMap observed) of
        Just (InventoryAdapter.ObservedPresent uid) -> pure uid
        _ -> dieT "the claim or its store credential is absent, drifted or not ready"
  pvcLive <- live (pvc ^. #identity)
  pvcUid <- either dieT pure (requireAccepted "the rebuilt claim" (checkedPhysical (InventoryStore.headIncarnations headValue) (pvc ^. #identity) pvcLive))
  credentialPin <- traverse (\member -> (member,) <$> live (member ^. #identity)) credential
  recovery <-
    withRecoveryStore (contextNameText (active ^. #contextName)) backend offline (\reader -> verifyRecovery reader recoveryScope)
      >>= either dieT pure
  let request =
        VolumeRebuildRestoreRequest
          { app = app
          , volume = volume
          , namespace = namespaceName
          , restoreId = restoreKey
          , targetRevision = targetRevision
          , targetPvcUid = pvcUid
          , lineage = lineage
          , recovery = recovery
          , backend = backend
          , credential = credentialPin
          , source = Resource.SourceLocation ("storage restore-rebuilt/" <> app <> "/" <> volume) restoreKey
          }
  (restoreScope, restoreNative) <- either (dieT . T.pack . show) pure (compileVolumeRebuildRestoreScope request targetScope acceptedNative)
  case Map.lookup (ResourceInventory.scopeId restoreScope) (ResourceInventory.snapshotScopes snapshot) of
    Just (_, prior) | prior /= restoreScope -> dieT "restore ID already has different accepted intent; choose a new ID"
    _ -> pure ()
  candidate <- either (dieT . T.pack . show) pure (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope restoreScope NE.:| []))
  Inventory.planInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace (Map.union restoreNative targetNative))
    active
    candidate
    output
  TIO.putStrLn "Saved the reviewed volume rebuild restore. Apply it before the application serves from the volume."
