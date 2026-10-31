-- | The stored platform-versions snapshot (EP-236): one mutable object,
-- @versions/latest.json@, under the context's inventory root. Reading it is
-- bounded and context-bound; every refusal is a reason code, never the
-- store's error text, so no provider detail reaches a document.
module Nagare.Platform.Versions.Store
  ( versionSnapshotKey
  , snapshotByteLimit
  , validateSnapshot
  , readVersionSnapshot
  )
where

import Data.Aeson (eitherDecodeStrict')
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store (InventoryStore, readObject)
import Nagare.Platform.Versions
import Nagare.Resource.Types (ContextBinding (..), contextIdText, nameText)

versionSnapshotKey :: FilePath
versionSnapshotKey = "versions/latest.json"

-- | One MiB: a snapshot of a large installation is a few tens of KiB.
snapshotByteLimit :: Int
snapshotByteLimit = 1048576

-- | Accept a read snapshot only when it is present, within the limit, of
-- the known schema and bound to this context and project.
validateSnapshot :: ContextBinding -> Maybe ByteString -> Either Text VersionSnapshot
validateSnapshot binding = \case
  Nothing -> Left reasonSnapshotMissing
  Just bytes
    | BS.length bytes > snapshotByteLimit -> Left reasonSnapshotOversized
    | otherwise -> case eitherDecodeStrict' bytes of
        Left _ -> Left reasonSnapshotInvalid
        Right stored
          | stored ^. #snapshotSchema /= snapshotSchemaVersion -> Left reasonSnapshotInvalid
          | stored ^. #context /= contextIdText (binding ^. #identity) || stored ^. #project /= nameText (binding ^. #project) ->
              Left reasonSnapshotForeign
          | otherwise -> Right stored

-- | Read and validate the snapshot. A failed store read is
-- @snapshot_unavailable@.
readVersionSnapshot :: InventoryStore -> ContextBinding -> IO (Either Text VersionSnapshot)
readVersionSnapshot store binding = do
  loaded <- readObject store versionSnapshotKey
  pure $ case loaded of
    Left _ -> Left reasonSnapshotUnavailable
    Right bytes -> validateSnapshot binding bytes
