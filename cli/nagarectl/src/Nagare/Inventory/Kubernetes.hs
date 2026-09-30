-- | Bind structured Kubernetes declarations to the exact JSON bytes that a
-- native adapter may later submit. YAML presentation and key order do not
-- change the digest; the canonical JSON bytes are the execution input.
module Nagare.Inventory.Kubernetes
  ( bindKubernetesObject
  , kubernetesObjectIdentity
  )
where

import Data.Aeson (toJSON)
import Data.ByteString (ByteString)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | Stable logical role for a direct object in a packaged component.
kubernetesObjectIdentity :: ScopeId -> LogicalKey -> ProviderAddress -> Either Text ResourceId
kubernetesObjectIdentity owner key address = do
  bytes <- canonicalValue (toJSON address)
  role <- mkName ("object-" <> T.take 40 (digestText (contentDigest bytes)))
  pure (mintResourceId owner key role)

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
