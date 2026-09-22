-- | Stable direct Kubernetes members of the cache component. Renderers supply
-- structured objects; the compiler verifies their exact role and address.
module Nagare.Resource.CacheKubernetes
  ( CacheCoreInput (..)
  , cacheCoreResourceId
  , compileCacheCore
  ) where

import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types

data CacheCoreInput = CacheCoreInput
  { coreOwner :: !ScopeId
  , coreCluster :: !ResourceId
  , coreLogicalKey :: !LogicalKey
  , coreDatabase :: !ResourceId
  , coreCredential :: !ResourceId
  , coreServerConfig :: !Value
  , coreDeployment :: !Value
  , corePublicService :: !Value
  , coreInternalService :: !Value
  , coreGarbageCollection :: !Value
  , coreServerPolicy :: !Value
  , coreClientPolicy :: !Value
  , coreSource :: !SourceLocation
  }

cacheCoreResourceId :: CacheCoreInput -> Text -> ResourceId
cacheCoreResourceId input role = mintResourceId (coreOwner input) (coreLogicalKey input) (known role)

compileCacheCore
  :: (Value -> Either Text ContentDigest)
  -> CacheCoreInput
  -> Either (NonEmpty InventoryError) (ResourceBundle, [(ResourceId, Value)])
compileCacheCore digestOf input = do
  members <- traverse compileOne objects
  pure (ResourceBundle (map (Managed . fst) members) [] [] [] [] [], [(resource ^. #identity, value) | (resource, value) <- members])
  where
    objects =
      [ ("server-config", "", "configmap", "nagare-system", "nagare-nix-cache-server", coreServerConfig input, [])
      , ("deployment", "apps", "deployment", "nagare-system", "nix-cache", coreDeployment input,
          [coreDatabase input, coreCredential input, cacheCoreResourceId input "server-config"])
      , ("public-service", "", "service", "nagare-system", "nix-cache", corePublicService input,
          [cacheCoreResourceId input "deployment"])
      , ("internal-service", "", "service", "nagare-system", "nix-cache-internal", coreInternalService input,
          [cacheCoreResourceId input "deployment"])
      , ("garbage-collection", "batch", "cronjob", "nagare-system", "nix-cache-gc", coreGarbageCollection input,
          [cacheCoreResourceId input "deployment"])
      , ("server-network-policy", "networking.k8s.io", "networkpolicy", "nagare-system", "nix-cache-server", coreServerPolicy input,
          [cacheCoreResourceId input "deployment"])
      , ("client-network-policy", "networking.k8s.io", "networkpolicy", "personal", "nix-cache-clients", coreClientPolicy input,
          [cacheCoreResourceId input "public-service", cacheCoreResourceId input "internal-service"])
      ]
    compileOne (role, group, kind, namespace, name, value, prerequisites) = do
      digest <- first invalid (digestOf value)
      declaration <- first single $ compileKubernetesObject
        KubernetesInput
          { resourceId = cacheCoreResourceId input role
          , ownerScope = coreOwner input
          , clusterId = coreCluster input
          , inputObject = value
          , objectDigest = digest
          , lifecyclePolicy = Retain
          , inputDataPolicy = Stateless
          , inputSensitivity = Private
          , sourceLocation = (coreSource input) {path = path (coreSource input) <> "#" <> role}
          }
      let expected = Kubernetes (coreCluster input) group (known kind) (Just (known namespace)) (known name)
      unless (declaration ^. #address == expected)
        (Left (invalid ("cache " <> role <> " object has an unexpected Kubernetes address")))
      pure (declaration {dependencies = map OrderedAfter prerequisites}, value)
    invalid message = inventoryError "invalid-cache-core" message
      & #scopes .~ [coreOwner input]
      & #sources .~ [coreSource input]
      & single
    single err = err :| []

known :: Text -> Name
known value = either (error . show) id (mkName value)
