{-# LANGUAGE RankNTypes #-}

-- | Conditional-write inventory storage with filesystem and in-memory backends.
module Nagare.Inventory.Store
  ( InventoryStore
  , LockedStore
  , StoreError (..)
  , ScopeRevision (..)
  , ExecutorClaim (..)
  , MigrationTombstone (..)
  , HeadManifest (..)
  , StoreSnapshot (..)
  , openFilesystemStore
  , openFilesystemStoreReadOnly
  , newMemoryStore
  , newObjectStore
  , newObjectStoreWithLock
  , openObjectStoreReadOnly
  , openObjectStoreReadOnlyWithLock
  , storeClientIdentity
  , inventoryStoreRoot
  , initializeStore
  , readHead
  , readStoreSnapshot
  , publishIfAbsent
  , readObject
  , appendAtSequence
  , replaceHeadIfGenerationMatches
  , withProcessLock
  , lockedStore
  , exportStore
  , restoreStore
  , migrateStore
  , objectKeyFor
  , reviewKey
  , scopeKey
  , journalKey
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, bracket, catch, finally, try)
import Control.Monad (forM)
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
  deriving stock (Eq, Show)

data ScopeRevision = ScopeRevision
  { revisionGeneration :: !ScopeGeneration
  , revisionDigest :: !ContentDigest
  }
  deriving stock (Eq, Ord, Show, Generic)

data ExecutorClaim = ExecutorClaim
  { claimTransaction :: !Text
  , claimClientIdentity :: !Text
  , claimEpoch :: !Integer
  , claimTimestamp :: !Text
  }
  deriving stock (Eq, Show, Generic)

data MigrationTombstone = MigrationTombstone
  { migrationDestination :: !Text
  , migrationHeadDigest :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

data HeadManifest = HeadManifest
  { headSchemaVersion :: !Int
  , headGeneration :: !Integer
  , headSequence :: !Integer
  , headBinding :: !ContextBinding
  , headClientIdentity :: !Text
  , headAccepted :: !(Map ScopeId ScopeRevision)
  , headConverged :: !(Map ScopeId ScopeRevision)
  , headActiveTransaction :: !(Maybe Text)
  , headExecutorClaim :: !(Maybe ExecutorClaim)
  , headMigration :: !(Maybe MigrationTombstone)
  }
  deriving stock (Eq, Show, Generic)

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

newtype InventoryStore = InventoryStore Backend

newtype LockedStore (s :: Type) = LockedStore InventoryStore

lockedStore :: LockedStore s -> InventoryStore
lockedStore (LockedStore store) = store

instance ToJSON ScopeRevision where
  toJSON revision = object ["generation" .= revisionGeneration revision, "digest" .= revisionDigest revision]

instance FromJSON ScopeRevision where
  parseJSON = withObject "ScopeRevision" $ \o -> ScopeRevision <$> o .: "generation" <*> o .: "digest"

instance ToJSON ExecutorClaim where
  toJSON claim =
    object
      [ "transaction" .= claimTransaction claim
      , "clientIdentity" .= claimClientIdentity claim
      , "epoch" .= claimEpoch claim
      , "timestamp" .= claimTimestamp claim
      ]

instance FromJSON ExecutorClaim where
  parseJSON = withObject "ExecutorClaim" $ \o ->
    ExecutorClaim <$> o .: "transaction" <*> o .: "clientIdentity" <*> o .: "epoch" <*> o .: "timestamp"

instance ToJSON MigrationTombstone where
  toJSON marker = object ["destination" .= migrationDestination marker, "headDigest" .= migrationHeadDigest marker]

instance FromJSON MigrationTombstone where
  parseJSON = withObject "MigrationTombstone" $ \o ->
    MigrationTombstone <$> o .: "destination" <*> o .: "headDigest"

instance ToJSON HeadManifest where
  toJSON headValue =
    object
      ([ "version" .= headSchemaVersion headValue
      , "generation" .= headGeneration headValue
      , "sequence" .= headSequence headValue
      , "binding" .= headBinding headValue
      , "clientIdentity" .= headClientIdentity headValue
      , "accepted" .= revisionsValue (headAccepted headValue)
      , "converged" .= revisionsValue (headConverged headValue)
      , "activeTransaction" .= headActiveTransaction headValue
      , "executorClaim" .= headExecutorClaim headValue
      ] <> maybe [] (\marker -> ["migration" .= marker]) (headMigration headValue))
    where
      revisionsValue revisions = [object ["scope" .= scope, "revision" .= revision] | (scope, revision) <- Map.toAscList revisions]

instance FromJSON HeadManifest where
  parseJSON = withObject "HeadManifest" $ \o -> do
    let allowed = ["version", "generation", "sequence", "binding", "clientIdentity", "accepted", "converged", "activeTransaction", "executorClaim", "migration"]
    unless (all (`elem` allowed) (KM.keys o)) (fail "head manifest has an unknown field")
    version <- o .: "version"
    unless (version == 1) (fail "unsupported inventory head schema version")
    generation <- o .: "generation"
    sequenceNumber <- o .: "sequence"
    unless (generation >= 0 && sequenceNumber >= 0) (fail "head counters must not be negative")
    accepted <- parseRevisions =<< o .: "accepted"
    converged <- parseRevisions =<< o .: "converged"
    unless (all (`Map.member` accepted) (Map.keys converged)) (fail "converged scopes must also be accepted")
    HeadManifest version generation sequenceNumber
      <$> o .: "binding"
      <*> o .: "clientIdentity"
      <*> pure accepted
      <*> pure converged
      <*> o .: "activeTransaction"
      <*> o .: "executorClaim"
      <*> o .:? "migration"
    where
      parseRevisions values = do
        revisions <- traverse (withObject "scope revision" (\v -> (,) <$> v .: "scope" <*> v .: "revision")) values
        unless (length revisions == Map.size (Map.fromList revisions)) (fail "duplicate scope revision")
        pure (Map.fromList revisions)

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
  pure (InventoryStore (FilesystemBackend root guardVar))

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
      pure (InventoryStore (FilesystemBackend root guardVar))

newMemoryStore :: IO InventoryStore
newMemoryStore = InventoryStore <$> (MemoryBackend <$> newMVar (MemoryState Map.empty) <*> newMVar () <*> newMVar ())

-- | Bind an object prefix to one context before exposing its store. A URL
-- accidentally reused for another context cannot inherit deletion authority.
newObjectStore :: ObjectOps -> ContextBinding -> Text -> Maybe FilePath -> IO (Either StoreError InventoryStore)
newObjectStore ops binding client cache = openObjectStore True ops binding client cache Nothing

newObjectStoreWithLock :: ObjectOps -> ContextBinding -> Text -> Maybe FilePath -> FilePath -> IO (Either StoreError InventoryStore)
newObjectStoreWithLock ops binding client cache lockPath = openObjectStore True ops binding client cache (Just lockPath)

openObjectStoreReadOnly :: ObjectOps -> ContextBinding -> Text -> Maybe FilePath -> IO (Either StoreError InventoryStore)
openObjectStoreReadOnly ops binding client cache = openObjectStore False ops binding client cache Nothing

openObjectStoreReadOnlyWithLock :: ObjectOps -> ContextBinding -> Text -> Maybe FilePath -> FilePath -> IO (Either StoreError InventoryStore)
openObjectStoreReadOnlyWithLock ops binding client cache lockPath =
  openObjectStore False ops binding client cache (Just lockPath)

openObjectStore :: Bool -> ObjectOps -> ContextBinding -> Text -> Maybe FilePath -> Maybe FilePath -> IO (Either StoreError InventoryStore)
openObjectStore mayInitialize ops binding client cache lockPath = case canonicalValue (object
  ["version" .= (1 :: Int), "binding" .= binding]) of
  Left reason -> pure (Left (StoreInvalidObject "format.json" reason))
  Right expected -> do
    observed <- getObject ops (ObjectName "format.json")
    case observed of
      GetUnknown reason -> pure (Left (StoreIoError reason))
      ObjectFound _ bytes
        | bytes == expected -> Right <$> build
        | otherwise -> pure (Left (StoreConditionFailed "inventory object prefix belongs to a different context or format"))
      ObjectAbsent | not mayInitialize ->
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
  where
    build = InventoryStore <$> (ObjectBackend ops client cache lockPath <$> newMVar () <*> newMVar ())

storeClientIdentity :: InventoryStore -> Maybe Text
storeClientIdentity (InventoryStore (ObjectBackend _ client _ _ _ _)) = Just client
storeClientIdentity _ = Nothing

inventoryStoreRoot :: InventoryStore -> Maybe FilePath
inventoryStoreRoot (InventoryStore (FilesystemBackend root _)) = Just root
inventoryStoreRoot _ = Nothing

initializeStore :: InventoryStore -> ContextBinding -> Text -> IO (Either StoreError HeadManifest)
initializeStore store binding clientIdentity = do
  existing <- readHead store
  case existing of
    Left err -> pure (Left err)
    Right (Just headValue)
      | Just marker <- headMigration headValue ->
          pure (Left (StoreConditionFailed ("inventory store migrated to " <> migrationDestination marker <> "; reload the context shell")))
      | headBinding headValue == binding -> pure (Right headValue)
      | otherwise -> pure (Left (StoreConditionFailed "inventory store is bound to a different context or provider target"))
    Right Nothing -> do
      let initial = HeadManifest 1 0 0 binding clientIdentity Map.empty Map.empty Nothing Nothing Nothing
      replaced <- replaceHeadIfGenerationMatches store Nothing initial
      pure (initial <$ replaced)

readHead :: InventoryStore -> IO (Either StoreError (Maybe HeadManifest))
readHead store = do
  loaded <- readObject store "head.json"
  pure $ loaded >>= traverse decodeHead

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
    publishChecked safeKey = do
      existing <- readObjectUnlocked store safeKey
      case existing of
        Left err -> pure (Left err)
        Right (Just old)
          | old == bytes -> pure (Right (contentDigest bytes))
          | otherwise -> pure (Left (StoreObjectConflict safeKey))
        Right Nothing -> do
          written <- writeObjectUnlocked store False safeKey bytes
          pure (contentDigest bytes <$ written)

readObject :: InventoryStore -> FilePath -> IO (Either StoreError (Maybe ByteString))
readObject store key = case checkedKey key of
  Left err -> pure (Left err)
  Right safeKey -> readObjectUnlocked store safeKey

appendAtSequence :: InventoryStore -> Integer -> ByteString -> IO (Either StoreError ContentDigest)
appendAtSequence store sequenceNumber bytes
  | sequenceNumber < 0 = pure (Left (StoreConditionFailed "journal sequence must not be negative"))
  | otherwise = publishIfAbsent store (journalKey sequenceNumber) bytes

replaceHeadIfGenerationMatches :: InventoryStore -> Maybe Integer -> HeadManifest -> IO (Either StoreError ())
replaceHeadIfGenerationMatches store expected replacement = withBackendGuard store $ do
  currentResult <- readObjectUnlocked store "head.json"
  case currentResult >>= traverse decodeHead of
    Left err -> pure (Left err)
    Right current -> do
      let actual = headGeneration <$> current
          next = maybe 0 (+ 1) expected
      if maybe False (isJust . headMigration) current
        then pure (Left (StoreConditionFailed "inventory store has migrated; reload the context shell"))
        else if actual /= expected
        then pure (Left (StoreConditionFailed "inventory head generation changed"))
        else
          if headGeneration replacement /= next
            then pure (Left (StoreConditionFailed "replacement head generation is not the next generation"))
            else case canonicalValue (toJSON replacement) of
              Left err -> pure (Left (StoreInvalidObject "head.json" err))
              Right bytes -> case store of
                InventoryStore (ObjectBackend ops _ _ _ _ _) -> replaceObjectHead ops current bytes
                _ -> writeObjectUnlocked store True "head.json" bytes

mutableHeadAllowed :: InventoryStore -> IO (Either StoreError ())
mutableHeadAllowed store = do
  existing <- readObjectUnlocked store "head.json"
  pure $ case existing >>= traverse decodeHead of
    Left err -> Left err
    Right (Just headValue) | Just marker <- headMigration headValue ->
      Left (StoreConditionFailed ("inventory store migrated to " <> migrationDestination marker <> "; reload the context shell"))
    Right _ -> Right ()

replaceObjectHead :: ObjectOps -> Maybe HeadManifest -> ByteString -> IO (Either StoreError ())
replaceObjectHead ops previous bytes = do
  current <- getObject ops (ObjectName "head.json")
  case current of
    GetUnknown reason -> pure (Left (StoreIoError reason))
    ObjectAbsent | previous /= Nothing ->
      pure (Left (StoreConditionFailed "inventory head disappeared before conditional write"))
    ObjectFound _ _ | previous == Nothing ->
      pure (Left (StoreConditionFailed "inventory head appeared before conditional write"))
    ObjectFound _ old | Just prior <- previous, decodeHead old /= Right prior ->
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
      InventoryStore (MemoryBackend _ _ processLock) ->
        maskMVar processLock (Right <$> action (LockedStore store))
      InventoryStore (ObjectBackend _ _ _ lockPath _ processLock) ->
        maskMVar processLock $ case lockPath of
          Nothing -> Right <$> action (LockedStore store)
          Just path -> fileLock path
      InventoryStore (FilesystemBackend root _) -> do
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
restoreStore store backup = withBackendGuard store $ do
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
            Right values -> do
              writes <- traverse (uncurry (writeObjectUnlocked store False)) values
              pure (void (sequence writes))

-- | Copy a quiescent catalogue, verify the destination, then disable the
-- source by a conditional head replacement. Re-running after the tombstone
-- verifies the copy and succeeds without another write.
migrateStore :: InventoryStore -> InventoryStore -> Text -> Text -> IO (Either StoreError ())
migrateStore source destination sourceLabel label = do
  sourceLock <- withProcessLock source $ \_ ->
    withProcessLock destination $ \_ -> migrateLocked
  pure (sourceLock >>= id >>= id)
  where
    migrateLocked = do
      sourceHead <- readHead source
      case sourceHead of
        Left err -> pure (Left err)
        Right Nothing -> pure (Left (StoreConditionFailed "source inventory store is not initialized"))
        Right (Just oldHead)
          | isJust (headActiveTransaction oldHead) || isJust (headExecutorClaim oldHead) ->
              pure (Left (StoreConditionFailed "source inventory store has an unresolved transaction or executor claim"))
          | otherwise -> do
              keysResult <- listObjectKeys source
              case keysResult of
                Left err -> pure (Left err)
                Right keys -> do
                  let members = filter (/= "format.json") keys
                  loaded <- traverse (\key -> fmap ((key,) <$>) (readObject source key)) members
                  case sequence loaded >>= traverse requireMember of
                    Left err -> pure (Left err)
                    Right values -> do
                      let oldDigest = case headMigration oldHead of
                            Just marker -> migrationHeadDigest marker
                            Nothing -> maybe (contentDigest BS.empty) contentDigest (lookup "head.json" values)
                      case headMigration oldHead of
                        Just marker | migrationDestination marker /= label ->
                          pure (Left (StoreConditionFailed "source inventory store migrated to a different destination"))
                        Just _ -> verifyCopy members oldDigest
                        Nothing -> do
                          destinationHead <- readHead destination
                          case destinationHead of
                            Left err -> pure (Left err)
                            Right (Just current) | headMigration current == Nothing && current /= oldHead ->
                                pure (Left (StoreConditionFailed "destination inventory head differs"))
                            Right (Just current) | Just marker <- headMigration current,
                              migrationDestination marker /= sourceLabel ->
                                pure (Left (StoreConditionFailed "destination tombstone points to another store"))
                            Right _ -> copyAndCommit values members oldDigest oldHead
    copyAndCommit values members oldDigest oldHead = do
      copied <- traverse (\(key, bytes) -> if key == "head.json"
        then pure (Right ())
        else publishMigrationMember destination key bytes) values
      case sequence copied of
        Left err -> pure (Left err)
        Right _ -> case lookup "head.json" values of
          Nothing -> pure (Left (StoreConditionFailed "source inventory head disappeared"))
          Just headBytes -> do
            installed <- installMigrationHead destination sourceLabel headBytes
            case installed of
              Left err -> pure (Left err)
              Right _ -> do
                verified <- verifyCopy members oldDigest
                case verified of
                  Left err -> pure (Left err)
                  Right () -> replaceHeadIfGenerationMatches source
                    (Just (headGeneration oldHead))
                    oldHead
                      { headGeneration = headGeneration oldHead + 1
                      , headMigration = Just (MigrationTombstone label oldDigest)
                      }
    requireMember (_, Nothing) = Left (StoreConditionFailed "store changed while migration was reading it")
    requireMember (key, Just bytes) = do
      case immutableKeyDigest key of
        Just expected | contentDigest bytes /= expected ->
          Left (StoreInvalidObject key "immutable member digest mismatch during migration")
        _ -> Right ()
      Right (key, bytes)
    verifyCopy members expectedDigest = do
      sourceKeys <- listObjectKeys source
      destKeys <- listObjectKeys destination
      case (sourceKeys, destKeys) of
        (Right currentSource, Right currentDest)
          | filter (/= "format.json") currentSource == members
          , filter (/= "format.json") currentDest == members -> do
              comparisons <- traverse compareMember members
              pure (void (sequence comparisons) >> Right ())
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        _ -> pure (Left (StoreConditionFailed "inventory members changed during migration"))
      where
        compareMember key = do
          left <- readObject source key
          right <- readObject destination key
          pure $ do
            src <- left >>= maybe (Left (StoreConditionFailed "source member disappeared")) Right
            dst <- right >>= maybe (Left (StoreConditionFailed "destination member disappeared")) Right
            if key == "head.json" then
              unless (contentDigest dst == expectedDigest)
                (Left (StoreConditionFailed "destination inventory head digest differs"))
              else unless (src == dst)
                (Left (StoreConditionFailed "destination inventory member differs"))

publishMigrationMember :: InventoryStore -> FilePath -> ByteString -> IO (Either StoreError ())
publishMigrationMember destination key bytes = withBackendGuard destination $ do
  present <- readObjectUnlocked destination key
  case present of
    Left err -> pure (Left err)
    Right (Just actual) | actual == bytes -> pure (Right ())
    Right (Just _) -> pure (Left (StoreObjectConflict key))
    Right Nothing -> writeObjectUnlocked destination False key bytes

installMigrationHead :: InventoryStore -> Text -> ByteString -> IO (Either StoreError ())
installMigrationHead destination sourceLabel bytes = withBackendGuard destination $ do
  current <- readObjectUnlocked destination "head.json"
  case current >>= traverse decodeHead of
    Left err -> pure (Left err)
    Right oldHead -> case current of
      Right (Just oldBytes) | oldBytes == bytes -> pure (Right ())
      _ -> case oldHead of
        Just old | Just marker <- headMigration old,
          migrationDestination marker == sourceLabel -> writeHead (Just old)
        Just _ -> pure (Left (StoreConditionFailed "destination inventory head is already active or points elsewhere"))
        Nothing -> writeHead Nothing
  where
    writeHead oldHead = case destination of
      InventoryStore (ObjectBackend ops _ _ _ _ _) -> replaceObjectHead ops oldHead bytes
      _ -> writeObjectUnlocked destination (isJust oldHead) "head.json" bytes

decodeBackupManifest :: ByteString -> Either StoreError [(FilePath, ContentDigest)]
decodeBackupManifest bytes = do
  value <- first (StoreInvalidObject "backup.json" . T.pack) (eitherDecodeStrict' bytes)
  canonical <- first (StoreInvalidObject "backup.json") (canonicalValue value)
  unless (canonical == bytes) (Left (StoreInvalidObject "backup.json" "backup manifest is not canonical"))
  first (StoreInvalidObject "backup.json" . T.pack) (parseEither parser value)
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
withBackendGuard (InventoryStore (FilesystemBackend _ guardVar)) action = withMVar guardVar (const action)
withBackendGuard (InventoryStore (MemoryBackend _ guardVar _)) action = withMVar guardVar (const action)
withBackendGuard (InventoryStore (ObjectBackend _ _ _ _ guardVar _)) action = withMVar guardVar (const action)

readObjectUnlocked :: InventoryStore -> FilePath -> IO (Either StoreError (Maybe ByteString))
readObjectUnlocked (InventoryStore (MemoryBackend stateVar _ _)) key =
  Right . Map.lookup key . memoryObjects <$> readMVar stateVar
readObjectUnlocked (InventoryStore (FilesystemBackend root _)) key = do
  let path = root </> key
  exists <- doesPathExist path
  if not exists then pure (Right Nothing) else fmap Just <$> readVerifiedFile path
readObjectUnlocked (InventoryStore (ObjectBackend ops _ cache _ _ _)) key = do
  let expected = immutableKeyDigest key
      cachedPath = case (cache, expected) of
        (Just root, Just digest) -> Just (root </> T.unpack (digestText digest))
        _ -> Nothing
  cached <- case cachedPath of
    Nothing -> pure Nothing
    Just path -> do
      exists <- doesPathExist path
      if not exists then pure Nothing else do
        loaded <- readVerifiedFile path
        pure $ case (loaded, expected) of
          (Right bytes, Just digest) | contentDigest bytes == digest -> Just bytes
          _ -> Nothing
  case cached of
    Just bytes -> pure (Right (Just bytes))
    Nothing -> do
      observed <- getObject ops (ObjectName (T.pack key))
      case observed of
        ObjectAbsent -> pure (Right Nothing)
        GetUnknown reason -> pure (Left (StoreIoError reason))
        ObjectFound _ bytes -> case expected of
          Just digest | contentDigest bytes /= digest ->
            pure (Left (StoreInvalidObject key "remote immutable member digest mismatch"))
          _ -> do
            case cachedPath of
              Nothing -> pure ()
              Just path -> void (ioResult (atomicWrite path bytes))
            pure (Right (Just bytes))

immutableKeyDigest :: FilePath -> Maybe ContentDigest
immutableKeyDigest key = case splitDirectories key of
  [category, filename]
    | category `elem` ["scopes", "reviews", "native", "objects"]
    , takeExtension filename == ".json" ->
        either (const Nothing) Just (mkContentDigest (T.pack (dropExtension filename)))
  _ -> Nothing

readVerifiedFile :: FilePath -> IO (Either StoreError ByteString)
readVerifiedFile path = do
  attempted <- try $ do
    linked <- pathIsSymbolicLink path
    when linked (ioError (userError "file is a symlink"))
    status <- getFileStatus path
    unless (isRegularFile status) (ioError (userError "path is not a regular file"))
    unless (fileMode status .&. 0o077 == 0) (ioError (userError "file is accessible by group or other users"))
    BS.readFile path
  pure $ case attempted of
    Left (err :: IOException) -> Left (StoreInvalidObject path (T.pack (show err)))
    Right bytes -> Right bytes

writeObjectUnlocked :: InventoryStore -> Bool -> FilePath -> ByteString -> IO (Either StoreError ())
writeObjectUnlocked (InventoryStore (MemoryBackend stateVar _ _)) replace key bytes = do
  modifyMVar stateVar $ \state ->
    let objects = memoryObjects state
     in if not replace && Map.member key objects
          then pure (state, Left (StoreObjectConflict key))
          else pure (state {memoryObjects = Map.insert key bytes objects}, Right ())
writeObjectUnlocked (InventoryStore (FilesystemBackend root _)) replace key bytes = do
  let path = root </> key
  exists <- doesPathExist path
  if exists && not replace
    then pure (Left (StoreObjectConflict key))
    else ioResult (atomicWrite path bytes)
writeObjectUnlocked (InventoryStore (ObjectBackend ops _ _ _ _ _)) replace key bytes
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
listObjectKeysUnlocked (InventoryStore (MemoryBackend stateVar _ _)) =
  Right . sort . Map.keys . memoryObjects <$> readMVar stateVar
listObjectKeysUnlocked (InventoryStore (ObjectBackend ops _ _ _ _ _)) = do
  listed <- listObjects ops (ObjectName "")
  pure (first StoreIoError (sort . map (\(ObjectName name) -> T.unpack name) <$> listed))
listObjectKeysUnlocked (InventoryStore (FilesystemBackend root _)) = ioResult (sort <$> walk root "")
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

atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite path bytes = do
  let parent = takeDirectory path
  createDirectoryIfMissing True parent
  setFileMode parent 0o700
  (temporary, handle) <- openBinaryTempFile parent ".inventory-object.tmp"
  let cleanup = do
        hClose handle `catch` (\(_ :: IOException) -> pure ())
        removeFile temporary `catch` (\(_ :: IOException) -> pure ())
  ( do
      setFileMode temporary 0o600
      BS.hPut handle bytes
      hFlush handle
      hClose handle
      syncFile temporary
      renameFile temporary path
      setFileMode path 0o600
      syncDirectory parent
    )
    `catch` \(err :: IOException) -> cleanup >> ioError err

syncFile :: FilePath -> IO ()
syncFile path = bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise

syncDirectory :: FilePath -> IO ()
syncDirectory path = bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise

ioResult :: forall a. IO a -> IO (Either StoreError a)
ioResult action = do
  attempted <- try action
  pure $ first (StoreIoError . T.pack . show) (attempted :: Either IOException a)
