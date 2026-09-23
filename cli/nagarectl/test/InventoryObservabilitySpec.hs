module InventoryObservabilitySpec (inventoryObservabilityTests) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString.Char8 qualified as BC
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.IORef
import Data.Text qualified as T
import Control.Exception (finally)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Components.Observability
import Nagare.Inventory.Adapters.Helm
import Nagare.Inventory.Adapters.HelmRuntime
import Nagare.Inventory.Adapter
import Nagare.Inventory.Bootstrap (BootstrapInput (..), compileBootstrapStamp, compileBootstrapWithAuth, compilePinnedBootstrap)
import Nagare.Inventory.Components.Auth (AuthMode (CloudAuth))
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.Components.PackagedAuth (packagedAuthInputs)
import Nagare.Inventory.Components.ControllerImage (controllerImageDeclaration)
import Nagare.Inventory.Components.ObservabilityExtras (compileObservabilityExtras)
import Nagare.Inventory.Components.ObservabilitySecrets (compileObservabilitySecrets, loadObservabilitySecretObjectsFromDirectory, readAlertmanagerEnabled)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Inventory.Components.PackagedCache (compilePackagedCacheWithVerifiedImage)
import Nagare.Inventory.Components.Upstream (bindNetCertManagerControllerImage, pinnedUpstreamInputs)
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.HelmReview (helmSpecsFromReview)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryClass (Idempotent))
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit
import System.Environment (lookupEnv)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import System.Posix.Files (setFileMode)

