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
  , hasSubstantiveHistory
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
  , ObservedHead
  , observeHead
  , observedHeadManifest
  , replaceObservedHead
  , inspectHeadSchema
  , readStoreSnapshot
  , readReviewSnapshot
  , publishIfAbsent
  , readObject
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
import Nagare.Inventory.Store.FileIO (atomicWrite, readPrivateFile, syncDirectory, syncFile)
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

-- | Historical ownership kept after a scope or one of its members leaves the
-- accepted vector.
-- The scope member remains immutable in the store; this record binds the
-- exact live incarnation and keeps its provider claims reserved.
data RetainedIncarnation = RetainedIncarnation
  { retainedOwner :: !ScopeId
  , retainedRevision :: !ScopeRevision
  , retainedPhysical :: !PhysicalIdentity
  , retainedAt :: !Text
  , retainedMigrationReview :: !(Maybe ContentDigest)
  , retainedReplacedBy :: !(Maybe PhysicalIdentity)
  }
  deriving stock (Eq, Show, Generic)

data DeletionTombstone = DeletionTombstone
  { tombstoneOwner :: !ScopeId
  , tombstoneRevision :: !ScopeRevision
  , tombstonePhysical :: !PhysicalIdentity
  , tombstoneAt :: !Text
  , tombstoneReview :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

-- | A live data target stays reserved across process loss. The record is
-- private inventory history, never part of a public reviewed scope.
data DataFencePhase
  = FenceAcquiring
  | FenceExcluded
  | FenceChanging
  | FenceVerifying
  | FenceUnresolved
  | FenceReleasing
  deriving stock (Eq, Show, Generic)

data DataFenceRecord = DataFenceRecord
  { fenceContext :: !ContextBinding
  , fenceSession :: !Text
  , fenceTransaction :: !(Maybe Text)
  , fenceAccepted :: !(Map ScopeId ScopeRevision)
  , fencePhysical :: !(Map ResourceId PhysicalIdentity)
  , fenceTargets :: !(Set ResourceId)
  , fenceAffected :: !(Set ResourceId)
  , fenceRecoveryArtifact :: !Text
  , fenceRecoveryDigest :: !ContentDigest
  , fenceSavedWriters :: !(Map ResourceId Value)
  , fenceProviderIntent :: !(Maybe Value)
  , fencePhase :: !DataFencePhase
  , fenceAcquiredAt :: !Text
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
  , headRetained :: !(Map ResourceId RetainedIncarnation)
  , headCollected :: !(Map ResourceId DeletionTombstone)
  , headActiveTransaction :: !(Maybe Text)
  , headExecutorClaim :: !(Maybe ExecutorClaim)
  , headMigration :: !(Maybe MigrationTombstone)
  , headDataFence :: !(Maybe DataFenceRecord)
  , headIncarnations :: !(Map ResourceId PhysicalIdentity)
  -- ^ Physical identity of each accepted durable member, recorded when its
  -- transaction converges and never silently replaced (F49).
  }
  deriving stock (Eq, Show, Generic)

-- | Legacy platform mutations have no component receipts and may run only
-- before this store has accepted or retained any resource work. An initialized
-- but untouched head is safe for the older path; an admitted transaction is
-- not, even if no scope revision has committed yet.
hasSubstantiveHistory :: HeadManifest -> Bool
hasSubstantiveHistory headValue =
  headGeneration headValue > 0
    || headSequence headValue > 0
    || not (Map.null (headAccepted headValue))
    || not (Map.null (headConverged headValue))
    || not (Map.null (headRetained headValue))
    || not (Map.null (headCollected headValue))
    || isJust (headActiveTransaction headValue)
    || isJust (headExecutorClaim headValue)
    || isJust (headMigration headValue)
    || isJust (headDataFence headValue)

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

instance ToJSON RetainedIncarnation where
  toJSON retained =
    object
      ( [ "owner" .= retainedOwner retained
        , "revision" .= retainedRevision retained
        , "physical" .= retainedPhysical retained
        , "retainedAt" .= retainedAt retained
        ]
          <> ["migrationReview" .= digest | Just digest <- [retainedMigrationReview retained]]
          <> ["replacedBy" .= replacement | Just replacement <- [retainedReplacedBy retained]]
      )

instance FromJSON RetainedIncarnation where
  parseJSON = withObject "RetainedIncarnation" $ \o -> do
    unless
      (all (`elem` ["owner", "revision", "physical", "retainedAt", "migrationReview", "replacedBy"]) (KM.keys o))
      (fail "retained incarnation has an unknown field")
    RetainedIncarnation
      <$> o .: "owner"
      <*> o .: "revision"
      <*> o .: "physical"
      <*> o .: "retainedAt"
      <*> o .:? "migrationReview"
      <*> o .:? "replacedBy"

instance ToJSON DeletionTombstone where
  toJSON tombstone =
    object
      [ "owner" .= tombstoneOwner tombstone
      , "revision" .= tombstoneRevision tombstone
      , "physical" .= tombstonePhysical tombstone
      , "deletedAt" .= tombstoneAt tombstone
      , "review" .= tombstoneReview tombstone
      ]

instance FromJSON DeletionTombstone where
  parseJSON = withObject "DeletionTombstone" $ \o -> do
    unless
      (all (`elem` ["owner", "revision", "physical", "deletedAt", "review"]) (KM.keys o))
      (fail "deletion tombstone has an unknown field")
    DeletionTombstone
      <$> o .: "owner"
      <*> o .: "revision"
      <*> o .: "physical"
      <*> o .: "deletedAt"
      <*> o .: "review"

instance ToJSON DataFencePhase where
  toJSON phase = String $ case phase of
    FenceAcquiring -> "acquiring"
    FenceExcluded -> "excluded"
    FenceChanging -> "changing"
    FenceVerifying -> "verifying"
    FenceUnresolved -> "unresolved"
    FenceReleasing -> "releasing"

instance FromJSON DataFencePhase where
  parseJSON = withText "DataFencePhase" $ \case
    "acquiring" -> pure FenceAcquiring
    "excluded" -> pure FenceExcluded
    "changing" -> pure FenceChanging
    "verifying" -> pure FenceVerifying
    "unresolved" -> pure FenceUnresolved
    "releasing" -> pure FenceReleasing
    _ -> fail "unknown data fence phase"

instance ToJSON DataFenceRecord where
  toJSON fence =
    object $
      [ "context" .= fenceContext fence
      , "session" .= fenceSession fence
      , "transaction" .= fenceTransaction fence
      , "accepted"
          .= [ object ["scope" .= scope, "revision" .= revision]
             | (scope, revision) <- Map.toAscList (fenceAccepted fence)
             ]
      , "physical"
          .= [ object ["resource" .= resource, "identity" .= physical]
             | (resource, physical) <- Map.toAscList (fencePhysical fence)
             ]
      , "targets" .= Set.toAscList (fenceTargets fence)
      , "affected" .= Set.toAscList (fenceAffected fence)
      , "recoveryArtifact" .= fenceRecoveryArtifact fence
      , "recoveryDigest" .= fenceRecoveryDigest fence
      , "savedWriters"
          .= [ object ["resource" .= resource, "configuration" .= configuration]
             | (resource, configuration) <- Map.toAscList (fenceSavedWriters fence)
             ]
      , "phase" .= fencePhase fence
      , "acquiredAt" .= fenceAcquiredAt fence
      ]
        <> maybe
          []
          (\intent -> ["providerIntent" .= intent])
          (fenceProviderIntent fence)

instance FromJSON DataFenceRecord where
  parseJSON = withObject "DataFenceRecord" $ \o -> do
    unless
      ( all
          ( `elem`
              [ "context"
              , "session"
              , "transaction"
              , "accepted"
              , "physical"
              , "targets"
              , "affected"
              , "recoveryArtifact"
              , "recoveryDigest"
              , "savedWriters"
              , "providerIntent"
              , "phase"
              , "acquiredAt"
              ]
          )
          (KM.keys o)
      )
      (fail "data fence has an unknown field")
    accepted <-
      uniqueEntries "accepted scope"
        =<< traverse
          (withObject "fence scope" (\v -> (,) <$> v .: "scope" <*> v .: "revision"))
        =<< o .: "accepted"
    physical <-
      uniqueEntries "physical resource"
        =<< traverse
          (withObject "fence physical" (\v -> (,) <$> v .: "resource" <*> v .: "identity"))
        =<< o .: "physical"
    targetList <- o .: "targets"
    affectedList <- o .: "affected"
    unless
      ( not (null targetList)
          && length targetList == Set.size (Set.fromList targetList)
          && length affectedList == Set.size (Set.fromList affectedList)
          && Set.fromList (targetList <> affectedList) `Set.isSubsetOf` Map.keysSet physical
      )
      (fail "data fence target and affected identities must be complete and unique")
    saved <-
      uniqueEntries "saved writer"
        =<< traverse
          (withObject "fence writer" (\v -> (,) <$> v .: "resource" <*> v .: "configuration"))
        =<< o .: "savedWriters"
    unless
      (Map.keysSet saved == Set.fromList affectedList)
      (fail "data fence does not preserve every writer configuration")
    session <- o .: "session"
    recovery <- o .: "recoveryArtifact"
    unless
      (not (T.null session) && not (T.null recovery) && not (Map.null physical))
      (fail "data fence lacks its session, recovery artifact, or physical target")
    providerIntent <- o .:? "providerIntent"
    unless
      (maybe True isObject providerIntent)
      (fail "data fence provider intent must be an object")
    DataFenceRecord
      <$> o .: "context"
      <*> pure session
      <*> o .:? "transaction"
      <*> pure accepted
      <*> pure physical
      <*> pure (Set.fromList targetList)
      <*> pure (Set.fromList affectedList)
      <*> pure recovery
      <*> o .: "recoveryDigest"
      <*> pure saved
      <*> pure providerIntent
      <*> o .: "phase"
      <*> o .: "acquiredAt"
    where
      isObject (Object _) = True
      isObject _ = False
      uniqueEntries label entries = do
        let selected = Map.fromList entries
        unless (length entries == Map.size selected) (fail ("duplicate " <> label))
        pure selected

instance ToJSON HeadManifest where
  toJSON headValue =
    object
      ( [ "version" .= headSchemaVersion headValue
        , "generation" .= headGeneration headValue
        , "sequence" .= headSequence headValue
        , "binding" .= headBinding headValue
        , "clientIdentity" .= headClientIdentity headValue
        , "accepted" .= revisionsValue (headAccepted headValue)
        , "converged" .= revisionsValue (headConverged headValue)
        , "activeTransaction" .= headActiveTransaction headValue
        , "executorClaim" .= headExecutorClaim headValue
        ]
          <> ["retained" .= retainedValue (headRetained headValue) | not (Map.null (headRetained headValue))]
          <> ["collected" .= collectedValue (headCollected headValue) | not (Map.null (headCollected headValue))]
          <> maybe [] (\marker -> ["migration" .= marker]) (headMigration headValue)
          <> maybe [] (\fence -> ["dataFence" .= fence]) (headDataFence headValue)
          <> ["incarnations" .= [object ["resource" .= r, "physical" .= p] | (r, p) <- Map.toAscList (headIncarnations headValue)] | not (Map.null (headIncarnations headValue))]
      )
    where
      revisionsValue revisions = [object ["scope" .= scope, "revision" .= revision] | (scope, revision) <- Map.toAscList revisions]
      retainedValue entries =
        [ object ["resource" .= resource, "incarnation" .= incarnation]
        | (resource, incarnation) <- Map.toAscList entries
        ]
      collectedValue entries =
        [ object ["resource" .= resource, "tombstone" .= tombstone]
        | (resource, tombstone) <- Map.toAscList entries
        ]

instance FromJSON HeadManifest where
  parseJSON = withObject "HeadManifest" $ \o -> do
    let allowed = ["version", "generation", "sequence", "binding", "clientIdentity", "accepted", "converged", "retained", "collected", "activeTransaction", "executorClaim", "migration", "dataFence", "incarnations"]
    unless (all (`elem` allowed) (KM.keys o)) (fail "head manifest has an unknown field")
    version <- o .: "version"
    unless (version == 1) (fail "unsupported inventory head schema version")
    generation <- o .: "generation"
    sequenceNumber <- o .: "sequence"
    unless (generation >= 0 && sequenceNumber >= 0) (fail "head counters must not be negative")
    accepted <- parseRevisions =<< o .: "accepted"
    converged <- parseRevisions =<< o .: "converged"
    retained <- parseRetained =<< o .:? "retained" .!= []
    collected <- parseCollected =<< o .:? "collected" .!= []
    incarnations <- traverse (withObject "incarnation" (\v -> (,) <$> v .: "resource" <*> v .: "physical")) =<< o .:? "incarnations" .!= []
    unless (length incarnations == Map.size (Map.fromList incarnations)) (fail "duplicate incarnation resource")
    unless
      (Map.null (Map.intersection retained collected))
      (fail "resource cannot be retained and collected in the same head")
    active <- o .: "activeTransaction"
    unless
      (isJust active || all (`Map.member` accepted) (Map.keys converged))
      (fail "converged scopes must also be accepted when no transaction is active")
    binding <- o .: "binding"
    fence <- o .:? "dataFence"
    unless
      ( maybe
          True
          ( \entry ->
              fenceContext entry == binding
                && fenceAccepted entry == accepted
                && maybe
                  (isNothing active)
                  (\transaction -> active == Just transaction)
                  (fenceTransaction entry)
          )
          fence
      )
      (fail "data fence differs from its context, accepted head, or linked transaction")
    HeadManifest version generation sequenceNumber
      <$> pure binding
      <*> o .: "clientIdentity"
      <*> pure accepted
      <*> pure converged
      <*> pure retained
      <*> pure collected
      <*> pure active
      <*> o .: "executorClaim"
      <*> o .:? "migration"
      <*> pure fence
      <*> pure (Map.fromList incarnations)
    where
      parseRevisions values = do
        revisions <- traverse (withObject "scope revision" (\v -> (,) <$> v .: "scope" <*> v .: "revision")) values
        unless (length revisions == Map.size (Map.fromList revisions)) (fail "duplicate scope revision")
        pure (Map.fromList revisions)
      parseRetained values = do
        entries <- traverse (withObject "retained entry" (\v -> (,) <$> v .: "resource" <*> v .: "incarnation")) values
        unless (length entries == Map.size (Map.fromList entries)) (fail "duplicate retained resource")
        pure (Map.fromList entries)
      parseCollected values = do
        entries <- traverse (withObject "collected entry" (\v -> (,) <$> v .: "resource" <*> v .: "tombstone")) values
        unless (length entries == Map.size (Map.fromList entries)) (fail "duplicate collected resource")
        pure (Map.fromList entries)

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
openObjectStore mayInitialize ops binding client cache lockPath = case canonicalValue
  ( object
      ["version" .= (1 :: Int), "binding" .= binding]
  ) of
  Left reason -> pure (Left (StoreInvalidObject "format.json" reason))
  Right expected -> do
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
      let initial = HeadManifest 1 0 0 binding clientIdentity Map.empty Map.empty Map.empty Map.empty Nothing Nothing Nothing Nothing Map.empty
      replaced <- replaceHeadIfGenerationMatches store Nothing initial
      pure (initial <$ replaced)

readHead :: InventoryStore -> IO (Either StoreError (Maybe HeadManifest))
readHead store = do
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
    Right (Just headValue) -> do
      let key = reviewKey digest
      -- Cached content proves integrity, not publication in this store. Never
      -- let a prepopulated local cache manufacture publication authority.
      loaded <- case store of
        InventoryStore (ObjectBackend ops _ _ _ _ _) -> do
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
observeHead store = do
  observed <- case store of
    InventoryStore (ObjectBackend ops _ _ _ _ _) -> do
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
replaceObservedHead observed@(ObservedHead store _ _) replacement =
  withBackendGuard store (replaceObservedHeadUnlocked observed replacement)

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
        InventoryStore (ObjectBackend ops _ _ _ _ _) -> do
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

-- | Copy a quiescent catalogue with an inactive destination head. Disable the
-- source before activating the destination, so interruption cannot leave two
-- writable stores. Re-running completes either side of the handoff.
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
          | isJust (headActiveTransaction oldHead)
              || isJust (headExecutorClaim oldHead)
              || isJust (headDataFence oldHead) ->
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
                        Just marker
                          | migrationDestination marker /= label ->
                              pure (Left (StoreConditionFailed "source inventory store migrated to a different destination"))
                        Just _ -> do
                          activated <- activateMigrationHead destination sourceLabel oldDigest
                          case activated of
                            Left err -> pure (Left err)
                            Right () -> verifyCopy members oldDigest
                        Nothing -> do
                          destinationHead <- readHead destination
                          case destinationHead of
                            Left err -> pure (Left err)
                            Right (Just current)
                              | headMigration current == Nothing ->
                                  pure (Left (StoreConditionFailed "destination inventory head is already active"))
                            Right (Just current)
                              | Just marker <- headMigration current
                              , migrationDestination marker /= sourceLabel ->
                                  pure (Left (StoreConditionFailed "destination tombstone points to another store"))
                            Right _ -> copyAndCommit values members oldDigest oldHead
    copyAndCommit values members oldDigest oldHead = do
      copied <-
        traverse
          ( \(key, bytes) ->
              if key == "head.json"
                then pure (Right ())
                else publishMigrationMember destination key bytes
          )
          values
      case sequence copied of
        Left err -> pure (Left err)
        Right _ -> case lookup "head.json" values of
          Nothing -> pure (Left (StoreConditionFailed "source inventory head disappeared"))
          Just headBytes -> do
            installed <- installMigrationHead destination sourceLabel label headBytes
            case installed of
              Left err -> pure (Left err)
              Right _ -> do
                verified <- verifyStagedCopy members oldDigest
                case verified of
                  Left err -> pure (Left err)
                  Right () -> do
                    disabled <-
                      replaceHeadIfGenerationMatches
                        source
                        (Just (headGeneration oldHead))
                        oldHead
                          { headGeneration = headGeneration oldHead + 1
                          , headMigration = Just (MigrationTombstone label oldDigest)
                          }
                    case disabled of
                      Left err -> pure (Left err)
                      Right () -> do
                        activated <- activateMigrationHead destination sourceLabel oldDigest
                        case activated of
                          Left err -> pure (Left err)
                          Right () -> verifyCopy members oldDigest
    requireMember (_, Nothing) = Left (StoreConditionFailed "store changed while migration was reading it")
    requireMember (key, Just bytes) = do
      case immutableKeyDigest key of
        Just expected
          | contentDigest bytes /= expected ->
              Left (StoreInvalidObject key "immutable member digest mismatch during migration")
        _ -> Right ()
      Right (key, bytes)
    verifyStagedCopy members expectedDigest = verifyMembers members (Just expectedDigest)
    verifyCopy members expectedDigest = verifyMembers members (Just expectedDigest)
    verifyMembers members expectedDigest = do
      sourceKeys <- listObjectKeys source
      destKeys <- listObjectKeys destination
      case (sourceKeys, destKeys) of
        (Right currentSource, Right currentDest)
          | filter (/= "format.json") currentSource == members
          , filter (/= "format.json") currentDest == members -> do
              comparisons <- traverse (compareMember expectedDigest) members
              pure (void (sequence comparisons) >> Right ())
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        _ -> pure (Left (StoreConditionFailed "inventory members changed during migration"))
      where
        compareMember expected key = do
          left <- readObject source key
          right <- readObject destination key
          pure $ do
            src <- left >>= maybe (Left (StoreConditionFailed "source member disappeared")) Right
            dst <- right >>= maybe (Left (StoreConditionFailed "destination member disappeared")) Right
            if key == "head.json"
              then do
                destinationHead <- decodeHead dst
                let actualDigest = maybe (contentDigest dst) migrationHeadDigest (headMigration destinationHead)
                unless
                  (Just actualDigest == expected)
                  (Left (StoreConditionFailed "destination inventory head digest differs"))
              else
                unless
                  (src == dst)
                  (Left (StoreConditionFailed "destination inventory member differs"))

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
      InventoryStore (ObjectBackend ops _ _ _ _ _) -> replaceObjectHead ops oldHead staged
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
                InventoryStore (ObjectBackend ops _ _ _ _ _) -> replaceObjectHead ops (Just old) active
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
withBackendGuard (InventoryStore (FilesystemBackend _ guardVar)) action = withMVar guardVar (const action)
withBackendGuard (InventoryStore (MemoryBackend _ guardVar _)) action = withMVar guardVar (const action)
withBackendGuard (InventoryStore (ObjectBackend _ _ _ _ guardVar _)) action = withMVar guardVar (const action)

-- | Remember reconstructed observation data in the optional private local cache.
-- The content hash names the entry; accepted declarations must still bind it.
-- This never publishes a remote object or supplies review-publication authority.
-- Cache failure is harmless: callers retain the original compatibility reader.
cacheObservationBytes :: InventoryStore -> ByteString -> IO ()
cacheObservationBytes (InventoryStore (ObjectBackend _ _ (Just root) _ _ _)) bytes =
  void (ioResult (atomicWrite (root </> T.unpack (digestText (contentDigest bytes))) bytes))
cacheObservationBytes _ _ = pure ()

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
      if not exists
        then pure Nothing
        else do
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
          Just digest
            | contentDigest bytes /= digest ->
                pure (Left (StoreInvalidObject key "remote immutable member digest mismatch"))
          _ -> do
            case cachedPath of
              Nothing -> pure ()
              Just path -> void (ioResult (atomicWrite path bytes))
            pure (Right (Just bytes))

-- | Journal members are immutable once appended. Read the committed prefix in
-- one object-store transfer, then require every name bound by the head. The
-- journal decoder still checks sequence numbers and the complete hash chain.
readJournalPrefix :: InventoryStore -> Integer -> IO (Either StoreError [ByteString])
readJournalPrefix _ count | count < 0 = pure (Left (StoreConditionFailed "negative journal length"))
readJournalPrefix _ 0 = pure (Right [])
readJournalPrefix store@(InventoryStore backend) count = case backend of
  ObjectBackend ops _ _ _ _ _ -> do
    loaded <- getObjects ops (ObjectName "journal")
    pure $ do
      objects <- first StoreIoError loaded
      traverse
        ( \sequenceNumber ->
            let key = journalKey sequenceNumber
             in maybe
                  (Left (StoreInvalidObject key "committed journal event is missing"))
                  Right
                  (Map.lookup (ObjectName (T.pack key)) objects)
        )
        [0 .. count - 1]
  _ -> do
    loaded <- traverse (readObject store . journalKey) [0 .. count - 1]
    pure $ do
      values <- sequence loaded
      traverse (maybe (Left (StoreInvalidObject "journal" "committed journal event is missing")) Right) values

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

ioResult :: forall a. IO a -> IO (Either StoreError a)
ioResult action = do
  attempted <- try action
  pure $ first (StoreIoError . T.pack . show) (attempted :: Either IOException a)
