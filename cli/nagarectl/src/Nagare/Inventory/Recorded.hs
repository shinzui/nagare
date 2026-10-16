-- | The one reader of recorded inventory state (MasterPlan 28, EP-193).
--
-- A read proceeds in two stages. 'readRecordedHead' reads the authoritative
-- head once and checks that it exists, decodes canonically and is bound to
-- the expected context; head and scope-summary documents project from it
-- alone. 'loadRecordedStateAt' then hydrates the accepted scopes of exactly
-- that head, and, for site reads, the earlier converged revision of a scope
-- whose accepted revision has not converged. It never reads the head again.
--
-- Scope members are immutable and digest-checked, so one head is already a
-- consistent snapshot, and a verified decode is reused by digest across
-- reads from a byte-bounded cache. A missing or corrupt member is an error,
-- never an omitted scope, and an error is never cached.
--
-- Unlike the planning loader, this reader never refuses because a
-- transaction, claim, fence, migration or transition is open: those are
-- facts of the head. It reads no journal, review, native envelope, retained
-- or collected history, and never writes the store.
module Nagare.Inventory.Recorded
  ( RecordedHead
  , recordedHeadManifest
  , recordedHeadRevision
  , RecordedReader
  , RecordedReaderConfig (..)
  , defaultRecordedReaderConfig
  , newRecordedReader
  , readRecordedHead
  , Selection (..)
  , RecordedState
  , recordedStateHead
  , recordedAccepted
  , recordedConverged
  , loadRecordedStateAt
  , readRecordedState
  )
where

import Control.Concurrent.Async (Async, async, mapConcurrently, waitCatch)
import Control.Concurrent.MVar
import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_, displayException, onException)
import Data.Aeson (toJSON)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Unique (Unique, newUnique)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ScopeMember (decodeScopeMember)
import Nagare.Inventory.Store
  ( HeadManifest (..)
  , InventoryStore
  , ScopeRevision (..)
  , StoreError (..)
  , readHead
  , readObject
  , scopeKey
  )
import Nagare.Resource.Canonical (canonicalValue)
import Nagare.Resource.Inventory (ScopeDeclaration, scopeId)
import Nagare.Resource.Types

-- | A checked head, bound to the reader that read it.
data RecordedHead = RecordedHead
  { reader :: !Unique
  , manifest :: !HeadManifest
  , revision :: !ContentDigest
  }

recordedHeadManifest :: RecordedHead -> HeadManifest
recordedHeadManifest = manifest

-- | The digest of the canonical head: equal digests are the same snapshot.
recordedHeadRevision :: RecordedHead -> ContentDigest
recordedHeadRevision = revision

-- | The reader's service limits. The defaults are the admin API's (EP-197):
-- 64 MiB of decoded scope members and eight concurrent member reads.
data RecordedReaderConfig = RecordedReaderConfig
  { cacheBytes :: !Int
  , workers :: !Int
  }
  deriving stock (Eq, Show, Generic)

defaultRecordedReaderConfig :: RecordedReaderConfig
defaultRecordedReaderConfig = RecordedReaderConfig {cacheBytes = 64 * 1024 * 1024, workers = 8}

-- | A reusable reader of one context's store. The fresh head action is the
-- store's own 'readHead' for local callers; the in-cluster service supplies
-- one that also rechecks bucket ownership (EP-196). Either way this reader
-- validates presence and binding identically.
data RecordedReader = RecordedReader
  { readerId :: !Unique
  , store :: !InventoryStore
  , binding :: !ContextBinding
  , freshHead :: !(IO (Either StoreError (Maybe HeadManifest)))
  , cache :: !(MVar CacheState)
  , limit :: !Int
  , slots :: !QSem
  }

data CacheState = CacheState
  { entries :: !(Map ContentDigest CacheEntry)
  , recency :: !(Map Integer ContentDigest)
  , clock :: !Integer
  , charged :: !Int
  , loading :: !(Map ContentDigest (Async (Either StoreError (Int, ScopeDeclaration))))
  }

