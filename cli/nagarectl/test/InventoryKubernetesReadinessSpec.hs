-- | EP-180: readiness of observed Kubernetes objects, per the validated API
-- semantics of RES-4 (docs/research/kubernetes-api-semantics-for-inventory-proofs.md §2).
module InventoryKubernetesReadinessSpec (inventoryKubernetesReadinessTests) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterExecution (..), EffectOutcome (..), OperationAction (CreateResource, UpdateResource), effectIdentity)
import Nagare.Inventory.Adapters.Kubernetes (KubernetesAdapterOps (..), KubernetesMutation (..), KubernetesState (..), kubernetesObserve)
import Nagare.Inventory.Adapters.KubernetesRuntime (deploymentAvailable, domainMappingReady, knativeReady, readinessForAddress, waitForReadiness)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), runKubectlWith, withKubectlInterpreter)
import Nagare.Resource.Types (ProviderAddress (..), mkContextId, mkName)
import Nagare.Test.Model.Fixtures (bindMember, extraId, ok)
import Nagare.Test.World.Adversary (newAdversary)
import Nagare.Test.World.ApiServer (emptyServer, settleControllers)
import Nagare.Test.World.Cluster (clusterOps, newCluster)
import Nagare.Test.World.Cluster qualified as Cluster
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit
import WorkloadControlsInventorySpec (workloadControlsInventoryTests)

