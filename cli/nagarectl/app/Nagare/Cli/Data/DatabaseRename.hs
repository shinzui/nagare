-- | Data / DatabaseRename. Executable-private CLI boundary for the reviewed,
-- bounded rename of one retained standalone PostgreSQL database.
module Nagare.Cli.Data.DatabaseRename
  ( runDbRenamePlan
  )
where

import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Text qualified as T
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Inventory.Workflow (acceptedMigrationNative, inventoryMigrationSourceRegistry)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Database.Create (DbCreateParams (..), resolveDatabase)
import Nagare.Dsl.Database (Engine (Postgres), dbSecretName, mkDatabaseName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (databaseNameText, namespaceText)
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.KubernetesMigration (MigrationPlanning (..), kubernetesMigrationAdapter, renameProposal)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace, compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..))
import Nagare.Inventory.MigrationPlanning qualified as Inventory
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (contextNameText, storeBackendFor)

-- | Compile the database under both names from the same typed input. The old
-- name must reproduce the accepted scope member for member, which bounds the
-- change to the name alone; the new name becomes the reviewed destination.
runDbRenamePlan ::
  Maybe String ->
  Engine ->
  Text ->
  Text ->
  Maybe Text ->
  DbCreateParams ->
  Maybe String ->
  Maybe String ->
  FilePath ->
  IO ()
runDbRenamePlan mctx eng oldName newName scopeKey params backupName keyVersion output = do
  unless (eng == Postgres) (dieT "reviewed database rename supports PostgreSQL only")
  configured <- resolveDatabase eng newName params
  unless
    (databaseNameText (configured ^. #name) == newName && configured ^. #engine == eng)
    (dieT "reviewed database config must name the new database and its engine")
  let key = fromMaybe (maybe oldName Resource.logicalKeyText (configured ^. #logicalKey)) scopeKey
  when
    (maybe False ((/= key) . Resource.logicalKeyText) (configured ^. #logicalKey))
    (dieT "database config pins a different scope key")
  logicalKey <- either dieT pure (Resource.mkLogicalKey key)
  previousName <- either dieT pure (mkDatabaseName oldName)
  let destination = configured & #logicalKey ?~ logicalKey
      previous = destination & #name .~ previousName
      namespaceName = namespaceText (destination ^. #namespace)
  owner <- either dieT pure (Resource.mkScopeId Resource.Standalone ("database-" <> key))
  backup <- maybe (dieT "reviewed database rename requires --recovery-backup") (either dieT pure . Resource.mkName . T.pack) backupName
  version <- maybe (dieT "reviewed database rename requires --recovery-key-version") (either dieT pure . Resource.mkName . T.pack) keyVersion
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  backend <- either dieT pure (storeBackendFor (active ^. #profile) (active ^. #profile . #backupBucket))
  let compileFor database = do
        credential <- Resource.mkName (dbSecretName (databaseNameText (database ^. #name)))
        let recovery = RecoveryIntent backup (mkSecretRef credential version NE.:| [])
            source = Resource.SourceLocation "db rename" (databaseNameText (database ^. #name))
        first (T.pack . show) $
          compileStandaloneDatabase
            (DatabaseDirectInput database owner cluster (Just namespaceId) recovery source)
            (DatabaseBackupTarget backend (active ^. #profile . #backupRecoveryPoint))
  (_, previousNative) <- either dieT pure (compileFor previous)
  (scope, native) <- either dieT pure (compileFor destination)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
  let runtime =
        KubernetesRuntimeConfig
          context
          (contextNameText (active ^. #contextName))
          (fmap (fmap (const ())) (guardKubernetesContext active))
      sourcesFor planningCandidate history = do
        (kubernetes, helm) <- acceptedMigrationNative active planningCandidate history
        unless (Map.null helm) (dieT "database rename sources must all be Kubernetes objects")
        revision <-
          maybe
            (dieT "database rename needs an accepted database scope")
            (pure . fst)
            (Map.lookup owner (InventoryPlan.historyAccepted history))
        let sources = Map.map (\(declaration, bytes) -> (revision, declaration, bytes)) kubernetes
            accepted = Map.map (\(declaration, _) -> unsourced declaration) kubernetes
            expected = Map.map (\(declaration, _) -> unsourced declaration) previousNative
        unless
          (accepted == expected && Map.keysSet native == Map.keysSet expected)
          (dieT "accepted database differs from the given settings; only the name may change in a rename")
        pure sources
      destinationRegistry planningCandidate history = do
        sources <- sourcesFor planningCandidate history
        registry <- inventoryPlanRegistryWithNative active workspace native planningCandidate history
        either
          dieT
          pure
          ( InventoryAdapter.wrapRegisteredAdapter
              ResourceInventory.KubernetesExecutor
              (kubernetesMigrationAdapter runtime (Just (MigrationPlanning sources native (InventoryStore.headIncarnations (InventoryPlan.historyHead history)))))
              registry
          )
  let proposalFor history facts = do
        sources <- sourcesFor candidate history
        pure (renameProposal candidate (MigrationPlanning sources native (InventoryStore.headIncarnations (InventoryPlan.historyHead history))) owner facts)
  Inventory.planInventoryMigrationCandidateWith
    (inventoryMigrationSourceRegistry active workspace)
    destinationRegistry
    active
    candidate
    proposalFor
    output
  where
    -- Stored history orders dependencies canonically; compare as sets.
    unsourced declaration =
      declaration
        & #source
        .~ Resource.SourceLocation "" ""
        & #dependencies
        %~ sort
