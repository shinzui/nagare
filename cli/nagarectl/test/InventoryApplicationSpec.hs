module InventoryApplicationSpec (inventoryApplicationTests) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (mkDatabaseName)
import Nagare.Dsl.Load (loadApplication)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Application (compileApplicationDatabases)
import Nagare.Resource.Application (applicationScopeId)
import Nagare.Resource.Inventory (Declaration (Managed), ManagedResource (..), ResourceBundle (..))
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
  ]
