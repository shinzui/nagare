module InventoryStatusSpec (inventoryStatusTests) where

import Data.Map.Strict qualified as Map
import Data.Aeson (toJSON, object, (.=))
import Data.Generics.Labels ()
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Inventory.Status
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit
import System.Directory (doesPathExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

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
      category [(resourceId, ObservedReplacementRequired uid changed)] @?= ImmutableReplacementRequired
      category [(resourceId, ObservedUnowned uid)] @?= UnownedResource
      category [(resourceId, ObservedForeign uid)] @?= ForeignOwner
      category [(resourceId, ConfirmedAbsent changed)] @?= MissingResource
      category [(resourceId, ObservationUnavailable "unreadable")] @?= UnknownObservation
      category [] @?= UnknownObservation
      case classifyDrift inventory (known (observationSet [(resourceId, ObservedPresent uid)])) of
        [finding] -> do
          findingHealth finding @?= HealthUnknown
          toJSON finding @?= object
            ["resource" .= resourceId, "owner" .= owner,
             "executor" .= KubernetesExecutor, "address" .= (resource ^. #address),
             "category" .= Converged, "health" .= HealthUnknown,
             "physical" .= Just uid, "observedDigest" .= (Nothing :: Maybe ContentDigest),
             "reason" .= (Nothing :: Maybe Text)]
        _ -> assertFailure "status fixture has no unique managed resource"
      case classifyDrift inventory (known (observationSet
        [(resourceId, ObservationUnavailable "private provider stderr")])) of
        [finding] -> findingReason finding @?= Just "provider observation is unavailable"
        _ -> assertFailure "status fixture has no unique managed resource"
  , testCase "collection screening matches the conditional Kubernetes delete transport" $ do
      let supported = resource {lifecycle = DeleteWhenUnreferenced}
          service = supported {address = Kubernetes cluster "" (known (mkName "service"))
            (Just (known (mkName "default"))) (known (mkName "status-fixture"))}
          cronJob = supported {address = Kubernetes cluster "batch" (known (mkName "cronjob"))
            (Just (known (mkName "default"))) (known (mkName "status-fixture"))}
          statefulSet = supported {address = Kubernetes cluster "apps" (known (mkName "statefulset"))
            (Just (known (mkName "default"))) (known (mkName "status-fixture"))}
          clusterScoped = supported {address = Kubernetes cluster "" (known (mkName "configmap"))
            Nothing (known (mkName "status-fixture"))}
      supportsRetainedCollection supported @?= True
      supportsRetainedCollection resource @?= False
      supportsRetainedCollection service @?= True
      supportsRetainedCollection cronJob @?= True
      supportsRetainedCollection statefulSet @?= False
      supportsRetainedCollection clusterScoped @?= False
  , testCase "read-only status does not initialize a missing inventory store" $
      withSystemTempDirectory "inventory-status" $ \temporary -> do
        let missing = temporary </> "inventory"
        opened <- openFilesystemStoreReadOnly missing
        case opened of
          Left (StoreConditionFailed _) -> pure ()
          _ -> assertFailure "missing store should fail closed"
        doesPathExist missing >>= (@?= False)
  , testCase "active transaction status reports uncertain recovery without provider detail" $ do
      let transaction = known (mkTransactionId "tx-fixture")
          operation = known (mkOperationId "op-fixture")
          headValue = HeadManifest 1 1 3 (inventoryBinding inventory) "client"
            Map.empty Map.empty Map.empty Map.empty (Just "tx-fixture") Nothing Nothing
          event sequenceNumber prior state detail = JournalEvent 1 sequenceNumber prior
            transaction (if sequenceNumber == 0 then Nothing else Just operation)
            state "2026-09-23T00:00:00Z" detail
          admitted = event 0 Nothing Pending "private admission detail"
          intent = event 1 (Just (journalEventDigest admitted)) IntentRecorded "private command output"
          failed = event 2 (Just (journalEventDigest intent))
            (Failed (PartialOrUnknown "provider credential and stderr")) "private failure detail"
      case summarizeActiveTransaction headValue [admitted, intent, failed] of
        Right (Just status) -> do
          activeStatusRecoveryRequired status @?= True
          activeStatusReason status @?= "operation-recovery-required"
          toJSON status @?= object
            ["transaction" .= ("tx-fixture" :: Text), "recoveryRequired" .= True,
             "reason" .= ("operation-recovery-required" :: Text),
             "operations" .= [object ["operation" .= operation,
                                      "state" .= ("failed-uncertain" :: Text)]]]
        _ -> assertFailure "active transaction summary was absent"
      summarizeActiveTransaction headValue [] @?= Left "active transaction has no admission event"
  , testCase "dependency trace names the providing declaration and owner" $ do
      let consumerId = mintResourceId owner (known (mkLogicalKey "consumer"))
            (known (mkName "consumer"))
          consumer = ManagedResource consumerId owner KubernetesExecutor
            (Kubernetes cluster "" (known (mkName "configmap"))
              (Just (known (mkName "default"))) (known (mkName "status-consumer"))) []
            (NativeObject (contentDigest "consumer")) Retain Stateless Public
            [OrderedAfter resourceId] [] (SourceLocation "fixture" "consumer")
          topId = mintResourceId owner (known (mkLogicalKey "top"))
            (known (mkName "top"))
          top = ManagedResource topId owner KubernetesExecutor
            (Kubernetes cluster "" (known (mkName "configmap"))
              (Just (known (mkName "default"))) (known (mkName "status-top"))) []
            (NativeObject (contentDigest "top")) Retain Stateless Public
            [OrderedAfter consumerId] [] (SourceLocation "fixture" "top")
          joined = known (mkScopeDeclaration owner
            [ResourceBundle [Managed resource, Managed consumer, Managed top] [] [] [] [] []])
          joinedSnapshot = known (mkScopeSnapshot
            (ContextBinding (known (mkContextId "fixture")) (known (mkName "project")))
            (Map.singleton owner (known (mkScopeGeneration 1), joined)) Map.empty)
          joinedInventory = known (composeSnapshot joinedSnapshot)
      traceDependencies joinedInventory topId @?=
        [DependencyTrace topId consumerId (Just owner)
          (Just (SourceLocation "fixture" "consumer")) 1,
         DependencyTrace consumerId resourceId (Just owner)
          (Just (SourceLocation "fixture" "configmap")) 2]
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
