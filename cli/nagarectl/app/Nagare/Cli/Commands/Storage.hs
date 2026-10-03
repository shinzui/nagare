-- | Commands / Storage. Executable-private CLI boundary.
module Nagare.Cli.Commands.Storage
  ( runStorage
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
import Nagare.Cli.Application.Config (resolveStorageDep)
import Nagare.Cli.Inventory.Adapters (inventoryKubernetesAdapter)
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Options (StorageCommand (..))
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Cluster.GcsJob (StoreBackend (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName)
import Nagare.Dsl.Types
  ( Deployment
  , namespaceText
  , serviceNameText
  , volumeNameText
  )
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesAdapterOps (kubernetesObserve)
  , KubernetesState (KubernetesPresent)
  )
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  , mkKubernetesRuntimeOpsWithCacheKey
  , readBackupReceiptFromCompletedPod
  )
import Nagare.Inventory.Backup
  ( VolumeSnapshotRequest
      ( VolumeSnapshotRequest
      , volumeApp
      , volumeBackupId
      , volumeBackupSource
      , volumeExpiresAt
      , volumeName
      , volumeNamespace
      , volumeSourcePvcUid
      , volumeSourceRevision
      , volumeStorageBackend
      , volumeStoreCredential
      )
  , compileVolumeSnapshotScope
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Restore
  ( VolumeRestoreRequest
      ( VolumeRestoreRequest
      , volumeRestoreApp
      , volumeRestoreBackend
      , volumeRestoreBackup
      , volumeRestoreBackupJobUid
      , volumeRestoreBackupRevision
      , volumeRestoreCredential
      , volumeRestoreId
      , volumeRestoreName
      , volumeRestoreNamespace
      , volumeRestoreNow
      , volumeRestoreReceiptBytes
      , volumeRestoreSource
      , volumeRestoreTargetPvcUid
      , volumeRestoreTargetRevision
      )
  )
import Nagare.Inventory.ScheduledGcs (withScheduledObjectStore)
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.VolumePrune
  ( VolumePruneRequest
      ( VolumePruneRequest
      , pruneVolumeApp
      , pruneVolumeBackend
      , pruneVolumeBackupId
      , pruneVolumeBackupRevision
      , pruneVolumeBackupUid
      , pruneVolumeCredential
      , pruneVolumeName
      , pruneVolumeNamespace
      , pruneVolumeNow
      , pruneVolumeReceiptBytes
      , pruneVolumeSource
      )
  , compileVolumePruneScope
  )
import Nagare.Inventory.VolumeRestore (compileVolumeRestoreScopeWithPins)
import Nagare.Inventory.VolumeRestoreSource (verifyVolumeBackupObjects)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Storage.Inspect (runStorageInspect)
import Nagare.Storage.List (runStorageList)
import Nagare.Storage.Restore (previewStorageRestore)
import Nagare.Storage.Snapshot (previewSnapshot)
import Nagare.Target (contextNameText)

runStorage :: Maybe String -> StorageCommand -> IO ()
runStorage mctx = \case
  StorageList copts -> resolveStorageDep copts >>= runStorageList
  StorageInspect copts vol -> do
    dep <- resolveStorageDep copts
    runStorageInspect dep (T.pack vol)
  StorageSnapshot copts vol bucket expiry snapshotId output dryRun -> do
    if dryRun
      then do
        when
          (isJust expiry || isJust snapshotId || isJust output)
          (dieT "storage snapshot --dry-run cannot save a reviewed snapshot")
        dep <- resolveStorageDep copts
        backend <- resolveStoreBackend mctx bucket
        previewSnapshot dep (T.pack vol) backend
      else case (snapshotId, output) of
        (Just stableId, Just directory) -> do
          dep <- resolveStorageDep copts
          backend <- resolveStoreBackend mctx bucket
          runReviewedVolumeSnapshotPlan
            mctx
            dep
            (T.pack vol)
            backend
            (T.pack stableId)
            (T.pack <$> expiry)
            directory
        _ -> dieT "live storage snapshot requires --snapshot-id ID and --save-plan DIR"
  StorageRestore copts vol backupId bucket live dryRun restoreId output -> do
    when live (dieT "live volume overwrite is deferred; restore to a new PVC")
    if dryRun
      then do
        when
          (isJust restoreId || isJust output)
          (dieT "storage restore --dry-run cannot save a reviewed restore")
        dep <- resolveStorageDep copts
        backend <- resolveStoreBackend mctx bucket
        previewStorageRestore dep (T.pack vol) (T.pack backupId) live backend
      else do
        case (restoreId, output) of
          (Just stableId, Just directory) -> do
            dep <- resolveStorageDep copts
            backend <- resolveStoreBackend mctx bucket
            runReviewedVolumeRestorePlan
              mctx
              dep
              (T.pack vol)
              (T.pack backupId)
              (T.pack stableId)
              backend
              directory
          _ -> dieT "live storage restore requires --restore-id ID and --save-plan DIR"
  StoragePrune copts vol backupId bucket output -> do
    dep <- resolveStorageDep copts
    backend <- resolveStoreBackend mctx bucket
    runReviewedVolumePrunePlan
      mctx
      dep
      (T.pack vol)
      (T.pack backupId)
      backend
      output

runReviewedVolumeSnapshotPlan ::
  Maybe String -> Deployment -> Text -> StoreBackend -> Text -> Maybe Text -> FilePath -> IO ()
runReviewedVolumeSnapshotPlan mctx dep volume backend snapshotId expiryArg output = do
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
  let appName = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)
      declared = map (volumeNameText . (^. #name)) (dep ^. #volumes)
  unless
    (volume `elem` declared)
    (dieT ("app " <> appName <> " declares no volume named '" <> volume <> "'"))
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  pvcAddress <-
    either
      dieT
      pure
      ( Resource.kubernetesAddress
          cluster
          "v1"
          "PersistentVolumeClaim"
          (Just ns)
          (pvcName appName volume)
      )
  let sources =
        [ (scope, member)
        | (_, scope) <-
            Map.elems
              (ResourceInventory.snapshotScopes snapshot)
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
        , member ^. #address == pvcAddress
        ]
  (sourceScope, pvc) <- case sources of
    [single] -> pure single
    _ -> dieT "reviewed volume snapshot requires one accepted PVC at the selected address"
  credential <- case backend of
    GcsBackend {} -> pure Nothing
    MinioBackend ref -> do
      address <-
        either
          dieT
          pure
          ( Resource.kubernetesAddress
              cluster
              "v1"
              "Secret"
              (Just ns)
              (ref ^. #secretName)
          )
      case [ member
           | (_, scope) <-
               Map.elems
                 (ResourceInventory.snapshotScopes snapshot)
           , bundle <- ResourceInventory.scopeBundles scope
           , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
           , member ^. #address == address
           ] of
        [single] -> pure (Just single)
        _ -> dieT "reviewed local snapshot requires one accepted store credential Secret in the app namespace"
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  revision <- case Map.lookup
    (ResourceInventory.scopeId sourceScope)
    (InventoryPlan.historyAccepted history) of
    Just (acceptedRevision, acceptedScope) | acceptedScope == sourceScope -> pure acceptedRevision
    _ -> dieT "volume source scope differs from accepted history"
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  let sourceIds = pvc ^. #identity : maybe [] (\member -> [member ^. #identity]) credential
      sourceNative = Map.restrictKeys acceptedNative (Set.fromList sourceIds)
  unless
    (Map.size sourceNative == length sourceIds)
    (dieT "PVC or store credential lacks accepted private native evidence")
  sourceAdapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "volume source observation does not use a cache key"))
      sourceNative
  observed <- InventoryAdapter.adapterObserve sourceAdapter sourceIds >>= either dieT pure
  let physical resource = case Map.lookup resource (InventoryAdapter.observationMap observed) of
        Just (InventoryAdapter.ObservedPresent uid) -> pure uid
        _ -> dieT "PVC or store credential is absent, drifted, or not ready"
  pvcUid <- physical (pvc ^. #identity)
  credentialPin <-
    traverse
      ( \member -> do
          uid <- physical (member ^. #identity)
          pure (member, uid)
      )
      credential
  let request =
        VolumeSnapshotRequest
          { volumeApp = appName
          , volumeName = volume
          , volumeNamespace = ns
          , volumeBackupId = snapshotId
          , volumeExpiresAt = expiry
          , volumeSourceRevision = revision
          , volumeSourcePvcUid = pvcUid
          , volumeStorageBackend = backend
          , volumeStoreCredential = credentialPin
          , volumeBackupSource =
              Resource.SourceLocation
                ("storage snapshot/" <> appName <> "/" <> volume)
                snapshotId
          }
  (backupScope, backupNative) <-
    either
      (dieT . T.pack . show)
      pure
      (compileVolumeSnapshotScope request sourceScope acceptedNative)
  case Map.lookup
    (ResourceInventory.scopeId backupScope)
    (ResourceInventory.snapshotScopes snapshot) of
    Just (_, prior)
      | prior /= backupScope ->
          dieT "snapshot ID already has a different accepted intent; choose a new ID"
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
  TIO.putStrLn "Saved volume snapshot review. Apply it to submit the fixed Job and verify stored bytes."

runReviewedVolumeRestorePlan ::
  Maybe String -> Deployment -> Text -> Text -> Text -> StoreBackend -> FilePath -> IO ()
runReviewedVolumeRestorePlan mctx dep volume backupId restoreId backend output = do
  let appName = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)
      declared = map (volumeNameText . (^. #name)) (dep ^. #volumes)
  unless
    (volume `elem` declared)
    (dieT ("app " <> appName <> " declares no volume named '" <> volume <> "'"))
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  pvcAddress <-
    either
      dieT
      pure
      ( Resource.kubernetesAddress
          cluster
          "v1"
          "PersistentVolumeClaim"
          (Just ns)
          (pvcName appName volume)
      )
  (targetScope, pvc) <- case [ (scope, member)
                             | (_, scope) <-
                                 Map.elems
                                   (ResourceInventory.snapshotScopes snapshot)
                             , bundle <- ResourceInventory.scopeBundles scope
                             , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                             , member ^. #address == pvcAddress
                             ] of
    [single] -> pure single
    _ -> dieT "reviewed volume restore requires one accepted target PVC"
  backupOwner <-
    either
      dieT
      pure
      ( Resource.mkScopeId
          Resource.Standalone
          ("volume-snapshot-" <> ns <> "-" <> appName <> "-" <> volume <> "-" <> backupId)
      )
  backupScope <- case Map.lookup backupOwner (ResourceInventory.snapshotScopes snapshot) of
    Just (_, accepted)
      | Map.lookup
          "volume-backup.id"
          (ResourceInventory.scopeOverrides accepted)
          == Just backupId
          && Map.lookup
            "volume-backup.source.pvc"
            (ResourceInventory.scopeOverrides accepted)
            == Just (Resource.resourceIdText (pvc ^. #identity)) ->
          pure accepted
    _ -> dieT "reviewed volume restore requires the exact accepted snapshot ID and PVC"
  backupJob <- case [ member
                    | bundle <- ResourceInventory.scopeBundles backupScope
                    , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                    , case member ^. #address of
                        Resource.Kubernetes _ "batch" kind (Just namespace) _ ->
                          Resource.nameText kind == "job" && Resource.nameText namespace == ns
                        _ -> False
                    ] of
    [single] -> pure single
    _ -> dieT "accepted volume snapshot has no unique Job"
  credential <- case backend of
    GcsBackend {} -> pure Nothing
    MinioBackend ref -> do
      address <-
        either
          dieT
          pure
          ( Resource.kubernetesAddress
              cluster
              "v1"
              "Secret"
              (Just ns)
              (ref ^. #secretName)
          )
      case [ member
           | (_, scope) <-
               Map.elems
                 (ResourceInventory.snapshotScopes snapshot)
           , bundle <- ResourceInventory.scopeBundles scope
           , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
           , member ^. #address == address
           ] of
        [single] -> pure (Just single)
        _ -> dieT "reviewed local restore requires one accepted store credential Secret"
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  let acceptedRevision selected = case Map.lookup
        (ResourceInventory.scopeId selected)
        (InventoryPlan.historyAccepted history) of
        Just (revision, accepted) | accepted == selected -> pure revision
        _ -> dieT "volume restore target or snapshot differs from accepted history"
  targetRevision <- acceptedRevision targetScope
  backupRevision <- acceptedRevision backupScope
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  let targetIds = pvc ^. #identity : maybe [] (\member -> [member ^. #identity]) credential
      targetNative = Map.restrictKeys acceptedNative (Set.fromList targetIds)
      backupNative =
        Map.restrictKeys
          acceptedNative
          (Set.singleton (backupJob ^. #identity))
  unless
    (Map.size targetNative == length targetIds && Map.size backupNative == 1)
    (dieT "volume restore target or backup Job lacks accepted private native evidence")
  targetAdapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "volume target observation does not use a cache key"))
      targetNative
  observed <- InventoryAdapter.adapterObserve targetAdapter targetIds >>= either dieT pure
  let physical resource = case Map.lookup resource (InventoryAdapter.observationMap observed) of
        Just (InventoryAdapter.ObservedPresent uid) -> pure uid
        _ -> dieT "volume target or credential is absent, drifted, or not ready"
  pvcUid <- physical (pvc ^. #identity)
  credentialPin <-
    traverse
      ( \member -> do
          uid <- physical (member ^. #identity)
          pure (member, uid)
      )
      credential
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
      backupOps =
        mkKubernetesRuntimeOpsWithCacheKey
          config
          (\_ -> pure (Left "volume snapshot observation does not use a cache key"))
          backupNative
  backupState <- kubernetesObserve backupOps (backupJob ^. #identity)
  backupUid <- case (backupState, Map.lookup (backupJob ^. #identity) backupNative) of
    (KubernetesPresent uid _ (Just owner) digest, Just (_, bytes))
      | owner == backupJob ^. #identity
          && digest == InventoryDigest.contentDigest bytes ->
          pure uid
    _ -> dieT "accepted volume snapshot Job is absent, incomplete, foreign, or drifted"
  receiptBytes <-
    readBackupReceiptFromCompletedPod
      config
      backupNative
      (backupJob ^. #identity)
      backupUid
      >>= either dieT pure
  -- Pin the exact stored objects now: a newer or altered archive or receipt
  -- refuses here, before any review exists or any destination is written.
  let backupField key =
        maybe
          (dieT ("accepted volume snapshot lacks " <> key))
          pure
          (Map.lookup key (ResourceInventory.scopeOverrides backupScope))
  objectUrl <- backupField "volume-backup.object"
  receiptUrl <- backupField "volume-backup.receipt"
  pins <-
    withScheduledObjectStore (contextNameText (active ^. #contextName)) backend (\reader -> verifyVolumeBackupObjects reader objectUrl receiptUrl receiptBytes)
      >>= either dieT pure
      >>= either dieT pure
  now <- getCurrentTime
  let request =
        VolumeRestoreRequest
          { volumeRestoreApp = appName
          , volumeRestoreName = volume
          , volumeRestoreNamespace = ns
          , volumeRestoreId = restoreId
          , volumeRestoreBackup = backupScope
          , volumeRestoreBackupRevision = backupRevision
          , volumeRestoreBackupJobUid = backupUid
          , volumeRestoreReceiptBytes = receiptBytes
          , volumeRestoreNow = now
          , volumeRestoreTargetRevision = targetRevision
          , volumeRestoreTargetPvcUid = pvcUid
          , volumeRestoreBackend = backend
          , volumeRestoreCredential = credentialPin
          , volumeRestoreSource =
              Resource.SourceLocation
                ("storage restore/" <> appName <> "/" <> volume)
                restoreId
          }
  (restoreScope, restoreNative) <-
    either
      (dieT . T.pack . show)
      pure
      (compileVolumeRestoreScopeWithPins (Just pins) request targetScope acceptedNative)
  case Map.lookup
    (ResourceInventory.scopeId restoreScope)
    (ResourceInventory.snapshotScopes snapshot) of
    Just (_, prior)
      | prior /= restoreScope ->
          dieT "restore ID already has different accepted intent; choose a new ID"
    _ -> pure ()
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composeInventory
          snapshot
          (ResourceInventory.ReplaceScope restoreScope NE.:| [])
      )
  Inventory.planInventoryCandidateWith
    ( inventoryPlanRegistryWithNative
        active
        workspace
        (Map.unions [restoreNative, targetNative, backupNative])
    )
    active
    candidate
    output
  TIO.putStrLn "Saved reviewed scratch volume restore. Apply it to verify stored bytes and create a separate PVC."

runReviewedVolumePrunePlan ::
  Maybe String -> Deployment -> Text -> Text -> StoreBackend -> FilePath -> IO ()
runReviewedVolumePrunePlan mctx dep volume backupId backend output = do
  let appName = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)
      declared = map (volumeNameText . (^. #name)) (dep ^. #volumes)
  unless
    (volume `elem` declared)
    (dieT ("app " <> appName <> " declares no volume named '" <> volume <> "'"))
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  backupOwner <-
    either
      dieT
      pure
      ( Resource.mkScopeId
          Resource.Standalone
          ("volume-snapshot-" <> ns <> "-" <> appName <> "-" <> volume <> "-" <> backupId)
      )
  backupScope <- case Map.lookup backupOwner (ResourceInventory.snapshotScopes snapshot) of
    Just (_, accepted) -> pure accepted
    Nothing -> dieT "exact volume snapshot scope is not accepted"
  backupJob <- case [ member
                    | bundle <- ResourceInventory.scopeBundles backupScope
                    , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                    , case member ^. #address of
                        Resource.Kubernetes _ "batch" kind (Just namespaceName) _ ->
                          Resource.nameText kind == "job" && Resource.nameText namespaceName == ns
                        _ -> False
                    ] of
    [single] -> pure single
    _ -> dieT "accepted volume snapshot has no unique Job"
  credential <- case backend of
    GcsBackend {} -> pure Nothing
    MinioBackend ref -> do
      (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
      address <-
        either
          dieT
          pure
          ( Resource.kubernetesAddress
              cluster
              "v1"
              "Secret"
              (Just ns)
              (ref ^. #secretName)
          )
      case [ member
           | (_, scope) <-
               Map.elems
                 (ResourceInventory.snapshotScopes snapshot)
           , bundle <- ResourceInventory.scopeBundles scope
           , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
           , member ^. #address == address
           ] of
        [single] -> pure (Just single)
        _ -> dieT "reviewed local volume prune requires one accepted store credential Secret"
  pruneOwner <-
    either
      dieT
      pure
      ( Resource.mkScopeId
          Resource.Standalone
          ("volume-prune-" <> ns <> "-" <> appName <> "-" <> volume <> "-" <> backupId)
      )
  let users =
        [ Resource.scopeIdText (ResourceInventory.scopeId scope)
        | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
        , ResourceInventory.scopeId scope /= backupOwner
        , ResourceInventory.scopeId scope /= pruneOwner
        , Map.lookup "volume-restore.backup.scope" (ResourceInventory.scopeOverrides scope)
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
    ( dieT
        ( "accepted scopes still depend on this volume snapshot: "
            <> T.intercalate ", " users
        )
    )
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  let retainedUsers =
        [ resource ^. #identity
        | (_, resource) <- Map.elems (InventoryPlan.historyRetained history)
        , ResourceReference.OrderedAfter (backupJob ^. #identity)
            `elem` (resource ^. #dependencies)
        ]
  unless
    (null retainedUsers)
    (dieT "retained resources still depend on this volume snapshot")
  backupRevision <- case Map.lookup backupOwner (InventoryPlan.historyAccepted history) of
    Just (revision, accepted) | accepted == backupScope -> pure revision
    _ -> dieT "volume snapshot scope differs from accepted history"
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
    _ -> dieT "accepted volume snapshot Job lacks exact private native evidence"
  credentialNative <- case credential of
    Nothing -> pure Map.empty
    Just secret -> case Map.lookup (secret ^. #identity) acceptedNative of
      Just pair | fst pair == secret -> pure (Map.singleton (secret ^. #identity) pair)
      _ -> dieT "accepted volume prune credential lacks exact private native evidence"
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
          (\_ -> pure (Left "volume snapshot observation does not use a cache key"))
          (Map.union backupNative credentialNative)
  state <- kubernetesObserve ops (backupJob ^. #identity)
  backupUid <- case (state, Map.lookup (backupJob ^. #identity) backupNative) of
    (KubernetesPresent uid _ (Just owner) digest, Just (_, bytes))
      | owner == backupJob ^. #identity
          && digest == InventoryDigest.contentDigest bytes ->
          pure uid
    _ -> dieT "accepted volume snapshot Job is absent, incomplete, foreign, or drifted"
  credentialPin <-
    traverse
      ( \secret -> do
          observed <- kubernetesObserve ops (secret ^. #identity)
          case (observed, Map.lookup (secret ^. #identity) credentialNative) of
            (KubernetesPresent uid _ (Just owner) digest, Just (_, bytes))
              | owner == secret ^. #identity
                  && digest == InventoryDigest.contentDigest bytes ->
                  pure (secret, uid)
            _ -> dieT "volume prune credential is absent, foreign, or drifted"
      )
      credential
  receiptBytes <-
    readBackupReceiptFromCompletedPod
      config
      backupNative
      (backupJob ^. #identity)
      backupUid
      >>= either dieT pure
  now <- getCurrentTime
  let request =
        VolumePruneRequest
          { pruneVolumeApp = appName
          , pruneVolumeName = volume
          , pruneVolumeNamespace = ns
          , pruneVolumeBackupId = backupId
          , pruneVolumeBackupRevision = backupRevision
          , pruneVolumeBackupUid = backupUid
          , pruneVolumeReceiptBytes = receiptBytes
          , pruneVolumeNow = now
          , pruneVolumeBackend = backend
          , pruneVolumeCredential = credentialPin
          , pruneVolumeSource =
              Resource.SourceLocation
                ("storage prune-snapshot/" <> appName <> "/" <> volume)
                backupId
          }
  (pruneScope, pruneNative) <-
    either
      (dieT . T.pack . show)
      pure
      (compileVolumePruneScope request backupScope backupNative)
  case Map.lookup
    (ResourceInventory.scopeId pruneScope)
    (ResourceInventory.snapshotScopes snapshot) of
    Just (_, prior)
      | prior /= pruneScope ->
          dieT "prune review under this volume snapshot ID has different accepted intent"
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
        (Map.unions [pruneNative, backupNative, credentialNative])
    )
    active
    candidate
    output
  TIO.putStrLn "Saved exact volume snapshot pruning review. Apply it after inspecting the object and receipt identities."
