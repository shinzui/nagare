-- | Commands / Database. Executable-private CLI boundary.
module Nagare.Cli.Commands.Database
  ( runDb
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cli.Data.Backup
  ( runReviewedDbBackupPlan
  , runReviewedDbPruneBackupPlan
  )
import Nagare.Cli.Data.Lifecycle
  ( runDataRestart
  , runStandaloneRetirePlan
  )
import Nagare.Cli.Data.ManualReceipt (runReviewedManualReceiptPlan)
import Nagare.Cli.Data.Restore (runReviewedDbRestorePlan)
import Nagare.Cli.Data.ScheduledPrune
  ( runReviewedScheduledPruneRecoveryPlan
  )
import Nagare.Cli.Data.ScheduledReceipts
  ( runListScheduledReceipts
  , runReviewedScheduledReceiptPlan
  )
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Options (DbCommand (..))
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Ownership
  ( ownedHistoryResources
  , withAcceptedInventoryHistory
  )
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Cluster.Namespace (NamespacePurpose (..))
import Nagare.Database.Backup (previewDbBackup)
import Nagare.Database.Create
  ( DbCreateParams (..)
  , resolveDatabase
  , runDbCreateWithGuard
  )
import Nagare.Database.Get (runDbGet)
import Nagare.Database.List (runDbList)
import Nagare.Database.Restart (runDbRestart)
import Nagare.Database.Restore (previewDbRestore)
import Nagare.Dsl.Database (Engine, dbSecretName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (databaseNameText, namespaceText)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService
  ( NativeDataKind (DatabaseObjects)
  , acceptedFoundationNamespace
  , compileBackupPruneRemovalScope
  , compileStandaloneDatabase
  , databaseNativeOwned
  )
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (storeBackendFor)

-- | Dispatch the @db@ subcommands (MasterPlan 9, EP-45). The namespace defaults
-- to @personal@. EP-47 adds @DbBackup@/@DbRestore@ cases here.
runDb :: Maybe String -> DbCommand -> IO ()
runDb mctx = \case
  DbList o -> runDbList (nsOf (o ^. #namespace))
  DbCreate eng name o -> do
    when (isJust (o ^. #config)) (provisionGhcEnv Nothing)
    tp <- activeProfile mctx
    let params =
          DbCreateParams
            { namespace = nsOf (o ^. #namespace)
            , namespacePurpose = if o ^. #systemNamespace then PlatformNamespace else ApplicationNamespace
            , version = T.pack <$> o ^. #version
            , size = T.pack <$> o ^. #size
            , cpu = T.pack <$> o ^. #cpu
            , memory = T.pack <$> o ^. #memory
            , config = o ^. #config
            , dryRun = o ^. #dryRun
            , targetProfile = tp
            }
    if o ^. #dryRun
      then do
        when (isJust (o ^. #savePlan)) (dieT "database create --dry-run cannot save a review")
        runDbCreateWithGuard eng (T.pack name) params $ \database ->
          withAcceptedInventoryHistory mctx "database create" $ \history ->
            when
              (databaseNativeOwned database (ownedHistoryResources history))
              (dieT "database objects are owned by accepted or retained inventory history; direct create is refused")
      else
        runDbCreatePlan
          mctx
          eng
          (T.pack name)
          params
          (o ^. #recoveryBackup)
          (o ^. #recoveryKeyVersion)
          (o ^. #savePlan)
  DbGet o -> runDbGet (nsOf (o ^. #namespace)) (T.pack (o ^. #name))
  DbShell _ _ _ _ ->
    dieT
      "new interactive database maintenance is deferred; recover an already-admitted session through inventory recover"
  DbRestart o dry output ->
    runDataRestart
      mctx
      DatabaseObjects
      (T.pack (o ^. #name))
      (nsOf (o ^. #namespace))
      dry
      output
      (runDbRestart (nsOf (o ^. #namespace)) (T.pack (o ^. #name)) dry)
  DbDelete o ->
    runStandaloneRetirePlan
      mctx
      "database"
      (T.pack (o ^. #name))
      (nsOf (o ^. #namespace))
      (T.pack <$> o ^. #scopeKey)
      (o ^. #savePlan)
  DbRetire o ->
    runStandaloneRetirePlan
      mctx
      "database"
      (T.pack (o ^. #name))
      (nsOf (o ^. #namespace))
      (T.pack <$> o ^. #scopeKey)
      (o ^. #savePlan)
  DbBackup o -> do
    case (o ^. #backupId, o ^. #savePlan) of
      (Just backupId, Just output) -> do
        when
          (o ^. #dryRun || isJust (o ^. #keep))
          (dieT "reviewed database backup uses --save-plan and does not accept --dry-run or --keep")
        runReviewedDbBackupPlan
          mctx
          (T.pack (o ^. #name))
          (nsOf (o ^. #namespace))
          (o ^. #bucket)
          (T.pack backupId)
          (T.pack <$> o ^. #expiresAt)
          output
      (Nothing, Nothing) | o ^. #dryRun -> do
        when
          (isJust (o ^. #expiresAt))
          (dieT "--expires-at requires --backup-id and --save-plan")
        backend <- resolveStoreBackend mctx (o ^. #bucket)
        previewDbBackup
          (nsOf (o ^. #namespace))
          (T.pack (o ^. #name))
          backend
          (fromMaybe 7 (o ^. #keep))
      (Nothing, Nothing) -> dieT "live database backup requires --backup-id and --save-plan"
      _ -> dieT "reviewed database backup requires both --backup-id and --save-plan"
  DbPruneBackup o ->
    runReviewedDbPruneBackupPlan
      mctx
      (T.pack (o ^. #name))
      (nsOf (o ^. #namespace))
      (T.pack (o ^. #backupId))
      (o ^. #bucket)
      (o ^. #savePlan)
  DbPruneScheduledBackups _ ->
    dieT
      "new scheduled pruning is deferred; scheduled backups are retained"
  DbRecoverScheduledPrune o ->
    runReviewedScheduledPruneRecoveryPlan
      mctx
      (T.pack (o ^. #name))
      (nsOf (o ^. #namespace))
      (T.pack (o ^. #backupId))
      (o ^. #bucket)
      (o ^. #failedReview)
      (o ^. #savePlan)
  DbBackupReceipts o -> case (o ^. #backupId, o ^. #savePlan) of
    (Just selected, Just output) -> do
      when (o ^. #checkFreshness) (dieT "--check-freshness is a read-only listing check; omit ingestion options")
      runReviewedScheduledReceiptPlan
        mctx
        (T.pack (o ^. #name))
        (nsOf (o ^. #namespace))
        (o ^. #bucket)
        (T.pack selected)
        output
    (Nothing, Nothing) ->
      runListScheduledReceipts
        mctx
        (T.pack (o ^. #name))
        (nsOf (o ^. #namespace))
        (o ^. #bucket)
        (o ^. #checkFreshness)
    _ -> dieT "scheduled receipt ingestion requires both --backup-id and --save-plan"
  DbManualReceipt o -> case (o ^. #backupId, o ^. #savePlan) of
    (Just selected, Just output) ->
      runReviewedManualReceiptPlan
        mctx
        (T.pack (o ^. #name))
        (nsOf (o ^. #namespace))
        (T.pack selected)
        (o ^. #bucket)
        output
    _ -> dieT "manual receipt review requires both --backup-id and --save-plan"
  DbDisableBackupPrune o output ->
    runDisableBackupPrunePlan mctx (T.pack (o ^. #name)) (nsOf (o ^. #namespace)) output
  DbRestore o -> do
    when
      (o ^. #live)
      ( dieT
          "live database overwrite is deferred; restore into an isolated destination"
      )
    case (o ^. #restoreId, o ^. #savePlan) of
      (Just restoreKey, Just output) -> do
        when
          (o ^. #dryRun)
          (dieT "reviewed restore does not accept --dry-run")
        when
          (o ^. #live && isNothing (o ^. #recoveryBackup))
          (dieT "reviewed live restore requires --recovery-backup")
        when
          (not (o ^. #live) && isJust (o ^. #recoveryBackup))
          (dieT "--recovery-backup requires --into-live")
        runReviewedDbRestorePlan
          mctx
          (T.pack (o ^. #name))
          (nsOf (o ^. #namespace))
          (T.pack (o ^. #backupId))
          (T.pack restoreKey)
          (T.pack <$> o ^. #recoveryBackup)
          (o ^. #bucket)
          output
      (Nothing, Nothing) | o ^. #dryRun -> do
        when
          (isJust (o ^. #recoveryBackup))
          (dieT "--recovery-backup requires a saved live restore review")
        backend <- resolveStoreBackend mctx (o ^. #bucket)
        previewDbRestore (nsOf (o ^. #namespace)) (T.pack (o ^. #name)) (T.pack (o ^. #backupId)) (o ^. #live) backend
      (Nothing, Nothing) -> dieT "live database restore requires --restore-id and --save-plan"
      _ -> dieT "reviewed database restore requires both --restore-id and --save-plan"
  where
    nsOf = maybe "personal" T.pack

runDisableBackupPrunePlan :: Maybe String -> Text -> Text -> FilePath -> IO ()
runDisableBackupPrunePlan mctx name namespaceName output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  let selected =
        [ scope
        | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
        , case resource ^. #address of
            Resource.Kubernetes _ "batch" resourceKind (Just ns) nativeName ->
              Resource.nameText resourceKind == "cronjob"
                && Resource.nameText ns == namespaceName
                && Resource.nameText nativeName == "nagare-dbbackup-" <> name
            _ -> False
        ]
  scope <- case selected of
    [single] -> pure single
    _ -> dieT "reviewed backup prune removal requires one accepted database backup CronJob"
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNativeSelected
      (Set.fromList [member ^. #identity | bundle <- ResourceInventory.scopeBundles scope, ResourceInventory.Managed member <- ResourceInventory.declarations bundle])
      store
      history
      acceptedInventory
      >>= either dieT pure
  backend <-
    either
      dieT
      pure
      (storeBackendFor (active ^. #profile) (active ^. #profile . #backupBucket))
  (revised, native) <-
    either
      (dieT . T.pack . show)
      pure
      (compileBackupPruneRemovalScope name namespaceName backend scope acceptedNative)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composeInventory
          snapshot
          (ResourceInventory.ReplaceScope revised NE.:| [])
      )
  Inventory.planInventoryCandidateWith
    ( inventoryPlanRegistryWithNative
        active
        workspace
        (Map.filter ((/= "contribution") . (^. #source . #file) . fst) native)
    )
    active
    candidate
    output

runDbCreatePlan ::
  Maybe String ->
  Engine ->
  Text ->
  DbCreateParams ->
  Maybe String ->
  Maybe String ->
  Maybe FilePath ->
  IO ()
runDbCreatePlan mctx eng name params backupName keyVersion output = do
  db <- resolveDatabase eng name params
  let databaseName = databaseNameText (db ^. #name)
      namespaceName = namespaceText (db ^. #namespace)
      scopeName = maybe databaseName Resource.logicalKeyText (db ^. #logicalKey)
  unless
    (databaseName == name && db ^. #engine == eng)
    (dieT "reviewed database config must match the command's engine and name")
  owner <- either dieT pure (Resource.mkScopeId Resource.Standalone ("database-" <> scopeName))
  backup <- maybe (dieT "reviewed database create requires --recovery-backup") (either dieT pure . Resource.mkName . T.pack) backupName
  version <- maybe (dieT "reviewed database create requires --recovery-key-version") (either dieT pure . Resource.mkName . T.pack) keyVersion
  credential <- either dieT pure (Resource.mkName (dbSecretName databaseName))
  let recovery = RecoveryIntent backup (mkSecretRef credential version NE.:| [])
      source =
        Resource.SourceLocation
          (maybe "db create" T.pack (params ^. #config))
          databaseName
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  let direct = DatabaseDirectInput db owner cluster (Just namespaceId) recovery source
  backend <- either dieT pure (storeBackendFor (active ^. #profile) (active ^. #profile . #backupBucket))
  (scope, native) <- either (dieT . T.pack . show) pure (compileStandaloneDatabase direct backend)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  case output of
    Nothing ->
      Inventory.convergeInventoryCandidateWith
        (inventoryPlanRegistryWithNative active workspace native)
        (inventoryExecutionRegistry mctx)
        active
        candidate
    Just directory ->
      Inventory.planInventoryCandidateWith
        (inventoryPlanRegistryWithNative active workspace native)
        active
        candidate
        directory
