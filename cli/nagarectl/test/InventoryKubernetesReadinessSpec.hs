-- | EP-180: readiness of observed Kubernetes objects, per the validated API
-- semantics of RES-4 (docs/research/kubernetes-api-semantics-for-inventory-proofs.md §2).
module InventoryKubernetesReadinessSpec (inventoryKubernetesReadinessTests) where

import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesRuntime (deploymentAvailable, knativeReady)
import Test.Tasty
import Test.Tasty.HUnit

inventoryKubernetesReadinessTests :: TestTree
inventoryKubernetesReadinessTests =
  testGroup
    "Kubernetes readiness (RES-4)"
    [ testCase "a Deployment is ready only when its rollout is complete, as kubectl rollout status judges it (F70)" $ do
        -- RES-4 §2 (E5): during a bad-image update of one replica the old
        -- ReplicaSet keeps Available=True, and the controller has observed the
        -- new generation, but the new pod never becomes available.
        let midRollout = deployment 2 2 1 [("Available", "True"), ("Progressing", "True")] (2, 1, 1)
        assertBool "a mid-rollout Deployment read ready" (not (deploymentAvailable midRollout))
        -- ProgressDeadlineExceeded is not terminal: the controller keeps trying.
        let deadline = deployment 2 2 1 [("Available", "True"), ("Progressing", "False")] (2, 1, 1)
        assertBool "a Deployment past its progress deadline read ready" (not (deploymentAvailable deadline))
        let rolledOut = deployment 2 2 1 [("Available", "True"), ("Progressing", "True")] (1, 1, 1)
        assertBool "a rolled-out Deployment read not ready" (deploymentAvailable rolledOut)
        -- A status from the previous generation proves nothing about this one.
        let behind = deployment 3 2 1 [("Available", "True"), ("Progressing", "True")] (1, 1, 1)
        assertBool "a Deployment one generation behind read ready" (not (deploymentAvailable behind))
        let scaled = deployment 2 2 3 [("Available", "True"), ("Progressing", "True")] (3, 3, 2)
        assertBool "a Deployment with an unavailable updated replica read ready" (not (deploymentAvailable scaled))
    , testCase "a Knative Service or DomainMapping is ready only at the observed generation (F69)" $
        -- RES-4 §2 (E4): after a spec write the controller keeps the previous
        -- generation's Ready=True until it observes the new spec.
        forM_ [("serving.knative.dev/v1", "Service"), ("serving.knative.dev/v1beta1", "DomainMapping")] $ \(api, kind) -> do
          assertBool (T.unpack kind <> " one generation behind read ready") (not (knativeReady (knative api kind 3 2 "True")))
          assertBool (T.unpack kind <> " at its generation read not ready") (knativeReady (knative api kind 3 3 "True"))
          assertBool (T.unpack kind <> " not Ready read ready") (not (knativeReady (knative api kind 3 3 "False")))
    ]

-- | A Deployment at a generation, observed at a generation, with a requested
-- replica count, conditions, and (status.replicas, updatedReplicas,
-- availableReplicas).
deployment :: Int -> Int -> Int -> [(Text, Text)] -> (Int, Int, Int) -> Value
deployment generation observed replicas conditions (total, updated, available) =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("Deployment" :: Text)
    , "metadata" .= object ["generation" .= generation]
    , "spec" .= object ["replicas" .= replicas]
    , "status"
        .= object
          [ "observedGeneration" .= observed
          , "replicas" .= total
          , "updatedReplicas" .= updated
          , "availableReplicas" .= available
          , "conditions" .= [object ["type" .= kind, "status" .= state] | (kind, state) <- conditions]
          ]
    ]

-- | A Knative object at a generation, observed at a generation, with its
-- Ready condition.
knative :: Text -> Text -> Int -> Int -> Text -> Value
knative api kind generation observed ready =
  object
    [ "apiVersion" .= api
    , "kind" .= kind
    , "metadata" .= object ["generation" .= generation]
    , "status" .= object ["observedGeneration" .= observed, "conditions" .= [object ["type" .= ("Ready" :: Text), "status" .= ready]]]
    ]
