-- | The @db app-database@ commands (EP-202). Executable-private CLI boundary:
-- each builds reviewed app-database scopes against the accepted inventory and
-- saves or prints their review.
module Nagare.Cli.Data.AppDatabase
  ( runAppDatabase
  )
where

import Control.Monad (forM, forM_)
import Data.Aeson (encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Cli.Data.ScheduledPrune (runReviewedScheduledPrunePlan, runReviewedScheduledPruneRecoveryPlan)
import Nagare.Cli.Data.ScheduledReceipts (IngestSelection (..), runReviewedAppDatabaseReceiptPlan)
import Nagare.Cli.Inventory.Adapters (inventoryKubernetesAdapter)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Options.AppDatabase
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Process (currentTimestamp)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.AppDatabase (AppDatabase (..), AppDatabaseRole (..), appDatabaseNameText, appDatabaseRoleToken, appDatabaseSecretName, parseAppDatabaseRole)
import Nagare.Dsl.Load (loadAppDatabases, renderLoadError)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (namespaceText)
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.AppDatabase
import Nagare.Inventory.AppDatabaseBackup (AppDatabaseBackupRequest (..), compileAppDatabaseOnDemandBackupScope)
import Nagare.Inventory.AppDatabaseEvidence (loadAppDatabaseEvidence, renderAppDatabaseEvidence)
import Nagare.Inventory.AppDatabaseRestore (AppDatabaseRestoreRequest (..), RestoreTarget (..), compileAppDatabaseRestoreScope)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Restore (restoreTargetPins)
import Nagare.Inventory.ScheduledPrune (PruneSource (AppDatabasePruneSource))
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, storeBackendFor)
import System.IO.Temp (withSystemTempDirectory)

