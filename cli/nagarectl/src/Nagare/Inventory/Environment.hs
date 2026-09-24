-- | Independently reviewed Runtime environment intent for one application.
-- The ConfigMap is the same native object used by the existing envFrom render;
-- an application scope replacement leaves this channel's revision alone.
module Nagare.Inventory.Environment
  ( compileRuntimeEnvChannel
  , compileRuntimeSecretChannel
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
import Nagare.Dsl.Render (managedConfigMapName, managedSecretName)
import Nagare.Dsl.Types (EnvScope (Runtime))
import Nagare.Env.Store (renderEnvConfigMap, renderEnvSecret)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), Sensitivity (Private, Secret))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

compileRuntimeEnvChannel
  :: T.Text -> T.Text -> ResourceId -> ResourceId -> Map T.Text T.Text -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileRuntimeEnvChannel app namespaceName cluster namespaceId values source = do
  compileChannel "env" "runtime-env" "configmap" "ConfigMap" Private
    (managedConfigMapName app Runtime) (renderEnvConfigMap app namespaceName Runtime values)
    app namespaceName cluster namespaceId source

-- | The version token is explicit intent and appears only in the declaration
-- source path. Secret values remain in the private native review, never in the
-- public scope or operation summary.
compileRuntimeSecretChannel
  :: T.Text -> T.Text -> ResourceId -> ResourceId -> Name
  -> Map T.Text T.Text -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileRuntimeSecretChannel app namespaceName cluster namespaceId version values source =
  compileChannel "secret" "runtime-secret" "secret" "Secret" Secret
    (managedSecretName app Runtime) (renderEnvSecret app namespaceName Runtime values)
    app namespaceName cluster namespaceId
    (source {path = "runtime-secret/" <> nameText version})

compileChannel
  :: T.Text -> T.Text -> T.Text -> T.Text -> Sensitivity -> T.Text -> ByteString
  -> T.Text -> T.Text -> ResourceId -> ResourceId -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileChannel scopePrefix logicalKey roleText objectKind visibility nativeName bytes
    app namespaceName cluster namespaceId source = do
  owner <- first invalid (mkScopeId Application (scopePrefix <> "-" <> app <> "-runtime"))
  key <- first invalid (mkLogicalKey logicalKey)
  role <- first invalid (mkName roleText)
  let resourceId = mintResourceId owner key role
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
    , inputSensitivity = visibility
    , sourceLocation = source
    })
  expected <- first invalid (kubernetesAddress cluster "v1" objectKind
    (Just namespaceName) nativeName)
  unless (resource ^. #address == expected)
    (Left (invalid "Runtime channel renderer changed its native address"))
  let member = resource {dependencies = [OrderedAfter namespaceId]}
  scope <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [] []]
  pure (scope, Map.singleton resourceId (member, native))
  where
    invalid message = inventoryError "invalid-runtime-channel" message
      & #sources .~ [source]
      & (:| [])
