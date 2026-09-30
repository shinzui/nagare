-- | Read-only authority discovery. Absence, foreign state and failed reads are
-- different outcomes; none of these operations initializes history or a writer.
module Nagare.Inventory.Store.Discovery (InventoryDiscovery (..), HistoryAuthority (..), chooseHistoryAuthority, discoverInventoryObjects) where

import Data.Aeson (object, toJSON, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types (ContextBinding)
import Nagare.Resource.Wire (canonicalValue)

data InventoryDiscovery
  = DiscoveredHistory !InventoryStore !HeadManifest
  | DiscoveredMissingBucket
  | DiscoveredEmptyPrefix
  | DiscoveryForeign !Text
  | DiscoveryIncomplete !Text
  | DiscoveryUnavailable !Text

data HistoryAuthority = UseLocalFoundation | UseRemoteHistory deriving stock (Eq, Show)

chooseHistoryAuthority :: Text -> Maybe HeadManifest -> InventoryDiscovery -> Either Text HistoryAuthority
chooseHistoryAuthority destination local remote = do
  case local >>= headMigration of
    Just marker
      | migrationDestination marker /= destination ->
          Left "local inventory migration destination differs from the selected remote store"
    _ -> Right ()
  case remote of
    DiscoveryUnavailable reason -> Left reason
    DiscoveryForeign reason -> Left reason
    DiscoveryIncomplete reason -> Left reason
    DiscoveredHistory _ _ -> case local of
      Just value
        | isNothing (headMigration value)
        , hasSubstantiveHistory value ->
            Left "local inventory history exists beside remote history; explicit migration/conflict resolution is required"
      _ -> Right UseRemoteHistory
    _
      | isJust (local >>= headMigration) -> Left "migrated remote inventory history is missing; refusing a new history"
      | otherwise -> Right UseLocalFoundation

discoverInventoryObjects :: ObjectOps -> IO (Either Text Bool) -> ContextBinding -> IO InventoryDiscovery
discoverInventoryObjects ops prefixEmpty binding = do
  format <- getObject ops (ObjectName "format.json")
  case format of
    GetUnknown reason -> pure (DiscoveryUnavailable reason)
    ObjectAbsent ->
      prefixEmpty >>= \case
        Left reason -> pure (DiscoveryUnavailable reason)
        Right False -> pure (DiscoveryIncomplete "inventory format is missing but the prefix contains history")
        Right True -> pure DiscoveredEmptyPrefix
    ObjectFound _ bytes -> case canonicalValue (object ["version" .= (1 :: Int), "binding" .= toJSON binding]) of
      Left reason -> pure (DiscoveryIncomplete reason)
      Right expected | bytes /= expected -> pure (DiscoveryForeign "inventory format differs from the selected context or supported format")
      Right _ -> do
        opened <- openObjectStoreReadOnly ops binding "discovery-only" Nothing
        case opened of
          Left err -> pure (DiscoveryUnavailable (T.pack (show err)))
          Right store ->
            readHead store >>= \case
              Left (StoreIoError reason) -> pure (DiscoveryUnavailable reason)
              Left err -> pure (DiscoveryIncomplete (T.pack (show err)))
              Right Nothing -> pure (DiscoveryIncomplete "inventory format exists but the history head is missing")
              Right (Just headValue)
                | headBinding headValue /= binding -> pure (DiscoveryForeign "inventory head belongs to a different context or provider project")
                | isJust (headMigration headValue) -> pure (DiscoveryIncomplete "remote inventory history has migrated; refusing to resurrect it")
                | otherwise -> pure (DiscoveredHistory store headValue)
