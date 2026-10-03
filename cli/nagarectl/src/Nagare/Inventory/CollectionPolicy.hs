-- | The narrow retained-resource deletion contract proved by the current
-- native executor. Planning, read-only screening, and preparation must agree.
module Nagare.Inventory.CollectionPolicy
  ( supportsRetainedCollection
  , requiresControllerCollection
  )
where

import Data.Generics.Labels ()
import Nagare.Dsl.Prelude
import Nagare.Inventory.CloudCollection (cloudCollectionEligible)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

supportsRetainedCollection :: ManagedResource -> Bool
supportsRetainedCollection declaration =
  declaration ^. #lifecycle == DeleteWhenUnreferenced
    && declaration ^. #dataPolicy == Stateless
    && case (declaration ^. #executor, declaration ^. #address) of
      (PulumiExecutor, _) -> cloudCollectionEligible declaration
      (CdnExecutor, DnsRecord {}) -> scopeKind (declaration ^. #owner) `elem` [Application, Standalone]
      (CdnExecutor, CloudflareDnsRecord {}) -> scopeKind (declaration ^. #owner) `elem` [Application, Standalone]
      (KubernetesExecutor, Kubernetes _ "" kind (Just _) _) ->
        nameText kind `elem` ["configmap", "service", "persistentvolumeclaim"]
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
