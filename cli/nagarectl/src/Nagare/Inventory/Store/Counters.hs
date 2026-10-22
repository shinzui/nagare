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
  )
where

import Control.Exception (finally)
import Control.Monad (forM_)
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
enableStoreTrace = atomicModifyIORef' registry (\kept -> (Just (fromMaybe [] kept), ()))

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
        TIO.hPutStrLn stderr ("nagarectl trace: stores " <> T.pack (show (length stores)) <> ", wall " <> T.pack (showFFloat (Just 2) (fromIntegral (finished - started) / 1.0e9 :: Double) "") <> " s")
