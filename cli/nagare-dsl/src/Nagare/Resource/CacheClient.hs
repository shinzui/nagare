-- | Typed client configuration consuming the cache's generated signing key.
-- The reviewed ConfigMap retains only a placeholder; the runtime fills that
-- slot after the logical cache operation has proved its output.
module Nagare.Resource.CacheClient
  ( CacheClientInput (..)
  , compileCacheClient
  ) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types

data CacheClientInput = CacheClientInput
  { clientOwner :: !ScopeId
  , clientCluster :: !ResourceId
  , clientLogicalKey :: !LogicalKey
  , clientCache :: !ResourceId
  , clientObject :: !Value
  , clientSource :: !SourceLocation
  }

compileCacheClient
  :: (Value -> Either Text ContentDigest)
  -> CacheClientInput
  -> Either (NonEmpty InventoryError) (ResourceBundle, ResourceId, Value)
compileCacheClient digestOf input = do
  unless (hasOneKeyPlaceholder (clientCache input) (clientObject input))
    (Left (single (invalid "cache client ConfigMap must contain exactly one generated-key placeholder")))
  digest <- first (single . invalid) (digestOf (clientObject input))
  declaration <- first single $ compileKubernetesObject
    KubernetesInput
      { resourceId = resource
      , ownerScope = clientOwner input
      , clusterId = clientCluster input
      , inputObject = clientObject input
      , objectDigest = digest
      , lifecyclePolicy = Retain
      , inputDataPolicy = Stateless
      , inputSensitivity = Public
      , sourceLocation = clientSource input
      }
  unless (declaration ^. #address == Kubernetes (clientCluster input) "" (known "configmap") (Just (known "personal")) (known "nagare-nix-cache-client"))
    (Left (single (invalid "cache client ConfigMap has an unexpected address")))
  let publicKey = outputRef NixCachePublicKeyW (clientCache input) (known "public-key") [NonEmptyOutput] Public
      guarded = declaration {dependencies = [Consumes (SomeRef publicKey)]}
  pure (ResourceBundle [Managed guarded] [] [] [] [] [], resource, clientObject input)
  where
    resource = mintResourceId (clientOwner input) (clientLogicalKey input) (known "client-config")
    invalid message = inventoryError "invalid-cache-client" message
      & #scopes .~ [clientOwner input]
      & #sources .~ [clientSource input]
    single err = err :| []
    known = either (error . show) id . mkName

hasOneKeyPlaceholder :: ResourceId -> Value -> Bool
hasOneKeyPlaceholder producer (Object root) = case (KM.lookup "data" root, KM.lookup "metadata" root) of
  (Just (Object entries), Just (Object metadata)) -> case (KM.toList entries, KM.lookup "annotations" metadata) of
    ([("nix.conf", String textValue)], Just (Object annotations)) ->
      T.count "${ATTIC_PUBLIC_KEY}" textValue == 1
        && KM.lookup "nagare.dev/cache-key-producer" annotations == Just (String (resourceIdText producer))
        && KM.lookup "nagare.dev/cache-client-template" annotations == Just (String "v1")
    _ -> False
  _ -> False
hasOneKeyPlaceholder _ _ = False
