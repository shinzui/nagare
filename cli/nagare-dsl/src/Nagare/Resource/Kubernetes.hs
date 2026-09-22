-- | Compile a structured Kubernetes object into the same declaration used by
-- inventory validation. The caller retains the object bytes and supplies their
-- content digest; this module does not render or execute the object.
module Nagare.Resource.Kubernetes
  ( KubernetesInput (..)
  , parseKubernetesManifest
  , expandKubernetesList
  , compileKubernetesObject
  )
where

import Data.Aeson (Result (..), Value (..), fromJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

data KubernetesInput = KubernetesInput
  { resourceId :: !ResourceId
  , ownerScope :: !ScopeId
  , clusterId :: !ResourceId
  , inputObject :: !Value
  , objectDigest :: !ContentDigest
  , lifecyclePolicy :: !LifecyclePolicy
  , inputDataPolicy :: !DataPolicy
  , inputSensitivity :: !Sensitivity
  , sourceLocation :: !SourceLocation
  }

-- | Parse every YAML document before assigning resource identities. Each
-- document and List member keeps a source path for collision diagnostics.
parseKubernetesManifest :: SourceLocation -> ByteString -> Either InventoryError [(SourceLocation, Value)]
parseKubernetesManifest source bytes = do
  documents <- case Yaml.decodeAllEither' bytes of
    Left failure -> Left (bad (Text.pack (show failure)))
    Right [] -> Left (bad "Kubernetes manifest has no documents")
    Right values -> Right values
  concat <$> traverse expandDocument (zip [0 :: Int ..] documents)
  where
    expandDocument (ordinal, value) =
      expandKubernetesList
        (source {path = path source <> "#document[" <> Text.pack (show ordinal) <> "]"})
        value
    bad message = (inventoryError "invalid-kubernetes-object" message) {sources = [source]}

-- | Expand the Kubernetes @List@ envelope before assigning identities or
-- validating claims. An empty or malformed list cannot silently become one
-- opaque managed object. The source suffix identifies the original member in
-- diagnostics and remains stable when unrelated documents are added.
expandKubernetesList :: SourceLocation -> Value -> Either InventoryError [(SourceLocation, Value)]
expandKubernetesList source value = case value of
  Object root | KeyMap.lookup "kind" root == Just (String "List") ->
    case KeyMap.lookup "items" root of
      Just (Array items) | not (null items) ->
        concat <$> traverse expandMember (zip [0 :: Int ..] (foldr (:) [] items))
      _ -> Left (bad source "Kubernetes List.items must be a nonempty array")
  Object _ -> Right [(source, value)]
  _ -> Left (bad source "Kubernetes document must be an object")
  where
    expandMember (ordinal, item) =
      expandKubernetesList
        (source {path = path source <> "[" <> Text.pack (show ordinal) <> "]"})
        item
    bad location message =
      (inventoryError "invalid-kubernetes-object" message) {sources = [location]}

-- | Parse identity and controller reservations from the actual object. A
-- malformed controller object is refused rather than downgraded to NativeObject,
-- which would silently drop its derived claims.
compileKubernetesObject :: KubernetesInput -> Either InventoryError ManagedResource
compileKubernetesObject input = do
  root <- asObject "object" (inputObject input)
  apiVersion <- textField "apiVersion" root
  kind <- textField "kind" root
  when (kind == "List") (Left (bad "Kubernetes List must be expanded before compilation"))
  metadata <- field "metadata" root >>= asObject "metadata"
  name <- textField "name" metadata
  namespace <- case KeyMap.lookup "namespace" metadata of
    Nothing -> Right Nothing
    Just (String value) -> Right (Just value)
    _ -> Left (bad "metadata.namespace must be a string")
  address <- mapLeft bad (kubernetesAddress (clusterId input) apiVersion kind namespace name)
  spec <- desiredSpec root address
  pure
    ManagedResource
      { identity = resourceId input
      , owner = ownerScope input
      , executor = KubernetesExecutor
      , address
      , aliases = []
      , spec
      , lifecycle = lifecyclePolicy input
      , dataPolicy = inputDataPolicy input
      , sensitivity = inputSensitivity input
      , dependencies = []
      , delegations = []
      , source = sourceLocation input
      }
  where
    bad message =
      (inventoryError "invalid-kubernetes-object" message)
        { resources = [resourceId input]
        , scopes = [ownerScope input]
        , sources = [sourceLocation input]
        }
    field key value = maybe (Left (bad ("missing " <> key))) Right (KeyMap.lookup (Key.fromText key) value)
    asObject label = \case
      Object value -> Right value
      _ -> Left (bad (label <> " must be an object"))
    textField key value = do
      v <- field key value
      case v of
        String t -> Right t
        _ -> Left (bad (key <> " must be a string"))
    desiredSpec root = \case
      Kubernetes _ "serving.knative.dev" kind _ _ | nameText kind == "service" -> Right (KnativeService (objectDigest input))
      Kubernetes _ "cert-manager.io" kind _ _ | nameText kind == "certificate" -> do
        body <- field "spec" root >>= asObject "spec"
        secret <- textField "secretName" body >>= mapLeft bad . mkName
        Right (Certificate secret (objectDigest input))
      Kubernetes _ "apps" kind _ _ | nameText kind == "statefulset" -> do
        body <- field "spec" root >>= asObject "spec"
        count <- case KeyMap.lookup "replicas" body of
          Nothing -> Right 1
          Just number@(Number _) -> case fromJSON number of
            Success count -> Right count
            Error _ -> Left (bad "spec.replicas must be an integer")
          _ -> Left (bad "spec.replicas must be an integer")
        templates <- case KeyMap.lookup "volumeClaimTemplates" body of
          Nothing -> Right []
          Just (Array entries) -> traverse templateName (foldr (:) [] entries)
          _ -> Left (bad "spec.volumeClaimTemplates must be an array")
        Right (StatefulSet count templates (objectDigest input))
      Kubernetes _ "" kind Nothing _ | nameText kind == "namespace" -> Right NamespaceSpec
      _ -> Right (NativeObject (objectDigest input))
    templateName value = do
      entry <- asObject "volumeClaimTemplate" value
      metadata <- field "metadata" entry >>= asObject "volumeClaimTemplate.metadata"
      textField "name" metadata >>= mapLeft bad . mkName
    mapLeft f = either (Left . f) Right
