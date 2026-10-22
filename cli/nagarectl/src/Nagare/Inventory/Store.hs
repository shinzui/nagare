{-# LANGUAGE RankNTypes #-}

-- | Conditional-write inventory storage with filesystem and in-memory backends.
module Nagare.Inventory.Store
  ( InventoryStore
  , LockedStore
  , StoreError (..)
  , ScopeRevision (..)
  , ExecutorClaim (..)
  , MigrationTombstone (..)
  , RetainedIncarnation (..)
  , DeletionTombstone (..)
  , DataFencePhase (..)
  , DataFenceRecord (..)
  , HeadManifest (..)
  , TransitionMarker (..)
  , hasSubstantiveHistory
  , transitionReviewIdentity
  , parseTransitionReviewIdentity
  , StoreSnapshot (..)
  , storeCounters
  , countStore
  , openFilesystemStore
  , openFilesystemStoreReadOnly
  , newMemoryStore
  , newObjectStore
  , newObjectStoreWithLock
  , openObjectStoreReadOnly
  , openObjectStoreReadOnlyWithLock
  , storeClientIdentity
  , storeRetryPause
  , inventoryStoreRoot
  , initializeStore
  , initializeStoreFrom
  , readHead
  , ObservedHead
  , observeHead
  , observedHeadManifest
  , replaceObservedHead
  , inspectHeadSchema
  , readStoreSnapshot
  , readReviewSnapshot
  , readReviewSnapshotAt
  , publishIfAbsent
  , readObject
  , readImmutableObjects
  , readImmutableObjectsEach
  , cacheObservationBytes
  , readJournalPrefix
  , appendAtSequence
  , appendAtObservedHead
  , replaceHeadIfGenerationMatches
  , withProcessLock
  , lockedStore
  , exportStore
  , restoreStore
  , restoreStoreFor
  , publishMigrationMember
  , installMigrationHead
  , activateMigrationHead
  , listObjectKeys
  , immutableKeyDigest
  , decodeHead
  , objectKeyFor
  , reviewKey
  , scopeKey
  , journalKey
  )
where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.MVar
import Control.Exception (IOException, bracket, catch, finally, try)
import Control.Monad (forM, forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Kind (Type)
import Data.List (isPrefixOf, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hTryLock, hUnlock)
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Digest
import Nagare.Inventory.Store.Counters
import Nagare.Inventory.Store.FileIO (atomicWrite, readPrivateFile, syncDirectory, syncFile)
import Nagare.Inventory.Store.Manifest
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Directory
import System.Environment (lookupEnv)
import System.FilePath
import System.IO
import System.IO.Error (isAlreadyExistsError, isAlreadyInUseError, isDoesNotExistError)
import System.IO.Temp (withTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, isDirectory, isRegularFile, setFileMode)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Unistd (fileSynchronise)

data StoreError
  = StoreIoError !Text
  | StoreInvalidPath !FilePath
  | StoreInvalidObject !FilePath !Text
  | StoreObjectConflict !FilePath
  | StoreConditionFailed !Text
  | StoreBusy
  | StoreReentry
  | StoreCredentialsUnavailable !Text
  | StoreAuthRequired
  deriving stock (Eq, Show)

data StoreSnapshot = StoreSnapshot
  { storeSnapshotHead :: !HeadManifest
  , storeSnapshotReviewDigests :: !(Set ContentDigest)
  }
  deriving stock (Eq, Show, Generic)

data MemoryState = MemoryState
  { memoryObjects :: !(Map FilePath ByteString)
  }

data Backend
  = FilesystemBackend !FilePath !(MVar ())
  | MemoryBackend !(MVar MemoryState) !(MVar ()) !(MVar ())
  | ObjectBackend !ObjectOps !Text !(Maybe FilePath) !(Maybe FilePath) !(MVar ()) !(MVar ())

-- | A backend and the counters of the operations made through it (EP-212).
data InventoryStore = InventoryStore !Backend !StoreCounters

newtype LockedStore (s :: Type) = LockedStore InventoryStore

lockedStore :: LockedStore s -> InventoryStore
lockedStore (LockedStore store) = store

openFilesystemStore :: FilePath -> IO (Either StoreError InventoryStore)
openFilesystemStore root = ioResult $ do
  exists <- doesPathExist root
  when exists $ do
    linked <- pathIsSymbolicLink root
    when linked (ioError (userError "inventory store root is a symlink"))
    status <- getFileStatus root
    unless (isDirectory status) (ioError (userError "inventory store root is not a directory"))
  createDirectoryIfMissing True root
  setFileMode root 0o700
  guardVar <- newMVar ()
  opened "filesystem" (FilesystemBackend root guardVar)

-- | Open an existing catalogue for status without creating files or changing
-- permissions. Missing history is an explicit absence, never an empty head.
openFilesystemStoreReadOnly :: FilePath -> IO (Either StoreError InventoryStore)
openFilesystemStoreReadOnly root = do
  exists <- doesPathExist root
  if not exists
    then pure (Left (StoreConditionFailed "inventory store is not initialized"))
    else ioResult $ do
      linked <- pathIsSymbolicLink root
      when linked (ioError (userError "inventory store root is a symlink"))
      status <- getFileStatus root
      unless (isDirectory status) (ioError (userError "inventory store root is not a directory"))
      guardVar <- newMVar ()
      opened "filesystem" (FilesystemBackend root guardVar)

newMemoryStore :: IO InventoryStore
newMemoryStore = (MemoryBackend <$> newMVar (MemoryState Map.empty) <*> newMVar () <*> newMVar ()) >>= opened "memory"

-- | A store over a backend, with fresh counters that count this open.
opened :: Text -> Backend -> IO InventoryStore
opened kind backend = do
  counters <- newStoreCounters kind
  countElapsed counters StoreOpen 0
  pure (InventoryStore backend counters)

-- | Count every remote operation a transport makes for this store.
countingObjectOps :: StoreCounters -> ObjectOps -> ObjectOps
countingObjectOps counters ops =
  ops
    { getObject = counted counters RemoteGet . getObject ops
    , getImmutableObject = counted counters RemoteGet . getImmutableObject ops
    , getObjects = counted counters RemoteGet . getObjects ops
    , putObject = \condition name bytes -> counted counters RemotePut (putObject ops condition name bytes)
    , listObjects = counted counters Listing . listObjects ops
    }

storeCounters :: InventoryStore -> StoreCounters
storeCounters (InventoryStore _ counters) = counters

-- | Count one store operation and its time.
countStore :: InventoryStore -> Counter -> IO a -> IO a
countStore store = counted (storeCounters store)

-- | Bind an object prefix to one context before exposing its store. A URL
-- accidentally reused for another context cannot inherit deletion authority.
newObjectStore :: ObjectOps -> ContextBinding -> Text -> Maybe FilePath -> IO (Either StoreError InventoryStore)
newObjectStore ops binding client cache = openObjectStore True ops binding client cache Nothing

newObjectStoreWithLock :: ObjectOps -> ContextBinding -> Text -> Maybe FilePath -> FilePath -> IO (Either StoreError InventoryStore)
newObjectStoreWithLock ops binding client cache lockPath = openObjectStore True ops binding client cache (Just lockPath)

openObjectStoreReadOnly :: ObjectOps -> ContextBinding -> Text -> Maybe FilePath -> IO (Either StoreError InventoryStore)
openObjectStoreReadOnly ops binding client cache = openObjectStore False ops binding client cache Nothing

openObjectStoreReadOnlyWithLock :: ObjectOps -> ContextBinding -> Text -> Maybe FilePath -> FilePath -> IO (Either StoreError InventoryStore)
openObjectStoreReadOnlyWithLock ops binding client cache lockPath = openObjectStore False ops binding client cache (Just lockPath)

openObjectStore :: Bool -> ObjectOps -> ContextBinding -> Text -> Maybe FilePath -> Maybe FilePath -> IO (Either StoreError InventoryStore)
openObjectStore mayInitialize transport binding client cache lockPath = case canonicalValue (object ["version" .= (1 :: Int), "binding" .= binding]) of
  Left reason -> pure (Left (StoreInvalidObject "format.json" reason))
  Right expected -> do
    counters <- newStoreCounters "object"
    let ops = countingObjectOps counters transport
        build = InventoryStore <$> (ObjectBackend ops client cache lockPath <$> newMVar () <*> newMVar ()) <*> pure counters
    counted counters StoreOpen (checkFormat ops expected build)
  where
    checkFormat ops expected build = do
      observed <- getObject ops (ObjectName "format.json")
      case observed of
        GetUnknown reason -> pure (Left (StoreIoError reason))
        ObjectFound _ bytes
          | bytes == expected -> Right <$> build
          | otherwise -> pure (Left (StoreConditionFailed "inventory object prefix belongs to a different context or format"))
        ObjectAbsent
          | not mayInitialize ->
              pure (Left (StoreConditionFailed "inventory object prefix is not initialized"))
        ObjectAbsent -> do
          outcome <- putObject ops IfAbsent (ObjectName "format.json") expected
          case outcome of
            PutWritten _ -> Right <$> build
            PutPreconditionFailed -> do
              raced <- getObject ops (ObjectName "format.json")
              case raced of
                ObjectFound _ bytes | bytes == expected -> Right <$> build
                _ -> pure (Left (StoreConditionFailed "inventory object prefix format changed during open"))
            PutNoEffect reason -> pure (Left (StoreConditionFailed reason))
            PutUnknown reason -> pure (Left (StoreIoError reason))

storeClientIdentity :: InventoryStore -> Maybe Text
storeClientIdentity (InventoryStore (ObjectBackend _ client _ _ _ _) _) = Just client
storeClientIdentity _ = Nothing

storeRetryPause :: InventoryStore -> Maybe (Int -> IO ())
storeRetryPause (InventoryStore (ObjectBackend ops _ _ _ _ _) _) = Just (pauseBeforeRetry ops)
storeRetryPause _ = Nothing

inventoryStoreRoot :: InventoryStore -> Maybe FilePath
inventoryStoreRoot (InventoryStore (FilesystemBackend root _) _) = Just root
inventoryStoreRoot _ = Nothing

initializeStore :: InventoryStore -> ContextBinding -> Text -> IO (Either StoreError HeadManifest)
initializeStore store binding clientIdentity =
  readHead store >>= either (pure . Left) (initializeStoreFrom store binding clientIdentity)

-- | 'initializeStore' from a head the caller already read, without reading it
-- again. A new head is still written by compare-and-swap against absence.
initializeStoreFrom :: InventoryStore -> ContextBinding -> Text -> Maybe HeadManifest -> IO (Either StoreError HeadManifest)
initializeStoreFrom store binding clientIdentity existing =
  case existing of
    Just headValue
      | Just marker <- headMigration headValue ->
          pure (Left (StoreConditionFailed ("inventory store migrated to " <> migrationDestination marker <> "; reload the context shell")))
      | headBinding headValue == binding -> pure (Right headValue)
      | otherwise -> pure (Left (StoreConditionFailed "inventory store is bound to a different context or provider target"))
    Nothing -> do
      let initial = HeadManifest 1 0 0 binding clientIdentity Map.empty Map.empty Map.empty Map.empty Nothing Nothing Nothing Nothing Map.empty Nothing
      replaced <- replaceHeadIfGenerationMatches store Nothing initial
      pure (initial <$ replaced)

readHead :: InventoryStore -> IO (Either StoreError (Maybe HeadManifest))
readHead store = countStore store HeadRead $ do
  loaded <- readObject store "head.json"
  pure $ loaded >>= traverse decodeHead

-- | Identify a newer canonical head without interpreting its ownership or
-- executor fields. Only read-only status may use this result; mutations still
-- require the supported full decoder in 'readHead'.
inspectHeadSchema :: ByteString -> Either StoreError Int
inspectHeadSchema bytes = do
  value <- first (StoreInvalidObject "head.json" . T.pack) (eitherDecodeStrict' bytes)
  canonical <- first (StoreInvalidObject "head.json") (canonicalValue value)
  unless (canonical == bytes) (Left (StoreInvalidObject "head.json" "head manifest is not canonical"))
  version <-
    first
      (StoreInvalidObject "head.json" . T.pack)
      ( parseEither
          (withObject "HeadManifest" (.: "version"))
          value
      )
  unless (version >= (1 :: Int)) (Left (StoreInvalidObject "head.json" "invalid inventory head schema version"))
  pure version

decodeHead :: ByteString -> Either StoreError HeadManifest
decodeHead bytes = do
  headValue <- first (StoreInvalidObject "head.json" . T.pack) (eitherDecodeStrict' bytes)
  canonical <- first (StoreInvalidObject "head.json") (canonicalValue (toJSON headValue))
  unless (canonical == bytes) (Left (StoreInvalidObject "head.json" "head manifest is not canonical"))
  pure headValue

readStoreSnapshot :: InventoryStore -> IO (Either StoreError StoreSnapshot)
readStoreSnapshot store = do
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue) -> do
      keysResult <- listObjectKeys store
      pure $ do
        keys <- keysResult
        StoreSnapshot headValue . Set.fromList <$> traverse digestFromReviewKey (filter ("reviews/" `isPrefixOf`) keys)
  where
    digestFromReviewKey key =
      let token = T.pack (dropExtension (takeFileName key))
       in first (const (StoreInvalidObject key "review key does not contain a valid digest")) (mkContentDigest token)

-- | Execution already names its immutable review. Verify that publication
-- directly and retain the same fresh-head boundary, without listing unrelated
-- archive keys. The caller must still load/validate the complete review bundle.
readReviewSnapshot :: InventoryStore -> ContentDigest -> IO (Either StoreError StoreSnapshot)
readReviewSnapshot store digest = do
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue) -> readReviewSnapshotAt store headValue digest

-- | 'readReviewSnapshot' at a head the command already read (EP-212). The
-- review's publication is still read directly, never from the cache.
readReviewSnapshotAt :: InventoryStore -> HeadManifest -> ContentDigest -> IO (Either StoreError StoreSnapshot)
readReviewSnapshotAt store headValue digest = do
  let key = reviewKey digest
  -- Cached content proves integrity, not publication in this store. Never
  -- let a prepopulated local cache manufacture publication authority.
  loaded <- case store of
    (InventoryStore (ObjectBackend ops _ _ _ _ _) _) -> do
      result <- getObject ops (ObjectName (T.pack key))
      pure $ case result of
        ObjectFound _ bytes -> Right (Just bytes)
        ObjectAbsent -> Right Nothing
        GetUnknown reason -> Left (StoreIoError reason)
    _ -> readObject store key
  pure $ do
    bytes <- loaded >>= maybe (Left (StoreInvalidObject key "selected review is not published")) Right
    unless
      (contentDigest bytes == digest)
      (Left (StoreInvalidObject key "selected review digest mismatch"))
    pure (StoreSnapshot headValue (Set.singleton digest))

publishIfAbsent :: InventoryStore -> FilePath -> ByteString -> IO (Either StoreError ContentDigest)
publishIfAbsent store key bytes = withBackendGuard store $
  case checkedKey key of
    Left err -> pure (Left err)
    Right safeKey -> do
      active <- mutableHeadAllowed store
      case active of
        Left err -> pure (Left err)
        Right () -> publishChecked safeKey
  where
    -- The conditional create is the absence proof: try it first, and read
    -- back only when the store refuses it (EP-213). Equal bytes are an
    -- idempotent success; different bytes conflict. An unacknowledged write is
    -- already classified by read-back in the transport ('classifyPutReadback').
    publishChecked safeKey = do
      -- A member this context already read is in the verified digest cache;
      -- publishing it again costs nothing remote, as before EP-213.
      cached <- cachedImmutable store safeKey
      if cached == Just bytes then pure (Right (contentDigest bytes)) else createFirst safeKey
    createFirst safeKey = do
      written <- writeObjectUnlocked store False safeKey bytes
      case written of
        Right () -> pure (Right (contentDigest bytes))
        Left (StoreObjectConflict _) -> do
          existing <- readObjectUnlocked store safeKey
          pure $ case existing of
            Left err -> Left err
            Right (Just old) | old == bytes -> Right (contentDigest bytes)
            Right _ -> Left (StoreObjectConflict safeKey)
        Left err -> pure (Left err)

-- | The verified bytes of an immutable member in the local digest cache.
cachedImmutable :: InventoryStore -> FilePath -> IO (Maybe ByteString)
cachedImmutable (InventoryStore (ObjectBackend _ _ (Just root) _ _ _) counters) key
  | Just digest <- immutableKeyDigest key = do
      let path = root </> T.unpack (digestText digest)
      exists <- doesPathExist path
      loaded <- if exists then readVerifiedFile path else pure (Left (StoreInvalidPath path))
      case loaded of
        Right bytes | contentDigest bytes == digest -> Just bytes <$ countElapsed counters CachedGet 0
        _ -> pure Nothing
cachedImmutable _ _ = pure Nothing

readObject :: InventoryStore -> FilePath -> IO (Either StoreError (Maybe ByteString))
readObject store key = case checkedKey key of
  Left err -> pure (Left err)
  Right safeKey -> readObjectUnlocked store safeKey

-- | Read content-addressed members through the digest cache, at most eight
-- remote reads in flight. Every key must name its digest; a missing member or
-- a failed read returns 'Left' and never a partial map (EP-213).
--
-- The reads go in waves of eight, and a failed wave schedules no further
-- read. A wave makes the same reads whatever order its members finish in, so
-- the recovery model's store-call count stays deterministic under a fault.
readImmutableObjects :: InventoryStore -> [FilePath] -> IO (Either StoreError (Map FilePath ByteString))
readImmutableObjects store keys = case traverse member (Set.toAscList (Set.fromList keys)) of
  Left err -> pure (Left err)
  Right members -> waves Map.empty members
  where
    member key = do
      safeKey <- checkedKey key
      digest <- maybe (Left (StoreInvalidObject key "not a content-addressed member")) Right (immutableKeyDigest safeKey)
      pure (safeKey, digest)
    waves found [] = pure (Right found)
    waves found pending = do
      let (wave, rest) = splitAt immutableReadWidth pending
      loaded <- mapConcurrently readMember wave
      case sequence loaded of
        Left err -> pure (Left err)
        Right values -> waves (Map.union found (Map.fromList values)) rest
    readMember (key, digest) = do
      loaded <- readObjectUnlocked store key
      pure $ do
        bytes <- loaded >>= maybe (Left (StoreInvalidObject key "immutable member is missing")) Right
        unless (contentDigest bytes == digest) (Left (StoreInvalidObject key "immutable member digest mismatch"))
        pure (key, bytes)

-- | Every key's own result, read in the same waves of eight (EP-218), for a
-- caller that tells a missing member from an invalid one. Nothing stops early.
readImmutableObjectsEach :: InventoryStore -> [FilePath] -> IO (Map FilePath (Either StoreError (Maybe ByteString)))
readImmutableObjectsEach store keys = Map.fromList . concat <$> traverse wave (chunks (Set.toAscList (Set.fromList keys)))
  where
    chunks [] = []
    chunks pending = let (now, later) = splitAt immutableReadWidth pending in now : chunks later
    wave = mapConcurrently (\key -> (,) key <$> readObject store key)

-- | Like the journal batch's eight workers in "Nagare.Inventory.Store.Gogol".
immutableReadWidth :: Int
immutableReadWidth = 8

appendAtSequence :: InventoryStore -> Integer -> ByteString -> IO (Either StoreError ContentDigest)
appendAtSequence store sequenceNumber bytes
  | sequenceNumber < 0 = pure (Left (StoreConditionFailed "journal sequence must not be negative"))
  | otherwise = publishIfAbsent store (journalKey sequenceNumber) bytes

-- | The caller has already checked this head under the transaction writer
-- lock. Conditional creation handles a competing writer; the later head CAS
-- refuses stale sequence advancement. Avoid rereading head and checking the
-- known-absent event before each normal append.
appendAtObservedHead ::
  InventoryStore ->
  HeadManifest ->
  ByteString ->
  IO (Either StoreError ContentDigest)
appendAtObservedHead store headValue bytes
  | isJust (headMigration headValue) =
      pure (Left (StoreConditionFailed "inventory store has migrated; reload the context shell"))
  | otherwise = withBackendGuard store $ do
      let key = journalKey (headSequence headValue)
      written <- writeObjectUnlocked store False key bytes
      pure (contentDigest bytes <$ written)

-- | A command-local observation binds decoded authority to its exact provider
-- generation and store. No caller can manufacture it or apply it to another
-- store. Reuse is safe: conditional replacement rejects a stale observation.
data ObservedHead = ObservedHead !InventoryStore !(Maybe HeadManifest) !(Maybe Generation)

observedHeadManifest :: ObservedHead -> Maybe HeadManifest
observedHeadManifest (ObservedHead _ current _) = current

observeHead :: InventoryStore -> IO (Either StoreError ObservedHead)
observeHead store = countStore store HeadRead $ do
  observed <- case store of
    (InventoryStore (ObjectBackend ops _ _ _ _ _) _) -> do
      result <- getObject ops (ObjectName "head.json")
      pure $ case result of
        GetUnknown reason -> Left (StoreIoError reason)
        ObjectAbsent -> Right (Nothing, Nothing)
        ObjectFound generation bytes -> Right (Just bytes, Just generation)
    _ -> fmap (fmap (\bytes -> (bytes, Nothing))) (readObjectUnlocked store "head.json")
  pure $ do
    (bytes, generation) <- observed
    current <- traverse decodeHead bytes
    pure (ObservedHead store current generation)

replaceObservedHead :: ObservedHead -> HeadManifest -> IO (Either StoreError ())
replaceObservedHead observed@(ObservedHead store _ _) replacement = withBackendGuard store (replaceObservedHeadUnlocked observed replacement)

replaceHeadIfGenerationMatches :: InventoryStore -> Maybe Integer -> HeadManifest -> IO (Either StoreError ())
replaceHeadIfGenerationMatches store expected replacement = withBackendGuard store $ do
  observed <- observeHead store
  case observed of
    Left err -> pure (Left err)
    Right value
      | (headGeneration <$> observedHeadManifest value) /= expected ->
          pure (Left (StoreConditionFailed "inventory head generation changed"))
      | otherwise -> replaceObservedHeadUnlocked value replacement

replaceObservedHeadUnlocked :: ObservedHead -> HeadManifest -> IO (Either StoreError ())
replaceObservedHeadUnlocked (ObservedHead store current providerGeneration) replacement
  | maybe False (isJust . headMigration) current =
      pure (Left (StoreConditionFailed "inventory store has migrated; reload the context shell"))
  | headGeneration replacement /= maybe 0 ((+ 1) . headGeneration) current =
      pure (Left (StoreConditionFailed "replacement head generation is not the next generation"))
  | otherwise = case canonicalValue (toJSON replacement) of
      Left err -> pure (Left (StoreInvalidObject "head.json" err))
      Right bytes -> case store of
        (InventoryStore (ObjectBackend ops _ _ _ _ _) _) -> do
          outcome <-
            putObject
              ops
              (maybe IfAbsent IfGenerationMatches providerGeneration)
              (ObjectName "head.json")
              bytes
          pure $ case outcome of
            PutWritten _ -> Right ()
            PutPreconditionFailed -> Left (StoreConditionFailed "inventory head generation changed")
            PutNoEffect reason -> Left (StoreConditionFailed reason)
            PutUnknown reason -> Left (StoreIoError reason)
        _ -> do
          -- Local stores have no provider CAS; recheck under the backend guard.
          latest <- readObjectUnlocked store "head.json"
          case latest >>= traverse decodeHead of
            Left err -> pure (Left err)
            Right actual | actual == current -> writeObjectUnlocked store True "head.json" bytes
            Right _ -> pure (Left (StoreConditionFailed "inventory head generation changed"))

mutableHeadAllowed :: InventoryStore -> IO (Either StoreError ())
mutableHeadAllowed store = do
  existing <- readObjectUnlocked store "head.json"
  pure $ case existing >>= traverse decodeHead of
    Left err -> Left err
    Right (Just headValue)
      | Just marker <- headMigration headValue ->
          Left (StoreConditionFailed ("inventory store migrated to " <> migrationDestination marker <> "; reload the context shell"))
    Right _ -> Right ()

replaceObjectHead :: ObjectOps -> Maybe HeadManifest -> ByteString -> IO (Either StoreError ())
replaceObjectHead ops previous bytes = do
  current <- getObject ops (ObjectName "head.json")
  case current of
    GetUnknown reason -> pure (Left (StoreIoError reason))
    ObjectAbsent
      | previous /= Nothing ->
          pure (Left (StoreConditionFailed "inventory head disappeared before conditional write"))
    ObjectFound _ _
      | previous == Nothing ->
          pure (Left (StoreConditionFailed "inventory head appeared before conditional write"))
    ObjectFound _ old
      | Just prior <- previous
      , decodeHead old /= Right prior ->
          pure (Left (StoreConditionFailed "inventory head changed before conditional write"))
    _ -> do
      let condition = case current of
            ObjectAbsent -> IfAbsent
            ObjectFound generation _ -> IfGenerationMatches generation
      outcome <- putObject ops condition (ObjectName "head.json") bytes
      pure $ case outcome of
        PutWritten _ -> Right ()
        PutPreconditionFailed -> Left (StoreConditionFailed "inventory head generation changed")
        PutNoEffect reason -> Left (StoreConditionFailed reason)
        PutUnknown reason -> Left (StoreIoError reason)

withProcessLock :: forall a. InventoryStore -> (forall s. LockedStore s -> IO a) -> IO (Either StoreError a)
withProcessLock store action = do
  inherited <- lookupEnv "NAGARE_INVENTORY_TRANSACTION"
  if maybe False (not . null) inherited
    then pure (Left StoreReentry)
    else case store of
      (InventoryStore (MemoryBackend _ _ processLock) _) ->
        maskMVar processLock (Right <$> action (LockedStore store))
      (InventoryStore (ObjectBackend _ _ _ lockPath _ processLock) _) ->
        maskMVar processLock $ case lockPath of
          Nothing -> Right <$> action (LockedStore store)
          Just path -> fileLock path
      (InventoryStore (FilesystemBackend root _) _) -> do
        createDirectoryIfMissing True root
        fileLock (root </> "process.lock")
  where
    fileLock path = do
      createDirectoryIfMissing True (takeDirectory path)
      attempted <- try $ bracket (openFile path AppendMode) hClose $ \handle -> do
        setFileMode path 0o600
        acquired <- hTryLock handle ExclusiveLock
        if not acquired
          then pure (Left StoreBusy)
          else (Right <$> action (LockedStore store)) `finally` hUnlock handle
      pure $ case (attempted :: Either IOException (Either StoreError a)) of
        Left err | isAlreadyInUseError err -> Left StoreBusy
        Left err -> Left (StoreIoError (T.pack (show err)))
        Right result -> result
    maskMVar lock work = do
      acquired <- tryTakeMVar lock
      case acquired of
        Nothing -> pure (Left StoreBusy)
        Just () -> work `finally` putMVar lock ()

exportStore :: LockedStore s -> FilePath -> IO (Either StoreError ())
exportStore locked output = do
  let store = lockedStore locked
  keysResult <- listObjectKeys store
  case keysResult of
    Left err -> pure (Left err)
    Right keys -> do
      membersResult <- traverse (\key -> fmap ((key,) <$>) (readObject store key)) keys
      case sequence membersResult >>= traverse requireMember of
        Left err -> pure (Left err)
        Right members -> ioResult $ do
          exists <- doesPathExist output
          when exists (ioError (userError "backup output already exists"))
          let parent = takeDirectory output
          createDirectoryIfMissing True parent
          withTempDirectory parent ".inventory-backup-" $ \staging -> do
            setFileMode staging 0o700
            mapM_ (writeMember staging) members
            let manifestValue = object ["version" .= (1 :: Int), "members" .= [object ["path" .= key, "digest" .= contentDigest bytes] | (key, bytes) <- members]]
                manifestBytes = either (error . T.unpack) id (canonicalValue manifestValue)
            atomicWrite (staging </> "backup.json") manifestBytes
            renameDirectory staging output
            syncDirectory parent
  where
    requireMember (_, Nothing) = Left (StoreConditionFailed "store changed while export was reading it")
    requireMember (key, Just bytes) = Right (key, bytes)
    writeMember staging (key, bytes) = atomicWrite (staging </> key) bytes

restoreStore :: InventoryStore -> FilePath -> IO (Either StoreError ())
restoreStore store backup = restoreStoreChecked store backup Nothing

-- | Recheck the destination binding against the verified backup member
-- immediately before writing. A changed backup cannot bypass command review.
restoreStoreFor :: InventoryStore -> FilePath -> ContextBinding -> IO (Either StoreError ())
restoreStoreFor store backup binding = restoreStoreChecked store backup (Just binding)

restoreStoreChecked :: InventoryStore -> FilePath -> Maybe ContextBinding -> IO (Either StoreError ())
restoreStoreChecked store backup expectedBinding = withBackendGuard store $ do
  currentResult <- listObjectKeysUnlocked store
  case currentResult of
    Left err -> pure (Left err)
    Right current | not (null current) -> pure (Left (StoreConditionFailed "restore requires an empty inventory store"))
    Right _ -> do
      manifestResult <- readVerifiedFile (backup </> "backup.json")
      case manifestResult >>= decodeBackupManifest of
        Left err -> pure (Left err)
        Right members -> do
          loaded <- traverse (loadMember backup) members
          case sequence loaded of
            Left err -> pure (Left err)
            Right values -> case expectedBinding of
              Nothing -> writeValues values
              Just binding -> case lookup "head.json" values of
                Nothing -> pure (Left (StoreConditionFailed "backup has no inventory head"))
                Just bytes -> case decodeHead bytes of
                  Left err -> pure (Left err)
                  Right headValue
                    | headBinding headValue /= binding ->
                        pure (Left (StoreConditionFailed "backup belongs to a different context or provider project"))
                    | isJust (headMigration headValue) ->
                        pure (Left (StoreConditionFailed "backup is a migrated source"))
                    | otherwise -> writeValues values
  where
    writeValues values = do
      writes <- traverse (uncurry (writeObjectUnlocked store False)) values
      pure (void (sequence writes))

publishMigrationMember :: InventoryStore -> FilePath -> ByteString -> IO (Either StoreError ())
publishMigrationMember destination key bytes = withBackendGuard destination $ do
  present <- readObjectUnlocked destination key
  case present of
    Left err -> pure (Left err)
    Right (Just actual) | actual == bytes -> pure (Right ())
    Right (Just _) -> pure (Left (StoreObjectConflict key))
    Right Nothing -> writeObjectUnlocked destination False key bytes

installMigrationHead :: InventoryStore -> Text -> Text -> ByteString -> IO (Either StoreError ())
installMigrationHead destination sourceLabel label bytes = withBackendGuard destination $ do
  current <- readObjectUnlocked destination "head.json"
  case current >>= traverse decodeHead of
    Left err -> pure (Left err)
    Right oldHead -> case decodeHead bytes of
      Left err -> pure (Left err)
      Right active -> case canonicalValue
        ( toJSON
            ( active
                { headMigration = Just (MigrationTombstone sourceLabel (contentDigest bytes))
                }
            )
        ) of
        Left err -> pure (Left (StoreInvalidObject "head.json" err))
        Right staged -> case current of
          Right (Just oldBytes) | oldBytes == staged -> pure (Right ())
          _ -> case oldHead of
            Just old
              | Just marker <- headMigration old
              , migrationDestination marker == label ->
                  pure (Left (StoreConditionFailed "destination head already points to its own location"))
            Just old
              | Just marker <- headMigration old
              , migrationDestination marker == sourceLabel ->
                  writeHead (Just old) staged
            Just _ -> pure (Left (StoreConditionFailed "destination inventory head is already active or points elsewhere"))
            Nothing -> writeHead Nothing staged
  where
    writeHead oldHead staged = case destination of
      (InventoryStore (ObjectBackend ops _ _ _ _ _) _) -> replaceObjectHead ops oldHead staged
      _ -> writeObjectUnlocked destination (isJust oldHead) "head.json" staged

activateMigrationHead :: InventoryStore -> Text -> ContentDigest -> IO (Either StoreError ())
activateMigrationHead destination sourceLabel expectedDigest = withBackendGuard destination $ do
  current <- readObjectUnlocked destination "head.json"
  case current >>= traverse decodeHead of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "destination inventory head is absent"))
    Right (Just old) -> case headMigration old of
      Nothing ->
        pure $
          if maybe False ((== expectedDigest) . contentDigest) (either (const Nothing) id current)
            then Right ()
            else Left (StoreConditionFailed "destination inventory head differs")
      Just marker
        | migrationDestination marker == sourceLabel
            && migrationHeadDigest marker == expectedDigest ->
            case canonicalValue (toJSON (old {headMigration = Nothing})) of
              Left err -> pure (Left (StoreInvalidObject "head.json" err))
              Right active
                | contentDigest active /= expectedDigest ->
                    pure (Left (StoreConditionFailed "staged destination head differs"))
              Right active -> case destination of
                (InventoryStore (ObjectBackend ops _ _ _ _ _) _) -> replaceObjectHead ops (Just old) active
                _ -> writeObjectUnlocked destination True "head.json" active
      _ -> pure (Left (StoreConditionFailed "destination head migration marker differs"))

