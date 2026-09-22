-- | Bind the pure database bundle to exact canonical Kubernetes members.
-- The private bytes returned here are the only native inputs suitable for a
-- reviewed Kubernetes adapter; no YAML is rendered again at apply time.
module Nagare.Inventory.Database (compileDatabaseNative) where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Database
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

compileDatabaseNative
  :: DatabaseDirectInput
  -> Either (NonEmpty InventoryError) (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileDatabaseNative input = do
  (bundle, native) <- compileDatabaseDirect digestOf input
  bound <- traverse (bindOne bundle) native
  pure (bundle, Map.fromList bound)
  where
    digestOf value = contentDigest <$> canonicalValue value
    bindOne bundle (resource, value) = do
      declaration <- maybe (Left (single (invalid "database native object has no declaration"))) Right
        (lookup resource [(r ^. #identity, r) | Managed r <- declarations bundle])
      digest <- first (single . invalid) (digestOf value)
      (recompiled, bytes) <- first single $ bindKubernetesObject
        KubernetesInput
          { resourceId = resource
          , ownerScope = declaration ^. #owner
          , clusterId = directClusterId input
          , inputObject = value
          , objectDigest = digest
          , lifecyclePolicy = declaration ^. #lifecycle
          , inputDataPolicy = declaration ^. #dataPolicy
          , inputSensitivity = declaration ^. #sensitivity
          , sourceLocation = declaration ^. #source
          }
      unless (recompiled {dependencies = declaration ^. #dependencies} == declaration)
        (Left (single (invalid "database native object changed during binding")))
      pure (resource, (declaration, bytes))
    invalid message = inventoryError "invalid-database-native" message
      & #scopes .~ [directOwnerScope input]
      & #sources .~ [directSourceLocation input]
    single err = err :| []
