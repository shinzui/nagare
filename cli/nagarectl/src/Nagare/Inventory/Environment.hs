-- | Independently reviewed Runtime environment intent for one application.
-- The ConfigMap is the same native object used by the existing envFrom render;
-- an application scope replacement leaves this channel's revision alone.
module Nagare.Inventory.Environment
  ( compileRuntimeEnvChannel
  , compileBuildEnvChannel
  , compilePreviewEnvChannel
  , compileRuntimeSecretChannel
  , compileBuildSecretChannel
  , compilePreviewSecretChannel
  , validateSecretRotation
  , acceptedEnvChannelValues
  , acceptedSecretChannelValues
  ) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (managedConfigMapName, managedSecretName)
import Nagare.Dsl.Types (EnvScope (Build, Preview, Runtime))
import Nagare.Env.Store (extractSecretData, renderEnvConfigMap, renderEnvSecret)
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
  compileChannel "env" "runtime" "runtime-env" "configmap" "ConfigMap" Private
    (managedConfigMapName app Runtime) (renderEnvConfigMap app namespaceName Runtime values)
    app namespaceName cluster namespaceId source

-- | Build variables have a distinct accepted revision from Runtime variables.
-- The existing build-argument reader consumes this exact ConfigMap address.
compileBuildEnvChannel
  :: T.Text -> T.Text -> ResourceId -> ResourceId -> Map T.Text T.Text -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileBuildEnvChannel app namespaceName cluster namespaceId values source =
  compileChannel "env" "build" "build-env" "configmap" "ConfigMap" Private
    (managedConfigMapName app Build) (renderEnvConfigMap app namespaceName Build values)
    app namespaceName cluster namespaceId source

-- | Preview overlays have their own accepted revision and the exact native
-- address read by preview workloads after the Runtime environment pair.
compilePreviewEnvChannel
  :: T.Text -> T.Text -> ResourceId -> ResourceId -> Map T.Text T.Text -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compilePreviewEnvChannel app namespaceName cluster namespaceId values source =
  compileChannel "env" "preview" "preview-env" "configmap" "ConfigMap" Private
    (managedConfigMapName app Preview) (renderEnvConfigMap app namespaceName Preview values)
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
  compileChannel "secret" "runtime" "runtime-secret" "secret" "Secret" Secret
    (managedSecretName app Runtime) (renderEnvSecret app namespaceName Runtime values)
    app namespaceName cluster namespaceId
    (source {path = "runtime-secret/" <> nameText version})

-- | Build credentials rotate independently from Runtime credentials and bind
-- their private native bytes to an explicit version before review publication.
compileBuildSecretChannel
  :: T.Text -> T.Text -> ResourceId -> ResourceId -> Name
  -> Map T.Text T.Text -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileBuildSecretChannel app namespaceName cluster namespaceId version values source =
  compileChannel "secret" "build" "build-secret" "secret" "Secret" Secret
    (managedSecretName app Build) (renderEnvSecret app namespaceName Build values)
    app namespaceName cluster namespaceId
    (source {path = "build-secret/" <> nameText version})

compilePreviewSecretChannel
  :: T.Text -> T.Text -> ResourceId -> ResourceId -> Name
  -> Map T.Text T.Text -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compilePreviewSecretChannel app namespaceName cluster namespaceId version values source =
  compileChannel "secret" "preview" "preview-secret" "secret" "Secret" Secret
    (managedSecretName app Preview) (renderEnvSecret app namespaceName Preview values)
    app namespaceName cluster namespaceId
    (source {path = "preview-secret/" <> nameText version})

-- | Merge reviews read the accepted private native ConfigMap, never a live
-- provider value. The next plan still binds to the exact accepted base revision.
acceptedEnvChannelValues
  :: ScopeSnapshot -> Map ResourceId (ManagedResource, ByteString) -> ScopeDeclaration
  -> Either T.Text (Map T.Text T.Text)
