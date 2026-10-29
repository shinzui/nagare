-- | Per-store operation counts and times (EP-212). Every opened store carries
-- one 'StoreCounters'. When tracing is enabled (@NAGARE_TRACE=1@,
-- @NAGARE_TRACE_FILE@, or a test collecting counts) each new record is also
-- kept in a process-wide list so the command can report every store when it
-- ends. The same recorder keeps the command's spans and counts (EP-224);
-- "Nagare.Inventory.Trace" turns them into the versioned trace document.
module Nagare.Inventory.Store.Counters
  ( Counter (..)
  , StoreCounters
  , CounterSnapshot
  , newStoreCounters
  , counted
  , countElapsed
  , snapshotCounters
  , countOf
  , counterLabel
  , renderCounters
  , enableStoreTrace
  , tracedStoreCounters
  , collectStoreCounters
  , printTraceSummary
  , WireRequest (..)
  , ObjectClass (..)
  , objectClass
  , requestLabel
  , classLabel
  , CommandTrace (..)
  , currentCommandTrace
  , SpanContext (..)
  , rootContext
  , labelled
  , withSpan
  , tracePhase
  , traceCount
  , traceProcess
  , traceOperations
  , traceWire
  , collectCommandTrace
  )
where

import Control.Exception (finally, onException)
import Control.Monad (forM_)
import Data.Foldable (foldl')
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Contract.Trace (CountCategory (..), OperationRecord, SpanLabels, SpanResult (..), TraceSpan (..), noLabels)
import Nagare.Dsl.Prelude
import Numeric (showFFloat)
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
       in counterLabel counter <> " " <> T.pack (show n) <> if n > 0 && timed counter then " (" <> T.pack (showFFloat (Just 2) seconds "") <> " s)" else ""
    timed counter = counter `notElem` [CachedGet]

counterLabel :: Counter -> Text
counterLabel = \case
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
  fresh <- newTrace
  atomicModifyIORef' commandTrace (\kept -> (Just (fromMaybe fresh kept), ()))

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
  fresh <- newTrace
  writeIORef commandTrace (Just fresh)
  ( do
      result <- action
      collected <- fromMaybe fresh <$> readIORef commandTrace
      pure (result, collected)
    )
    `finally` writeIORef commandTrace previous

-- | The @NAGARE_TRACE=1@ summary on stderr: one line per store opened, the
-- phases, the wire and the wall time since @started@.
printTraceSummary :: Word64 -> IO ()
printTraceSummary started = do
  finished <- getMonotonicTimeNSec
  stores <- tracedStoreCounters
  forM_ stores $ \counters@(StoreCounters kind _) -> do
    snapshot <- snapshotCounters counters
    TIO.hPutStrLn stderr ("nagarectl trace: " <> kind <> " store: " <> renderCounters snapshot)
  traced <- readIORef commandTrace
  forM_ traced $ \recorded -> do
    unless (Map.null (recorded ^. #phases)) $
      TIO.hPutStrLn stderr ("nagarectl trace: phases: " <> renderPhases (recorded ^. #phases))
    unless (Map.null (recorded ^. #wire)) $
      TIO.hPutStrLn stderr ("nagarectl trace: http: " <> renderWire (recorded ^. #wire))
  TIO.hPutStrLn stderr ("nagarectl trace: stores " <> T.pack (show (length stores)) <> ", wall " <> seconds (finished - started) <> " s")

-- | EP-221: what one command spent outside the logical store counters. A
-- phase is a named step (a gcloud or kubectl subprocess, an ownership proof
-- with its retries, an En request) with its count and nanoseconds. The wire
-- counts actual HTTP requests to the store, the objects whose bodies they
-- downloaded and the body bytes, per request kind and object class; a
-- 'RemoteGet' batch of many journal events is many media requests here.
-- EP-224 adds the command's spans, its other counts and its planned and
-- executed operations, all relative to 'origin', the monotonic start.
data CommandTrace = CommandTrace
  { phases :: !(Map Text (Int, Word64))
  , wire :: !(Map (WireRequest, ObjectClass) (Int, Int, Int))
  , origin :: !Word64
  , nextSpan :: !Int
  , spans :: ![TraceSpan]
  -- ^ Newest first.
  , counts :: !(Map (CountCategory, Text) (Int, Word64))
  , operations :: !(Map (OperationRecord, Text, Text) Int)
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

newTrace :: IO CommandTrace
newTrace = do
  now <- getMonotonicTimeNSec
  pure (CommandTrace Map.empty Map.empty now 0 [] Map.empty Map.empty)

commandTrace :: IORef (Maybe CommandTrace)
commandTrace = unsafePerformIO (newIORef Nothing)
{-# NOINLINE commandTrace #-}

-- | The recorded trace so far, when tracing is enabled.
currentCommandTrace :: IO (Maybe CommandTrace)
currentCommandTrace = readIORef commandTrace

modifyTrace :: (CommandTrace -> CommandTrace) -> IO ()
modifyTrace change = atomicModifyIORef' commandTrace (\kept -> (fmap change kept, ()))

-- | Where a span sits: its explicit parent and labels. Callers pass the
-- context they were given to the steps they start.
data SpanContext = SpanContext
  { parentSpan :: !(Maybe Int)
  , spanLabels :: !SpanLabels
  }
  deriving stock (Eq, Show, Generic)

rootContext :: SpanContext
rootContext = SpanContext Nothing noLabels

-- | A context for a step of one operation, under no parent.
labelled :: SpanLabels -> SpanContext
labelled = SpanContext Nothing

-- | Time an action as one span of a named phase. The action receives the
-- context for its own child spans. A span whose action throws is recorded
-- as 'ResultThrew' and the exception propagates unchanged.
withSpan :: SpanContext -> Text -> (SpanContext -> IO a) -> IO a
withSpan context name action = do
  enabled <- isJust <$> readIORef commandTrace
  if not enabled
    then action context
    else do
      identity <- atomicModifyIORef' commandTrace $ \case
        Nothing -> (Nothing, 0)
        Just traced -> (Just (traced & #nextSpan +~ 1), traced ^. #nextSpan)
      started <- getMonotonicTimeNSec
      let close outcome = do
            finished <- getMonotonicTimeNSec
            modifyTrace $ \traced ->
              let relative t = t - min t (traced ^. #origin)
               in traced
                    & #spans
                    %~ (TraceSpan identity (context ^. #parentSpan) name (context ^. #spanLabels) (relative started) (relative finished) outcome :)
                    & #phases
                    %~ Map.insertWith add name (1, finished - started)
      result <- action (context & #parentSpan ?~ identity) `onException` close ResultThrew
      close ResultSucceeded
      pure result
  where
    add (n, t) (m, u) = (n + m, t + u)

-- | Time an action as one occurrence of a named phase while tracing.
tracePhase :: Text -> IO a -> IO a
tracePhase name action = withSpan rootContext name (const action)

-- | Count one occurrence of named work, with the nanoseconds it took (zero
-- when untimed).
traceCount :: CountCategory -> Text -> Word64 -> IO ()
traceCount category name elapsed =
  modifyTrace (#counts %~ Map.insertWith (\(n, t) (m, u) -> (n + m, t + u)) (category, name) (1, elapsed))

-- | Time one external program run and count it under its program name.
traceProcess :: Text -> IO a -> IO a
traceProcess program action = do
  started <- getMonotonicTimeNSec
  result <- action `onException` (getMonotonicTimeNSec >>= \finished -> traceCount CategoryProcess program (finished - started))
  finished <- getMonotonicTimeNSec
  traceCount CategoryProcess program (finished - started)
  pure result

-- | Count planned or executed operations by action and executor.
traceOperations :: OperationRecord -> [(Text, Text)] -> IO ()
traceOperations kind entries =
  modifyTrace (#operations %~ \kept -> foldl' (\acc (action, executor) -> Map.insertWith (+) (kind, action, executor) 1 acc) kept entries)

-- | Record one HTTP request and, when it downloaded a body, its byte count.
traceWire :: WireRequest -> ObjectClass -> Maybe Int -> IO ()
traceWire request objects body =
  modifyTrace (#wire %~ Map.insertWith add (request, objects) (1, length body, fromMaybe 0 body))
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

requestLabel :: WireRequest -> Text
requestLabel = \case
  MetadataRequest -> "metadata"
  MediaRequest -> "media"
  ListingRequest -> "listing"
  UploadRequest -> "upload"

classLabel :: ObjectClass -> Text
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
