{-# LANGUAGE OverloadedStrings #-}

-- | The lifecycle event feed's storage (EP-231 M2): a context-bound
-- @lifecycle/v1/@ prefix beside the inventory, with one constant-size
-- conditional head and immutable, content-addressed segments and index
-- nodes. The feed writer holds no inventory authority.
--
-- Every interpreter is an 'ObjectOps': the cloud bucket's own, an in-memory
-- one and a filesystem one, so the feed has one code path and the same fault
-- scenarios run against all three. Readers use exact GETs and never list.
module Nagare.Events.Store
  ( FeedStore
  , feedStoreOps
  , feedStoreCounters
  , newFeedStore
  , memoryObjectOps
  , filesystemObjectOps
  , FeedError (..)
  , FeedHead (..)
  , feedHeadVersion
  , ObservedFeed
  , observedFeedHead
  , observeFeed
  , readFeedHead
  , ReplaceOutcome (..)
  , replaceFeedHead
  , publishFeedObject
  , readFeedObject
  , readFeedObjects
  , segmentKey
  , indexKey
  , idsKey
  , feedHeadKey
  )
where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.MVar
import Control.Exception (IOException, bracket, try)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hLock, hUnlock)
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Events.Source (SourceCheckpoint)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store.Counters (Counter (CachedGet, RemoteGet, RemotePut), StoreCounters, countElapsed, counted, newStoreCounters)
import Nagare.Inventory.Store.FileIO (atomicWrite)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO (IOMode (ReadWriteMode), hClose, openFile)

-- | The feed's object operations, already bound to its prefix, the counters
-- of every request made through them, and a bounded cache of the immutable
-- objects it read or wrote. A content-addressed object never changes, so the
-- cache is always valid; a long-running writer's cycle then reads little more
-- than the head.
data FeedStore = FeedStore !ObjectOps !StoreCounters !(IORef (Map ContentDigest ByteString, Int))

feedStoreOps :: FeedStore -> ObjectOps
feedStoreOps (FeedStore ops _ _) = ops

feedStoreCounters :: FeedStore -> StoreCounters
feedStoreCounters (FeedStore _ counters _) = counters

-- | At most this many cached bytes; past it the cache starts again.
cacheBudget :: Int
cacheBudget = 16 * 1024 * 1024

remember :: FeedStore -> ContentDigest -> ByteString -> IO ()
remember (FeedStore _ _ cache) digest bytes =
  atomicModifyIORef' cache $ \(kept, size) ->
    let size' = size + BS.length bytes
     in if size' > cacheBudget then ((Map.singleton digest bytes, BS.length bytes), ()) else ((Map.insert digest bytes kept, size'), ())

recall :: FeedStore -> ContentDigest -> IO (Maybe ByteString)
recall (FeedStore _ counters cache) digest = do
  found <- Map.lookup digest . fst <$> readIORef cache
  found <$ when (isJust found) (countElapsed counters CachedGet 0)

newFeedStore :: ObjectOps -> IO FeedStore
newFeedStore ops = do
  counters <- newStoreCounters "lifecycle"
  cache <- newIORef (Map.empty, 0)
  pure
    ( FeedStore
        ops
          { getObject = counted counters RemoteGet . getObject ops
          , getImmutableObject = counted counters RemoteGet . getImmutableObject ops
          , putObject = \condition name bytes -> counted counters RemotePut (putObject ops condition name bytes)
          , getObjects = \_ -> pure (Left "the lifecycle feed never lists")
          , listObjects = \_ -> pure (Left "the lifecycle feed never lists")
          }
        counters
        cache
    )

data FeedError
  = FeedNotEnabled
  | FeedTransport !Text
  | FeedInvalid !Text !Text
  | FeedBindingMismatch
  | FeedConflict !Text
  deriving stock (Eq, Show)

-- | The feed head: constant size whatever the history's length. It names
-- the visible event count, the tail index node and the node listing every
-- completed one, the event-ID index root, and the source checkpoints the
-- visible events were materialized up to: the inventory journal's and the
-- backup collector's observation chain's (EP-233).
data FeedHead = FeedHead
  { schemaVersion :: !Int
  , binding :: !ContextBinding
  , epoch :: !Text
  , generation :: !Integer
  , count :: !Integer
  , tail :: !(Maybe ContentDigest)
  , completed :: !(Maybe ContentDigest)
  , ids :: !(Maybe ContentDigest)
  , journal :: !SourceCheckpoint
  , receipts :: !SourceCheckpoint
  }
  deriving stock (Eq, Show, Generic)

