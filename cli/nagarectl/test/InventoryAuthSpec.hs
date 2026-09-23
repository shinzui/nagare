module InventoryAuthSpec (inventoryAuthTests) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (StoreBackend (..), MinioRef (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Database (Database (Database), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Components.Auth
import Nagare.Inventory.Bootstrap (BootstrapInput (..), compileBootstrapWithAuth, compileBootstrapWithAuthAndScopes)
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Inventory.Components.PackagedAuth (compilePackagedAuth, packagedAuthInputs)
import Nagare.Inventory.Components.LocalObjectStore (compileLocalObjectStore)
import Nagare.Inventory.Components.Observability (PackagedHelmInput (..), compilePinnedObservability, pinnedObservabilityInputs)
import Nagare.Inventory.Components.Upstream (IssuerMode (LocalIssuer), configuredUpstreamInputsWithIssuer, pinnedUpstreamInputs)
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
  , testCase "packaged auth supplies complete database inputs and refuses mutable images" $ do
      let foundation = FoundationInput (ok (mkScopeId Platform "foundation")) fixtureCluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
          backend = GcsBackend "project" "bucket"
          pinned = authImages fixture
      (auth, databases) <- expectRight (packagedAuthInputs "../.." foundation CloudAuth
        "example.test" pinned backend)
      length databases @?= 2
      authNamespace auth @?= foundationNamespaceId foundation (ok (mkName "nagare-system"))
      (scope, native) <- compilePackagedAuth "../.." foundation CloudAuth
        "example.test" pinned backend >>= expectRight
      length (scopeBundles scope) @?= 3
      assertBool "packaged auth native database members are missing" (Map.size native > 20)
      invalid <- compilePackagedAuth "../.." foundation CloudAuth "example.test"
        (Map.insert "en" "registry.example.test/en:mutable" pinned) backend
      assertBool "mutable auth image was accepted" (case invalid of Left _ -> True; Right _ -> False)
  , testCase "local MinIO transport compiles as an owned scope" $ do
      let foundation = FoundationInput (ok (mkScopeId Platform "foundation")) fixtureCluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
          store = MinioRef "http://minio.nagare-system.svc.cluster.local:9000"
            "nagare-backups" "nagare-minio-credentials"
      (scope, native) <- compileLocalObjectStore "../.." foundation store >>= expectRight
      Map.size native @?= 5
      assertBool "MinIO scope omitted the bucket Job"
        (any (\(resource, _) -> case resource ^. #address of
          Kubernetes _ "batch" kind _ name -> nameText kind == "job" && nameText name == "minio-make-bucket"
          _ -> False) (Map.elems native))
      length (scopeBundles scope) @?= 1
      changed <- compileLocalObjectStore "../.." foundation
        (store {bucket = "wrong-bucket"})
      assertBool "local object-store profile mismatch was accepted" (case changed of Left _ -> True; Right _ -> False)
  , testCase "local auth backup waits for the owned MinIO bucket" $ do
      let observabilityInputs = pinnedObservabilityInputs fixtureCluster "../.." "v1.32.0"
          foundation = FoundationInput (ok (mkScopeId Platform "foundation")) fixtureCluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" (map packagedOwner observabilityInputs)
          store = MinioRef "http://minio.nagare-system.svc.cluster.local:9000"
            "nagare-backups" "nagare-minio-credentials"
          backend = MinioBackend store
          binding = ContextBinding (ok (mkContextId "local-auth-fixture")) (ok (mkName "project"))
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      upstream <- configuredUpstreamInputsWithIssuer fixtureCluster "../.."
        "example.test" "registry.example.test" LocalIssuer >>= expectRight
      let bootstrap = BootstrapInput foundation Nothing upstream
      (localScope, localNative) <- compileLocalObjectStore "../.." foundation store >>= expectRight
      let bucketJobs = [resource ^. #identity | (resource, _) <- Map.elems localNative,
            case resource ^. #address of
              Kubernetes _ "batch" kind _ name -> nameText kind == "job" && nameText name == "minio-make-bucket"
              _ -> False]
      [bucketJob] <- pure bucketJobs
      (auth, databases) <- expectRight (packagedAuthInputs "../.." foundation LocalAuth
        "example.test" (authImages fixture) backend)
      (candidate, _) <- compileBootstrapWithAuthAndScopes snapshot bootstrap
        auth {authExtraPrerequisites = [bucketJob]} databases [localScope] >>= expectRight
      (observability, _) <- compilePinnedObservability (foundationOwner foundation)
        observabilityInputs >>= expectRight
      complete <- expectRight (composeInventory snapshot (candidateChanges candidate <>
        (case observability of
          firstScope : rest -> ReplaceScope firstScope :| map ReplaceScope rest
          [] -> error "observability scopes disappeared")))
      Map.size (inventoryScopes (candidateInventory complete)) @?= 13
  ]

fixture :: AuthInput
fixture = AuthInput fixtureOwner fixtureCluster namespaceId "../.." images "example.test"
  (Map.fromList [("en", dbId "en"), ("shomei", dbId "shomei")]) [] CloudAuth
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
