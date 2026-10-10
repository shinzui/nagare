-- | EP-183 M4: `db restore-rebuilt` saves the review that loads a rebuilt
-- database's data (PostgreSQL, ClickHouse or Redis) from the one recovery point its rebuild named.
-- The receipt is verified with the predecessor's escrowed key, so neither the
-- lost cluster nor an ingestion is needed. Executable-private CLI boundary.
module Nagare.Cli.Data.RebuildRestore
  ( runRebuildRestorePlan
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Data.SigningKeyEscrow (decryptEscrow, escrowedReceiptEvidence)
import Nagare.Cli.Inventory.Adapters (inventoryKubernetesAdapter)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Cluster.GcsJob (storePrefixUrl)
import Nagare.Database.Backup (dbBackupKeyPrefix)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Lineage (RebuildSource (FromRecoveryPoint))
import Nagare.Inventory.LineageHistory (memberLineage)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.RebuildRestore (RebuildRestoreRequest (..), compileRebuildRestoreScope)
import Nagare.Inventory.Restore (restoreTargetPins)
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (contextNameText)

runRebuildRestorePlan :: Maybe String -> Text -> Text -> Text -> FilePath -> Maybe String -> Maybe (String, FilePath) -> FilePath -> IO ()
runRebuildRestorePlan mctx database namespaceName restoreKey escrowPath bucketArg offline output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  statefulAddress <- either dieT pure (Resource.kubernetesAddress cluster "apps/v1" "StatefulSet" (Just namespaceName) database)
  pvcAddress <- either dieT pure (Resource.kubernetesAddress cluster "v1" "PersistentVolumeClaim" (Just namespaceName) (dbPvcName database))
  (targetScope, stateful) <- case [ (scope, member)
                                  | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
                                  , bundle <- ResourceInventory.scopeBundles scope
                                  , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                                  , member ^. #address == statefulAddress
                                  ] of
    [single] -> pure single
    _ -> dieT "a rebuild restore requires one accepted database StatefulSet at the selected address"
  pvc <- case [ member
              | bundle <- ResourceInventory.scopeBundles targetScope
              , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
              , member ^. #address == pvcAddress
              ] of
    [single] -> pure single
    _ -> dieT "a rebuild restore requires one accepted database PVC"
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  let headValue = InventoryPlan.historyHead history
  lineage <-
    memberLineage store headValue (pvc ^. #identity)
      >>= either dieT pure
      >>= maybe (dieT "the database volume's recorded incarnation was not created by a converged rebuild; a backup restores into it only from its own incarnation") pure
  point <- case lineage ^. #proof . #source of
    FromRecoveryPoint selected -> pure selected
    _ -> dieT "the rebuild started the volume fresh; it names no recovery point"
  targetRevision <- case Map.lookup (ResourceInventory.scopeId targetScope) (InventoryPlan.historyAccepted history) of
    Just (revision, accepted) | accepted == targetScope -> pure revision
    _ -> dieT "the database scope differs from accepted history"
  inventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <- InventoryStatus.loadAcceptedNative store history inventory >>= either dieT pure
  let sourceIds = [stateful ^. #identity, pvc ^. #identity]
  adapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "rebuild restore target observation does not use a cache key"))
      (Map.restrictKeys acceptedNative (Set.fromList sourceIds))
  observed <- InventoryAdapter.adapterObserve adapter sourceIds >>= either dieT pure
  (statefulUid, pvcUid) <- either dieT pure (restoreTargetPins (InventoryStore.headIncarnations headValue) observed (stateful ^. #identity) (pvc ^. #identity))
  escrow <- decryptEscrow escrowPath
  unless
    (escrow ^. #context == contextNameText (active ^. #contextName) && escrow ^. #database == database && escrow ^. #namespace == namespaceName)
    (dieT "the escrow belongs to another context, database or namespace")
  backend <- resolveStoreBackend mctx bucketArg
  let prefix = storePrefixUrl backend (dbBackupKeyPrefix database)
      suffix = "." <> escrow ^. #format <> ".receipt.json"
  backupId <-
    maybe
      (dieT "the rebuild's recovery point is not a scheduled backup of this database in the selected store")
      pure
      (T.stripPrefix prefix (point ^. #receipt) >>= T.stripSuffix suffix)
  evidence <- escrowedReceiptEvidence escrow backend backupId offline >>= either dieT pure
  let request =
        RebuildRestoreRequest
          { database = database
          , namespace = namespaceName
          , restoreId = restoreKey
          , targetRevision = targetRevision
          , targetStatefulUid = statefulUid
          , targetPvcUid = pvcUid
          , lineage = lineage
          , escrowPvcUid = escrow ^. #pvcUid
          , evidence = evidence
          , backend = backend
          , source = Resource.SourceLocation ("db restore-rebuilt/" <> database) restoreKey
          }
  (restoreScope, restoreNative) <- either (dieT . T.pack . show) pure (compileRebuildRestoreScope request targetScope acceptedNative)
  case Map.lookup (ResourceInventory.scopeId restoreScope) (ResourceInventory.snapshotScopes snapshot) of
    Just (_, prior) | prior /= restoreScope -> dieT "restore ID already has different accepted intent; choose a new ID"
    _ -> pure ()
  candidate <- either (dieT . T.pack . show) pure (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope restoreScope NE.:| []))
  Inventory.planInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace (Map.union restoreNative (Map.restrictKeys acceptedNative (Set.fromList sourceIds))))
    active
    candidate
    output
  TIO.putStrLn "Saved the reviewed rebuild restore. Apply it to load the recovery point into the empty rebuilt database."
