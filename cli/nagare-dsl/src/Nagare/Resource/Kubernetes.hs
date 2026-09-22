-- | Compile a structured Kubernetes object into the same declaration used by
-- inventory validation. The caller retains the object bytes and supplies their
-- content digest; this module does not render or execute the object.
module Nagare.Resource.Kubernetes
  ( KubernetesInput (..)
  , compileKubernetesObject
  )
where

import Data.Aeson (Result (..), Value (..), fromJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
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

-- | Parse identity and controller reservations from the actual object. A
-- malformed controller object is refused rather than downgraded to NativeObject,
-- which would silently drop its derived claims.
compileKubernetesObject :: KubernetesInput -> Either InventoryError ManagedResource
compileKubernetesObject input = do
  root <- asObject "object" (inputObject input)
  apiVersion <- textField "apiVersion" root
  kind <- textField "kind" root
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
