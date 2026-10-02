-- | Application / Inputs. Executable-private CLI boundary.
module Nagare.Cli.Application.Inputs
  ( parseHookEffects
  , reviewedStandaloneDatabases
  , validateInlinePreviewAdoption
  , validateInlineReleaseAdoption
  )
where

import Data.Generics.Labels ()
import Data.List (find, sort)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Application (Application (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( DatabaseName
  , databaseNameText
  , mkServiceName
  , serviceNameText
  )
import Nagare.Inventory.Application
  ( DatabaseBinding
  , acceptedDatabaseBindings
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Lifecycle qualified as InventoryLifecycle
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Application qualified as ResourceApplication
import Nagare.Resource.Database qualified as ResourceDatabase
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget)

-- Resolve hook effects against the loaded application before composing the
-- review. Application-owned databases can be named without guessing their IDs.
parseHookEffects :: Application -> [String] -> [String] -> Either Text (Map Text [Resource.ResourceId])
parseHookEffects app affected stateless = do
  rows <- traverse parseAffected affected
  bare <- traverse (mkServiceName . T.pack) stateless
  let bareNames = map serviceNameText bare
      affectedNames = map fst rows
  unless
    ( length bareNames == Set.size (Set.fromList bareNames)
        && Set.null
          ( Set.intersection
              (Set.fromList bareNames)
              (Set.fromList affectedNames)
          )
    )
    (Left "hook effect declarations repeat a task or conflict with --hook-no-data-effects")
  pure
    ( Map.union
        (Map.fromList [(name, []) | name <- bareNames])
        ( Map.map
            sort
            ( Map.fromListWith
                (<>)
                [(name, [resource]) | (name, resource) <- rows]
            )
        )
    )
  where
    parseAffected value = case T.breakOn "=" (T.pack value) of
      (task, rest) | not (T.null task) && not (T.null rest) -> do
        name <- mkServiceName task
        resource <- case T.stripPrefix "database:" (T.drop 1 rest) of
          Nothing -> Resource.mkResourceId (T.drop 1 rest)
          Just databaseName -> do
            database <-
              maybe
                (Left "--hook-affects names an undeclared application database")
                Right
                (find ((== databaseName) . databaseNameText . (^. #name)) (app ^. #databases))
            owner <- ResourceApplication.applicationScopeId app
            role <- Resource.mkName "statefulset"
            ResourceDatabase.databaseResourceId owner role database
        pure (serviceNameText name, resource)
      _ -> Left "--hook-affects needs TASK=database:NAME or TASK=RESOURCE-ID"

-- | Database engine and credential authority come from the accepted private
-- review, never from a live name lookup or an independently supplied config.
reviewedStandaloneDatabases ::
  ActiveTarget ->
  ResourceInventory.ScopeSnapshot ->
  Resource.ResourceId ->
  Text ->
  [DatabaseName] ->
  IO (Map DatabaseName DatabaseBinding)
reviewedStandaloneDatabases _ _ _ _ [] = pure Map.empty
reviewedStandaloneDatabases active snapshot cluster namespaceName names = do
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (native, _) <-
    InventoryStatus.loadAcceptedNative store history inventory
      >>= either dieT pure
  either dieT pure (acceptedDatabaseBindings snapshot native cluster namespaceName names)

validateInlineReleaseAdoption ::
  ResourceInventory.ScopeDeclaration -> Text -> InventoryLifecycle.AdoptionInput -> IO ()
validateInlineReleaseAdoption scope releaseName proposal = do
  let releaseMembers =
        [ member
        | bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
        , case member ^. #address of
            Resource.Kubernetes _ "" kind _ name ->
              Resource.nameText kind == "configmap"
                && Resource.nameText name == releaseName
            _ -> False
        ]
      managedIds =
        Set.fromList
          [ member ^. #identity
          | bundle <- ResourceInventory.scopeBundles scope
          , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
          ]
      proposed = InventoryLifecycle.adoptionTargets proposal
  releaseMember <- case releaseMembers of
    [member] -> pure member
    _ -> dieT "legacy import has no unique release-history declaration"
  unless
    ( all
        ( \target ->
            InventoryLifecycle.adoptionResource target `Set.member` managedIds
              && isNothing (InventoryLifecycle.adoptionPreviousOwner target)
        )
        proposed
    )
    (dieT "legacy release import can adopt only unowned resources in the selected deploy scope")
  unless
    (any ((== releaseMember ^. #identity) . InventoryLifecycle.adoptionResource) proposed)
    ( dieT
        ( "legacy import proposal must adopt the unowned release resource "
            <> Resource.resourceIdText (releaseMember ^. #identity)
        )
    )

validateInlinePreviewAdoption ::
  ResourceInventory.ScopeDeclaration -> InventoryLifecycle.AdoptionInput -> IO ()
validateInlinePreviewAdoption scope proposal = do
  let managedIds =
        Set.fromList
          [ member ^. #identity
          | bundle <- ResourceInventory.scopeBundles scope
          , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
          ]
      proposed = InventoryLifecycle.adoptionTargets proposal
      targetIds = map InventoryLifecycle.adoptionResource proposed
  unless
    ( not (null proposed)
        && Set.size (Set.fromList targetIds) == length proposed
        && all
          ( \target ->
              InventoryLifecycle.adoptionResource target `Set.member` managedIds
                && isNothing (InventoryLifecycle.adoptionPreviousOwner target)
          )
          proposed
    )
    (dieT "preview adoption can target only distinct unowned resources in its selected scope")
