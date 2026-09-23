module InventoryAuthSpec (inventoryAuthTests) where

import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import Data.ByteString.Char8 qualified as BC
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Aeson.KeyMap qualified as KM
import Data.Text.Encoding qualified as TE
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (StoreBackend (..), MinioRef (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Database (Database (Database), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Components.Auth
import Nagare.Inventory.BackendMap (compileContributedBackendMaps, renderBackendMapNative)
import Nagare.Inventory.Bootstrap (BootstrapInput (..), compileBootstrapStamp, compileBootstrapWithAuth, compileBootstrapWithAuthAndScopes)
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Inventory.Components.PackagedAuth (compilePackagedAuth, packagedAuthInputs)
import Nagare.Inventory.Components.ControllerImage (controllerImageDeclaration)
import Nagare.Inventory.Components.LocalObjectStore (compileLocalObjectStore)
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..), credentialDataMatches, materializeLocalObjectStoreCredentialWith, minioSourceData, mkKubernetesRuntimeOps)
import Nagare.Inventory.Adapters.Kubernetes (KubernetesAdapterOps (..), KubernetesState (..), mkKubernetesAdapter)
import Nagare.Inventory.Adapter (Adapter (..), AdapterExecution (AdapterEffectCompleted), OperationAction (CreateResource), PlannedOperation (..), ResourceObservation (ConfirmedAbsent), observationSet)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Plan (loadInventoryHistory, noLifecycleDecisions, observationRequirements, planChanges, proposalOperations, requiredResources)
import Nagare.Inventory.Store (initializeStore, newMemoryStore)
import Nagare.Resource.Policy (RecoveryClass (Idempotent))
import Nagare.Inventory.Components.Observability (PackagedHelmInput (..), compilePinnedObservability, pinnedObservabilityInputs)
import Nagare.Inventory.Components.ObservabilityExtras (compileObservabilityExtras)
import Nagare.Inventory.Components.ObservabilitySecrets (compileObservabilitySecrets)
import Nagare.Inventory.Components.Upstream (IssuerMode (LocalIssuer), bindNetCertManagerControllerImage, configuredUpstreamInputsWithIssuer, pinnedUpstreamInputs)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (LifecyclePolicy (Protect), RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Kubernetes (parseKubernetesManifest)
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit
import System.Exit (ExitCode (..))
import System.Environment (lookupEnv)
import System.Process (readProcessWithExitCode)
import Control.Exception (finally)
import Control.Monad (forM_)

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
  , testCase "backend contributions bind exact reviewed ConfigMap bytes" $ do
      (authBundle, _) <- compileAuth fixture >>= expectRight
      let authScope = ok (mkScopeDeclaration fixtureOwner [authBundle])
          appOwner = ok (mkScopeId Application "sample")
          route = RegisterBackend fixtureOwner fixtureCluster (ok (mkName "sample.example.test"))
            "http://sample.personal.svc.cluster.local" ProtectedBackend (ok (mkLogicalKey "route"))
          appScope = ok (mkScopeDeclaration appOwner
            [ResourceBundle [] [] [] [route] [] []])
          scopes = Map.fromList [(fixtureOwner, authScope), (appOwner, appScope)]
          effective = ok (composedDeclarations scopes)
      [(resourceId, (resource, native))] <- pure (Map.toList (ok (compileContributedBackendMaps effective)))
      resourceId @?= backendMapResourceId fixtureOwner
      emptyObject <- either (assertFailure . show) pure (composedDeclarations
        (Map.singleton fixtureOwner authScope))
      [(_, (_, emptyNative))] <- pure (Map.toList (ok (compileContributedBackendMaps emptyObject)))
      packaged <- BS.readFile "../../cluster/bootstrap/nagare-access/configmap.yaml"
      manifests <- either (assertFailure . show) pure (parseKubernetesManifest
        (SourceLocation "cluster/bootstrap/nagare-access/configmap.yaml" "auth") packaged)
      [legacyMap] <- pure [value | (_, value@(Object fields)) <- manifests,
        KM.lookup "kind" fields == Just (String "ConfigMap")]
      canonicalValue legacyMap @?= Right emptyNative
      let context = ok (mkContextId "auth-backend-test")
          ops = KubernetesAdapterOps context
            (\_ -> pure (KubernetesAbsent (contentDigest "absent")))
            (\_ -> pure AdapterEffectCompleted)
          operation = PlannedOperation (ok (mkOperationId "op-auth-backend"))
            CreateResource KubernetesExecutor (resourceId :| []) (contentDigest "backend-map") [] Idempotent
          adapter = mkKubernetesAdapter (Map.singleton resourceId (resource, native)) ops
      _ <- adapterPrepare adapter operation >>= expectRight
      changed <- either (assertFailure . T.unpack) pure (renderBackendMapNative
        [(ok (mkName "sample.example.test"), "https://foreign.example.test", ProtectedBackend)])
      let badAdapter = mkKubernetesAdapter (Map.singleton resourceId (resource, changed)) ops
      rejected <- adapterPrepare badAdapter operation
      assertBool "changed backend bytes passed typed contribution binding" (case rejected of
        Left _ -> True; Right _ -> False)
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
          bootstrap = BootstrapInput foundation Nothing (pinnedUpstreamInputs fixtureCluster "../..") []
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
      let credentials = [(resource, bytes) | (resource, bytes) <- Map.elems native,
            case resource ^. #address of
              Kubernetes _ "" kind _ name ->
                nameText kind == "secret" && nameText name == "nagare-minio-credentials"
              _ -> False]
      length credentials @?= 2
      assertBool "fixed MinIO credential leaked into reviewed native bytes"
        (all (not . BC.isInfixOf "minioadmin" . snd) credentials)
      let primary = [(resource, bytes) | (resource, bytes) <- credentials,
            case resource ^. #address of
              Kubernetes _ _ _ (Just namespaceName) _ -> nameText namespaceName == "nagare-system"
              _ -> False]
      [(primaryResource, primaryBytes)] <- pure primary
      let config = KubernetesRuntimeConfig (ok (mkContextId "local-minio-fixture"))
            "unused" (pure (Right ()))
      materialized <- materializeLocalObjectStoreCredentialWith
        (pure (Left "primary credential must not read Kubernetes")) config (TE.decodeUtf8 primaryBytes)
        >>= either (assertFailure . T.unpack) pure
      let reviewed = eitherDecodeStrict primaryBytes :: Either String Value
          created = eitherDecodeStrict (TE.encodeUtf8 materialized) :: Either String Value
      credentialDataMatches (either (error . show) id reviewed)
        (either (error . show) id created) @?= True
      let source = object
            [ "apiVersion" .= ("v1" :: T.Text)
            , "kind" .= ("Secret" :: T.Text)
            , "type" .= ("Opaque" :: T.Text)
            , "metadata" .= object
                [ "name" .= ("nagare-minio-credentials" :: T.Text)
                , "namespace" .= ("nagare-system" :: T.Text)
                , "annotations" .= object
                    [ "nagare.dev/context-id" .= contextIdText (runtimeContext config)
                    , "nagare.dev/resource-id" .= resourceIdText (primaryResource ^. #identity)
                    , "nagare.dev/minio-credential-template" .= ("v1" :: T.Text)
                    ]
                ]
            , "data" .= object
                [ "AWS_ACCESS_KEY_ID" .= ("dXNlcg==" :: T.Text)
                , "AWS_SECRET_ACCESS_KEY" .= ("cGFzcw==" :: T.Text)
                ]
            ]
      assertBool "owned MinIO source Secret was rejected"
        (case minioSourceData config (resourceIdText (primaryResource ^. #identity)) source of
          Right _ -> True; Left _ -> False)
      assertBool "foreign MinIO source identity was accepted"
        (case minioSourceData config "foreign-resource" source of
          Left _ -> True; Right _ -> False)
      let personal = [bytes | (resource, bytes) <- credentials,
            case resource ^. #address of
              Kubernetes _ _ _ (Just namespaceName) _ -> nameText namespaceName == "personal"
              _ -> False]
      [personalBytes] <- pure personal
      let fetch = pure (Right (ExitSuccess, T.unpack (TE.decodeUtf8 (LBS.toStrict (encode source))), ""))
      copied <- materializeLocalObjectStoreCredentialWith fetch config (TE.decodeUtf8 personalBytes)
        >>= either (assertFailure . T.unpack) pure
      case eitherDecodeStrict (TE.encodeUtf8 copied) of
        Right (Object fields) -> KM.lookup "data" fields @?= case source of
          Object sourceFields -> KM.lookup "data" sourceFields
          _ -> Nothing
        other -> assertFailure ("copied MinIO credential is malformed: " <> show other)
      selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
      case selected of
        Nothing -> pure ()
        Just selectedContext -> do
          assertBool "refusing a non-disposable Kubernetes context"
            ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
          let kubectl args input = readProcessWithExitCode "kubectl"
                (["--context", selectedContext] <> args) input
              liveConfig = config {runtimeKubectlContext = T.pack selectedContext}
          forM_ ["nagare-system", "personal"] $ \namespaceName -> do
            (existingCode, existingNamespace, _) <- kubectl
              ["get", "namespace", namespaceName, "-o", "name", "--ignore-not-found"] ""
            existingCode @?= ExitSuccess
            assertBool "disposable test namespace is already in use" (null existingNamespace)
          (namespaceCode, _, namespaceError) <- kubectl ["create", "namespace", "nagare-system"] ""
          assertBool namespaceError (namespaceCode == ExitSuccess)
          (do
            (personalCode, _, personalError) <- kubectl ["create", "namespace", "personal"] ""
            assertBool personalError (personalCode == ExitSuccess)
            let specifications = Map.fromList [(resource ^. #identity, (resource, bytes)) | (resource, bytes) <- credentials]
                adapter = mkKubernetesAdapter specifications (mkKubernetesRuntimeOps liveConfig specifications)
                createSecret rid = do
                  let operationName = if rid == primaryResource ^. #identity
                        then "op-minio-primary" else "op-minio-copy"
                      operation = PlannedOperation (ok (mkOperationId operationName))
                        CreateResource KubernetesExecutor (rid :| []) (contentDigest "local-minio-secret") [] Idempotent
                  prepared <- adapterPrepare adapter operation >>= expectRight
                  adapterPreflight adapter operation prepared >>= expectRight
                  adapterExecute adapter operation prepared >>= (@?= AdapterEffectCompleted)
                  _ <- adapterVerify adapter operation prepared >>= expectRight
                  pure ()
            createSecret (primaryResource ^. #identity)
            case [(resource, bytes) | (resource, bytes) <- credentials,
                  case resource ^. #address of
                    Kubernetes _ _ _ (Just namespaceName) _ -> nameText namespaceName == "personal"
                    _ -> False] of
              [(personalResource, _)] -> createSecret (personalResource ^. #identity)
              _ -> assertFailure "personal MinIO Secret is missing"
            (primaryCode, primaryOutput, primaryError) <- kubectl
              ["get", "secret", "nagare-minio-credentials", "-n", "nagare-system", "-o", "json"] ""
            assertBool primaryError (primaryCode == ExitSuccess)
            (copyCode, copyOutput, copyError) <- kubectl
              ["get", "secret", "nagare-minio-credentials", "-n", "personal", "-o", "json"] ""
            assertBool copyError (copyCode == ExitSuccess)
            let observedData body = case eitherDecodeStrict (BC.pack body) of
                  Right (Object fields) -> KM.lookup "data" fields
                  _ -> Nothing
            observedData copyOutput @?= observedData primaryOutput)
            `finally` do
              _ <- kubectl ["delete", "namespace", "nagare-system", "personal", "--wait=false"] ""
              pure ()
      assertBool "personal MinIO Secret lacks a dependency on generated primary"
        (any (\(resource, bytes) -> case resource ^. #address of
          Kubernetes _ "" kind (Just namespaceName) _ ->
            nameText kind == "secret" && nameText namespaceName == "personal"
              && OrderedAfter (primaryResource ^. #identity) `elem` resource ^. #dependencies
              && BC.isInfixOf (BC.pack (T.unpack (resourceIdText (primaryResource ^. #identity)))) bytes
          _ -> False) credentials)
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
      rawUpstream <- configuredUpstreamInputsWithIssuer fixtureCluster "../.."
        "example.test" "registry.example.test" LocalIssuer >>= expectRight
      (controllerScope, controllerImage, publication) <- expectRight
        (controllerImageDeclaration "registry.example.test"
          (ok (mkContentDigest (T.replicate 64 "a")))
          (ok (mkContentDigest (T.replicate 64 "b"))))
      upstream <- either (assertFailure . T.unpack) pure
        (bindNetCertManagerControllerImage fixtureCluster controllerImage publication rawUpstream)
      let bootstrap = BootstrapInput foundation Nothing upstream [controllerScope]
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
      (secretScope, _, secretIds) <- compileObservabilitySecrets foundation
        [(SourceLocation "fixture:grafana" "Secret", object
          ["apiVersion" .= ("v1" :: T.Text), "kind" .= ("Secret" :: T.Text),
           "metadata" .= object ["name" .= ("grafana-admin" :: T.Text),
             "namespace" .= ("monitoring" :: T.Text)],
           "stringData" .= object ["admin-user" .= ("admin" :: T.Text),
             "admin-password" .= ("fixture-canary" :: T.Text)]])]
        >>= expectRight
      let orderedObservability = case observabilityInputs of
            firstRelease : rest -> firstRelease
              {packagedDependencies = map OrderedAfter secretIds <> packagedDependencies firstRelease} : rest
            [] -> []
      (observability, _) <- compilePinnedObservability (foundationOwner foundation)
        orderedObservability >>= expectRight
      let metricsId = case observabilityInputs of
            firstRelease : _ -> packagedReleaseId firstRelease
            [] -> error "pinned metrics release disappeared"
      (extras, _) <- compileObservabilityExtras "../.." foundation
        metricsId >>= expectRight
      complete <- expectRight (composeInventory snapshot (candidateChanges candidate <>
        (case observability of
          firstScope : rest -> ReplaceScope firstScope :|
            (map ReplaceScope rest <> [ReplaceScope extras, ReplaceScope secretScope])
          [] -> error "observability scopes disappeared")))
      Map.size (inventoryScopes (candidateInventory complete)) @?= 16
      let marker = object ["apiVersion" .= ("v1" :: T.Text), "kind" .= ("ConfigMap" :: T.Text),
            "metadata" .= object ["name" .= ("nagare-platform-version" :: T.Text),
              "namespace" .= ("nagare-system" :: T.Text)],
            "data" .= object ["version" .= ("0.4.0" :: T.Text)]]
      (stampScope, stampNative) <- expectRight (compileBootstrapStamp fixtureCluster marker complete)
      stamped <- expectRight (composeInventory snapshot (candidateChanges complete <>
        (ReplaceScope stampScope :| [])))
      Map.size (inventoryScopes (candidateInventory stamped)) @?= 17
      assertBool "local bootstrap included the cloud-only cache"
        (Map.notMember (ok (mkScopeId Platform "cache")) (inventoryScopes (candidateInventory stamped))
          && Map.notMember (ok (mkScopeId Platform "cache-image")) (inventoryScopes (candidateInventory stamped)))
      historyStore <- newMemoryStore
      _ <- initializeStore historyStore binding "local-bootstrap" >>= expectRight
      history <- loadInventoryHistory historyStore >>= expectRight
      let required = requiredResources (observationRequirements stamped history)
          observed = ok (observationSet [(resource, ConfirmedAbsent (contentDigest "absent"))
            | resource <- Set.toAscList required])
          operations = proposalOperations (ok (planChanges stamped noLifecycleDecisions history observed))
          markerOperations = [operation | operation <- operations,
            any (`elem` Map.keys stampNative) (plannedResources operation)]
      case markerOperations of
        [operation] -> Set.fromList (plannedDependencies operation) @?=
          Set.fromList [plannedOperationId other | other <- operations,
            plannedOperationId other /= plannedOperationId operation]
        other -> assertFailure ("expected one final local marker operation, got " <> show other)
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
