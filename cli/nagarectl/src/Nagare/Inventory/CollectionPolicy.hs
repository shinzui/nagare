-- | The narrow retained-resource deletion contract proved by the current
-- native executor. Planning, read-only screening, and preparation must agree.
module Nagare.Inventory.CollectionPolicy
  ( supportsRetainedCollection
  , requiresControllerCollection
  , retainedConsumerInert
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.CloudCollection (cloudCollectionEligible)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

-- | A retained member that can no longer use what it names and can never be collected itself, so it
-- must not hold it: a revoked grant admits nobody, and a release history is only a record that orders
-- after its workload. Counting them would keep a retired site's route forever (F140).
retainedConsumerInert :: ManagedResource -> Bool
retainedConsumerInert declaration = case declaration ^. #spec of
  AccessGrantSpec _ granted -> not granted
  _ -> any (`T.isSuffixOf` resourceIdText (declaration ^. #identity)) ["/release-history/configmap", "/release-history"]

supportsRetainedCollection :: ManagedResource -> Bool
supportsRetainedCollection declaration =
  declaration ^. #lifecycle == DeleteWhenUnreferenced
    && declaration ^. #dataPolicy == Stateless
    && case (declaration ^. #executor, declaration ^. #address) of
      (PulumiExecutor, _) -> cloudCollectionEligible declaration
      (CdnExecutor, DnsRecord {}) -> scopeKind (declaration ^. #owner) `elem` [Application, Standalone]
      (CdnExecutor, CloudflareDnsRecord {}) -> scopeKind (declaration ^. #owner) `elem` [Application, Standalone]
      (KubernetesExecutor, Kubernetes _ "" kind (Just _) _) ->
        nameText kind `elem` ["configmap", "service", "persistentvolumeclaim", "serviceaccount"]
      -- Database and broker StatefulSets declare no durable data themselves:
      -- their PVC and credential Secret are separate retained members.
      (KubernetesExecutor, Kubernetes _ "apps" kind (Just _) _) ->
        nameText kind == "statefulset"
      (KubernetesExecutor, Kubernetes _ "rbac.authorization.k8s.io" kind (Just _) _) ->
        nameText kind `elem` ["role", "rolebinding"]
      (KubernetesExecutor, Kubernetes _ "batch" kind (Just _) _) ->
        nameText kind `elem` ["cronjob", "job"]
      (KubernetesExecutor, Kubernetes _ "serving.knative.dev" kind (Just _) _) ->
        nameText kind `elem` ["domainmapping", "service"]
      _ -> False

-- | Knative does not block orphaning a DomainMapping's controller children, so
-- an Orphan DELETE silently leaves its KIngress programming the shared gateway
-- (F34). Such a parent is collected only with its exclusive descendants.
requiresControllerCollection :: ManagedResource -> Bool
requiresControllerCollection declaration =
  case (declaration ^. #executor, declaration ^. #address) of
    (KubernetesExecutor, Kubernetes _ "serving.knative.dev" kind (Just _) _) -> nameText kind == "domainmapping"
    _ -> False