decodeBackupManifest :: ByteString -> Either StoreError [(FilePath, ContentDigest)]
decodeBackupManifest bytes = do
  value <- first (StoreInvalidObject "backup.json" . T.pack) (eitherDecodeStrict' bytes)
  canonical <- first (StoreInvalidObject "backup.json") (canonicalValue value)
  unless (canonical == bytes) (Left (StoreInvalidObject "backup.json" "backup manifest is not canonical"))
  members <- first (StoreInvalidObject "backup.json" . T.pack) (parseEither parser value)
  let keys = map fst members
  unless
    (length keys == Set.size (Set.fromList keys))
    (Left (StoreInvalidObject "backup.json" "duplicate backup members"))
  unless
    ("head.json" `elem` keys)
    (Left (StoreInvalidObject "backup.json" "missing inventory head"))
  pure members
  where
    parser = withObject "backup manifest" $ \o -> do
      version <- o .: "version"
      unless (version == (1 :: Int)) (fail "unsupported backup schema")
      o .: "members" >>= traverse (withObject "backup member" (\v -> (,) <$> v .: "path" <*> v .: "digest"))

loadMember :: FilePath -> (FilePath, ContentDigest) -> IO (Either StoreError (FilePath, ByteString))
loadMember backup (key, expected) = case checkedKey key of
  Left err -> pure (Left err)
  Right safeKey -> do
    loaded <- readVerifiedFile (backup </> safeKey)
    pure $ do
      bytes <- loaded
      unless (contentDigest bytes == expected) (Left (StoreInvalidObject safeKey "backup member digest mismatch"))
      pure (safeKey, bytes)

objectKeyFor :: Text -> ContentDigest -> FilePath
objectKeyFor category digest = T.unpack category </> T.unpack (digestText digest) <.> "json"

reviewKey :: ContentDigest -> FilePath
reviewKey = objectKeyFor "reviews"

scopeKey :: ContentDigest -> FilePath
scopeKey = objectKeyFor "scopes"

journalKey :: Integer -> FilePath
journalKey sequenceNumber = "journal" </> pad 20 (show sequenceNumber) <.> "json"
  where
    pad width value = replicate (max 0 (width - length value)) '0' <> value

withBackendGuard :: InventoryStore -> IO (Either StoreError a) -> IO (Either StoreError a)
withBackendGuard (InventoryStore (FilesystemBackend _ guardVar) _) action = withMVar guardVar (const action)
withBackendGuard (InventoryStore (MemoryBackend _ guardVar _) _) action = withMVar guardVar (const action)
withBackendGuard (InventoryStore (ObjectBackend _ _ _ _ guardVar _) _) action = withMVar guardVar (const action)

-- | Remember reconstructed observation data in the optional private local cache.
-- The content hash names the entry; accepted declarations must still bind it.
-- This never publishes a remote object or supplies review-publication authority.
-- Cache failure is harmless: callers retain the original compatibility reader.
cacheObservationBytes :: InventoryStore -> ByteString -> IO ()
cacheObservationBytes (InventoryStore (ObjectBackend _ _ (Just root) _ _ _) _) bytes =
  void (ioResult (atomicWrite (root </> T.unpack (digestText (contentDigest bytes))) bytes))
cacheObservationBytes _ _ = pure ()

readObjectUnlocked :: InventoryStore -> FilePath -> IO (Either StoreError (Maybe ByteString))
readObjectUnlocked (InventoryStore (MemoryBackend stateVar _ _) _) key =
  Right . Map.lookup key . memoryObjects <$> readMVar stateVar
readObjectUnlocked (InventoryStore (FilesystemBackend root _) _) key = do
  let path = root </> key
  exists <- doesPathExist path
  if not exists then pure (Right Nothing) else fmap Just <$> readVerifiedFile path
readObjectUnlocked (InventoryStore (ObjectBackend ops _ cache _ _ _) counters) key = do
  let expected = immutableKeyDigest key
      cachedPath = case (cache, expected) of
        (Just root, Just digest) -> Just (root </> T.unpack (digestText digest))
        _ -> Nothing
  cached <- case cachedPath of
    Nothing -> pure Nothing
    Just path -> do
      exists <- doesPathExist path
      if not exists
        then pure Nothing
        else do
          loaded <- readVerifiedFile path
          pure $ case (loaded, expected) of
            (Right bytes, Just digest) | contentDigest bytes == digest -> Just bytes
            _ -> Nothing
  case cached of
    Just bytes -> Right (Just bytes) <$ countElapsed counters CachedGet 0
    Nothing -> case expected of
      -- A content-addressed member is verified by its digest: one media
      -- request, no generation (EP-213). A mismatch is never cached.
      Just digest -> do
        observed <- getImmutableObject ops (ObjectName (T.pack key))
        case observed of
          ImmutableMissing -> pure (Right Nothing)
          ImmutableUnknown reason -> pure (Left (StoreIoError reason))
          ImmutableFound bytes
            | contentDigest bytes /= digest ->
                pure (Left (StoreInvalidObject key "remote immutable member digest mismatch"))
            | otherwise -> do
                case cachedPath of
                  Nothing -> pure ()
                  Just path -> void (ioResult (atomicWrite path bytes))
                pure (Right (Just bytes))
      Nothing -> do
        observed <- getObject ops (ObjectName (T.pack key))
        pure $ case observed of
          ObjectAbsent -> Right Nothing
          GetUnknown reason -> Left (StoreIoError reason)
          ObjectFound _ bytes -> Right (Just bytes)

-- | Journal members are immutable once appended. Read the committed prefix in
-- one object-store transfer, then require every name bound by the head. The
-- journal decoder still checks sequence numbers and the complete hash chain.
readJournalPrefix :: InventoryStore -> Integer -> IO (Either StoreError [ByteString])
readJournalPrefix _ count | count < 0 = pure (Left (StoreConditionFailed "negative journal length"))
readJournalPrefix _ 0 = pure (Right [])
readJournalPrefix store@(InventoryStore backend counters) count = case backend of
  ObjectBackend ops _ (Just root) _ _ _ -> readJournalCached ops counters root count
  ObjectBackend ops _ Nothing _ _ _ -> readJournalBatch ops count
  _ -> do
    loaded <- traverse (readObject store . journalKey) [0 .. count - 1]
    pure $ do
      values <- sequence loaded
      traverse (maybe (Left (StoreInvalidObject "journal" "committed journal event is missing")) Right) values

readJournalBatch :: ObjectOps -> Integer -> IO (Either StoreError [ByteString])
readJournalBatch ops count = do
  loaded <- getObjects ops (ObjectName "journal")
  pure $ do
    objects <- first StoreIoError loaded
    traverse
      ( \sequenceNumber ->
          let key = journalKey sequenceNumber
           in maybe (Left (StoreInvalidObject key "committed journal event is missing")) Right (Map.lookup (ObjectName (T.pack key)) objects)
      )
      [0 .. count - 1]

-- | EP-217: events are written once, so a command serves the contiguous
-- prefix it cached earlier and fetches only the events after it. One read of
-- the newest cached event binds the copy to the store: rewriting an older
-- event under a valid chain changes that event. Callers still validate the
-- whole chain. An empty cache, a long tail or a differing anchor reads the
-- whole prefix as before and refills the copy.
readJournalCached :: ObjectOps -> StoreCounters -> FilePath -> Integer -> IO (Either StoreError [ByteString])
readJournalCached ops counters root count = do
  cached <- cachedPrefix 0
  anchored <- case reverse cached of
    [] -> pure False
    newest : _ -> (== ImmutableFound newest) <$> getImmutableObject ops (journalName (fromIntegral (length cached) - 1))
  let known = if anchored then cached else []
      next = fromIntegral (length known)
  fetched <-
    if not anchored || count - next > journalTailLimit
      then fmap (drop (length known)) <$> readJournalBatch ops count
      else fetchTail [next .. count - 1]
  case fetched of
    Left err -> pure (Left err)
    Right events -> do
      forM_ (zip [next ..] events) $ \(sequenceNumber, bytes) -> void (ioResult (atomicWrite (cachedEvent sequenceNumber) bytes))
      pure (Right (known <> events))
  where
    cachedEvent sequenceNumber = root </> "journal" </> takeFileName (journalKey sequenceNumber)
    journalName = ObjectName . T.pack . journalKey
    cachedPrefix sequenceNumber
      | sequenceNumber >= count = pure []
      | otherwise = do
          exists <- doesPathExist (cachedEvent sequenceNumber)
          loaded <- if exists then readVerifiedFile (cachedEvent sequenceNumber) else pure (Left (StoreInvalidPath ""))
          case loaded of
            Right bytes -> countElapsed counters CachedGet 0 >> (bytes :) <$> cachedPrefix (sequenceNumber + 1)
            Left _ -> pure []
    fetchTail [] = pure (Right [])
    fetchTail pending = do
      let (wave, rest) = splitAt immutableReadWidth pending
      loaded <- mapConcurrently fetchOne wave
      case sequence loaded of
        Left err -> pure (Left err)
        Right events -> fmap (events <>) <$> fetchTail rest
    fetchOne sequenceNumber = do
      observed <- getImmutableObject ops (journalName sequenceNumber)
      pure $ case observed of
        ImmutableFound bytes -> Right bytes
        ImmutableMissing -> Left (StoreInvalidObject (journalKey sequenceNumber) "committed journal event is missing")
        ImmutableUnknown reason -> Left (StoreIoError reason)

-- | The longest tail read event by event; a longer one uses the batch.
journalTailLimit :: Integer
journalTailLimit = 64

immutableKeyDigest :: FilePath -> Maybe ContentDigest
immutableKeyDigest key = case splitDirectories key of
  [category, filename]
    | category `elem` ["scopes", "reviews", "native", "objects"]
    , takeExtension filename == ".json" ->
        either (const Nothing) Just (mkContentDigest (T.pack (dropExtension filename)))
  _ -> Nothing

readVerifiedFile :: FilePath -> IO (Either StoreError ByteString)
readVerifiedFile path = first (StoreInvalidObject path . T.pack . show) <$> readPrivateFile path

writeObjectUnlocked :: InventoryStore -> Bool -> FilePath -> ByteString -> IO (Either StoreError ())
writeObjectUnlocked (InventoryStore (MemoryBackend stateVar _ _) _) replace key bytes = do
  modifyMVar stateVar $ \state ->
    let objects = memoryObjects state
     in if not replace && Map.member key objects
          then pure (state, Left (StoreObjectConflict key))
          else pure (state {memoryObjects = Map.insert key bytes objects}, Right ())
writeObjectUnlocked (InventoryStore (FilesystemBackend root _) _) replace key bytes = do
  let path = root </> key
  exists <- doesPathExist path
  if exists && not replace
    then pure (Left (StoreObjectConflict key))
    else ioResult (atomicWrite path bytes)
writeObjectUnlocked (InventoryStore (ObjectBackend ops _ _ _ _ _) _) replace key bytes
  | replace = pure (Left (StoreConditionFailed "object replacement requires an explicit generation"))
  | otherwise = do
      outcome <- putObject ops IfAbsent (ObjectName (T.pack key)) bytes
      pure $ case outcome of
        PutWritten _ -> Right ()
        PutPreconditionFailed -> Left (StoreObjectConflict key)
        PutNoEffect reason -> Left (StoreConditionFailed reason)
        PutUnknown reason -> Left (StoreIoError reason)

listObjectKeys :: InventoryStore -> IO (Either StoreError [FilePath])
listObjectKeys store = withBackendGuard store (listObjectKeysUnlocked store)

listObjectKeysUnlocked :: InventoryStore -> IO (Either StoreError [FilePath])
listObjectKeysUnlocked (InventoryStore (MemoryBackend stateVar _ _) counters) =
  counted counters Listing (Right . sort . Map.keys . memoryObjects <$> readMVar stateVar)
listObjectKeysUnlocked (InventoryStore (ObjectBackend ops _ _ _ _ _) _) = do
  listed <- listObjects ops (ObjectName "")
  pure (first StoreIoError (sort . map (\(ObjectName name) -> T.unpack name) <$> listed))
listObjectKeysUnlocked (InventoryStore (FilesystemBackend root _) counters) = counted counters Listing (ioResult (sort <$> walk root ""))
  where
    walk base relative = do
      let directory = if null relative then base else base </> relative
      entries <- listDirectory directory
      fmap concat $ forM entries $ \entry -> do
        let rel = if null relative then entry else relative </> entry
            path = base </> rel
        if rel == "process.lock" || ".inventory-object" `isPrefixOf` entry
          then pure []
          else do
            linked <- pathIsSymbolicLink path
            when linked (ioError (userError ("store member is a symlink: " <> rel)))
            status <- getFileStatus path
            if isDirectory status then walk base rel else if isRegularFile status then pure [rel] else ioError (userError ("invalid store member: " <> rel))

checkedKey :: FilePath -> Either StoreError FilePath
checkedKey key
  | isAbsolute key = Left (StoreInvalidPath key)
  | null key = Left (StoreInvalidPath key)
  | any (`elem` ["", ".", ".."]) (splitDirectories key) = Left (StoreInvalidPath key)
  | normalise key /= key = Left (StoreInvalidPath key)
  | otherwise = Right key

ioResult :: forall a. IO a -> IO (Either StoreError a)
ioResult action = do
  attempted <- try action
  pure $ first (StoreIoError . T.pack . show) (attempted :: Either IOException a)