inventoryKubernetesReadinessTests :: TestTree
inventoryKubernetesReadinessTests =
  testGroup
    "Kubernetes readiness (RES-4)"
    [ workloadControlsInventoryTests
    , testCase "Knative's own Certificate is awaited, because readiness holds it to Ready and its controller answers a moment later" $ do
        asked <- newIORef []
        let answer request = (Right (ExitSuccess, "", "")) <$ modifyIORef' asked (<> [request ^. #arguments])
            config = withKubectlInterpreter (runKubectlWith answer) (KubernetesRuntimeConfig (ok (mkContextId "context-1")) "readiness" (pure (Right ())))
            address = Kubernetes extraId "networking.internal.knative.dev" (ok (mkName "certificate")) (Just (ok (mkName "knative-serving"))) (ok (mkName "routing-serving-certs"))
        waitForReadiness config address >>= \case
          AdapterEffectCompleted -> pure ()
          _ -> assertFailure "the wait did not complete"
        calls <- readIORef asked
        case calls of
          [("wait" : "--for=condition=ready" : target : _)] -> target @?= "certificates.networking.internal.knative.dev/routing-serving-certs"
          other -> assertFailure ("expected one kubectl wait, got " <> show other)
    , testCase "a Job's readiness wait ends on the Job's own verdict: a running Job outlasts five minutes, one that never starts stops there, a failure stops at once, and so does a Job that cannot be read" $ do
        let address = Kubernetes extraId "batch" (ok (mkName "job")) (Just (ok (mkName "personal"))) (ok (mkName "migrate-hook"))
            notYet = Right (ExitFailure 1, "", "error: timed out waiting for the condition on jobs/migrate-hook")
            completeWaits = filter (elem "--for=condition=complete")
            job status = Right (ExitSuccess, "{\"status\":" <> status <> "}", "")
            waited answerFor = do
              asked <- newIORef []
              let answer request = do
                    earlier <- atomicModifyIORef' asked (\calls -> (calls <> [request ^. #arguments], calls))
                    pure (answerFor (length (completeWaits earlier)) (request ^. #arguments))
                  config = withKubectlInterpreter (runKubectlWith answer) (KubernetesRuntimeConfig (ok (mkContextId "context-1")) "readiness" (pure (Right ())))
              (,) <$> waitForReadiness config address <*> readIORef asked
            answering status done n arguments
              | take 1 arguments == ["get"] = job status
              | n >= done && "--for=condition=complete" `elem` arguments = Right (ExitSuccess, "", "")
              | otherwise = notYet
        -- A migration that takes ten minutes with its pod running: sixty unmet ten-second rounds, then Complete.
        (slow, slowCalls) <- waited (answering "{\"active\":1,\"ready\":1}" 60)
        slow @?= AdapterEffectCompleted
        length (completeWaits slowCalls) @?= 61
        -- A Job whose pod never becomes ready stops after five minutes of rounds.
        (stuck, stuckCalls) <- waited (answering "{\"active\":1}" 60)
        stuck @?= AdapterEffectAmbiguous "Kubernetes Job did not prove readiness; reobserve before retry"
        length (completeWaits stuckCalls) @?= 30
        (failed, failedCalls) <- waited (\_ arguments -> if "--for=condition=failed" `elem` arguments then Right (ExitSuccess, "", "") else notYet)
        failed @?= AdapterEffectAmbiguous "Kubernetes Job failed; reobserve before retry"
        map (take 2) failedCalls @?= [["wait", "--for=condition=complete"], ["wait", "--for=condition=failed"]]
        (gone, goneCalls) <- waited (\_ _ -> Right (ExitFailure 1, "", "Error from server (NotFound): jobs.batch \"migrate-hook\" not found"))
        gone @?= AdapterEffectAmbiguous "Kubernetes Job did not prove readiness; reobserve before retry"
        length goneCalls @?= 1
    , testCase "a Deployment is ready only when its rollout is complete, as kubectl rollout status judges it (F70)" $ do
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
    , testCase "a DomainMapping's HTTP downgrade is not readiness; TLS off and a Ready certificate are (EP-183 M1)" $ do
        let mapping :: Maybe Text -> Value
            mapping reason' = case knative "serving.knative.dev/v1beta1" "DomainMapping" 1 1 "True" of
              Object root -> Object (KM.insert "status" (object ["observedGeneration" .= (1 :: Int), "conditions" .= [object ["type" .= ("Ready" :: Text), "status" .= ("True" :: Text)], object (["type" .= ("CertificateProvisioned" :: Text), "status" .= ("True" :: Text)] <> ["reason" .= r | Just r <- [reason']])]]) root)
              other -> other
        assertBool "an HTTP downgrade read ready" (not (domainMappingReady (mapping (Just "HTTPDowngrade"))))
        assertBool "TLS off read not ready" (domainMappingReady (mapping (Just "TLSNotEnabled")))
        assertBool "a Ready certificate read not ready" (domainMappingReady (mapping Nothing))
        readinessForAddress (Kubernetes extraId "serving.knative.dev" (ok (mkName "domainmapping")) Nothing (ok (mkName "a.example"))) (mapping (Just "HTTPDowngrade")) @?= Just False
    , testCase "a DomainMapping served over HTTP while its certificate is pending is not ready, and its create does not complete (EP-183 M1)" $ do
        -- Knative 1.22's domainmapping reconciler, with the default
        -- http-protocol Enabled: a certificate that is not Ready downgrades the
        -- host to HTTP and reports CertificateProvisioned=True/HTTPDowngrade,
        -- so Ready=True. A deploy that trusts Ready alone reports a protected
        -- route as served while it answers only plain HTTP.
        let cases =
              [ ("external-domain TLS off", False, Set.empty, mappingValue, True)
              , ("certificate Ready", True, Set.empty, mappingValue, True)
              , ("certificate pending", True, Set.singleton mappingHost, mappingValue, False)
              , -- EP-246: a carried route's opt-out needs no certificate.
                ("certificate pending, route opted out", True, Set.singleton mappingHost, optedOutMapping, True)
              ]
        forM_ cases $ \(label, tls, pending, value, servesTls) -> do
          cluster <- newCluster (emptyServer & #externalDomainTls .~ tls & #unissued .~ pending) =<< newAdversary []
          let context = ok (mkContextId "context-1")
              (managed, bytes) = bindMember extraId value
              ops = fst (clusterOps context cluster (Map.singleton extraId (managed, bytes)))
              digest = contentDigest bytes
          before <- kubernetesObserve ops extraId
          result <- kubernetesMutateConditional ops (KubernetesMutation 1 (ok (mkOperationId "op-mapping")) digest CreateResource extraId (managed ^. #address) (TE.decodeUtf8 bytes) digest before Nothing Nothing)
          after <- kubernetesObserve ops extraId
          case (servesTls, snd (effectIdentity result), after) of
            (True, OutcomeCompleted, KubernetesPresent {}) -> pure ()
            (False, OutcomeAmbiguous _, KubernetesNotReady {}) -> pure ()
            other -> assertFailure (label <> ": the create ended as " <> show other)
          -- Once the certificate is issued the same object is ready: a resume
          -- verifies it without another write.
          unless servesTls $ do
            Cluster.modifyServer cluster (settleControllers . (#unissued .~ Set.empty))
            kubernetesObserve ops extraId >>= \case
              KubernetesPresent {} -> pure ()
              other -> assertFailure (label <> ": after the certificate was issued: " <> show other)
    , testCase "a route stuck on a pending certificate takes its TLS opt-out in place and is ready (EP-246)" $ do
        cluster <- newCluster (emptyServer & #externalDomainTls .~ True & #unissued .~ Set.singleton mappingHost) =<< newAdversary []
        let context = ok (mkContextId "context-1")
            (managed, bytes) = bindMember extraId mappingValue
            (_, optedBytes) = bindMember extraId optedOutMapping
            createOps = fst (clusterOps context cluster (Map.singleton extraId (managed, bytes)))
            updateOps = fst (clusterOps context cluster (Map.singleton extraId (managed, optedBytes)))
        absent <- kubernetesObserve createOps extraId
        _ <- kubernetesMutateConditional createOps (KubernetesMutation 1 (ok (mkOperationId "op-mapping")) (contentDigest bytes) CreateResource extraId (managed ^. #address) (TE.decodeUtf8 bytes) (contentDigest bytes) absent Nothing Nothing)
        (stuck, stamp) <- kubernetesObserveStamped updateOps extraId
        case stuck of
          KubernetesNotReady {} -> pure ()
          other -> assertFailure ("the downgraded route was " <> show other)
        result <- kubernetesMutateConditional updateOps (KubernetesMutation 1 (ok (mkOperationId "op-opt-out")) (contentDigest optedBytes) UpdateResource extraId (managed ^. #address) (TE.decodeUtf8 optedBytes) (contentDigest optedBytes) stuck Nothing stamp)
        snd (effectIdentity result) @?= OutcomeCompleted
        kubernetesObserve updateOps extraId >>= \case
          KubernetesPresent {} -> pure ()
          other -> assertFailure ("the opted-out route was " <> show other)
    ]

mappingHost :: Text
mappingHost = "scenario-a.example.test"

-- | The DomainMapping a protected route renders: the host is its name.
mappingValue :: Value
mappingValue =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
    , "kind" .= ("DomainMapping" :: Text)
    , "metadata" .= object ["name" .= mappingHost, "namespace" .= ("personal" :: Text)]
    , "spec" .= object ["ref" .= object ["name" .= ("web" :: Text), "kind" .= ("Service" :: Text), "apiVersion" .= ("serving.knative.dev/v1" :: Text)]]
    ]

-- | The same route with Knative's per-route TLS opt-out, as a carried route declares it.
optedOutMapping :: Value
optedOutMapping = case mappingValue of
  Object root
    | Just (Object metadata) <- KM.lookup "metadata" root ->
        Object (KM.insert "metadata" (Object (KM.insert "annotations" (object ["networking.knative.dev/disable-external-domain-tls" .= ("true" :: Text)]) metadata)) root)
  other -> other

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
