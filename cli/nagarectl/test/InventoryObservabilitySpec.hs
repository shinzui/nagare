module InventoryObservabilitySpec (inventoryObservabilityTests) where

import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Observability
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
        HelmRelease members _ -> length members @?= 3
        _ -> assertFailure "missing Helm release spec"
  , testCase "same Kubernetes address in render and CRDs refuses" $ do
      let input = fixture {releaseCrdsBytes = Just rendered}
      case compileRenderedRelease input of
        Left _ -> pure ()
        Right _ -> assertFailure "duplicate rendered member was accepted"
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
