-- | Reviewed schedule shutdown and retirement use the accepted CronJob bytes.
-- Collection is a separate lifecycle decision against the retained incarnation.
module Nagare.Inventory.TaskLifecycle
  ( taskSuspended
  , compileTaskSuspensionScope
  , retireSuspendedTaskScope
  ) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

taskSuspended :: Maybe T.Text -> ManagedResource -> ByteString
  -> Either (NonEmpty InventoryError) Bool
taskSuspended appName resource bytes = do
  let invalid message = inventoryError "invalid-task-lifecycle" message
        & #resources .~ [resource ^. #identity] & (:| [])
  (ns, nativeName) <- case resource ^. #address of
    Kubernetes _ "batch" kind (Just namespaceName) name
      | nameText kind == "cronjob" && resource ^. #executor == KubernetesExecutor ->
          Right (nameText namespaceName, nameText name)
    _ -> Left (invalid "task lifecycle requires an accepted namespaced CronJob")
  value <- first (invalid . T.pack . show)
    (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  canonical <- first invalid (canonicalValue value)
  unless (resource ^. #spec == NativeObject (contentDigest canonical))
    (Left (invalid "CronJob native bytes differ from the accepted declaration"))
  root <- case value of
    Object fields -> Right fields
    _ -> Left (invalid "CronJob native evidence is not an object")
  unless (KM.lookup "apiVersion" root == Just (String "batch/v1")
      && KM.lookup "kind" root == Just (String "CronJob"))
    (Left (invalid "task native evidence is not a batch/v1 CronJob"))
  metadata <- objectField invalid "metadata" root
  unless (KM.lookup "namespace" metadata == Just (String ns)
      && KM.lookup "name" metadata == Just (String nativeName))
    (Left (invalid "CronJob native address differs from its declaration"))
  labels <- objectField invalid "labels" metadata
  unless (KM.lookup "nagare.dev/app" labels == (String <$> appName))
    (Left (invalid "CronJob app label differs from the selected APP"))
  spec <- objectField invalid "spec" root
  case KM.lookup "suspend" spec of
    Nothing -> Right False
    Just (Bool suspended) -> Right suspended
    _ -> Left (invalid "CronJob spec.suspend is not a boolean")

compileTaskSuspensionScope :: Maybe T.Text -> ManagedResource -> ScopeDeclaration
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileTaskSuspensionScope appName selected accepted native = do
  bytes <- selectedNative selected accepted native
  _ <- taskSuspended appName selected bytes
  value <- first (invalid . T.pack . show)
    (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  changed <- case value of
    Object root -> case KM.lookup "spec" root of
      Just (Object spec) -> Right (Object (KM.insert "spec"
        (Object (KM.insert "suspend" (Bool True) spec)) root))
      _ -> Left (invalid "CronJob spec is missing")
    _ -> Left (invalid "CronJob native evidence is not an object")
  changedBytes <- first invalid (canonicalValue changed)
  let updated = selected & #spec .~ NativeObject (contentDigest changedBytes)
      key = "operational.task-suspend." <> resourceIdText (selected ^. #identity)
  revised <- replaceMember selected (Just updated) accepted
  pure (withScopeOverrides (Map.insert key "true" (scopeOverrides revised)) revised,
    Map.insert (selected ^. #identity) (updated, changedBytes) native)
  where
    invalid message = inventoryError "invalid-task-lifecycle" message
      & #resources .~ [selected ^. #identity] & (:| [])

retireSuspendedTaskScope :: Maybe T.Text -> ManagedResource -> ScopeDeclaration
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError) ScopeDeclaration
retireSuspendedTaskScope appName selected accepted native = do
  bytes <- selectedNative selected accepted native
  suspended <- taskSuspended appName selected bytes
  unless suspended (Left (invalid "CronJob must be suspended in accepted intent before retirement"))
  revised <- replaceMember selected Nothing accepted
  let key = "operational.task-retirement." <> resourceIdText (selected ^. #identity)
  pure (withScopeOverrides (Map.insert key "retained" (scopeOverrides revised)) revised)
  where
    invalid message = inventoryError "invalid-task-lifecycle" message
      & #resources .~ [selected ^. #identity] & (:| [])

selectedNative :: ManagedResource -> ScopeDeclaration
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError) ByteString
selectedNative selected accepted native = do
  let invalid message = inventoryError "invalid-task-lifecycle" message
        & #resources .~ [selected ^. #identity] & (:| [])
      members = [member | bundle <- scopeBundles accepted,
        Managed member <- declarations bundle,
        member ^. #identity == selected ^. #identity]
  unless (members == [selected] && selected ^. #owner == scopeId accepted)
    (Left (invalid "selected CronJob differs from the accepted scope member"))
  (bound, bytes) <- maybe (Left (invalid "CronJob lacks accepted private native evidence")) Right
    (Map.lookup (selected ^. #identity) native)
  unless (bound == selected)
    (Left (invalid "CronJob differs from its private native evidence"))
  pure bytes

replaceMember :: ManagedResource -> Maybe ManagedResource -> ScopeDeclaration
  -> Either (NonEmpty InventoryError) ScopeDeclaration
replaceMember selected replacement accepted = do
  let replace bundle = bundle & #declarations %~ concatMap (\case
        Managed member | member ^. #identity == selected ^. #identity ->
          maybe [] (pure . Managed) replacement
        declaration -> [declaration])
  base <- mkScopeDeclaration (scopeId accepted) (map replace (scopeBundles accepted))
  pure $ withScopeOverrides (scopeOverrides accepted) $ case scopeConfigDigest accepted of
    Nothing -> base
    Just digest -> withScopeConfigDigest digest base

objectField :: (T.Text -> NonEmpty InventoryError) -> T.Text -> KM.KeyMap Value
  -> Either (NonEmpty InventoryError) (KM.KeyMap Value)
objectField invalid key fields = case KM.lookup (K.fromText key) fields of
  Just (Object value) -> Right value
  _ -> Left (invalid ("CronJob has no object " <> key))
