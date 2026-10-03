-- | Reviewed collection of a retired database's companions. Only stateless
-- members qualify; durable data and recovery credentials stay retained.
module InventoryCompanionCollectionSpec (inventoryCompanionCollectionTests) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List (isInfixOf, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (Database (Database), Engine (..), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapters.KubernetesRuntime (collectionDeleteRequest)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Test.Support.Kubernetes (cluster, expectRight, ok)
import Test.Tasty
import Test.Tasty.HUnit

inventoryCompanionCollectionTests :: TestTree
inventoryCompanionCollectionTests =
  testGroup
    "inventory companion collection"
    [ testCase "retained database companions are collectable only for stateless members" $ do
        let owner = ok (mkScopeId Standalone "database-pg-companions")
            db =
              Database
                (ok (mkDatabaseName "pg-companions"))
                Nothing
                Postgres
                (defaultEngineVersion Postgres)
                (ok (Dsl.mkNamespace "personal"))
                (ok (Dsl.mkQuantity "1Gi"))
                Nothing
                Dsl.Retain
            recovery =
              RecoveryIntent
                (ok (mkName "backup"))
                (mkSecretRef (ok (mkName "nagare-db-pg-companions")) (ok (mkName "v1")) :| [])
            direct =
              DatabaseDirectInput
                db
                owner
                cluster
                Nothing
                recovery
                (SourceLocation "database" "pg-companions")
            (_, databaseNative) =
              ok
                ( compileStandaloneDatabase
                    direct
                    (DatabaseBackupTarget (GcsBackend "project" "bucket") HourlyRecoveryPoint)
                )
            role declaration = last (T.splitOn "/" (resourceIdText (declaration ^. #identity)))
            members = map fst (Map.elems databaseNative)
            collectable = sort [role declaration | declaration <- members, supportsRetainedCollection declaration]
            retained = sort [role declaration | declaration <- members, not (supportsRetainedCollection declaration)]
            uid = ok (mkPhysicalIdentity "companion-uid")
        collectable @?= sort ["backup", "backup-account", "backup-read-binding", "backup-read-role", "service", "statefulset"]
        retained @?= sort ["backup-signing-key", "credential", "pvc"]
        forM_ [declaration | declaration <- members, supportsRetainedCollection declaration] $ \declaration -> do
          (arguments, body) <- expectRight (collectionDeleteRequest (declaration ^. #address) uid "resource-version")
          let propagation = if role declaration == "statefulset" then "Background" else "Orphan"
          assertBool
            ("companion deletion dropped its preconditions or propagation: " <> T.unpack (role declaration))
            (all (\part -> BS.isInfixOf part (TE.encodeUtf8 body)) ["companion-uid", "resource-version", propagation])
          case arguments of
            ["delete", "--raw", path, "-f", "-"] ->
              assertBool ("companion deletion path is not namespaced: " <> path) ("/namespaces/personal/" `isInfixOf` path)
            _ -> assertFailure "companion deletion is not a raw conditional DELETE"
    ]
