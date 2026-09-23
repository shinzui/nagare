module InventoryObservabilitySpec (inventoryObservabilityTests) where

import Data.ByteString.Char8 qualified as BC
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Observability
import Nagare.Inventory.Bootstrap (compilePinnedBootstrap)
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

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
      , releaseApiVersions = []
      , releaseDependencies = []
      }