feedHeadVersion :: Int
feedHeadVersion = 1

feedHeadKey :: ObjectName
feedHeadKey = ObjectName "head.json"

segmentKey, indexKey, idsKey :: ContentDigest -> ObjectName
segmentKey = addressed "segments"
indexKey = addressed "index"
idsKey = addressed "ids"

addressed :: Text -> ContentDigest -> ObjectName
addressed category digest = ObjectName (category <> "/" <> digestText digest <> ".json")

-- | A head read bound to the provider generation it came with.
data ObservedFeed = ObservedFeed !(Maybe FeedHead) !(Maybe Generation)
  deriving stock (Eq, Show)

observedFeedHead :: ObservedFeed -> Maybe FeedHead
observedFeedHead (ObservedFeed current _) = current

observeFeed :: FeedStore -> ContextBinding -> IO (Either FeedError ObservedFeed)
observeFeed store expected = do
  outcome <- getObject (feedStoreOps store) feedHeadKey
  pure $ case outcome of
    GetUnknown reason -> Left (FeedTransport reason)
    ObjectAbsent -> Right (ObservedFeed Nothing Nothing)
    ObjectFound generationTag bytes -> do
      headValue <- decodeFeedHead bytes
      unless (headValue ^. #binding == expected) (Left FeedBindingMismatch)
      pure (ObservedFeed (Just headValue) (Just generationTag))

-- | The current head; an absent head is 'FeedNotEnabled', never an empty feed.
readFeedHead :: FeedStore -> ContextBinding -> IO (Either FeedError FeedHead)
readFeedHead store expected = do
  observed <- observeFeed store expected
  pure (observed >>= maybe (Left FeedNotEnabled) Right . observedFeedHead)

data ReplaceOutcome = Replaced | Superseded
  deriving stock (Eq, Show)

-- | Replace the head observed in @observed@ with @replacement@. A lost
-- acknowledgement is settled by reading the head back: equal bytes mean the
-- write landed. Another writer's head is 'Superseded'; the caller rereads.
replaceFeedHead :: FeedStore -> ObservedFeed -> FeedHead -> IO (Either FeedError ReplaceOutcome)
replaceFeedHead store (ObservedFeed current providerGeneration) replacement
  | replacement ^. #generation /= maybe 0 ((+ 1) . (^. #generation)) current = pure (Left (FeedConflict "replacement head generation is not the next generation"))
  | otherwise = do
      let bytes = encodeFeedHead replacement
          condition = maybe IfAbsent IfGenerationMatches providerGeneration
      outcome <- putObject (feedStoreOps store) condition feedHeadKey bytes
      case outcome of
        PutWritten _ -> pure (Right Replaced)
        PutPreconditionFailed -> pure (Right Superseded)
        PutNoEffect reason -> pure (Left (FeedTransport reason))
        PutUnknown reason -> do
          reread <- getObject (feedStoreOps store) feedHeadKey
          pure $ case reread of
            ObjectFound _ found | found == bytes -> Right Replaced
            ObjectFound _ _ -> Right Superseded
            ObjectAbsent -> Left (FeedTransport reason)
            GetUnknown again -> Left (FeedTransport again)

-- | Publish an immutable object under its content digest: absent is
-- created, equal bytes are an idempotent success, other bytes conflict.
publishFeedObject :: FeedStore -> (ContentDigest -> ObjectName) -> ByteString -> IO (Either FeedError ContentDigest)
publishFeedObject store keyOf bytes = do
  let digest = contentDigest bytes
      name = keyOf digest
  cached <- recall store digest
  outcome <- if isJust cached then pure (PutWritten (Generation 0)) else putObject (feedStoreOps store) IfAbsent name bytes
  case outcome of
    PutWritten _ -> Right digest <$ remember store digest bytes
    _ -> do
      existing <- getImmutableObject (feedStoreOps store) name
      pure $ case (outcome, existing) of
        (_, ImmutableFound found) | found == bytes -> Right digest
        (_, ImmutableFound _) -> Left (FeedConflict (objectText name <> " holds other bytes"))
        (PutNoEffect reason, _) -> Left (FeedTransport reason)
        (PutUnknown reason, _) -> Left (FeedTransport reason)
        (_, ImmutableUnknown reason) -> Left (FeedTransport reason)
        _ -> Left (FeedTransport ("could not publish " <> objectText name))

-- | One immutable object, verified against the digest its name carries.
readFeedObject :: FeedStore -> (ContentDigest -> ObjectName) -> ContentDigest -> IO (Either FeedError ByteString)
readFeedObject store keyOf digest = do
  let name = keyOf digest
  cached <- recall store digest
  outcome <- maybe (getImmutableObject (feedStoreOps store) name) (pure . ImmutableFound) cached
  case outcome of
    ImmutableFound bytes
      | contentDigest bytes == digest -> Right bytes <$ remember store digest bytes
      | otherwise -> pure (Left (FeedInvalid (objectText name) "digest mismatch"))
    ImmutableMissing -> pure (Left (FeedInvalid (objectText name) "a committed feed object is missing"))
    ImmutableUnknown reason -> pure (Left (FeedTransport reason))

-- | Several immutable objects, at most eight requests in flight.
readFeedObjects :: FeedStore -> (ContentDigest -> ObjectName) -> [ContentDigest] -> IO (Either FeedError (Map ContentDigest ByteString))
readFeedObjects store keyOf digests = go Map.empty (Map.keys (Map.fromList [(digest, ()) | digest <- digests]))
  where
    go found [] = pure (Right found)
    go found pending = do
      let (wave, rest) = splitAt 8 pending
      loaded <- mapConcurrently (\digest -> fmap ((,) digest) <$> readFeedObject store keyOf digest) wave
      case sequence loaded of
        Left err -> pure (Left err)
        Right values -> go (Map.union found (Map.fromList values)) rest

objectText :: ObjectName -> Text
objectText (ObjectName name) = name

encodeFeedHead :: FeedHead -> ByteString
encodeFeedHead = either (error . T.unpack) id . canonicalValue . toJSON

decodeFeedHead :: ByteString -> Either FeedError FeedHead
decodeFeedHead bytes = do
  headValue <- first (FeedInvalid "head.json" . T.pack) (eitherDecodeStrict' bytes)
  canonical <- first (FeedInvalid "head.json") (canonicalValue (toJSON headValue))
  unless (canonical == bytes) (Left (FeedInvalid "head.json" "the feed head is not canonical"))
  pure headValue

instance ToJSON FeedHead where
  toJSON headValue =
    object
      [ "version" .= (headValue ^. #schemaVersion)
      , "binding" .= (headValue ^. #binding)
      , "epoch" .= (headValue ^. #epoch)
      , "generation" .= (headValue ^. #generation)
      , "count" .= (headValue ^. #count)
      , "tail" .= (headValue ^. #tail)
      , "completed" .= (headValue ^. #completed)
      , "ids" .= (headValue ^. #ids)
      , "journal" .= (headValue ^. #journal)
      , "receipts" .= (headValue ^. #receipts)
      ]

instance FromJSON FeedHead where
  parseJSON = withObject "feed head" $ \o -> do
    unless (all (`elem` ["version", "binding", "epoch", "generation", "count", "tail", "completed", "ids", "journal", "receipts"]) (KM.keys o)) (fail "the feed head has an unknown field")
    version <- o .: "version"
    unless (version == feedHeadVersion) (fail "unsupported lifecycle feed version")
    headValue <- FeedHead version <$> o .: "binding" <*> o .: "epoch" <*> o .: "generation" <*> o .: "count" <*> o .: "tail" <*> o .: "completed" <*> o .: "ids" <*> o .: "journal" <*> o .: "receipts"
    unless (headValue ^. #count >= 0 && headValue ^. #generation >= 0) (fail "feed head counters must not be negative")
    pure headValue

-- | An in-memory bucket: integer generations, conditional puts.
memoryObjectOps :: IO ObjectOps
memoryObjectOps = do
  state <- newMVar (Map.empty :: Map Text (Integer, ByteString), 0 :: Integer)
  let getOne name = do
        (objects, _) <- readMVar state
        pure $ case Map.lookup name objects of
          Just (generationNumber, bytes) -> ObjectFound (Generation generationNumber) bytes
          Nothing -> ObjectAbsent
  pure
    ObjectOps
      { getObject = \(ObjectName name) -> getOne name
      , getImmutableObject = \(ObjectName name) -> immutableGet <$> getOne name
      , getObjects = \(ObjectName prefix) -> do
          (objects, _) <- readMVar state
          pure (Right (Map.fromList [(ObjectName name, bytes) | (name, (_, bytes)) <- Map.toList objects, (prefix <> "/") `T.isPrefixOf` name]))
      , putObject = \condition (ObjectName name) bytes -> modifyMVar state $ \(objects, next) ->
          let current = fst <$> Map.lookup name objects
              allowed = case condition of
                IfAbsent -> isNothing current
                IfGenerationMatches (Generation expected) -> current == Just expected
                IfGenerationMatches (ObjectEtag _) -> False
           in if allowed
                then pure ((Map.insert name (next + 1, bytes) objects, next + 1), PutWritten (Generation (next + 1)))
                else pure ((objects, next), PutPreconditionFailed)
      , listObjects = \(ObjectName prefix) -> do
          (objects, _) <- readMVar state
          pure (Right [ObjectName name | name <- Map.keys objects, prefix `T.isPrefixOf` name])
      , pauseBeforeRetry = \_ -> pure ()
      }

-- | A directory as a bucket. A put holds an exclusive lock on the
-- directory's lock file; an object's generation is the digest of its bytes,
-- which is enough for the feed's content-distinct heads.
filesystemObjectOps :: FilePath -> IO ObjectOps
filesystemObjectOps root = do
  -- Opening creates nothing: a reader of a feed never enabled sees it absent.
  let path name = root </> T.unpack name
      readOne name = do
        exists <- doesFileExist (path name)
        if not exists
          then pure ObjectAbsent
          else do
            loaded <- try (BS.readFile (path name)) :: IO (Either IOException ByteString)
            pure $ case loaded of
              Left err -> GetUnknown (T.pack (show err))
              Right bytes -> ObjectFound (ObjectEtag (digestText (contentDigest bytes))) bytes
      locked action =
        createDirectoryIfMissing True root
          >> bracket
            (openFile (root </> ".lock") ReadWriteMode)
            hClose
            ( \handle ->
                bracket (hLock handle ExclusiveLock) (const (hUnlock handle)) (const action)
            )
  pure
    ObjectOps
      { getObject = \(ObjectName name) -> if safe name then readOne name else pure (GetUnknown "unsafe object name")
      , getImmutableObject = \(ObjectName name) -> if safe name then immutableGet <$> readOne name else pure (ImmutableUnknown "unsafe object name")
      , getObjects = \_ -> pure (Left "the filesystem feed store does not list")
      , putObject = \condition (ObjectName name) bytes ->
          if not (safe name)
            then pure (PutNoEffect "unsafe object name")
            else locked $ do
              current <- readOne name
              let allowed = case (condition, current) of
                    (IfAbsent, ObjectAbsent) -> True
                    (IfGenerationMatches expected, ObjectFound actual _) -> expected == actual
                    _ -> False
              case current of
                GetUnknown reason -> pure (PutUnknown reason)
                _
                  | not allowed -> pure PutPreconditionFailed
                  | otherwise -> do
                      written <- try (atomicWrite (path name) bytes) :: IO (Either IOException ())
                      pure $ case written of
                        Left err -> PutUnknown (T.pack (show err))
                        Right () -> PutWritten (ObjectEtag (digestText (contentDigest bytes)))
      , listObjects = \_ -> pure (Left "the filesystem feed store does not list")
      , pauseBeforeRetry = \_ -> pure ()
      }
  where
    safe name =
      not (T.null name)
        && not ("/" `T.isPrefixOf` name)
        && all (\part -> part `notElem` ["", ".", ".."]) (T.splitOn "/" name)
        && T.all (\c -> c /= '\\' && c /= '\0') name
