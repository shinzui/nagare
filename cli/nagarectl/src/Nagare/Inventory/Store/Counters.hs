-- | Per-store operation counts and times (EP-212). Every opened store carries
-- one 'StoreCounters'. When tracing is enabled (@NAGARE_TRACE=1@, or a test
-- collecting counts) each new record is also kept in a process-wide list so
-- the command can print one summary line per store when it ends.
module Nagare.Inventory.Store.Counters
  ( Counter (..)
  , StoreCounters
  , CounterSnapshot
  , newStoreCounters
  , counted
  , countElapsed
  , snapshotCounters
  , countOf
  , renderCounters
  , enableStoreTrace
  , tracedStoreCounters
  , collectStoreCounters
  , withStoreTrace
  , WireRequest (..)
  , ObjectClass (..)
  , objectClass
  , CommandTrace (..)
  , tracePhase
  , traceWire
  , collectCommandTrace
  )
where

import Control.Exception (finally)
import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Dsl.Prelude
import Numeric (showFFloat)
import System.Environment (lookupEnv)
import System.IO (stderr)
import System.IO.Unsafe (unsafePerformIO)

data Counter
  = StoreOpen
  | GcloudSession
  | HeadRead
  | HistoryLoad
  | RemoteGet
  | CachedGet
  | RemotePut
  | Listing
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The store's kind and its count and elapsed nanoseconds per counter.
data StoreCounters = StoreCounters !Text !(IORef (Map Counter (Int, Word64)))

-- | Count and elapsed seconds per counter.
type CounterSnapshot = Map Counter (Int, Double)

