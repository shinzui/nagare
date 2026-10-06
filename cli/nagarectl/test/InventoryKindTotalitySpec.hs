-- | EP-177 (ADR 25 amendment): every executor, and every Kubernetes kind an
-- adapter admits or a release-line compiler emits, has a kind-table row, and
-- each row's claims agree with the adapter.
module InventoryKindTotalitySpec (inventoryKindTotalityTests) where

import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (Database (Database), Engine (Postgres, Redis), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapters.KubernetesCollection (collectionKinds, collectionPathPrefix)
import Nagare.Inventory.Adapters.KubernetesRuntime (readinessKinds, supportedUpdateKinds, supportsReadiness)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (HourlyRecoveryPoint))
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Types
import Nagare.Test.World.Kinds
import Test.Tasty
import Test.Tasty.HUnit

inventoryKindTotalityTests :: TestTree
inventoryKindTotalityTests =
  testGroup
    "kind totality"
    [ testCase "every executor has a kind row; only Kubernetes is in line" $ do
        missing [executor' | executor' <- [minBound .. maxBound], executor' `notElem` map (^. #executor) kindTable] @?= []
        [row | row <- kindTable, row ^. #executor /= KubernetesExecutor, row ^. #status == InLine] @?= []
    , testCase "every Kubernetes kind an adapter admits or a release-line compiler emits has a row" $ do
        -- The compiled database kinds are a real part of the universe.
        assertBool (show compiledKinds) (all (`elem` compiledKinds) [("apps", "statefulset"), ("", "persistentvolumeclaim"), ("batch", "cronjob")])
        missing [selected | selected <- universe, selected `notElem` rowKinds] @?= []
    , testCase "each in-line row's actions and readiness agree with the adapter" $
        missing (concatMap disagreements [row | row <- kindTable, row ^. #status == InLine]) @?= []
    , testCase "the adapter's kind lists agree with its own predicates" $ do
        [selected | selected <- collectionKinds, not (isJust (uncurry collectionPathPrefix selected))] @?= []
        [selected | selected <- readinessKinds, not (supportsReadiness (address selected))] @?= []
    , testCase "every in-line row has a fixture for the generated model" $
        [kubernetesKind row | row <- kindTable, row ^. #status == InLine, isNothing (kindFixture row)] @?= []
    , testCase "kind rows are unique" $
        let keys = [(row ^. #executor, row ^. #kind) | row <- kindTable]
         in length keys @?= length (nub keys)
    ]
  where
    missing :: (Show a) => [a] -> [Text]
    missing = map (T.pack . show)
    rowKinds = mapMaybe kubernetesKind kindTable
    universe = sort (nub (supportedUpdateKinds <> readinessKinds <> collectionKinds <> compiledKinds))
    disagreements row = case kubernetesKind row of
      Nothing -> []
      Just selected ->
        [ (selected, "update claim differs from the adapter's update list" :: Text)
        | (KindUpdate `elem` row ^. #actions) /= (selected `elem` supportedUpdateKinds)
        ]
          <> [ (selected, "collect claim differs from the adapter's collection list")
             | (KindCollect `elem` row ^. #actions) /= isJust (uncurry collectionPathPrefix selected)
             ]
          <> [ (selected, "readiness differs from the adapter's readiness wait")
             | (row ^. #readiness /= NoReadiness) /= supportsReadiness (address selected)
             ]
          <> [ (selected, "only a Job can fail terminally")
             | (row ^. #readiness == CanFail) /= (selected == ("batch", "job"))
             ]
    address (group, kind') =
      Kubernetes
        (mintResourceId owner (known (mkLogicalKey "cluster")) (known (mkName "cluster")))
        group
        (known (mkName kind'))
        (Just (known (mkName "default")))
        (known (mkName "probe"))
    -- The Kubernetes kinds a standalone PostgreSQL and Redis database, with
    -- scheduled backups, compile to.
    compiledKinds =
      nub
        [ (group, nameText kind')
        | engine <- [Postgres, Redis]
        , let (scope, _) = known (compileStandaloneDatabase (direct engine) (DatabaseBackupTarget (GcsBackend "project" "bucket") HourlyRecoveryPoint))
        , bundle <- scopeBundles scope
        , Managed member <- declarations bundle
        , Kubernetes _ group kind' _ _ <- [member ^. #address]
        ]
    direct engine =
      DatabaseDirectInput
        (Database (known (mkDatabaseName "kinds")) Nothing engine (defaultEngineVersion engine) (known (Dsl.mkNamespace "default")) (known (Dsl.mkQuantity "1Gi")) Nothing Dsl.Retain)
        owner
        (mintResourceId owner (known (mkLogicalKey "cluster")) (known (mkName "cluster")))
        Nothing
        (RecoveryIntent (known (mkName "backup")) (mkSecretRef (known (mkName "db-password")) (known (mkName "v1")) :| []))
        (SourceLocation "kinds" "database")
    owner = known (mkScopeId Standalone "kinds")

known :: (Show e) => Either e a -> a
known = either (error . show) id
