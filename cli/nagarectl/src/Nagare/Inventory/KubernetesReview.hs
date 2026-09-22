-- | Reconstruct Kubernetes adapter inputs only from immutable private review
-- members. Apply and resume do not reopen packaged manifests or render again.
module Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview) where

import Data.Aeson (eitherDecodeStrict)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Plan
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope)

kubernetesSpecsFromReview
  :: ReviewBundle
  -> Either Text (Map ResourceId (ManagedResource, ByteString))
kubernetesSpecsFromReview bundle = do
  scopes <- traverse (first (T.pack . show) . decodeScope) (Map.elems (reviewBundleScopes bundle))
  let declarationsById = Map.fromList
        [ (resource ^. #identity, resource)
        | scope <- scopes
        , resourceBundle <- scopeBundles scope
        , Managed resource <- declarations resourceBundle
        ]
      context = reviewContextBinding (reviewBundleDocument bundle) ^. #identity
      operations =
        [ operation
        | operation <- reviewOperations (reviewBundleDocument bundle)
        , plannedExecutor (reviewPlannedOperation operation) == KubernetesExecutor
        ]
  entries <- traverse (reconstruct context declarationsById) operations
  unless (length entries == Map.size (Map.fromList entries)) (Left "review has duplicate Kubernetes resource operations")
  pure (Map.fromList entries)
  where
    reconstruct context declarationsById reviewOperation = do
      let operation = reviewPlannedOperation reviewOperation
      resource <- case NE.toList (plannedResources operation) of
        [single] -> Right single
        _ -> Left "reviewed Kubernetes operation does not name exactly one resource"
      declaration <- maybe (Left "reviewed Kubernetes resource is absent from desired scopes") Right
        (Map.lookup resource declarationsById)
      memberDigest <- maybe (Left "reviewed Kubernetes operation has no private native member") Right
        (reviewNativeDigest reviewOperation)
      bytes <- maybe (Left "reviewed Kubernetes native member is missing") Right
        (Map.lookup memberDigest (reviewBundleNative bundle))
      unless (contentDigest bytes == memberDigest) (Left "reviewed Kubernetes native member digest differs")
      mutation <- first T.pack (eitherDecodeStrict bytes)
      unless
        ( mutationOperation mutation == plannedOperationId operation
            && mutationResource mutation == resource
            && mutationAction mutation == plannedAction operation
            && mutationInputDigest mutation == plannedInputDigest operation
            && mutationAddress mutation == address declaration
        ) (Left "reviewed Kubernetes mutation differs from its operation")
      native <- unstampNative context resource (mutationNativeDigest mutation) (mutationNativeJson mutation)
      value <- first T.pack (eitherDecodeStrict native)
      cluster <- case address declaration of
        Kubernetes target _ _ _ _ -> Right target
        _ -> Left "reviewed Kubernetes declaration has no Kubernetes address"
      (recompiled, rebound) <- first (T.pack . show) $ bindKubernetesObject
        KubernetesInput
          { resourceId = resource
          , ownerScope = declaration ^. #owner
          , clusterId = cluster
          , inputObject = value
          , objectDigest = mutationNativeDigest mutation
          , lifecyclePolicy = declaration ^. #lifecycle
          , inputDataPolicy = declaration ^. #dataPolicy
          , inputSensitivity = declaration ^. #sensitivity
          , sourceLocation = declaration ^. #source
          }
      unless (address recompiled == address declaration && spec recompiled == spec declaration && rebound == native)
        (Left "reviewed Kubernetes native object differs from its typed declaration")
      pure (resource, (declaration, native))
