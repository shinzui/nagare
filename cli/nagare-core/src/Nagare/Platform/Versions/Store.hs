-- | The stored platform-versions snapshot (EP-236): one mutable object,
-- @versions/latest.json@, under the context's inventory root. Reading it is
-- bounded and context-bound; every refusal is a reason code, never the
-- store's error text, so no provider detail reaches a document.
module Nagare.Platform.Versions.Store
  ( versionSnapshotKey
  , snapshotByteLimit
  , validateSnapshot
  , readVersionSnapshot
  , Publication (..)
  , publishVersionSnapshot
  )
where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (IOException, bracket_, try)
import Data.Aeson (eitherDecodeStrict', encode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text qualified as T
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hLock, hUnlock)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store (HeadManifest (..), InventoryStore, observationTransport, readHead, readObject)
import Nagare.Inventory.Store.FileIO (atomicWrite)
import Nagare.Inventory.Store.ObjectOps (GetOutcome (..), ObjectName (..), ObjectOps (..), PutCondition (..), PutOutcome (..))
import Nagare.Platform.Versions
import Nagare.Resource.Types (ContextBinding (..), contextIdText, nameText)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO (IOMode (ReadWriteMode), withFile)
import System.IO.Unsafe (unsafePerformIO)

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

-- | What a publication did. A stored snapshot that completed later than
-- this one is kept, so a slow collection never replaces a newer one.
data Publication
  = Published
  | KeptNewer
  deriving stock (Eq, Show)

-- | Publish a complete snapshot. Locally the read, comparison and atomic
-- rename run under an exclusive lock; remotely the write is conditional on
-- the generation read (or on absence) and retried on a lost race. The head,
-- journal and convergence facts are never touched. A migrated store, a
-- foreign binding or an oversized snapshot is refused.
publishVersionSnapshot :: InventoryStore -> VersionSnapshot -> IO (Either Text Publication)
publishVersionSnapshot store snapshot
  | BS.length bytes > snapshotByteLimit = pure (Left "the snapshot exceeds 1 MiB")
  | otherwise = do
      current <- readHead store
      case current of
        Left _ -> pure (Left "the inventory head is unreadable")
        Right Nothing -> pure (Left "the inventory store is not initialized")
        Right (Just headValue)
          | isJust (headMigration headValue) -> pure (Left "the inventory store has migrated; reload the context shell")
          | boundTo (headBinding headValue) /= (snapshot ^. #context, snapshot ^. #project) ->
              pure (Left "the snapshot is bound to another context or project")
          | otherwise -> case observationTransport store of
              Nothing -> pure (Left "this inventory store keeps no observation objects")
              Just (Left root) -> publishLocal root
              Just (Right ops) -> publishRemote ops (3 :: Int)
  where
    bytes = LBS.toStrict (encode snapshot)
    boundTo binding = (contextIdText (binding ^. #identity), nameText (binding ^. #project))
    newer existing = case eitherDecodeStrict' existing of
      Right (stored :: VersionSnapshot) -> stored ^. #completedAt > snapshot ^. #completedAt
      Left _ -> False
    publishLocal root = do
      let directory = root </> "versions"
          target = root </> versionSnapshotKey
      outcome <- try . withMVar localPublishers . const $ do
        createDirectoryIfMissing True directory
        withFile (directory </> "latest.lock") ReadWriteMode $ \handle ->
          bracket_ (hLock handle ExclusiveLock) (hUnlock handle) $ do
            present <- doesFileExist target
            existing <- if present then Just <$> BS.readFile target else pure Nothing
            if maybe False newer existing
              then pure KeptNewer
              else Published <$ atomicWrite target bytes
      pure (first (\(failure :: IOException) -> "the snapshot could not be written: " <> T.pack (show failure)) outcome)
    publishRemote ops attempts = do
      let name = ObjectName (T.pack versionSnapshotKey)
      observed <- getObject ops name
      let conditional condition = do
            written <- putObject ops condition name bytes
            case written of
              PutWritten _ -> pure (Right Published)
              PutPreconditionFailed
                | attempts > 1 -> publishRemote ops (attempts - 1)
                | otherwise -> pure (Left "the snapshot changed during every publication attempt")
              PutNoEffect reason -> pure (Left reason)
              PutUnknown reason -> pure (Left reason)
      case observed of
        GetUnknown reason -> pure (Left reason)
        ObjectAbsent -> conditional IfAbsent
        ObjectFound generation existing
          | newer existing -> pure (Right KeptNewer)
          | otherwise -> conditional (IfGenerationMatches generation)

-- | One local publisher per process at a time: the runtime refuses a second
-- writable handle on the lock file, and the file lock orders processes.
localPublishers :: MVar ()
localPublishers = unsafePerformIO (newMVar ())
{-# NOINLINE localPublishers #-}
