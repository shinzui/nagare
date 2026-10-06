-- | Data / Backup. Executable-private CLI boundary.
module Nagare.Cli.Data.Backup
  ( runReviewedDbBackupPlan
  , runReviewedDbPruneBackupPlan
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Nagare.Cli.Inventory.Adapters (inventoryKubernetesAdapter)
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesState (KubernetesPresent)
  , kubernetesObserve
  )
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  , mkKubernetesRuntimeOpsWithCacheKey
  , readBackupReceiptFromCompletedPod
  )
import Nagare.Inventory.Backup
  ( ManualBackupRequest
      ( ManualBackupRequest
      , backupId
      , backupSource
      , databaseName
      , expiresAt
      , namespaceName
      , sourceIncarnations
      , sourcePvcUid
      , sourceRevision
      , sourceStatefulUid
      , storageBackend
      )
  , compileManualBackupScope
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Prune
  ( ManualPruneRequest
      ( ManualPruneRequest
      , pruneBackupId
      , pruneBackupRevision
      , pruneBackupUid
      , pruneDatabaseName
      , pruneNamespaceName
      , pruneNow
      , pruneReceiptBytes
      , pruneSource
      , pruneStorageBackend
      )
  , compileManualPruneScope
  )
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (contextNameText)

runReviewedDbBackupPlan ::
  Maybe String -> Text -> Text -> Maybe String -> Text -> Maybe Text -> FilePath -> IO ()
runReviewedDbBackupPlan mctx database namespaceName bucketArg backupId expiryArg output = do
  expiry <- case expiryArg of
    Nothing -> pure Nothing
    Just expiryText -> case parseTimeM
                              True
                              defaultTimeLocale
                              "%Y-%m-%dT%H:%M:%SZ"
                              (T.unpack expiryText) ::
                              Maybe UTCTime of
      Nothing -> dieT "--expires-at must be UTC in YYYY-MM-DDTHH:MM:SSZ form"
      Just parsed -> do
        now <- getCurrentTime
        unless (parsed > now) (dieT "--expires-at must be in the future")
        pure (Just parsed)
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  statefulAddress <-
    either
      dieT
      pure
      ( Resource.kubernetesAddress
          cluster
          "apps/v1"
          "StatefulSet"
          (Just namespaceName)
          database
      )
  let sources =
        [ (scope, member)
        | (_, scope) <-
            Map.elems
              (ResourceInventory.snapshotScopes snapshot)
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
        , member ^. #address == statefulAddress
        ]
  (sourceScope, stateful) <- case sources of
    [single] -> pure single
    _ -> dieT "reviewed backup requires one accepted database StatefulSet at the selected address"
  pvcAddress <-
    either
      dieT
      pure
      ( Resource.kubernetesAddress
          cluster
          "v1"
          "PersistentVolumeClaim"
          (Just namespaceName)
          (dbPvcName database)
      )
  pvc <- case [ member
              | bundle <- ResourceInventory.scopeBundles sourceScope
              , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
              , member ^. #address == pvcAddress
              ] of
    [single] -> pure single
    _ -> dieT "reviewed backup requires one accepted database PVC in the source scope"
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  revision <- case Map.lookup
    (ResourceInventory.scopeId sourceScope)
    (InventoryPlan.historyAccepted history) of
    Just (acceptedRevision, acceptedScope) | acceptedScope == sourceScope -> pure acceptedRevision
    _ -> dieT "database source scope differs from accepted history"
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  let sourceIds = [stateful ^. #identity, pvc ^. #identity]
      sourceNative = Map.restrictKeys acceptedNative (Set.fromList sourceIds)
  unless
    (Map.size sourceNative == 2)
    (dieT "database StatefulSet or PVC lacks accepted private native evidence")
  sourceAdapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "backup source observation does not use a cache key"))
      sourceNative
  observed <- InventoryAdapter.adapterObserve sourceAdapter sourceIds >>= either dieT pure
  let physical resource = case Map.lookup resource (InventoryAdapter.observationMap observed) of
        Just (InventoryAdapter.ObservedPresent uid) -> pure uid
        _ -> dieT "database StatefulSet or PVC is absent, drifted, or not ready"
  statefulUid <- physical (stateful ^. #identity)
  pvcUid <- physical (pvc ^. #identity)
  backend <- resolveStoreBackend mctx bucketArg
  let request =
        ManualBackupRequest
          { databaseName = database
          , namespaceName = namespaceName
          , backupId = backupId
          , expiresAt = expiry
          , sourceRevision = revision
          , sourceStatefulUid = statefulUid
          , sourcePvcUid = pvcUid
          , storageBackend = backend
          , backupSource = Resource.SourceLocation ("db backup/" <> database) backupId
          , sourceIncarnations = InventoryStore.headIncarnations (InventoryPlan.historyHead history)
          }
  (backupScope, backupNative) <-
    either
      (dieT . T.pack . show)
      pure
      (compileManualBackupScope request sourceScope acceptedNative)
  case Map.lookup
    (ResourceInventory.scopeId backupScope)
    (ResourceInventory.snapshotScopes snapshot) of
    Just (_, prior)
      | prior /= backupScope ->
          dieT "backup ID already has a different accepted intent; choose a new ID"
    _ -> pure ()
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composeInventory
          snapshot
          (ResourceInventory.ReplaceScope backupScope NE.:| [])
      )
  Inventory.planInventoryCandidateWith
    ( inventoryPlanRegistryWithNative
        active
        workspace
        (Map.union backupNative sourceNative)
    )
    active
    candidate
    output
  TIO.putStrLn "Saved manual backup review. Apply it to submit the fixed Job and verify stored bytes."

runReviewedDbPruneBackupPlan ::
  Maybe String -> Text -> Text -> Text -> Maybe String -> FilePath -> IO ()
runReviewedDbPruneBackupPlan mctx database namespaceName backupId bucketArg output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  backupOwner <-
    either
      dieT
      pure
      ( Resource.mkScopeId
          Resource.Standalone
          ("database-backup-" <> namespaceName <> "-" <> database <> "-" <> backupId)
      )
  backupScope <- case Map.lookup backupOwner (ResourceInventory.snapshotScopes snapshot) of
    Just (_, accepted) -> pure accepted
    Nothing -> dieT "exact manual backup scope is not accepted"
  let backupJobs =
        [ member
        | bundle <- ResourceInventory.scopeBundles backupScope
        , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
        , case member ^. #address of
            Resource.Kubernetes _ "batch" kind (Just ns) _ ->
              Resource.nameText kind == "job" && Resource.nameText ns == namespaceName
            _ -> False
        ]
  backupJob <- case backupJobs of
    [single] -> pure single
    _ -> dieT "accepted manual backup has no unique Job"
  pruneOwner <-
    either
      dieT
      pure
      ( Resource.mkScopeId
          Resource.Standalone
          ("database-prune-" <> namespaceName <> "-" <> database <> "-" <> backupId)
      )
  let users =
        [ Resource.scopeIdText (ResourceInventory.scopeId scope)
        | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
        , ResourceInventory.scopeId scope /= backupOwner
        , ResourceInventory.scopeId scope /= pruneOwner
        , Map.lookup "restore.backup.scope" (ResourceInventory.scopeOverrides scope)
            == Just (Resource.scopeIdText backupOwner)
            || any
              ( \bundle ->
                  any
                    ( \case
                        ResourceInventory.Managed member ->
                          ResourceReference.OrderedAfter (backupJob ^. #identity)
                            `elem` (member ^. #dependencies)
                        _ -> False
                    )
                    (ResourceInventory.declarations bundle)
              )
              (ResourceInventory.scopeBundles scope)
        ]
  unless
    (null users)
    (dieT ("accepted restore scopes still depend on this backup: " <> T.intercalate ", " users))
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  backupRevision <- case Map.lookup backupOwner (InventoryPlan.historyAccepted history) of
    Just (revision, accepted) | accepted == backupScope -> pure revision
    _ -> dieT "manual backup scope differs from accepted history"
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  backupNative <- case Map.lookup (backupJob ^. #identity) acceptedNative of
    Just pair | fst pair == backupJob -> pure (Map.singleton (backupJob ^. #identity) pair)
    _ -> dieT "accepted manual backup Job lacks exact private native evidence"
  context <-
    either
      dieT
      pure
      ( Resource.mkContextId
          (contextNameText (active ^. #contextName))
      )
  let config =
        KubernetesRuntimeConfig
          context
          (contextNameText (active ^. #contextName))
          (fmap (fmap (const ())) (guardKubernetesContext active))
      ops =
        mkKubernetesRuntimeOpsWithCacheKey
          config
          (\_ -> pure (Left "backup Job observation does not use a cache key"))
          backupNative
  state <- kubernetesObserve ops (backupJob ^. #identity)
  backupUid <- case (state, Map.lookup (backupJob ^. #identity) backupNative) of
    (KubernetesPresent uid _ (Just owner) digest, Just (_, bytes))
      | owner == backupJob ^. #identity
          && digest == InventoryDigest.contentDigest bytes ->
          pure uid
    _ -> dieT "accepted backup Job is absent, incomplete, foreign, or drifted"
  receiptBytes <-
    readBackupReceiptFromCompletedPod
      config
      backupNative
      (backupJob ^. #identity)
      backupUid
      >>= either dieT pure
  backend <- resolveStoreBackend mctx bucketArg
  now <- getCurrentTime
  let request =
        ManualPruneRequest
          { pruneDatabaseName = database
          , pruneNamespaceName = namespaceName
          , pruneBackupId = backupId
          , pruneBackupRevision = backupRevision
          , pruneBackupUid = backupUid
          , pruneReceiptBytes = receiptBytes
          , pruneNow = now
          , pruneStorageBackend = backend
          , pruneSource = Resource.SourceLocation ("db prune-backup/" <> database) backupId
          }
  (pruneScope, pruneNative) <-
    either
      (dieT . T.pack . show)
      pure
      (compileManualPruneScope request backupScope backupNative)
  case Map.lookup
    (ResourceInventory.scopeId pruneScope)
    (ResourceInventory.snapshotScopes snapshot) of
    Just (_, prior)
      | prior /= pruneScope ->
          dieT "prune review under this backup ID has different accepted intent"
    _ -> pure ()
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composeInventory
          snapshot
          (ResourceInventory.ReplaceScope pruneScope NE.:| [])
      )
  Inventory.planInventoryCandidateWith
    ( inventoryPlanRegistryWithNative
        active
        workspace
        (Map.union pruneNative backupNative)
    )
    active
    candidate
    output
  TIO.putStrLn "Saved exact backup pruning review. Apply it after inspecting the object and receipt identities."