registry :: IORef (Maybe [StoreCounters])
registry = unsafePerformIO (newIORef Nothing)
{-# NOINLINE registry #-}

newStoreCounters :: Text -> IO StoreCounters
newStoreCounters kind = do
  counters <- StoreCounters kind <$> newIORef Map.empty
  atomicModifyIORef' registry (\kept -> (fmap (counters :) kept, ()))
  pure counters

counted :: StoreCounters -> Counter -> IO a -> IO a
counted counters counter action = do
  started <- getMonotonicTimeNSec
  result <- action
  finished <- getMonotonicTimeNSec
  record counters counter (finished - started)
  pure result

-- | Record one occurrence whose time was measured by the caller.
countElapsed :: StoreCounters -> Counter -> Word64 -> IO ()
countElapsed = record

record :: StoreCounters -> Counter -> Word64 -> IO ()
record (StoreCounters _ ref) counter elapsed =
  atomicModifyIORef' ref (\kept -> (Map.insertWith (\(n, t) (m, u) -> (n + m, t + u)) counter (1, elapsed) kept, ()))

snapshotCounters :: StoreCounters -> IO CounterSnapshot
snapshotCounters (StoreCounters _ ref) = Map.map (\(n, t) -> (n, fromIntegral t / 1.0e9)) <$> readIORef ref

countOf :: Counter -> CounterSnapshot -> Int
countOf counter = maybe 0 fst . Map.lookup counter

-- | One summary line, every counter shown, timed counters with their seconds.
renderCounters :: CounterSnapshot -> Text
renderCounters snapshot = T.intercalate ", " (map field [minBound .. maxBound])
  where
    field counter =
      let (n, seconds) = Map.findWithDefault (0, 0) counter snapshot
       in label counter <> " " <> T.pack (show n) <> if n > 0 && timed counter then " (" <> T.pack (showFFloat (Just 2) seconds "") <> " s)" else ""
    timed counter = counter `notElem` [CachedGet]
    label = \case
      StoreOpen -> "store opens"
      GcloudSession -> "gcloud sessions"
      HeadRead -> "head reads"
      HistoryLoad -> "history loads"
      RemoteGet -> "remote gets"
      CachedGet -> "cached gets"
      RemotePut -> "puts"
      Listing -> "listings"

enableStoreTrace :: IO ()
enableStoreTrace = do
  atomicModifyIORef' registry (\kept -> (Just (fromMaybe [] kept), ()))
  atomicModifyIORef' commandTrace (\kept -> (Just (fromMaybe emptyTrace kept), ()))

-- | Every store opened since tracing was enabled, oldest first.
tracedStoreCounters :: IO [StoreCounters]
tracedStoreCounters = maybe [] reverse <$> readIORef registry

-- | Run an action and return the counts of every store it opened, oldest
-- first. Tests use this; it assumes no other thread opens stores meanwhile.
collectStoreCounters :: IO a -> IO (a, [CounterSnapshot])
collectStoreCounters action = do
  previous <- readIORef registry
  writeIORef registry (Just [])
  ( do
      result <- action
      snapshots <- tracedStoreCounters >>= traverse snapshotCounters
      pure (result, snapshots)
    )
    `finally` writeIORef registry previous

-- | Run an action and return the phases and wire transfers it recorded. Tests
-- use this; it assumes no other thread records meanwhile.
collectCommandTrace :: IO a -> IO (a, CommandTrace)
collectCommandTrace action = do
  previous <- readIORef commandTrace
  writeIORef commandTrace (Just emptyTrace)
  ( do
      result <- action
      collected <- fromMaybe emptyTrace <$> readIORef commandTrace
      pure (result, collected)
    )
    `finally` writeIORef commandTrace previous

-- | Under @NAGARE_TRACE=1@, print one line per store opened by the action on
-- stderr when it ends, however it ends, followed by the wall time.
withStoreTrace :: IO a -> IO a
withStoreTrace action = do
  enabled <- (== Just "1") <$> lookupEnv "NAGARE_TRACE"
  if not enabled
    then action
    else do
      enableStoreTrace
      started <- getMonotonicTimeNSec
      action `finally` do
        finished <- getMonotonicTimeNSec
        stores <- tracedStoreCounters
        forM_ stores $ \counters@(StoreCounters kind _) -> do
          snapshot <- snapshotCounters counters
          TIO.hPutStrLn stderr ("nagarectl trace: " <> kind <> " store: " <> renderCounters snapshot)
        traced <- fromMaybe emptyTrace <$> readIORef commandTrace
        unless (Map.null (traced ^. #phases)) $
          TIO.hPutStrLn stderr ("nagarectl trace: phases: " <> renderPhases (traced ^. #phases))
        unless (Map.null (traced ^. #wire)) $
          TIO.hPutStrLn stderr ("nagarectl trace: http: " <> renderWire (traced ^. #wire))
        TIO.hPutStrLn stderr ("nagarectl trace: stores " <> T.pack (show (length stores)) <> ", wall " <> seconds (finished - started) <> " s")

-- | EP-221: what one command spent outside the logical store counters. A
-- phase is a named step (a gcloud or kubectl subprocess, an ownership proof
-- with its retries, an En request) with its count and nanoseconds. The wire
-- counts actual HTTP requests to the store, the objects whose bodies they
-- downloaded and the body bytes, per request kind and object class; a
-- 'RemoteGet' batch of many journal events is many media requests here.
data CommandTrace = CommandTrace
  { phases :: !(Map Text (Int, Word64))
  , wire :: !(Map (WireRequest, ObjectClass) (Int, Int, Int))
  }
  deriving stock (Eq, Show, Generic)

data WireRequest = MetadataRequest | MediaRequest | ListingRequest | UploadRequest
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data ObjectClass = ControlObjects | ScopeObjects | ReviewObjects | NativeObjects | JournalObjects | BucketObjects | OtherObjects
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The class of a store-relative key: the head and format are control
-- objects; the rest by their first directory.
objectClass :: Text -> ObjectClass
objectClass key = case T.takeWhile (/= '/') key of
  "head.json" -> ControlObjects
  "format.json" -> ControlObjects
  "scopes" -> ScopeObjects
  "reviews" -> ReviewObjects
  "native" -> NativeObjects
  "objects" -> NativeObjects
  "journal" -> JournalObjects
  _ -> OtherObjects

emptyTrace :: CommandTrace
emptyTrace = CommandTrace Map.empty Map.empty

commandTrace :: IORef (Maybe CommandTrace)
commandTrace = unsafePerformIO (newIORef Nothing)
{-# NOINLINE commandTrace #-}

-- | Time an action as one occurrence of a named phase while tracing.
tracePhase :: Text -> IO a -> IO a
tracePhase name action = do
  started <- getMonotonicTimeNSec
  result <- action
  finished <- getMonotonicTimeNSec
  atomicModifyIORef' commandTrace (\kept -> (fmap (\traced -> traced & #phases %~ Map.insertWith add name (1, finished - started)) kept, ()))
  pure result
  where
    add (n, t) (m, u) = (n + m, t + u)

-- | Record one HTTP request and, when it downloaded a body, its byte count.
traceWire :: WireRequest -> ObjectClass -> Maybe Int -> IO ()
traceWire request objects body =
  atomicModifyIORef' commandTrace (\kept -> (fmap (\traced -> traced & #wire %~ Map.insertWith add (request, objects) (1, length body, fromMaybe 0 body)) kept, ()))
  where
    add (a, b, c) (d, e, f) = (a + d, b + e, c + f)

renderPhases :: Map Text (Int, Word64) -> Text
renderPhases = T.intercalate ", " . map (\(name, (n, t)) -> name <> " " <> T.pack (show n) <> " (" <> seconds t <> " s)") . Map.toList

renderWire :: Map (WireRequest, ObjectClass) (Int, Int, Int) -> Text
renderWire = T.intercalate ", " . map field . Map.toList
  where
    field ((request, objects), (n, downloaded, bytes)) =
      requestLabel request
        <> " "
        <> classLabel objects
        <> " "
        <> T.pack (show n)
        <> if downloaded > 0 then " (" <> T.pack (show downloaded) <> " bodies, " <> T.pack (show bytes) <> " bytes)" else ""
    requestLabel = \case
      MetadataRequest -> "metadata"
      MediaRequest -> "media"
      ListingRequest -> "listing"
      UploadRequest -> "upload"
    classLabel = \case
      ControlObjects -> "control"
      ScopeObjects -> "scopes"
      ReviewObjects -> "reviews"
      NativeObjects -> "native"
      JournalObjects -> "journal"
      BucketObjects -> "bucket"
      OtherObjects -> "other"

seconds :: Word64 -> Text
seconds t = T.pack (showFFloat (Just 2) (fromIntegral t / 1.0e9 :: Double) "")