runAppDatabase :: Maybe String -> AppDatabaseCommand -> IO ()
runAppDatabase mctx = \case
  AppDatabasePlan o -> runPlan mctx o
  AppDatabaseRetire o -> do
    (active, snapshot) <- loadSnapshot mctx
    scope <- either dieT pure (namedAppDatabaseScope snapshot (T.pack (o ^. #name)) (T.pack <$> o ^. #scopeKey))
    accepted <- loadAcceptedNative active snapshot
    (revised, native) <- either (dieT . renderErrors) pure (retireAppDatabaseScope snapshot accepted scope)
    planReview active snapshot [revised] native (Just (o ^. #savePlan))
  AppDatabaseQuiesce o usersText -> do
    (active, snapshot) <- loadSnapshot mctx
    scope <- either dieT pure (namedAppDatabaseScope snapshot (T.pack (o ^. #name)) (T.pack <$> o ^. #scopeKey))
    accepted <- loadAcceptedNative active snapshot
    stamp <- currentTimestamp
    let roles = filter (not . T.null) (map T.strip (T.splitOn "," (T.pack usersText)))
    (revised, native) <- either (dieT . renderErrors) pure (quiesceAppDatabaseScope accepted scope roles stamp)
    planReview active snapshot [revised] native (Just (o ^. #savePlan))
  AppDatabaseResume o -> do
    (active, snapshot) <- loadSnapshot mctx
    scope <- either dieT pure (namedAppDatabaseScope snapshot (T.pack (o ^. #name)) (T.pack <$> o ^. #scopeKey))
    accepted <- loadAcceptedNative active snapshot
    stamp <- currentTimestamp
    (revised, native) <- either (dieT . renderErrors) pure (resumeAppDatabaseScope accepted scope stamp)
    planReview active snapshot [revised] native (Just (o ^. #savePlan))
  AppDatabaseBackup o requested -> do
    (active, snapshot) <- loadSnapshot mctx
    appScope <- either dieT pure (namedAppDatabaseScope snapshot (T.pack (o ^. #name)) (T.pack <$> o ^. #scopeKey))
    (_, stateful, pvc, statefulUid, pvcUid, history, accepted) <- serverPins active snapshot appScope
    backupId <- maybe (T.pack . formatTime defaultTimeLocale "%Y%m%d%H%M" <$> getCurrentTime) (pure . T.pack) requested
    (backupScope, native) <-
      either
        (dieT . renderErrors)
        pure
        ( compileAppDatabaseOnDemandBackupScope
            AppDatabaseBackupRequest
              { appScope = appScope
              , namespace = maybe "personal" T.pack (o ^. #namespace)
              , appDatabase = T.pack (o ^. #name)
              , backupId = backupId
              , statefulSet = stateful ^. #identity
              , persistentVolume = pvc ^. #identity
              , statefulUid = statefulUid
              , pvcUid = pvcUid
              , incarnations = InventoryStore.headIncarnations (InventoryPlan.historyHead history)
              , source = Resource.SourceLocation "db app-database backup" (T.pack (o ^. #name))
              }
            accepted
        )
    planReview active snapshot [backupScope] native (Just (o ^. #savePlan))
  AppDatabaseRotate o roleText -> do
    role <- case parseAppDatabaseRole (T.pack roleText) of
      Just parsed -> pure (appDatabaseRoleToken parsed)
      Nothing -> dieT "--user is runtime, migration or reader-NAME"
    (active, snapshot) <- loadSnapshot mctx
    scope <- either dieT pure (namedAppDatabaseScope snapshot (T.pack (o ^. #name)) (T.pack <$> o ^. #scopeKey))
    stamp <- currentTimestamp
    revised <- either (dieT . renderErrors) pure (rotateAppDatabaseScope scope role stamp)
    planReview active snapshot [revised] Map.empty (Just (o ^. #savePlan))
  AppDatabaseBackupReceipts o -> do
    selection <- case (o ^. #backupId, o ^. #allVerified) of
      (Just selected, False) -> pure (IngestRun (T.pack selected))
      (Nothing, True) -> pure IngestAllVerified
      _ -> dieT "backup-receipts takes exactly one of --backup-id and --all"
    runReviewedAppDatabaseReceiptPlan mctx (T.pack (o ^. #name)) (maybe "personal" T.pack (o ^. #namespace)) (o ^. #bucket) selection (o ^. #savePlan)
  AppDatabaseRestore o -> do
    (active, snapshot) <- loadSnapshot mctx
    let namespaceName = maybe "personal" T.pack (o ^. #namespace)
        scopes = map snd (Map.elems (ResourceInventory.snapshotScopes snapshot))
    appScope <- either dieT pure (namedAppDatabaseScope snapshot (T.pack (o ^. #name)) Nothing)
    receiptScope <- case [ scope
                         | scope <- scopes
                         , Map.lookup "scheduled.backup.id" (ResourceInventory.scopeOverrides scope) == Just (T.pack (o ^. #backupId))
                         , Map.lookup "scheduled.backup.source.scope" (ResourceInventory.scopeOverrides scope) == Just (Resource.scopeIdText (ResourceInventory.scopeId appScope))
                         ] of
      [found] -> pure found
      _ -> dieT "the backup is not an accepted, ingested run of this app database; ingest it with db app-database backup-receipts"
    (serverScope, _, _, statefulUid, pvcUid, history, accepted) <- serverPins active snapshot appScope
    serverRevision <-
      maybe (dieT "the app database's server scope is not accepted") (pure . fst) (Map.lookup (ResourceInventory.scopeId serverScope) (InventoryPlan.historyAccepted history))
    backend <- resolveStoreBackend mctx (o ^. #bucket)
    (restoreScope, native) <-
      either
        (dieT . renderErrors)
        pure
        ( compileAppDatabaseRestoreScope
            AppDatabaseRestoreRequest
              { appDatabase = T.pack (o ^. #name)
              , namespace = namespaceName
              , restoreId = T.pack (o ^. #restoreId)
              , appScope = appScope
              , serverScope = serverScope
              , receiptScope = receiptScope
              , targetStatefulUid = statefulUid
              , targetPvcUid = pvcUid
              , backend = backend
              , source = Resource.SourceLocation "db app-database restore" (T.pack (o ^. #name))
              , target = if o ^. #rebuilt then RebuiltTarget else ScratchTarget
              , serverRevision = serverRevision
              }
            accepted
        )
    planReview active snapshot [restoreScope] native (Just (o ^. #savePlan))
  AppDatabasePruneScheduledBackups o ->
    runReviewedScheduledPrunePlan mctx (AppDatabasePruneSource (T.pack (o ^. #name))) (maybe "personal" T.pack (o ^. #namespace)) (o ^. #bucket) (o ^. #savePlan)
  AppDatabaseRecoverScheduledPrune o ->
    runReviewedScheduledPruneRecoveryPlan mctx (AppDatabasePruneSource (T.pack (o ^. #name))) (maybe "personal" T.pack (o ^. #namespace)) (T.pack (o ^. #backupId)) (o ^. #bucket) (o ^. #failedReview) (o ^. #savePlan)
  AppDatabaseEvidence name _ asJson -> do
    (active, snapshot) <- loadSnapshot mctx
    scope <- either dieT pure (namedAppDatabaseScope snapshot (T.pack name) Nothing)
    store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
    let accepted = map snd (Map.elems (ResourceInventory.snapshotScopes snapshot))
    evidence <- loadAppDatabaseEvidence store (T.pack name) (ResourceInventory.scopeId scope) accepted >>= either dieT pure
    if asJson
      then LBS.putStr (encode evidence) >> TIO.putStrLn ""
      else mapM_ TIO.putStrLn (renderAppDatabaseEvidence evidence)
  AppDatabaseList namespaceFilter -> do
    (_, snapshot) <- loadSnapshot mctx
    let rows = [row | row <- appDatabaseRows snapshot, maybe True ((== row ^. #namespace) . T.pack) namespaceFilter]
    TIO.putStrLn "APP DATABASE\tSERVER\tNAMESPACE\tENGINE\tDATABASES\tSTATE"
    forM_ rows $ \row ->
      TIO.putStrLn
        ( T.intercalate
            "\t"
            [ row ^. #name
            , row ^. #server
            , row ^. #namespace
            , row ^. #engine
            , T.intercalate "," (row ^. #databases)
            , if row ^. #retired then "retired" else if row ^. #quiesced then "quiesced" else "active"
            ]
        )

-- | Every app database the config declares becomes its own scope, composed
-- into one candidate against the accepted server scopes.
runPlan :: Maybe String -> AppDatabasePlanOpts -> IO ()
runPlan mctx o = do
  provisionGhcEnv Nothing
  databases <- loadAppDatabases (o ^. #config) >>= either (dieT . renderLoadError) pure
  (active, snapshot) <- loadSnapshot mctx
  accepted <- loadAcceptedNative active snapshot
  keyVersion <- either dieT pure (Resource.mkName (maybe "v1" T.pack (o ^. #recoveryKeyVersion)))
  backend <- either dieT pure (storeBackendFor (active ^. #profile) (active ^. #profile . #backupBucket))
  let target = DatabaseBackupTarget backend (active ^. #profile . #backupRecoveryPoint)
  -- A quiesced app database is left out until resume (EP-205): planning it
  -- would reopen its logins as convergence, and refusing would block every
  -- other app's changes during one app's window.
  let quiesced db = case appDatabaseScopeId db of
        Right owner | Just (_, scope) <- Map.lookup owner (ResourceInventory.snapshotScopes snapshot) -> not (null (quiescedRoles scope))
        _ -> False
  forM_ (filter quiesced databases) $ \db ->
    TIO.putStrLn ("app database " <> appDatabaseNameText (db ^. #name) <> " is quiesced; left out of this plan until db app-database resume")
  compiled <- forM (filter (not . quiesced) databases) $ \db -> do
    let name = appDatabaseNameText (db ^. #name)
    (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot (namespaceText (db ^. #namespace)))
    backup <- either dieT pure (Resource.mkName (maybe ("nagare-dbbackup-" <> name) T.pack (o ^. #recoveryBackup)))
    secrets <- either dieT pure (traverse (Resource.mkName . appDatabaseSecretName (db ^. #name)) [RuntimeRole, MigrationRole])
    let recovery = RecoveryIntent backup (NE.fromList [mkSecretRef secret keyVersion | secret <- secrets])
        source = Resource.SourceLocation (T.pack (o ^. #config)) name
    either (dieT . renderErrors) pure (compileStandaloneAppDatabase snapshot accepted target db cluster (Just namespaceId) recovery source)
  if null compiled
    then TIO.putStrLn "no operations"
    else planReview active snapshot (map fst compiled) (Map.unions (map snd compiled)) (o ^. #savePlan)

-- | The accepted server of an app database, its StatefulSet and claim, and
-- their live UIDs, which must be the recorded incarnations (ADR 27).
serverPins ::
  ActiveTarget ->
  ResourceInventory.ScopeSnapshot ->
  ResourceInventory.ScopeDeclaration ->
  IO
    ( ResourceInventory.ScopeDeclaration
    , ResourceInventory.ManagedResource
    , ResourceInventory.ManagedResource
    , Resource.PhysicalIdentity
    , Resource.PhysicalIdentity
    , InventoryPlan.InventoryHistory
    , Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString)
    )
serverPins active snapshot appScope = do
  let scopes = map snd (Map.elems (ResourceInventory.snapshotScopes snapshot))
      membersOf scope = [member | bundle <- ResourceInventory.scopeBundles scope, ResourceInventory.Managed member <- ResourceInventory.declarations bundle]
  statefulId <- case [target | member <- membersOf appScope, Resource.DatabaseUser target _ <- [member ^. #address]] of
    target : _ -> pure target
    [] -> dieT "the app database scope names no server"
  (serverScope, stateful) <- case [(scope, member) | scope <- scopes, member <- membersOf scope, member ^. #identity == statefulId] of
    [found] -> pure found
    _ -> dieT "the app database's server StatefulSet is not accepted"
  pvc <- case [member | member <- membersOf serverScope, Resource.Kubernetes _ "" kind _ _ <- [member ^. #address], Resource.nameText kind == "persistentvolumeclaim"] of
    [found] -> pure found
    _ -> dieT "the app database's server has no unique PVC"
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  (accepted, _) <- InventoryStatus.loadAcceptedNative store history inventory >>= either dieT pure
  sourceAdapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "restore target observation does not use a cache key"))
      (Map.restrictKeys accepted (Set.fromList [stateful ^. #identity, pvc ^. #identity]))
  observed <- InventoryAdapter.adapterObserve sourceAdapter [stateful ^. #identity, pvc ^. #identity] >>= either dieT pure
  (statefulUid, pvcUid) <- either dieT pure (restoreTargetPins (InventoryStore.headIncarnations (InventoryPlan.historyHead history)) observed (stateful ^. #identity) (pvc ^. #identity))
  pure (serverScope, stateful, pvc, statefulUid, pvcUid, history, accepted)

loadSnapshot :: Maybe String -> IO (ActiveTarget, ResourceInventory.ScopeSnapshot)
loadSnapshot mctx = do
  active <- activeTarget mctx
  snapshot <- Inventory.loadTargetSnapshot active
  pure (active, snapshot)

loadAcceptedNative :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> IO (Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString))
loadAcceptedNative active snapshot = do
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  fst <$> (InventoryStatus.loadAcceptedNative store history inventory >>= either dieT pure)

-- | Save the review, or, without a directory, print its operations (or
-- @no operations@) from a review written to a throwaway directory.
planReview ::
  ActiveTarget ->
  ResourceInventory.ScopeSnapshot ->
  [ResourceInventory.ScopeDeclaration] ->
  Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) ->
  Maybe FilePath ->
  IO ()
planReview active snapshot scopes native output = do
  changes <- maybe (dieT "no app database to plan") pure (NE.nonEmpty (map ResourceInventory.ReplaceScope scopes))
  candidate <- either (dieT . renderErrors) pure (ResourceInventory.composeInventory snapshot changes)
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  let registry = inventoryPlanRegistryWithNative active workspace native
  case output of
    Just directory -> Inventory.planInventoryCandidateWith registry active candidate directory
    Nothing -> withSystemTempDirectory "nagare-app-database-plan" $ \root -> do
      (bundle, _) <- Inventory.planInventoryCandidateQuiet registry active candidate (root <> "/review")
      case InventoryPlan.reviewOperations (InventoryPlan.reviewBundleDocument bundle) of
        [] -> TIO.putStrLn "no operations"
        operations -> mapM_ (TIO.putStrLn . InventoryPlan.reviewPublicSummary) operations

renderErrors :: NE.NonEmpty Resource.InventoryError -> Text
renderErrors = T.intercalate "; " . map (\err -> err ^. #code <> ": " <> err ^. #message) . NE.toList
