-- | Independently reviewed Runtime environment intent for one application.
-- The ConfigMap is the same native object used by the existing envFrom render;
-- an application scope replacement leaves this channel's revision alone.
module Nagare.Inventory.Environment
  ( compileRuntimeEnvChannel
  ) where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (managedConfigMapName)
import Nagare.Dsl.Types (EnvScope (Runtime))
import Nagare.Env.Store (renderEnvConfigMap)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

compileRuntimeEnvChannel
  :: T.Text -> T.Text -> ResourceId -> ResourceId -> Map T.Text T.Text -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileRuntimeEnvChannel app namespaceName cluster namespaceId values source = do
  owner <- first invalid (mkScopeId Application ("env-" <> app <> "-runtime"))
  key <- first invalid (mkLogicalKey "runtime-env")
  role <- first invalid (mkName "configmap")
  let resourceId = mintResourceId owner key role
      bytes = renderEnvConfigMap app namespaceName Runtime values
  value <- first (invalid . T.pack . show)
    (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  canonical <- first invalid (canonicalValue value)
  (resource, native) <- first (:| []) (bindKubernetesObject KubernetesInput
    { resourceId = resourceId
    , ownerScope = owner
    , clusterId = cluster
    , inputObject = value
    , objectDigest = contentDigest canonical
    , lifecyclePolicy = Retain
    , inputDataPolicy = Stateless
    , inputSensitivity = Private
    , sourceLocation = source
    })
  expected <- first invalid (kubernetesAddress cluster "v1" "ConfigMap"
    (Just namespaceName) (managedConfigMapName app Runtime))
  unless (resource ^. #address == expected)
    (Left (invalid "Runtime env renderer changed its native address"))
  let member = resource {dependencies = [OrderedAfter namespaceId]}
  scope <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [] []]
  pure (scope, Map.singleton resourceId (member, native))
  where
    invalid message = inventoryError "invalid-runtime-env-channel" message
      & #sources .~ [source]
      & (:| [])
