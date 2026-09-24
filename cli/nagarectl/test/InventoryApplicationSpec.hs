module InventoryApplicationSpec (inventoryApplicationTests) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (mkDatabaseName)
import Nagare.Dsl.Load (loadApplication, loadBroker)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Application (compileApplicationDatabases)
import Nagare.Inventory.DataService (compileStandaloneBroker, standaloneRetirementScope)
import Nagare.Resource.Application (applicationScopeId)
import Nagare.Resource.Inventory (Declaration (Managed), ManagedResource (..), ResourceBundle (..), mkScopeSnapshot, scopeBundles)
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

inventoryApplicationTests :: TestTree
inventoryApplicationTests = testGroup "application inventory compilation"
  [ testCase "complete typed database members join the application scope" $ do
      loaded <- loadApplication "test/fixtures/app/kizashi/Config.hs"
      app <- either (fail . show) pure loaded
      owner <- either (fail . show) pure (applicationScopeId app)
      let clusterOwner = either (error . show) id (mkScopeId Platform "foundation")
          cluster = mintResourceId clusterOwner
            (either (error . show) id (mkLogicalKey "cluster"))
            (either (error . show) id (mkName "resource"))
          recovery = RecoveryIntent (either (error . show) id (mkName "backup"))
            (mkSecretRef (either (error . show) id (mkName "db-password"))
              (either (error . show) id (mkName "v1")) :| [])
          recoveryByDatabase = Map.fromList
            [(database ^. #name, recovery) | database <- app ^. #databases]
          source = SourceLocation "test" "application"
          backend = GcsBackend "project" "bucket"
      (bundles, native) <- either (fail . show) pure
        (compileApplicationDatabases app cluster Nothing recoveryByDatabase backend source)
      length bundles @?= 1
      Map.size native @?= 5
      [resource ^. #owner | bundle <- bundles, Managed resource <- bundle ^. #declarations]
        @?= replicate 5 owner
      case compileApplicationDatabases app cluster Nothing Map.empty backend source of
        Left (err :| _) -> code err @?= "missing-database-recovery"
        Right _ -> assertFailure "database without recovery intent was accepted"
      case app ^. #databases of
        [database] -> do
          let key = either (error . show) id (mkLogicalKey "shared-database")
              renamedName = either (error . show) id (mkDatabaseName "kizashi-db-new")
              firstDatabase = database & #logicalKey .~ Just key
              secondDatabase = database & #name .~ renamedName & #logicalKey .~ Just key
              collisionApp = app & #databases .~ [firstDatabase, secondDatabase]
              bothRecovery = Map.fromList
                [(firstDatabase ^. #name, recovery), (secondDatabase ^. #name, recovery)]
          case compileApplicationDatabases collisionApp cluster Nothing bothRecovery backend source of
            Left (err :| _) -> code err @?= "duplicate-id"
            Right _ -> assertFailure "two databases with one logical key were accepted"
        _ -> assertFailure "fixture did not contain exactly one database"
  , testCase "standalone broker binds its PVC, Service, and StatefulSet" $ do
      loaded <- loadBroker "../nagare-dsl/test/fixtures/broker/redpanda/nagare/Config.hs"
      broker <- either (fail . show) pure loaded
      let owner = either (error . show) id (mkScopeId Standalone "broker-events")
          clusterOwner = either (error . show) id (mkScopeId Platform "foundation")
          cluster = mintResourceId clusterOwner
            (either (error . show) id (mkLogicalKey "cluster"))
            (either (error . show) id (mkName "resource"))
          namespaceId = mintResourceId clusterOwner
            (either (error . show) id (mkLogicalKey "foundation"))
            (either (error . show) id (mkName "namespace-personal"))
          recovery = RecoveryIntent (either (error . show) id (mkName "backup"))
            (mkSecretRef (either (error . show) id (mkName "broker-key"))
              (either (error . show) id (mkName "v1")) :| [])
          source = SourceLocation "test" "broker"
      case compileStandaloneBroker broker owner cluster namespaceId recovery source of
        Left (err :| _) -> code err @?= "invalid-standalone-broker"
        Right _ -> assertFailure "broker topics disappeared from inventory review"
      let withoutTopics = broker & #topics .~ []
      (scope, native) <- either (fail . show) pure
        (compileStandaloneBroker withoutTopics owner cluster namespaceId recovery source)
      length (scopeBundles scope) @?= 1
      Map.size native @?= 3
      [resource ^. #owner | bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations]
        @?= replicate 3 owner
      let checked = either (error . show) id
          binding = ContextBinding (checked (mkContextId "fixture")) (checked (mkName "project"))
          snapshot = either (error . show) id (mkScopeSnapshot binding
            (Map.singleton owner (checked (mkScopeGeneration 1), scope)) Map.empty)
      standaloneRetirementScope "broker" "events" "personal" Nothing snapshot @?= Right owner
      case standaloneRetirementScope "broker" "events" "other" Nothing snapshot of
        Left _ -> pure ()
        Right _ -> assertFailure "retirement accepted a different namespace"
      case standaloneRetirementScope "database" "events" "personal" Nothing snapshot of
        Left _ -> pure ()
        Right _ -> assertFailure "retirement selected a different data kind"
      case standaloneRetirementScope "broker" "other" "personal" (Just "events") snapshot of
        Left _ -> pure ()
        Right _ -> assertFailure "retirement selected a mismatched native name"
  ]
