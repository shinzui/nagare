-- | Inventory / Workflow. Executable-private CLI boundary.
module Nagare.Cli.Inventory.Workflow
  ( runInventoryAdopt
  , runInventoryApply
  , runInventoryCollect
  , runInventoryExport
  , runInventoryMigrate
  , runInventoryPlan
  , runInventoryRecover
  , runInventoryRegistryRecoveryPlan
  , runInventoryRestore
  , runInventoryResume
  , runInventoryRetire
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Bootstrap.Foundation (foundationStageTarget)
import Nagare.Cli.Inventory.Adapters
  ( inventoryHelmAdapter
  , inventoryKubernetesAdapter
  )
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistry)
import Nagare.Cli.Platform.InfrastructureReview
  ( prepareInfraMutation
  )
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.Cache
  ( cacheSpecsFromDeclarations
  )
import Nagare.Inventory.Artifact qualified as InventoryArtifact
import Nagare.Inventory.Cloud qualified as InventoryCloud
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Host qualified as InventoryHost
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target
  ( ActiveTarget
  , InventoryStoreKind (InventoryStoreGcs, InventoryStoreLocal)
  , Mode (Cloud)
  , effectiveInventoryStore
  )

runInventoryPlan :: Maybe String -> FilePath -> [String] -> FilePath -> IO ()
runInventoryPlan mctx candidateDirectory retained output = do
  target <- activeTarget mctx
  candidate <- Inventory.loadCandidate candidateDirectory >>= either dieT pure
  let inventory = ResourceInventory.candidateInventory candidate
      declarations = ResourceInventory.inventoryDeclarations inventory
      scopes = Map.elems (ResourceInventory.inventoryScopes inventory)
  registrations <- either dieT pure (InventoryCloud.registrationsFromDeclarations declarations)
  artifactSpecs <- either dieT pure (InventoryArtifact.artifactExecutionSpecsFromDeclarations declarations)
  cacheSpecs <- either dieT pure (cacheSpecsFromDeclarations declarations)
  hostInputs <- either dieT pure (InventoryHost.hostExecutionInputsFromScopes scopes)
  let kubernetesResources = [resource | ResourceInventory.Managed resource <- declarations, resource ^. #executor == ResourceInventory.KubernetesExecutor]
      helmResources = [resource | ResourceInventory.Managed resource <- declarations, resource ^. #executor == ResourceInventory.HelmExecutor]
  if null retained && null registrations && Map.null artifactSpecs && isNothing hostInputs && null kubernetesResources && null helmResources && Map.null cacheSpecs
    then Inventory.planInventory target candidateDirectory output
    else do
      resources <- traverse (either dieT pure . Resource.mkResourceId . T.pack) retained
      let infrastructure =
            Set.fromList
              [ ResourceInventory.PulumiExecutor
              , ResourceInventory.ArtifactExecutor
              , ResourceInventory.HostExecutor
              ]
          selectedInfra required =
            Set.filter
              ( \executor ->
                  not (null (Map.findWithDefault [] executor required))
              )
              infrastructure
          -- A new store can seed only unchanged base scopes. Its selected
          -- replacements are enough to decide preflight before seeding.
          freshInfra =
            Set.fromList
              [ resource ^. #executor
              | ResourceInventory.ReplaceScope scope <-
                  NE.toList
                    (ResourceInventory.candidateChanges candidate)
              , bundle <- ResourceInventory.scopeBundles scope
              , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
              , Set.member (resource ^. #executor) infrastructure
              ]
      -- Keep infrastructure preflight before the planner initializes or seeds
      -- history; unrelated accepted providers need no preparation.
      preflightInfra <-
        Inventory.openTargetStoreReadOnly target >>= \case
          Left (InventoryStore.StoreConditionFailed "inventory store is not initialized") ->
            pure freshInfra
          Left err -> dieT (T.pack (show err))
          Right store ->
            InventoryStore.readHead store >>= \case
              Left err -> dieT (T.pack (show err))
              Right Nothing -> pure freshInfra
              Right (Just headValue)
                | not (InventoryStore.hasSubstantiveHistory headValue) ->
                    pure freshInfra
              Right (Just _) -> do
                history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
                pure
                  ( selectedInfra
                      ( InventoryPlan.requirementsByExecutor
                          (InventoryPlan.observationRequirements candidate history)
                      )
                  )
      (active, workspace) <-
        if not (Set.null preflightInfra)
          && ( Set.member ResourceInventory.PulumiExecutor preflightInfra
                 || target ^. #profile . #mode == Cloud
             )
          then prepareInfraMutation mctx
          else do
            active <- activeTarget mctx
            (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
            pure (active, workspace)
      let registryFor selected history = do
            let currentInfra =
                  selectedInfra
                    ( InventoryPlan.requirementsByExecutor
                        (InventoryPlan.observationRequirements selected history)
                    )
            when
              (not (Set.isSubsetOf currentInfra preflightInfra))
              (dieT "selected infrastructure changed since preflight; replan")
            inventoryPlanRegistry active workspace selected history
      Inventory.planInventoryWithRetirements
        registryFor
        target
        candidateDirectory
        resources
        output

runInventoryAdopt :: Maybe String -> FilePath -> FilePath -> IO ()
runInventoryAdopt mctx input output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  Inventory.planInventoryAdoptionWith (inventoryPlanRegistry active workspace) active input output

runInventoryMigrate :: Maybe String -> FilePath -> FilePath -> IO ()
runInventoryMigrate mctx input output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  Inventory.planInventoryMigrationWith
    (inventoryMigrationSourceRegistry active workspace)
    (inventoryPlanRegistry active workspace)
    active
    input
    output

inventoryMigrationSourceRegistry ::
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.CompositionCandidate ->
  InventoryPlan.InventoryHistory ->
  IO InventoryAdapter.AdapterRegistry
inventoryMigrationSourceRegistry active workspace candidate history = do
  let requirements = InventoryPlan.observationRequirements candidate history
      sourceIds = Map.keysSet (InventoryPlan.migrationIncarnations requirements)
      binding = ResourceInventory.inventoryBinding (ResourceInventory.candidateInventory candidate)
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  acceptedSnapshot <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.mkScopeSnapshot
          binding
          ( Map.map
              (\(revision, scope) -> (InventoryStore.revisionGeneration revision, scope))
              (InventoryPlan.historyAccepted history)
          )
          (InventoryPlan.historyReservations history)
      )
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot acceptedSnapshot)
  (allKubernetes, allHelm) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  let oldKubernetes = Map.filterWithKey (\resource _ -> Set.member resource sourceIds) allKubernetes
      oldHelm = Map.filterWithKey (\resource _ -> Set.member resource sourceIds) allHelm
      selected = Map.keysSet oldKubernetes `Set.union` Map.keysSet oldHelm
      unsupported = sourceIds `Set.difference` selected
  unless
    (Set.null unsupported)
    (dieT "migration source needs an installed immutable provider observation contract")
  kubernetes <-
    inventoryKubernetesAdapter
      active
      binding
      (\_ -> pure (Left "migration source cache output unavailable"))
      oldKubernetes
  helm <- inventoryHelmAdapter active workspace binding oldHelm
  either dieT pure (InventoryAdapter.mkAdapterRegistry [kubernetes, helm])

runInventoryRetire :: Maybe String -> String -> FilePath -> IO ()
runInventoryRetire mctx rawScope output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  owner <- either dieT pure (parseScope (T.pack rawScope))
  Inventory.planInventoryRetirementWith (inventoryPlanRegistry active workspace) active owner output
  where
    parseScope scopeText = case T.splitOn ":" scopeText of
      [kind, name] -> do
        scopeKind <- case kind of
          "platform" -> Right Resource.Platform
          "application" -> Right Resource.Application
          "standalone" -> Right Resource.Standalone
          "publication" -> Right Resource.Publication
          _ -> Left "scope kind must be platform, application, standalone, or publication"
        Resource.mkScopeId scopeKind name
      _ -> Left "scope must be KIND:NAME"

runInventoryCollect :: Maybe String -> NE.NonEmpty String -> FilePath -> IO ()
runInventoryCollect mctx rawResources output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  resources <- traverse (either dieT pure . Resource.mkResourceId . T.pack) rawResources
  Inventory.planInventoryCollectionsWith (inventoryPlanRegistry active workspace) active resources output

runInventoryApply :: Maybe String -> FilePath -> Bool -> IO ()
runInventoryApply mctx reviewDirectory yes = do
  target <- activeTarget mctx
  Inventory.applyInventoryWithFactory (inventoryExecutionRegistry mctx) target reviewDirectory yes

runInventoryResume :: Maybe String -> Text -> Bool -> Bool -> IO ()
runInventoryResume mctx transaction yes takeOver = do
  target <- activeTarget mctx
  selected <- foundationResumeTarget target transaction
  Inventory.resumeInventoryWithFactoryTakeover (inventoryExecutionRegistry mctx) selected transaction yes takeOver
  when
    ( effectiveInventoryStore (target ^. #profile) == InventoryStoreGcs
        && effectiveInventoryStore (selected ^. #profile) == InventoryStoreLocal
    )
    $ Inventory.migrateTargetStore selected InventoryStoreGcs False
      >>= either (dieT . T.pack . show) TIO.putStrLn

-- The first foundation transaction precedes the remote inventory format. Only
-- its exact immutable review can authorize recovery from the local journal.
foundationResumeTarget :: ActiveTarget -> Text -> IO ActiveTarget
foundationResumeTarget target transaction
  | effectiveInventoryStore (target ^. #profile) == InventoryStoreLocal = pure target
  | otherwise = do
      selected <- foundationStageTarget target
      if effectiveInventoryStore (selected ^. #profile) == InventoryStoreGcs
        then pure selected
        else do
          store <- Inventory.openTargetStoreReadOnly selected >>= either (dieT . T.pack . show) pure
          headValue <-
            InventoryStore.readHead store
              >>= either (dieT . T.pack . show) pure
              >>= maybe (dieT refusal) pure
          unless
            (InventoryStore.headActiveTransaction headValue == Just transaction)
            (dieT refusal)
          digest <- either dieT pure (Resource.mkContentDigest (T.drop 3 transaction))
          bundle <- InventoryPlan.loadPublishedReview store digest >>= either (dieT . T.pack . show) pure
          owner <- either dieT pure (Resource.mkScopeId Resource.Platform "cloud-foundation")
          let document = InventoryPlan.reviewBundleDocument bundle
              operations = InventoryPlan.reviewOperations document
          unless
            ( target ^. #profile . #mode == Cloud
                && "nagare-bootstrap:" `T.isPrefixOf` InventoryPlan.reviewPayloadIdentity document
                && Map.null (InventoryPlan.reviewBaseRevisions document)
                && Map.keysSet (InventoryPlan.reviewDesiredRevisions document) == Set.singleton owner
                && InventoryPlan.reviewDesiredRevisions document == InventoryStore.headAccepted headValue
                && not (null operations)
                && all
                  ( (== ResourceInventory.CloudFoundationExecutor)
                      . InventoryAdapter.plannedExecutor
                      . InventoryPlan.reviewPlannedOperation
                  )
                  operations
            )
            (dieT refusal)
          pure selected
  where
    refusal = "local inventory recovery requires the exact active initial cloud foundation review"

runInventoryRecover :: Maybe String -> Text -> Text -> FilePath -> Bool -> IO ()
runInventoryRecover mctx transaction operation decisionFile takeOver = do
  target <- activeTarget mctx
  Inventory.recoverInventoryWithFactory (inventoryExecutionRegistry mctx) target transaction operation decisionFile takeOver

runInventoryRegistryRecoveryPlan :: Maybe String -> String -> String -> FilePath -> IO ()
runInventoryRegistryRecoveryPlan mctx transaction operation output = do
  target <- activeTarget mctx
  Inventory.prepareRegistryRecoveryWithFactory
    (inventoryExecutionRegistry mctx)
    target
    (T.pack transaction)
    (T.pack operation)
    output

runInventoryExport :: Maybe String -> FilePath -> IO ()
runInventoryExport mctx output = do
  target <- activeTarget mctx
  Inventory.exportInventory target output

runInventoryRestore :: Maybe String -> FilePath -> Bool -> IO ()
runInventoryRestore mctx backup yes = do
  target <- activeTarget mctx
  Inventory.restoreInventory target backup yes