data CacheEntry = CacheEntry
  { tick :: !Integer
  , size :: !Int
  , declaration :: !ScopeDeclaration
  }

newRecordedReader ::
  RecordedReaderConfig ->
  InventoryStore ->
  ContextBinding ->
  IO (Either StoreError (Maybe HeadManifest)) ->
  IO RecordedReader
newRecordedReader config inventoryStore expected headAction = do
  unique <- newUnique
  state <- newMVar (CacheState Map.empty Map.empty 0 0 Map.empty)
  semaphore <- newQSem (max 1 (config ^. #workers))
  pure
    RecordedReader
      { readerId = unique
      , store = inventoryStore
      , binding = expected
      , freshHead = headAction
      , cache = state
      , limit = max 0 (config ^. #cacheBytes)
      , slots = semaphore
      }

-- | Read the authoritative head once and check it belongs to this context.
readRecordedHead :: RecordedReader -> IO (Either StoreError RecordedHead)
readRecordedHead recordedReader = do
  observed <- freshHead recordedReader
  pure $ do
    headValue <- observed >>= maybe (Left (StoreConditionFailed "inventory store is not initialized")) Right
    unless
      (headBinding headValue == binding recordedReader)
      (Left (StoreConditionFailed "inventory head belongs to another context or project"))
    canonical <- first (StoreInvalidObject "head.json") (canonicalValue (toJSON headValue))
    pure (RecordedHead (readerId recordedReader) headValue (contentDigest canonical))

-- | Which scope revisions to hydrate. Site reads also need the earlier
-- converged revision of an application or standalone scope whose accepted
-- revision has not converged.
data Selection = AcceptedOnly | WithConvergedSites
  deriving stock (Eq, Show)

-- | The hydrated scopes of one checked head.
data RecordedState = RecordedState
  { head :: !RecordedHead
  , accepted :: !(Map ScopeId (ScopeRevision, ScopeDeclaration))
  , converged :: !(Map ScopeId (ScopeRevision, ScopeDeclaration))
  }

recordedStateHead :: RecordedState -> RecordedHead
recordedStateHead = Nagare.Inventory.Recorded.head

-- | Every accepted scope with its revision and declaration.
recordedAccepted :: RecordedState -> Map ScopeId (ScopeRevision, ScopeDeclaration)
recordedAccepted = accepted

-- | The earlier converged revisions loaded for 'WithConvergedSites': only
-- application and standalone scopes whose converged revision differs from
-- the accepted one. A scope whose revisions agree is in 'recordedAccepted'.
recordedConverged :: RecordedState -> Map ScopeId (ScopeRevision, ScopeDeclaration)
recordedConverged = converged

loadRecordedStateAt :: RecordedReader -> RecordedHead -> Selection -> IO (Either StoreError RecordedState)
loadRecordedStateAt recordedReader checked selection
  | reader checked /= readerId recordedReader =
      pure (Left (StoreConditionFailed "recorded head was read by another reader"))
  | otherwise = do
      let headValue = manifest checked
          acceptedRevisions = Map.toAscList (headAccepted headValue)
          earlier =
            [ (scope, revisionValue)
            | selection == WithConvergedSites
            , (scope, revisionValue) <- Map.toAscList (headConverged headValue)
            , scopeKind scope `elem` [Application, Standalone]
            , Map.lookup scope (headAccepted headValue) /= Just revisionValue
            ]
      acceptedLoaded <- mapConcurrently (member recordedReader) acceptedRevisions
      earlierLoaded <- mapConcurrently (member recordedReader) earlier
      pure $
        RecordedState checked
          <$> (Map.fromList <$> sequence acceptedLoaded)
          <*> (Map.fromList <$> sequence earlierLoaded)

member :: RecordedReader -> (ScopeId, ScopeRevision) -> IO (Either StoreError (ScopeId, (ScopeRevision, ScopeDeclaration)))
member recordedReader (scope, revisionValue) = do
  loaded <- cachedDeclaration recordedReader scope (revisionDigest revisionValue)
  pure (fmap (\declarationValue -> (scope, (revisionValue, declarationValue))) loaded)

-- | One verified scope member: from the cache, from a load already in
-- flight, or read now within the worker limit. A waiter's cancellation does
-- not cancel a shared load; a failed load is reported to every waiter and
-- never cached.
cachedDeclaration :: RecordedReader -> ScopeId -> ContentDigest -> IO (Either StoreError ScopeDeclaration)
cachedDeclaration recordedReader scope digest = do
  pending <- modifyMVar (cache recordedReader) $ \state ->
    case Map.lookup digest (entries state) of
      Just entry -> pure (touch digest entry state, Left (declaration entry))
      Nothing -> case Map.lookup digest (loading state) of
        Just running -> pure (state, Right running)
        Nothing -> do
          -- The new load settles under this MVar, so it cannot finish before
          -- it is registered.
          running <- async fetch
          pure (state {loading = Map.insert digest running (loading state)}, Right running)
  case pending of
    Left declarationValue -> pure (owned declarationValue)
    Right running -> do
      outcome <- waitCatch running
      pure $ case outcome of
        Left failure -> Left (StoreIoError (T.pack (displayException failure)))
        Right result -> result >>= owned . snd
  where
    owned declarationValue
      | scopeId declarationValue == scope = Right declarationValue
      | otherwise = Left (StoreInvalidObject (scopeKey digest) "scope member identity mismatch")
    fetch = flip onException (settle Nothing) $ do
      bytes <-
        bracket_
          (waitQSem (slots recordedReader))
          (signalQSem (slots recordedReader))
          (readObject (store recordedReader) (scopeKey digest))
      let decoded = do
            found <- bytes
            declarationValue <- decodeScopeMember scope digest found
            pure (maybe 0 BS.length found, declarationValue)
      settle (either (const Nothing) Just decoded)
      pure decoded
    settle success = modifyMVar_ (cache recordedReader) $ \state ->
      pure (admit (limit recordedReader) digest success state {loading = Map.delete digest (loading state)})

touch :: ContentDigest -> CacheEntry -> CacheState -> CacheState
touch digest entry state =
  state
    { entries = Map.insert digest entry {tick = next} (entries state)
    , recency = Map.insert next digest (Map.delete (tick entry) (recency state))
    , clock = next
    }
  where
    next = clock state + 1

-- | Keep a verified member unless it alone exceeds the limit, then evict the
-- least recently used members until the charged bytes fit again.
admit :: Int -> ContentDigest -> Maybe (Int, ScopeDeclaration) -> CacheState -> CacheState
admit _ _ Nothing state = state
admit limitBytes digest (Just (bytes, declarationValue)) state
  | bytes > limitBytes || Map.member digest (entries state) = state
  | otherwise =
      evict
        state
          { entries = Map.insert digest (CacheEntry next bytes declarationValue) (entries state)
          , recency = Map.insert next digest (recency state)
          , clock = next
          , charged = charged state + bytes
          }
  where
    next = clock state + 1
    evict current
      | charged current <= limitBytes = current
      | Just ((_, oldest), rest) <- Map.minViewWithKey (recency current)
      , Just entry <- Map.lookup oldest (entries current) =
          evict
            current
              { entries = Map.delete oldest (entries current)
              , recency = rest
              , charged = charged current - size entry
              }
      | otherwise = current

-- | The CLI's one-shot read: the store's own head, every accepted scope and
-- the earlier converged site revisions.
readRecordedState :: InventoryStore -> ContextBinding -> IO (Either StoreError RecordedState)
readRecordedState inventoryStore expected = do
  recordedReader <- newRecordedReader defaultRecordedReaderConfig inventoryStore expected (readHead inventoryStore)
  checked <- readRecordedHead recordedReader
  case checked of
    Left failure -> pure (Left failure)
    Right headValue -> loadRecordedStateAt recordedReader headValue WithConvergedSites
