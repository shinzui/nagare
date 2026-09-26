-- | Bind the pure database bundle to exact canonical Kubernetes members.
-- The private bytes returned here are the only native inputs suitable for a
-- reviewed Kubernetes adapter; no YAML is rendered again at apply time.
module Nagare.Inventory.Database (compileDatabaseForBackend) where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Database.Backup (renderInventoryDbBackupCronJob)
import Nagare.Dsl.Database (Database (..), engineVersionText)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (RetentionPolicy (..), databaseNameText, namespaceText)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Database
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

compileDatabaseNative
  :: DatabaseDirectInput
  -> Either (NonEmpty InventoryError) (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileDatabaseNative input = do
  compiled <- compileDatabaseDirect digestOf input
  bindDatabaseMembers input compiled
  where
    digestOf value = contentDigest <$> canonicalValue value

compileDatabaseNativeWithBackup
  :: DatabaseDirectInput
  -> Value
  -> Either (NonEmpty InventoryError) (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileDatabaseNativeWithBackup input backupObject = do
  compiled <- compileDatabaseBundle digestOf input backupObject
  bindDatabaseMembers input compiled
  where
    digestOf value = contentDigest <$> canonicalValue value

-- | Compile the same scheduled backup manifest the legacy database command
-- renders, using the selected backend and the complete typed Database value.
-- Throwaway databases intentionally have no scheduled backup.
compileDatabaseForBackend
  :: DatabaseDirectInput
  -> StoreBackend
  -> Either (NonEmpty InventoryError) (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileDatabaseForBackend input backend
  | directDatabase input ^. #retention == Delete = compileDatabaseNative input
  | otherwise = do
      let database = directDatabase input
          rendered = renderInventoryDbBackupCronJob
            (namespaceText (database ^. #namespace))
            (databaseNameText (database ^. #name))
            (database ^. #engine)
            (engineVersionText (database ^. #version))
            backend 7
      backup <- first (\err -> invalid (T.pack (show err))) (Yaml.decodeEither' rendered)
      compileDatabaseNativeWithBackup input backup
  where
    invalid message = inventoryError "invalid-database-backup" message
      & #scopes .~ [directOwnerScope input]
      & #sources .~ [directSourceLocation input]
      & (:| [])

bindDatabaseMembers
  :: DatabaseDirectInput
  -> (ResourceBundle, [(ResourceId, Value)])
  -> Either (NonEmpty InventoryError) (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
bindDatabaseMembers input (bundle, native) = do
  bound <- traverse bindOne native
  let declarationsById = [member ^. #identity | Managed member <- declarations bundle]
      nativeById = Map.fromList bound
  unless (length declarationsById == length native
      && Map.size nativeById == length native
      && Map.keysSet nativeById == Set.fromList declarationsById)
    (Left (single (invalid "database native membership differs from its declarations")))
  pure (bundle, nativeById)
  where
    digestOf value = contentDigest <$> canonicalValue value
    bindOne (resource, value) = do
      declaration <- maybe (Left (single (invalid "database native object has no declaration"))) Right
        (lookup resource [(r ^. #identity, r) | Managed r <- declarations bundle])
      digest <- first (single . invalid) (digestOf value)
      (recompiled, bytes) <- first single $ bindKubernetesObject
        KubernetesInput
          { resourceId = resource
          , ownerScope = declaration ^. #owner
          , clusterId = directClusterId input
          , inputObject = value
          , objectDigest = digest
          , lifecyclePolicy = declaration ^. #lifecycle
          , inputDataPolicy = declaration ^. #dataPolicy
          , inputSensitivity = declaration ^. #sensitivity
          , sourceLocation = declaration ^. #source
          }
      unless (recompiled {dependencies = declaration ^. #dependencies} == declaration)
        (Left (single (invalid "database native object changed during binding")))
      pure (resource, (declaration, bytes))
    invalid message = inventoryError "invalid-database-native" message
      & #scopes .~ [directOwnerScope input]
      & #sources .~ [directSourceLocation input]
    single err = err :| []
