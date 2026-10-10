-- | Readiness of observed Kubernetes objects: whether a live object's
-- controller reports the reviewed generation healthy, or a Job terminally
-- failed. Internal implementation behind
-- "Nagare.Inventory.Adapters.KubernetesRuntime", which re-exports it.
module Nagare.Inventory.Adapters.KubernetesReadiness
  ( observedReady
  , readinessForAddress
  , jobCompleted
  , jobFailed
  , crdEstablished
  , certificateReady
  , knativeReady
  , domainMappingReady
  , httpDowngraded
  , hasCondition
  , deploymentAvailable
  , statefulSetReady
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Resource.Types

-- A failed controller condition is a health finding, not a failed read of
-- the object's configuration or ownership. Execution still refuses to verify
-- a KubernetesNotReady state as completed.
observedReady :: Value -> Bool
observedReady (Object root) = case (KM.lookup "apiVersion" root, KM.lookup "kind" root) of
  (_, Just (String "Job")) -> jobCompleted (Object root)
  (_, Just (String "CustomResourceDefinition")) -> crdEstablished (Object root)
  (_, Just (String "Certificate")) -> certificateReady (Object root)
  (_, Just (String "ClusterIssuer")) -> certificateReady (Object root)
  (Just (String "serving.knative.dev/v1"), Just (String "Service")) -> knativeReady (Object root)
  (Just (String "serving.knative.dev/v1beta1"), Just (String "DomainMapping")) -> domainMappingReady (Object root)
  (_, Just (String "Deployment")) -> deploymentAvailable (Object root)
  (Just (String "apps/v1"), Just (String "StatefulSet")) -> statefulSetReady (Object root)
  _ -> True
observedReady _ = True

jobCompleted :: Value -> Bool
jobCompleted = hasCondition "Complete"

jobFailed :: Value -> Bool
jobFailed (Object root)
  | KM.lookup "kind" root == Just (String "Job") =
      hasCondition "Failed" (Object root)
jobFailed _ = False

crdEstablished :: Value -> Bool
crdEstablished = hasCondition "Established"

certificateReady :: Value -> Bool
certificateReady = hasCondition "Ready"

-- | F69, RES-4 §2 (E4) and U9: a Knative Service or DomainMapping is ready
-- only once its controller has observed this generation and reports
-- Ready=True. Until then, a Ready=True belongs to the previous generation.
knativeReady :: Value -> Bool
knativeReady value = generationObserved value && hasCondition "Ready" value

generationObserved :: Value -> Bool
generationObserved (Object root) = case (KM.lookup "metadata" root, KM.lookup "status" root) of
  (Just (Object metadata), Just (Object status)) -> case (KM.lookup "generation" metadata, KM.lookup "observedGeneration" status) of
    (Just (Number generation), Just (Number observed)) -> generation == observed
    _ -> False
  _ -> False
generationObserved _ = False

hasCondition :: Text -> Value -> Bool
hasCondition conditionType (Object root) = case KM.lookup "status" root of
  Just (Object status) -> case KM.lookup "conditions" status of
    Just (Array conditions) -> any completed (foldr (:) [] conditions)
    _ -> False
  _ -> False
  where
    completed (Object condition) =
      KM.lookup "type" condition == Just (String conditionType)
        && KM.lookup "status" condition == Just (String "True")
    completed _ = False
hasCondition _ _ = False

-- | EP-183 M1: a DomainMapping is ready only once it serves the TLS it was
-- given. With external-domain TLS on and the route's certificate not Ready,
-- Knative 1.22's default @http-protocol: Enabled@ serves the host over plain
-- HTTP meanwhile and reports @CertificateProvisioned=True/HTTPDowngrade@, so
-- @Ready@ is True. That downgrade is not readiness. TLS off
-- (@TLSNotEnabled@) is the context's choice and stays ready.
domainMappingReady :: Value -> Bool
domainMappingReady value = knativeReady value && not (httpDowngraded value)

-- | The route is served over HTTP because its certificate is not Ready.
httpDowngraded :: Value -> Bool
httpDowngraded (Object root) = case KM.lookup "status" root of
  Just (Object status) -> case KM.lookup "conditions" status of
    Just (Array conditions) -> any downgrade (foldr (:) [] conditions)
    _ -> False
  _ -> False
  where
    downgrade (Object condition) =
      KM.lookup "type" condition == Just (String "CertificateProvisioned")
        && KM.lookup "reason" condition == Just (String "HTTPDowngrade")
    downgrade _ = False
httpDowngraded _ = False

-- | F70, RES-4 §2 (E5) and U9: a Deployment is ready when its rollout is
-- complete, as `kubectl rollout status` judges it. The controller has observed
-- this generation, every requested replica is updated, no old replica remains,
-- and every updated replica is available. Available=True is not readiness:
-- during a bad-image update of one replica the old ReplicaSet keeps it, and
-- ProgressDeadlineExceeded is not terminal.
deploymentAvailable :: Value -> Bool
deploymentAvailable (Object root) = fromMaybe False $ do
  Object metadata <- KM.lookup "metadata" root
  Object status <- KM.lookup "status" root
  generation <- number (KM.lookup "generation" metadata)
  observed <- number (KM.lookup "observedGeneration" status)
  let requested = fromMaybe 1 (number (KM.lookup "spec" root >>= \case Object spec -> KM.lookup "replicas" spec; _ -> Nothing))
      count key = fromMaybe 0 (number (KM.lookup key status))
      updated = count "updatedReplicas"
  pure (observed == generation && updated == requested && count "replicas" == updated && count "availableReplicas" == updated)
  where
    number = \case
      Just (Number n) -> Just n
      _ -> Nothing
deploymentAvailable _ = False

-- StatefulSets do not expose the Deployment Available condition. A matching
-- observed generation and the requested number of ready, updated Pods is the
-- bounded health signal; it does not assert application-level or data health.
statefulSetReady :: Value -> Bool
statefulSetReady (Object root) = case (KM.lookup "metadata" root, KM.lookup "spec" root, KM.lookup "status" root) of
  (Just (Object metadata), Just (Object specValue), Just (Object status)) ->
    let requested = case KM.lookup "replicas" specValue of
          Just (Number replicas) -> Just replicas
          Nothing -> Just 1
          _ -> Nothing
        ready = case KM.lookup "readyReplicas" status of
          Just (Number replicas) -> Just replicas
          Nothing -> Just 0
          _ -> Nothing
        updated = case KM.lookup "updatedReplicas" status of
          Just (Number replicas) -> Just replicas
          Nothing -> Just 0
          _ -> Nothing
     in case ( KM.lookup "generation" metadata
             , KM.lookup "observedGeneration" status
             , requested
             , ready
             , updated
             ) of
          ( Just (Number generation)
            , Just (Number observed)
            , Just desired
            , Just actualReady
            , Just actualUpdated
            ) ->
              generation == observed && actualReady >= desired && actualUpdated >= desired
          _ -> False
  _ -> False
statefulSetReady _ = False

readinessForAddress :: ProviderAddress -> Value -> Maybe Bool
readinessForAddress address value = case address of
  Kubernetes _ "batch" kind _ _ | nameText kind == "job" -> Just (jobCompleted value)
  Kubernetes _ "apiextensions.k8s.io" kind _ _ | nameText kind == "customresourcedefinition" -> Just (crdEstablished value)
  Kubernetes _ "cert-manager.io" kind _ _ | nameText kind `elem` ["certificate", "clusterissuer"] -> Just (certificateReady value)
  Kubernetes _ "serving.knative.dev" kind _ _ | nameText kind == "service" -> Just (knativeReady value)
  Kubernetes _ "serving.knative.dev" kind _ _ | nameText kind == "domainmapping" -> Just (domainMappingReady value)
  Kubernetes _ "apps" kind _ _ | nameText kind == "deployment" -> Just (deploymentAvailable value)
  Kubernetes _ "apps" kind _ _ | nameText kind == "statefulset" -> Just (statefulSetReady value)
  _ -> Nothing
