module InventoryStatusSpec (inventoryStatusTests) where

import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Status
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

inventoryStatusTests :: TestTree
inventoryStatusTests = testGroup "inventory status"
  [ testCase "keeps provider absence, foreign ownership, drift, and unreadability distinct" $ do
      let uid = known (mkPhysicalIdentity "uid-1")
          changed = contentDigest "changed"
          category observation = case classifyDrift inventory (known (observationSet observation)) of
            [finding] -> findingCategory finding
            _ -> error "status fixture has no unique managed resource"
      category [(resourceId, ObservedPresent uid)] @?= Converged
      category [(resourceId, ObservedDrifted uid changed)] @?= ConfigurationDrift
      category [(resourceId, ObservedForeign uid)] @?= ForeignOwner
      category [(resourceId, ConfirmedAbsent changed)] @?= MissingResource
      category [(resourceId, ObservationUnavailable "unreadable")] @?= UnknownObservation
      category [] @?= UnknownObservation
  ]
  where
    known :: Show e => Either e a -> a
    known = either (error . show) id
    owner = known (mkScopeId Platform "fixture")
    cluster = mintResourceId owner (known (mkLogicalKey "cluster")) (known (mkName "cluster"))
    resourceId = mintResourceId owner (known (mkLogicalKey "config")) (known (mkName "resource"))
    resource = ManagedResource resourceId owner KubernetesExecutor
      (Kubernetes cluster "" (known (mkName "configmap")) (Just (known (mkName "default")))
        (known (mkName "status-fixture"))) []
      (NativeObject (contentDigest "desired")) Retain Stateless Public [] []
      (SourceLocation "fixture" "configmap")
    scope = known (mkScopeDeclaration owner [ResourceBundle [Managed resource] [] [] [] [] []])
    snapshot = known (mkScopeSnapshot
      (ContextBinding (known (mkContextId "fixture")) (known (mkName "project")))
      (Map.singleton owner (known (mkScopeGeneration 1), scope)) Map.empty)
    inventory = known (composeSnapshot snapshot)
