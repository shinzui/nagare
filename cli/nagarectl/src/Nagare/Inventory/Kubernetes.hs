-- | Bind structured Kubernetes declarations to the exact JSON bytes that a
-- native adapter may later submit. YAML presentation and key order do not
-- change the digest; the canonical JSON bytes are the execution input.
module Nagare.Inventory.Kubernetes
  ( bindKubernetesObject
  )
where

import Data.ByteString (ByteString)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

bindKubernetesObject :: KubernetesInput -> Either InventoryError (ManagedResource, ByteString)
bindKubernetesObject input = do
  bytes <- first invalid (canonicalValue (inputObject input))
  unless (contentDigest bytes == objectDigest input) (Left (invalid "Kubernetes object digest differs from canonical native bytes"))
  declaration <- compileKubernetesObject input
  pure (declaration, bytes)
  where
    invalid message =
      (inventoryError "invalid-kubernetes-object" message)
        { resources = [resourceId input]
        , scopes = [ownerScope input]
        , sources = [sourceLocation input]
        }
