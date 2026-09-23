module InventoryObservabilitySpec (inventoryObservabilityTests) where

import Data.ByteString.Char8 qualified as BC
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.IORef
import Data.Text qualified as T
import Control.Exception (finally)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Observability
import Nagare.Inventory.Adapters.Helm
import Nagare.Inventory.Adapters.HelmRuntime
import Nagare.Inventory.Adapter
import Nagare.Inventory.Bootstrap (compilePinnedBootstrap)
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
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
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)

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
      compiled <- compilePinnedObservability foundationOwner (pinnedObservabilityInputs cluster "../.." "v1.32.0")
      (scopes, native) <- either (assertFailure . show) pure compiled
      length scopes @?= 5
      assertBool "chart CRD direct members missing" (Map.size native > 5)
      let foundation = FoundationInput foundationOwner cluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" (map scopeId scopes)
          binding = ContextBinding (ok (mkContextId "helm-fixture")) (name "project")
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      base <- compilePinnedBootstrap snapshot foundation Nothing "../.." >>= either (assertFailure . show) pure
      let (candidate, _) = base
      case composeInventory snapshot (candidateChanges candidate <> (case scopes of
          firstScope : rest -> ReplaceScope firstScope :| map ReplaceScope rest
          [] -> error "five observability scopes disappeared")) of
        Left errors -> assertFailure (show errors)
        Right _ -> pure ()
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
  , testCase "disposable Helm create is gated by reviewed native bytes" $ do
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
                Left reason -> assertFailure (show reason)) `finally` cleanup
  ]
  where
    ok :: (Show e) => Either e a -> a
    ok = either (error . show) id
    scope = ok (mkScopeId Platform "observability")
    cluster = mintResourceId scope (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
    name = ok . mkName
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