inventoryObservabilityTests :: TestTree
inventoryObservabilityTests = testGroup "Helm release compiler"
  [ testCase "post-rendered hooks and chart CRDs receive direct claims" $ do
      let (release, native) = ok (compileRenderedRelease fixture)
      assertBool "empty native contract" (not (BC.null native))
      case release ^. #spec of
        HelmRelease members _ -> length members @?= 2
        _ -> assertFailure "missing Helm release spec"
  , testCase "same Kubernetes address in render and CRDs refuses" $ do
      let input = fixture {releaseCrdsBytes = Just rendered}
      case compileRenderedRelease input of
        Left _ -> pure ()
        Right _ -> assertFailure "duplicate rendered member was accepted"
  , testCase "vendored metrics chart captures hooks and separate CRDs" $ do
      let root = "../../cluster/observability/"
          chart = root <> "vendor/victoria-metrics-k8s-stack-0.81.0.tgz"
          values = root <> "victoria-metrics/values.yaml"
      valuesBytes <- BS.readFile values
      captured <- capturePackagedRelease PackagedHelmInput
        { packagedReleaseId = releaseId fixture
        , packagedOwner = scope
        , packagedCluster = cluster
        , packagedNamespace = name "monitoring"
        , packagedName = name "vmks"
        , packagedChart = chart
        , packagedChartDigest = ok (mkContentDigest "34e2dfafb05dfdcf85aac05c8e61fa5e2f2dd33672422d4e09c066e09b664c13")
        , packagedValues = values
        , packagedValuesDigest = contentDigest valuesBytes
        , packagedPlugin = root <> "helm-review/capture"
        , packagedKubeVersion = "v1.32.0"
        , packagedHelmVersion = "v4.2.4"
        , packagedApiVersions = []
        , packagedDependencies = []
        }
      input <- either (assertFailure . show) pure captured
      assertBool "chart CRDs were not captured" (maybe False (not . BS.null) (releaseCrdsBytes input))
      case compileRenderedRelease input of
        Left err -> assertFailure (show err)
        Right (release, _) -> case release ^. #spec of
          HelmRelease members _ -> assertBool "metrics post-rendered members missing" (length members > 50)
          _ -> assertFailure "missing Helm release spec"
  , testCase "all five pinned charts compile as independent scopes" $ do
      let foundationOwner = ok (mkScopeId Platform "foundation")
          inputs = pinnedObservabilityInputs cluster "../.." "v1.32.0"
          foundation = FoundationInput foundationOwner cluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" (map packagedOwner inputs)
      (secretScope, secretNative, secretIds) <- compileObservabilitySecrets foundation secretObjects
        >>= either (assertFailure . show) pure
      assertBool "observability Secret retained stringData or plaintext"
        (all (\(_, bytes) -> not ("stringData" `BC.isInfixOf` bytes)
          && not ("fixture-canary" `BC.isInfixOf` bytes)) (Map.elems secretNative))
      assertBool "observability Secret was not normalized to data"
        (any (BC.isInfixOf "Zml4dHVyZS1jYW5hcnk=" . snd) (Map.elems secretNative))
      let orderedInputs = case inputs of
            firstRelease : rest -> firstRelease
              {packagedDependencies = map OrderedAfter secretIds <> packagedDependencies firstRelease} : rest
            [] -> []
      compiled <- compilePinnedObservability foundationOwner orderedInputs
      (scopes, native) <- either (assertFailure . show) pure compiled
      length scopes @?= 5
      assertBool "chart CRD direct members missing" (Map.size native > 5)
      let binding = ContextBinding (ok (mkContextId "helm-fixture")) (name "project")
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      base <- compilePinnedBootstrap snapshot foundation Nothing "../.." >>= either (assertFailure . show) pure
      let metricsId = case pinnedObservabilityInputs cluster "../.." "v1.32.0" of
            firstRelease : _ -> packagedReleaseId firstRelease
            [] -> error "pinned metrics release disappeared"
      (extras, extraNative) <- compileObservabilityExtras "../.." foundation
        metricsId
        >>= either (assertFailure . show) pure
      Map.size extraNative @?= 6
      Map.size secretNative @?= 1
      let (candidate, _) = base
      case composeInventory snapshot (candidateChanges candidate <> (case scopes of
          firstScope : rest -> ReplaceScope firstScope :|
            (map ReplaceScope rest <> [ReplaceScope extras, ReplaceScope secretScope])
          [] -> error "five observability scopes disappeared")) of
        Left errors -> assertFailure (show errors)
        Right _ -> pure ()
  , testCase "observability Secret input follows pinned Alertmanager policy" $ do
      let foundation = FoundationInput (ok (mkScopeId Platform "foundation")) cluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
          metricsInput = case pinnedObservabilityInputs cluster "../.." "v1.32.0" of
            firstRelease : _ -> firstRelease
            [] -> error "pinned metrics release disappeared"
      enabled <- readAlertmanagerEnabled (packagedValues metricsInput)
        (packagedValuesDigest metricsInput) >>= either (assertFailure . T.unpack) pure
      enabled @?= False
      absent <- compileObservabilitySecrets foundation []
      assertBool "missing Grafana admin Secret was accepted"
        (case absent of Left _ -> True; Right _ -> False)
      let overlapping = [(SourceLocation "fixture:overlap" "Secret", object
            [ "apiVersion" .= ("v1" :: T.Text)
            , "kind" .= ("Secret" :: T.Text)
            , "metadata" .= object
                [ "name" .= ("grafana-admin" :: T.Text)
                , "namespace" .= ("monitoring" :: T.Text)
                ]
            , "data" .= object ["admin-user" .= ("YWRtaW4=" :: T.Text)]
            , "stringData" .= object
                [ "admin-user" .= ("admin" :: T.Text)
                , "admin-password" .= ("fixture" :: T.Text)
                ]
            ])]
      duplicate <- compileObservabilitySecrets foundation overlapping
      assertBool "overlapping Secret data and stringData was accepted"
        (case duplicate of Left _ -> True; Right _ -> False)
  , testCase "encrypted observability input is required and decryption errors stay private" $
      withSystemTempDirectory "observability-secrets" $ \directory -> do
        let executable = directory </> "fake-sops"
            grafana = directory </> "grafana-admin.yaml"
            secret = "apiVersion: v1\nkind: Secret\nmetadata:\n  name: grafana-admin\n  namespace: monitoring\nstringData:\n  admin-user: admin\n  admin-password: fixture\n"
        missing <- loadObservabilitySecretObjectsFromDirectory executable directory False
        assertBool "missing Grafana credentials were accepted" (case missing of Left _ -> True; Right _ -> False)
        BC.writeFile grafana secret
        BC.writeFile executable "#!/bin/sh\ncat \"$2\"\n"
        setFileMode executable 0o755
        loaded <- loadObservabilitySecretObjectsFromDirectory executable directory False
          >>= either (assertFailure . T.unpack) pure
        length loaded @?= 1
        required <- loadObservabilitySecretObjectsFromDirectory executable directory True
        assertBool "missing enabled Alertmanager configuration was accepted"
          (case required of Left _ -> True; Right _ -> False)
        BC.writeFile executable "#!/bin/sh\necho private-canary >&2\nexit 1\n"
        refused <- loadObservabilitySecretObjectsFromDirectory executable directory False
        case refused of
          Left reason -> assertBool "decryption output leaked into error" (not ("private-canary" `T.isInfixOf` reason))
          Right _ -> assertFailure "failed decryption was accepted"
  , testCase "cloud bootstrap composes auth, cache publication, and observability" $
      withSystemTempDirectory "bootstrap-complete" $ \root -> do
        let source = "../../cluster/bootstrap/nix-cache"
            destination = root </> "cluster/bootstrap/nix-cache"
            owner = ok (mkScopeId Platform "foundation")
            observabilityInputs = pinnedObservabilityInputs cluster "../.." "v1.32.0"
            foundation = FoundationInput owner cluster
              "../../cluster/bootstrap/job-runs/resourcequota.yaml" (map packagedOwner observabilityInputs)
            images = Map.fromList [(service,
              "registry.example.test/" <> service <> "@sha256:" <> T.replicate 64 "a")
              | service <- ["en", "shomei", "nagare-access"]]
            backend = GcsBackend "project" "backups"
            binding = ContextBinding (ok (mkContextId "complete-bootstrap")) (name "project")
            snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
        (secretScope, secretNative, secretIds) <- compileObservabilitySecrets foundation secretObjects
          >>= either (assertFailure . show) pure
        createDirectoryIfMissing True destination
        listDirectory source >>= mapM_ (\entry -> do
          let path = source </> entry
          present <- doesFileExist path
          when present (copyFile path (destination </> entry)))
        BC.writeFile (destination </> "attic-pin.json")
          "{\"sourceCommit\":\"abcdef123456\",\"linuxAmd64Digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"
        BC.writeFile (destination </> "attic-server-image.tar.gz") "fixture-archive"
        (imageScope, cacheScope, cacheNative) <- compilePackagedCacheWithVerifiedImage root foundation "project"
          "registry.example/project/nagare" "backups" "nix-cache-bucket" "abcdef123456"
          (ok (mkContentDigest (T.replicate 64 "a"))) (contentDigest "fixture-archive")
          >>= either (assertFailure . show) pure
        (auth, databases) <- either (assertFailure . show) pure
          (packagedAuthInputs "../.." foundation CloudAuth "example.test" images backend)
        (controllerScope, controllerImage, publication) <- either (assertFailure . show) pure
          (controllerImageDeclaration "registry.example.test"
            (ok (mkContentDigest (T.replicate 64 "a")))
            (ok (mkContentDigest (T.replicate 64 "b"))))
        upstream <- either (assertFailure . T.unpack) pure
          (bindNetCertManagerControllerImage cluster controllerImage publication
            (pinnedUpstreamInputs cluster "../.."))
        (base, baseNative) <- compileBootstrapWithAuth snapshot
          (BootstrapInput foundation Nothing upstream [controllerScope]) auth databases
          >>= either (assertFailure . show) pure
        let orderedInputs = case observabilityInputs of
              firstRelease : rest -> firstRelease
                {packagedDependencies = map OrderedAfter secretIds <> packagedDependencies firstRelease} : rest
              [] -> []
        (observability, obsNative) <- compilePinnedObservability owner orderedInputs
          >>= either (assertFailure . show) pure
        let metricsId = case observabilityInputs of
              firstRelease : _ -> packagedReleaseId firstRelease
              [] -> error "pinned metrics release disappeared"
        (extras, extraNative) <- compileObservabilityExtras "../.." foundation
          metricsId >>= either (assertFailure . show) pure
        let changes = candidateChanges base <> (ReplaceScope imageScope :|
              (ReplaceScope cacheScope : map ReplaceScope observability
                <> [ReplaceScope extras, ReplaceScope secretScope]))
            native = Map.unions [baseNative, cacheNative, obsNative, extraNative, secretNative]
        Map.size native @?= sum (map Map.size [baseNative, cacheNative, obsNative, extraNative, secretNative])
        complete <- either (assertFailure . show) pure (composeInventory snapshot changes)
        Map.size (inventoryScopes (candidateInventory complete)) @?= 16
        let marker = object ["apiVersion" .= ("v1" :: T.Text), "kind" .= ("ConfigMap" :: T.Text),
              "metadata" .= object ["name" .= ("nagare-platform-version" :: T.Text),
                "namespace" .= ("nagare-system" :: T.Text)],
              "data" .= object ["version" .= ("0.4.0" :: T.Text)]]
        (stampScope, stampNative) <- either (assertFailure . show) pure
          (compileBootstrapStamp cluster marker complete)
        stamped <- either (assertFailure . show) pure
          (composeInventory snapshot (candidateChanges complete <> (ReplaceScope stampScope :| [])))
        Map.size (inventoryScopes (candidateInventory stamped)) @?= 17
        Map.size stampNative @?= 1
  , testCase "reviewed Helm adapter refuses a changed release revision" $ do
      let (release, native) = ok (compileRenderedRelease fixture)
          operation = PlannedOperation (ok (mkOperationId "op-helm-create")) CreateResource HelmExecutor
            (releaseId fixture :| []) (contentDigest native) [] Idempotent
          specs = Map.singleton (releaseId fixture) (release, native)
      current <- newIORef (HelmAbsent (contentDigest (BC.pack "absence")))
      let adapter = mkHelmAdapter specs HelmAdapterOps
            { helmObserve = \_ -> readIORef current
            , helmMutateConditional = \mutation -> do
                writeIORef current (HelmPresent (ok (mkPhysicalIdentity "helm-1")) "1"
                  (helmMutationResource mutation) (helmMutationContractDigest mutation))
                pure AdapterEffectCompleted
            }
      prepared <- adapterPrepare adapter operation >>= either (assertFailure . show) pure
      writeIORef current (HelmPresent (ok (mkPhysicalIdentity "foreign")) "2"
        (releaseId fixture) (contentDigest native))
      refused <- adapterPreflight adapter operation prepared
      case refused of
        Left _ -> pure ()
        Right _ -> assertFailure "changed release revision was accepted"
      result <- adapterExecute adapter operation prepared
      case result of
        AdapterEffectFailed _ -> pure ()
        _ -> assertFailure "changed release was mutated"
      writeIORef current (HelmAbsent (contentDigest (BC.pack "absence")))
      completed <- adapterExecute adapter operation prepared
      completed @?= AdapterEffectCompleted
      verified <- adapterVerify adapter operation prepared
      case verified of
        Right _ -> pure ()
        Left reason -> assertFailure (show reason)
  , testCase "private review reconstructs the Helm contract" $ do
      let (release, native) = ok (compileRenderedRelease fixture)
          specs = Map.singleton (releaseId fixture) (release, native)
          binding = ContextBinding (ok (mkContextId "helm-review")) (name "project")
          declared = ok (mkScopeDeclaration scope [ResourceBundle [Managed release] [] [] [] [] []])
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
          candidate = ok (composeInventory snapshot (ReplaceScope declared :| []))
          absent = contentDigest (BC.pack "absent")
          observations = ok (observationSet [(releaseId fixture, ConfirmedAbsent absent)])
      current <- newIORef (HelmAbsent absent)
      let adapter = mkHelmAdapter specs HelmAdapterOps
            { helmObserve = \_ -> readIORef current
            , helmMutateConditional = \_ -> pure AdapterEffectCompleted
            }
          registry = ok (mkAdapterRegistry [adapter])
      store <- newMemoryStore
      _ <- initializeStore store binding "helm-review-client" >>= either (assertFailure . show) pure
      history <- loadInventoryHistory store >>= either (assertFailure . show) pure
      let proposal = ok (planChanges candidate noLifecycleDecisions history observations)
      before <- readStoreSnapshot store >>= either (assertFailure . show) pure
      reviewed <- prepareReview registry before proposal >>= either (assertFailure . show) pure
      helmSpecsFromReview reviewed @?= Right specs
  , testCase "disposable Helm create and upgrade retain reviewed native bytes" $ do
      selected <- lookupEnv "NAGARE_EP147_TEST_CONTEXT"
      case selected of
        Nothing -> pure ()
        Just selectedContext -> do
          assertBool "refusing a non-disposable Kubernetes context"
            ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
          withSystemTempDirectory "nagare-helm-runtime-test" $ \temporary -> do
            let namespace = "inventory-helm-adapter"
                fixturePath = "test/fixtures/helm-review-static"
                chartPath = temporary </> "inventory-review-static-fixture-0.1.0.tgz"
                valuesPath = fixturePath </> "values.yaml"
                run command args = readProcessWithExitCode command args ""
                kubectl args = run "kubectl" (["--context", selectedContext] <> args)
            (createCode, _, _) <- kubectl ["create", "namespace", namespace]
            createCode @?= ExitSuccess
            let cleanup = do
                  _ <- kubectl ["delete", "namespace", namespace, "--wait=false"]
                  pure ()
            (do
              (packageCode, _, packageError) <- run "helm" ["package", fixturePath, "--destination", temporary]
              assertEqual packageError ExitSuccess packageCode
              chartBytes <- BS.readFile chartPath
              valuesBytes <- BS.readFile valuesPath
              let input = PackagedHelmInput
                    { packagedReleaseId = releaseId fixture
                    , packagedOwner = scope
                    , packagedCluster = cluster
                    , packagedNamespace = name "inventory-helm-adapter"
                    , packagedName = name "inventory-helm-adapter"
                    , packagedChart = chartPath
                    , packagedChartDigest = contentDigest chartBytes
                    , packagedValues = valuesPath
                    , packagedValuesDigest = contentDigest valuesBytes
                    , packagedPlugin = "../../cluster/observability/helm-review/capture"
                    , packagedKubeVersion = "v1.32.5+k3s1"
                    , packagedHelmVersion = "v4.2.4"
                    , packagedApiVersions = []
                    , packagedDependencies = []
                    }
              captured <- capturePackagedRelease input >>= either (assertFailure . show) pure
              (release, native) <- either (assertFailure . show) pure (compileRenderedRelease captured)
              let runtime = HelmRuntimeConfig (T.pack selectedContext) (ok (mkContextId "helm-test"))
                    "../../cluster/observability/helm-review" (Map.singleton (releaseId fixture) release)
                    (pure (Right ()))
                  adapter = mkHelmAdapter (Map.singleton (releaseId fixture) (release, native))
                    (helmRuntimeOps runtime)
                  operation = PlannedOperation (ok (mkOperationId "op-helm-runtime")) CreateResource HelmExecutor
                    (releaseId fixture :| []) (contentDigest native) [] Idempotent
              prepared <- adapterPrepare adapter operation >>= either (assertFailure . show) pure
              applied <- adapterExecute adapter operation prepared
              applied @?= AdapterEffectCompleted
              verified <- adapterVerify adapter operation prepared
              case verified of
                Right _ -> pure ()
                Left reason -> assertFailure (show reason)
              let changedValuesPath = temporary </> "updated-values.yaml"
              BS.writeFile changedValuesPath "token: upgraded\n"
              changedValues <- BS.readFile changedValuesPath
              let changedInput = input
                    { packagedValues = changedValuesPath
                    , packagedValuesDigest = contentDigest changedValues
                    }
              changedCapture <- capturePackagedRelease changedInput >>= either (assertFailure . show) pure
              (changedRelease, changedNative) <- either (assertFailure . show) pure
                (compileRenderedRelease changedCapture)
              let changedRuntime = runtime
                    { helmDeclarations = Map.singleton (releaseId fixture) changedRelease }
                  changedAdapter = mkHelmAdapter
                    (Map.singleton (releaseId fixture) (changedRelease, changedNative))
                    (helmRuntimeOps changedRuntime)
                  update = operation
                    { plannedOperationId = ok (mkOperationId "op-helm-runtime-update")
                    , plannedAction = UpdateResource
                    , plannedInputDigest = contentDigest changedNative
                    }
              updatePrepared <- adapterPrepare changedAdapter update >>= either (assertFailure . show) pure
              adapterPreflight changedAdapter update updatePrepared >>= either (assertFailure . show) pure
              adapterExecute changedAdapter update updatePrepared >>= (@?= AdapterEffectCompleted)
              _ <- adapterVerify changedAdapter update updatePrepared >>= either (assertFailure . show) pure
              (readCode, actual, readError) <- kubectl ["get", "configmap", "inventory-review-static-fixture",
                "--namespace", namespace, "-o", "jsonpath={.data.token}"]
              assertEqual readError ExitSuccess readCode
              actual @?= "upgraded") `finally` cleanup
  ]
  where
    ok :: (Show e) => Either e a -> a
    ok = either (error . show) id
    scope = ok (mkScopeId Platform "observability")
    cluster = mintResourceId scope (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
    name = ok . mkName
    secretObjects :: [(SourceLocation, Value)]
    secretObjects = [(SourceLocation "fixture:grafana-admin" "Secret", object
      ["apiVersion" .= ("v1" :: T.Text), "kind" .= ("Secret" :: T.Text),
       "metadata" .= object ["name" .= ("grafana-admin" :: T.Text),
         "namespace" .= ("monitoring" :: T.Text)],
       "stringData" .= object ["admin-user" .= ("admin" :: T.Text),
         "admin-password" .= ("fixture-canary" :: T.Text)]])]
    rendered = BC.pack "apiVersion: v1\nkind: Service\nmetadata:\n  name: metrics\n---\napiVersion: batch/v1\nkind: Job\nmetadata:\n  name: metrics-hook\n  annotations:\n    helm.sh/hook: pre-install\n"
    crds = BC.pack "apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: metrics.example.com\n"
    fixture = ObservabilityReleaseInput
      { releaseId = mintResourceId scope (ok (mkLogicalKey "metrics")) (name "release")
      , releaseOwner = scope
      , releaseCluster = cluster
      , releaseNamespace = name "monitoring"
      , releaseName = name "metrics"
      , releaseChartPath = "metrics-1.0.tgz"
      , releaseChartBytes = BC.pack "pinned chart"
      , releaseValuesPath = "metrics-values.yaml"
      , releaseValuesBytes = BC.pack "pinned values"
      , releaseRenderedBytes = rendered
      , releaseCrdsBytes = Just crds
      , releaseKubeVersion = "v1.32.0"
      , releaseHelmVersion = "v4.2.4"
      , releaseApiVersions = []
      , releaseDependencies = []
      }
