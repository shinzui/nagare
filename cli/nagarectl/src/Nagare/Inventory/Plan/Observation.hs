-- | Observation responsibilities; internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.Observation
  ( affectedManagedIds
  , observationRequirements
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Plan.Types
  ( InventoryHistory (..)
  , ObservationRequirements (..)
  , historyDeclarations
  )
import Nagare.Resource.Inventory
  ( CompositionCandidate
  , Declaration (Managed)
  , Executor (BrokerExecutor, KubernetesExecutor)
  , ScopeChange (CollectRetained, ReplaceScope, RetireScope)
  , candidateChanges
  , candidateInventory
  , contributionResourceId
  , inventoryDeclarations
  , inventoryScopes
  , scopeBundles
  , scopeId
  )
import Nagare.Resource.Reference
  ( Dependency (Consumes, OrderedAfter, ReadyAfter)
  , SomeRef (SomeRef)
  , refProducer
  )
import Nagare.Resource.Types (ResourceId)

observationRequirements :: CompositionCandidate -> InventoryHistory -> ObservationRequirements
observationRequirements candidate history =
  ObservationRequirements ids grouped migrations sourceGroups
  where
    desiredManaged =
      Map.fromList
        [(resource ^. #identity, resource) | Managed resource <- inventoryDeclarations (candidateInventory candidate)]
    historicalManaged =
      Map.fromList
        [(resource ^. #identity, resource) | Managed resource <- historyDeclarations history]
    migrations =
      Map.mapMaybe
        migration
        (Map.intersectionWith (,) historicalManaged desiredManaged)
    migration (source, destination)
      | source ^. #executor /= destination ^. #executor
          || source ^. #address /= destination ^. #address =
          Just (source, destination)
      | otherwise = Nothing
    -- The ordinary observation map has one entry per logical resource. For a
    -- changed executor it must ask only the destination adapter; otherwise
    -- observeWithRegistry receives duplicate IDs and refuses before the
    -- planner can report the required migration review. The source remains
    -- available separately in migrationIncarnations for a future dual read.
    affected = affectedManagedIds candidate history
    managed =
      [ (resourceId, resource ^. #executor)
      | (resourceId, resource) <- Map.toAscList (Map.union desiredManaged historicalManaged)
      , Set.member resourceId affected
      ]
        <> [ (resourceId, resource ^. #executor)
           | CollectRetained resourceId <- NE.toList (candidateChanges candidate)
           , Just (_, resource) <- [Map.lookup resourceId (historyRetained history)]
           ]
    ids = Set.fromList (map fst managed)
    grouped = Map.map (Set.toAscList . Set.fromList) (Map.fromListWith (<>) [(executor, [resource]) | (resource, executor) <- managed])
    sourceGroups =
      Map.map
        (Set.toAscList . Set.fromList)
        ( Map.fromListWith
            (<>)
            [(source ^. #executor, [resource]) | (resource, (source, _)) <- Map.toAscList migrations]
        )

-- | A scope replacement must not require observations of every unrelated
-- accepted provider resource. Effective shared-owner members whose composed
-- declaration changed remain selected, as do broker topics needed to verify a
-- newly selected consumer before it starts.
affectedManagedIds :: CompositionCandidate -> InventoryHistory -> Set ResourceId
affectedManagedIds candidate history =
  Set.unions
    [ selectedMembers
    , declaredTargets
    , changedMembers
    , brokerDependencies
    , contributionTargets
    , bootstrapDependencies
    , collections
    ]
  where
    desired =
      Map.fromList
        [ (resource ^. #identity, resource)
        | Managed resource <- inventoryDeclarations (candidateInventory candidate)
        ]
    historical =
      Map.fromList
        [ (resource ^. #identity, resource)
        | Managed resource <- historyDeclarations history
        ]
    selectedScopes = Set.fromList (mapMaybe selectedScope (NE.toList (candidateChanges candidate)))
    selectedScope (ReplaceScope scope) = Just (scopeId scope)
    selectedScope (RetireScope scope _) = Just scope
    selectedScope (CollectRetained _) = Nothing
    selectedMembers =
      Set.fromList
        [ resourceId
        | (resourceId, resource) <- Map.toAscList (Map.union desired historical)
        , Set.member (resource ^. #owner) selectedScopes
        ]
    declaredTargets =
      Set.fromList
        [ target
        | ReplaceScope scope <- NE.toList (candidateChanges candidate)
        , bundle <- scopeBundles scope
        , operation <- bundle ^. #operations
        , target <- NE.toList (operation ^. #affects)
        , Map.member target desired
        ]
    changedMembers =
      Set.fromList
        [ resourceId
        | resourceId <- Set.toAscList (Map.keysSet desired `Set.union` Map.keysSet historical)
        , Map.lookup resourceId desired /= Map.lookup resourceId historical
        ]
    brokerDependencies =
      Set.fromList
        [ target
        | resourceId <- Set.toAscList selectedMembers
        , Just consumer <- [Map.lookup resourceId desired]
        , dependency <- consumer ^. #dependencies
        , let target = dependencyResource dependency
        , Just producer <- [Map.lookup target desired]
        , producer ^. #executor == BrokerExecutor
        ]
    contributionTargets =
      Set.fromList
        [ target
        | scope <- Map.elems (inventoryScopes (candidateInventory candidate))
        , Set.member (scopeId scope) selectedScopes
        , bundle <- scopeBundles scope
        , contribution <- bundle ^. #contributions
        , let target = contributionResourceId contribution
        , Just resource <- [Map.lookup target desired]
        , resource ^. #executor == KubernetesExecutor
        ]
    bootstrapDependencies =
      Set.fromList
        [ target
        | resourceId <- Set.toAscList selectedMembers
        , Just consumer <- [Map.lookup resourceId desired]
        , consumer ^. #source . #file == "generated:bootstrap"
        , dependency <- consumer ^. #dependencies
        , let target = dependencyResource dependency
        , Map.member target desired
        ]
    collections = Set.fromList [resource | CollectRetained resource <- NE.toList (candidateChanges candidate)]
    dependencyResource (Consumes (SomeRef ref)) = refProducer ref
    dependencyResource (ReadyAfter (SomeRef ref)) = refProducer ref
    dependencyResource (OrderedAfter resource) = resource
