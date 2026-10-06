-- | Readiness of observed Kubernetes objects: whether a live object's
-- controller reports the reviewed generation healthy, or a Job terminally
-- failed. Internal implementation behind
-- "Nagare.Inventory.Adapters.KubernetesRuntime", which re-exports it.
module Nagare.Inventory.Adapters.KubernetesReadiness
  ( observedReady
  , jobCompleted
  , jobFailed
  , crdEstablished
  , certificateReady
  , knativeReady
  , hasCondition
  , deploymentAvailable
  , statefulSetReady
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Nagare.Dsl.Prelude hiding ((.=))

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
  (Just (String "serving.knative.dev/v1beta1"), Just (String "DomainMapping")) -> knativeReady (Object root)
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

knativeReady :: Value -> Bool
knativeReady = hasCondition "Ready"

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

deploymentAvailable :: Value -> Bool
deploymentAvailable value@(Object root) =
  hasCondition "Available" value
    && case (KM.lookup "status" root, KM.lookup "metadata" root) of
      (Just (Object status), Just (Object metadata)) ->
        case (KM.lookup "observedGeneration" status, KM.lookup "generation" metadata) of
          (Just observed, Just desired) -> observed == desired
          _ -> False
      _ -> False
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
