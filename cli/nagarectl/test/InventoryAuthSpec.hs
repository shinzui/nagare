module InventoryAuthSpec (inventoryAuthTests) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Database (Database (Database), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Components.Auth
import Nagare.Inventory.Bootstrap (BootstrapInput (..), compileBootstrapWithAuth)
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Inventory.Components.Upstream (pinnedUpstreamInputs)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (LifecyclePolicy (Protect), RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

inventoryAuthTests :: TestTree
inventoryAuthTests = testGroup "auth inventory component"
  [ testCase "packaged auth manifests bind stable Secrets and revised Jobs" $ do
      (bundle, native) <- compileAuth fixture >>= expectRight
      let members = [resource | Managed resource <- declarations bundle]
          secrets = [resource | resource <- members, case resource ^. #address of
            Kubernetes _ "" kind _ _ -> nameText kind == "secret"
            _ -> False]
          jobs = [resource | resource <- members, case resource ^. #address of
            Kubernetes _ "batch" kind _ _ -> nameText kind == "job"
            _ -> False]
          deployments = [resource | resource <- members, case resource ^. #address of
            Kubernetes _ "apps" kind _ _ -> nameText kind == "deployment"
            _ -> False]
      length secrets @?= 3
      assertBool "auth key material is not protected from retirement"
        (all ((== Protect) . (^. #lifecycle)) secrets)
      length jobs @?= 2
      length deployments @?= 2
      length (operations bundle) @?= 2
      Map.size native @?= length members
      assertBool "migration Job is not revision-named"
        (all (\resource -> case resource ^. #address of
          Kubernetes _ _ _ _ name -> "-migrate-" `T.isInfixOf` nameText name
          _ -> False) jobs)
      let jobIds = map (^. #identity) jobs
          proofIds = map (^. #identity) (operations bundle)
      assertBool "auth Deployments do not wait for migration proofs"
        (all (\deployment -> any (\proof -> OrderedAfter proof `elem` deployment ^. #dependencies) proofIds) deployments)
      assertBool "migration proofs do not bind their reviewed Jobs"
        (all (\operation -> any (`elem` jobIds) (NE.toList (operation ^. #affects))) (operations bundle))
      assertBool "auth objects lack the foundation Namespace prerequisite"
        (all (\resource -> case resource ^. #address of
          Kubernetes _ _ _ (Just _) _ -> OrderedAfter namespaceId `elem` resource ^. #dependencies
          _ -> True) members)
      (localBundle, localNative) <- compileAuth fixture {authMode = LocalAuth} >>= expectRight
      length (declarations localBundle) @?= length members
      assertBool "local WebAuthn policy did not change the reviewed auth object" (localNative /= native)
  , testCase "complete auth scope includes its typed database bundles" $ do
      let database service = Database (ok (mkDatabaseName (service <> "-db"))) Nothing Postgres
            (defaultEngineVersion Postgres) (ok (Dsl.mkNamespace "nagare-system"))
            (ok (Dsl.mkQuantity "5Gi")) Nothing Dsl.Retain
          recovery = RecoveryIntent (ok (mkName "backup"))
            (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
          direct service = DatabaseDirectInput (database service) fixtureOwner fixtureCluster
            (Just namespaceId) recovery (SourceLocation "auth-fixture" service)
          dbId service = ok (databaseResourceId fixtureOwner (ok (mkName "statefulset")) (database service))
          input = fixture {authDatabasePrerequisites = Map.fromList
            [("shomei", dbId "shomei"), ("en", dbId "en")]}
          backends = [(service, direct service, GcsBackend "project" "bucket")
            | service <- ["shomei", "en"]]
      (scope, native) <- compileAuthComponent input backends >>= expectRight
      length (scopeBundles scope) @?= 3
      assertBool "complete auth scope omitted its databases" (Map.size native > 20)
  , testCase "auth databases and workloads compose after the pinned cluster foundation" $ do
      let foundation = FoundationInput (ok (mkScopeId Platform "foundation")) fixtureCluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
          sharedNamespace = foundationNamespaceId foundation (ok (mkName "nagare-system"))
          database service = Database (ok (mkDatabaseName (service <> "-db"))) Nothing Postgres
            (defaultEngineVersion Postgres) (ok (Dsl.mkNamespace "nagare-system"))
            (ok (Dsl.mkQuantity "5Gi")) Nothing Dsl.Retain
          recovery = RecoveryIntent (ok (mkName "backup"))
            (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
          direct service = DatabaseDirectInput (database service) fixtureOwner fixtureCluster
            (Just sharedNamespace) recovery (SourceLocation "auth-fixture" service)
          dbId service = ok (databaseResourceId fixtureOwner (ok (mkName "statefulset")) (database service))
          auth = fixture {authNamespace = sharedNamespace,
            authDatabasePrerequisites = Map.fromList [(service, dbId service) | service <- ["shomei", "en"]]}
          backends = [(service, direct service, GcsBackend "project" "bucket")
            | service <- ["shomei", "en"]]
          bootstrap = BootstrapInput foundation Nothing (pinnedUpstreamInputs fixtureCluster "../..")
          binding = ContextBinding (ok (mkContextId "fixture")) (ok (mkName "project"))
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      (candidate, native) <- compileBootstrapWithAuth snapshot bootstrap auth backends >>= expectRight
      Map.size (inventoryScopes (candidateInventory candidate)) @?= 6
      assertBool "auth bootstrap omitted direct native members" (Map.size native > 130)
  ]

fixture :: AuthInput
fixture = AuthInput fixtureOwner fixtureCluster namespaceId "../.." images "example.test"
  (Map.fromList [("en", dbId "en"), ("shomei", dbId "shomei")]) CloudAuth
  where
    images = Map.fromList [(name, "registry.example.test/" <> name <> "@sha256:" <> digest)
      | name <- ["en", "shomei", "nagare-access"]]
    digest = mconcat (replicate 64 "a")
    dbId name = mintResourceId fixtureOwner (ok (mkLogicalKey name)) (ok (mkName "database"))

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Platform "auth")

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId fixtureOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

namespaceId :: ResourceId
namespaceId = mintResourceId fixtureOwner (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-nagare-system"))

ok :: Show e => Either e a -> a
ok = either (error . show) id

expectRight :: Show e => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
