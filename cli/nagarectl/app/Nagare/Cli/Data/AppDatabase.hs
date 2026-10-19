-- | The @db app-database@ commands (EP-202). Executable-private CLI boundary:
-- each builds reviewed app-database scopes against the accepted inventory and
-- saves or prints their review.
module Nagare.Cli.Data.AppDatabase
  ( runAppDatabase
  )
where

import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Data.ScheduledReceipts (IngestSelection (..), runReviewedAppDatabaseReceiptPlan)
import Nagare.Cli.Inventory.Adapters (inventoryKubernetesAdapter)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Options.AppDatabase
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Process (currentTimestamp)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.AppDatabase (AppDatabase (..), AppDatabaseRole (..), appDatabaseNameText, appDatabaseSecretName)
import Nagare.Dsl.Load (loadAppDatabases, renderLoadError)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (namespaceText)
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.AppDatabase
import Nagare.Inventory.AppDatabaseRestore (AppDatabaseRestoreRequest (..), RestoreTarget (..), compileAppDatabaseRestoreScope)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Restore (restoreTargetPins)
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
    revised <- either (dieT . renderErrors) pure (retireAppDatabaseScope snapshot scope)
    planReview active snapshot [revised] Map.empty (Just (o ^. #savePlan))
  AppDatabaseRotate o roleText -> do
    role <- case roleText of
      "runtime" -> pure "runtime"
      "migration" -> pure "migration"
      _ -> dieT "--user is runtime or migration"
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
        membersOf scope = [member | bundle <- ResourceInventory.scopeBundles scope, ResourceInventory.Managed member <- ResourceInventory.declarations bundle]
    appScope <- either dieT pure (namedAppDatabaseScope snapshot (T.pack (o ^. #name)) Nothing)
    receiptScope <- case [ scope
                         | scope <- scopes
                         , Map.lookup "scheduled.backup.id" (ResourceInventory.scopeOverrides scope) == Just (T.pack (o ^. #backupId))
                         , Map.lookup "scheduled.backup.source.scope" (ResourceInventory.scopeOverrides scope) == Just (Resource.scopeIdText (ResourceInventory.scopeId appScope))
                         ] of
      [found] -> pure found
      _ -> dieT "the backup is not an accepted, ingested run of this app database; ingest it with db app-database backup-receipts"
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
    serverRevision <-
      maybe (dieT "the app database's server scope is not accepted") (pure . fst) (Map.lookup (ResourceInventory.scopeId serverScope) (InventoryPlan.historyAccepted history))
    (statefulUid, pvcUid) <- either dieT pure (restoreTargetPins (InventoryStore.headIncarnations (InventoryPlan.historyHead history)) observed (stateful ^. #identity) (pvc ^. #identity))
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
            , if row ^. #retired then "retired" else "active"
            ]
        )

-- | Every app database the config declares becomes its own scope, composed
-- into one candidate against the accepted server scopes.
runPlan :: Maybe String -> AppDatabasePlanOpts -> IO ()
runPlan mctx o = do
  provisionGhcEnv Nothing
  databases <- loadAppDatabases (o ^. #config) >>= either (dieT . renderLoadError) pure
  (active, snapshot) <- loadSnapshot mctx
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  (accepted, _) <- InventoryStatus.loadAcceptedNative store history inventory >>= either dieT pure
  keyVersion <- either dieT pure (Resource.mkName (maybe "v1" T.pack (o ^. #recoveryKeyVersion)))
  backend <- either dieT pure (storeBackendFor (active ^. #profile) (active ^. #profile . #backupBucket))
  let target = DatabaseBackupTarget backend (active ^. #profile . #backupRecoveryPoint)
  compiled <- forM databases $ \db -> do
    let name = appDatabaseNameText (db ^. #name)
    (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot (namespaceText (db ^. #namespace)))
    backup <- either dieT pure (Resource.mkName (maybe ("nagare-dbbackup-" <> name) T.pack (o ^. #recoveryBackup)))
    secrets <- either dieT pure (traverse (Resource.mkName . appDatabaseSecretName (db ^. #name)) [RuntimeRole, MigrationRole])
    let recovery = RecoveryIntent backup (NE.fromList [mkSecretRef secret keyVersion | secret <- secrets])
        source = Resource.SourceLocation (T.pack (o ^. #config)) name
    either (dieT . renderErrors) pure (compileStandaloneAppDatabase snapshot accepted target db cluster (Just namespaceId) recovery source)
  planReview active snapshot (map fst compiled) (Map.unions (map snd compiled)) (o ^. #savePlan)

loadSnapshot :: Maybe String -> IO (ActiveTarget, ResourceInventory.ScopeSnapshot)
loadSnapshot mctx = do
  active <- activeTarget mctx
  snapshot <- Inventory.loadTargetSnapshot active
  pure (active, snapshot)

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