acceptedEnvChannelValues snapshot native candidate = case Map.lookup (scopeId candidate) (snapshotScopes snapshot) of
  Nothing -> Right Map.empty
  Just (_, scope) -> case
    [resource | bundle <- scopeBundles scope, Managed resource <- declarations bundle] of
    [resource] -> do
      let expected = [member | bundle <- scopeBundles candidate,
            Managed member <- declarations bundle]
      unless (case expected of
          [member] -> member ^. #identity == resource ^. #identity
            && member ^. #address == resource ^. #address
          _ -> False)
        (Left "accepted environment channel identity or address differs from requested channel")
      unless (resource ^. #executor == KubernetesExecutor
          && case resource ^. #address of
               Kubernetes _ "" kind (Just _) _ -> nameText kind == "configmap"
               _ -> False)
        (Left "accepted environment channel is not a namespaced ConfigMap")
      (nativeResource, bytes) <- maybe (Left "accepted environment channel has no private native member")
        Right (Map.lookup (resource ^. #identity) native)
      unless (nativeResource == resource)
        (Left "accepted environment channel native member differs from accepted declaration")
      value <- first (T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      case value of
        Object fields -> case KM.lookup "data" fields of
          Just dataValue -> case Aeson.fromJSON dataValue of
            Aeson.Success values -> Right values
            Aeson.Error _ -> Left "accepted environment channel has invalid data"
          Nothing -> Left "accepted environment channel has no data"
        _ -> Left "accepted environment channel has invalid native bytes"
    _ -> Left "accepted environment channel has unexpected membership"

-- | Recover Secret values only from the accepted private review. Callers must
-- keep the returned map private and submit a new explicit rotation version.
acceptedSecretChannelValues
  :: ScopeSnapshot -> Map ResourceId (ManagedResource, ByteString) -> ScopeDeclaration
  -> Either T.Text (Map T.Text T.Text)
acceptedSecretChannelValues snapshot native candidate = case Map.lookup (scopeId candidate) (snapshotScopes snapshot) of
  Nothing -> Right Map.empty
  Just (_, scope) -> case
    [resource | bundle <- scopeBundles scope, Managed resource <- declarations bundle] of
    [resource] -> do
      let expected = [member | bundle <- scopeBundles candidate,
            Managed member <- declarations bundle]
      unless (case expected of
          [member] -> member ^. #identity == resource ^. #identity
            && member ^. #address == resource ^. #address
          _ -> False)
        (Left "accepted Secret channel identity or address differs from requested channel")
      unless (resource ^. #executor == KubernetesExecutor
          && case resource ^. #address of
               Kubernetes _ "" kind (Just _) _ -> nameText kind == "secret"
               _ -> False)
        (Left "accepted Secret channel is not a namespaced Secret")
      (nativeResource, bytes) <- maybe (Left "accepted Secret channel has no private native member")
        Right (Map.lookup (resource ^. #identity) native)
      unless (nativeResource == resource)
        (Left "accepted Secret channel native member differs from accepted declaration")
      value <- first (const "accepted Secret channel has invalid native bytes")
        (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      case value of
        Object fields -> case KM.lookup "data" fields of
          Just dataValue -> case Aeson.fromJSON dataValue :: Aeson.Result (Map T.Text T.Text) of
            Aeson.Success _ -> extractSecretData bytes
            Aeson.Error _ -> Left "accepted Secret channel has invalid data"
          Nothing -> Left "accepted Secret channel has no data"
        _ -> Left "accepted Secret channel has invalid native bytes"
    _ -> Left "accepted Secret channel has unexpected membership"

-- | One opaque version identifies one exact Secret payload. Reusing a version
-- with different native content would make a rotation receipt ambiguous.
validateSecretRotation :: ScopeSnapshot -> ScopeDeclaration -> Either T.Text ()
validateSecretRotation snapshot candidate = do
  proposed <- singleSecret candidate
  case Map.lookup (scopeId candidate) (snapshotScopes snapshot) of
    Nothing -> Right ()
    Just (_, accepted) -> do
      previous <- singleSecret accepted
      unless (path (previous ^. #source) /= path (proposed ^. #source)
          || previous ^. #spec == proposed ^. #spec)
        (Left "Secret rotation version already names different content")
  where
    singleSecret scope = case
      [resource | bundle <- scopeBundles scope, Managed resource <- declarations bundle] of
      [resource] -> Right resource
      _ -> Left "Secret channel must have exactly one managed member"

compileChannel
  :: T.Text -> T.Text -> T.Text -> T.Text -> T.Text -> Sensitivity -> T.Text -> ByteString
  -> T.Text -> T.Text -> ResourceId -> ResourceId -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileChannel scopePrefix channelName logicalKey roleText objectKind visibility nativeName bytes
    app namespaceName cluster namespaceId source = do
  owner <- first invalid (mkScopeId Application (scopePrefix <> "-" <> app <> "-" <> channelName))
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
    (Left (invalid "environment channel renderer changed its native address"))
  let member = resource {dependencies = [OrderedAfter namespaceId]}
  scope <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [] []]
  pure (scope, Map.singleton resourceId (member, native))
  where
    invalid message = inventoryError ("invalid-" <> channelName <> "-channel") message
      & #sources .~ [source]
      & (:| [])
