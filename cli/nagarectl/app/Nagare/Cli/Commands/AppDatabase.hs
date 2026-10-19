-- | The @db app-database@ commands (EP-202). Executable-private CLI boundary:
-- each builds reviewed app-database scopes against the accepted inventory and
-- saves, prints or converges their review.
module Nagare.Cli.Commands.AppDatabase
  ( runAppDatabase
  )
where

import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Options.AppDatabase
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Process (currentTimestamp)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.AppDatabase (AppDatabase (..), AppDatabaseRole (..), appDatabaseNameText, appDatabaseSecretName)
import Nagare.Dsl.Load (loadAppDatabases, renderLoadError)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (namespaceText)
import Nagare.Inventory.AppDatabase
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget)
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
  compiled <- forM databases $ \db -> do
    let name = appDatabaseNameText (db ^. #name)
    (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot (namespaceText (db ^. #namespace)))
    backup <- either dieT pure (Resource.mkName (maybe ("nagare-dbbackup-" <> name) T.pack (o ^. #recoveryBackup)))
    secrets <- either dieT pure (traverse (Resource.mkName . appDatabaseSecretName (db ^. #name)) [RuntimeRole, MigrationRole])
    let recovery = RecoveryIntent backup (NE.fromList [mkSecretRef secret keyVersion | secret <- secrets])
        source = Resource.SourceLocation (T.pack (o ^. #config)) name
    either (dieT . renderErrors) pure (compileStandaloneAppDatabase snapshot accepted db cluster (Just namespaceId) recovery source)
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
