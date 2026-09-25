-- | The narrow retained-resource deletion contract proved by the current
-- native executor. Planning, read-only screening, and preparation must agree.
module Nagare.Inventory.CollectionPolicy
  ( supportsRetainedCollection
  ) where

import Data.Generics.Labels ()
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

supportsRetainedCollection :: ManagedResource -> Bool
supportsRetainedCollection declaration =
  declaration ^. #executor == KubernetesExecutor
    && declaration ^. #lifecycle == DeleteWhenUnreferenced
    && declaration ^. #dataPolicy == Stateless
    && case declaration ^. #address of
      Kubernetes _ "" kind (Just _) _ ->
        nameText kind `elem` ["configmap", "service", "persistentvolumeclaim"]
      Kubernetes _ "batch" kind (Just _) _ -> nameText kind == "cronjob"
      Kubernetes _ "serving.knative.dev" kind (Just _) _ ->
        nameText kind `elem` ["domainmapping", "service"]
      _ -> False
