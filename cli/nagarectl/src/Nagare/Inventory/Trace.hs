-- | EP-224: the producer of one command's trace document
-- ("Nagare.Contract.Trace"). @NAGARE_TRACE=1@ prints the human summary on
-- stderr; @NAGARE_TRACE_FILE=PATH@ alone enables collection and writes the
-- document there, privately and atomically, however the command ends. A
-- failure to write the trace is reported and never replaces the command's
-- own result.
module Nagare.Inventory.Trace
  ( withCommandTrace
  , withCommandScope
  , traceDocument
  , commandTraceDocument
  , commandOutcome
  , writeTraceDocument
  )
where

import Control.Exception (AsyncException (UserInterrupt), IOException, SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad (mfilter)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Traversable (for)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Contract.Trace
import Nagare.Dsl.Prelude
import Nagare.Inventory.ClusterSession (withCommandClusterSessions)
import Nagare.Inventory.Store.Counters
import Nagare.Inventory.Store.Remote (withCommandRemoteStores)
import System.Directory (removeFile, renameFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hClose, openBinaryTempFile, stderr)
import System.Posix.Files (setFileMode)

-- | A command's scope: its trace and, inside it, its cluster sessions
-- (EP-226) and remote stores (EP-224), so admissions and opens are traced.
withCommandScope :: Text -> IO a -> IO a
withCommandScope command = withCommandTrace command . withCommandClusterSessions . withCommandRemoteStores

-- | Run a command under the tracing the environment selects. The command is
-- named by the caller, never by its arguments.
withCommandTrace :: Text -> IO a -> IO a
withCommandTrace name action = do
  summary <- (== Just "1") <$> lookupEnv "NAGARE_TRACE"
  file <- mfilter (not . null) <$> lookupEnv "NAGARE_TRACE_FILE"
  if not summary && isNothing file
    then action
    else do
      enableStoreTrace
      started <- getMonotonicTimeNSec
      result <- try action
      when summary (printTraceSummary started)
      for_ file $ \path -> do
        document <- traceDocument name (either commandOutcome (const OutcomeCompleted) result)
        written <- try (writeTraceDocument path document)
        case written of
          Left (failure :: IOException) -> TIO.hPutStrLn stderr ("nagarectl trace: could not write " <> T.pack path <> ": " <> T.pack (show failure))
          Right () -> pure ()
      either throwIO pure result

-- | How an exception ends a command: an exit status keeps its meaning, an
-- interrupt or asynchronous cancellation is a cancellation, anything else
-- is a failure.
commandOutcome :: SomeException -> TraceOutcome
commandOutcome failure
  | Just ExitSuccess <- fromException failure = OutcomeCompleted
  | Just (ExitFailure _) <- fromException failure = OutcomeFailed
  | Just UserInterrupt <- fromException failure = OutcomeCancelled
  | Just (_ :: SomeAsyncException) <- fromException failure = OutcomeCancelled
  | otherwise = OutcomeFailed

-- | The document of everything recorded since tracing was enabled.
traceDocument :: Text -> TraceOutcome -> IO TraceDocument
traceDocument name outcome = do
  now <- getMonotonicTimeNSec
  recorded <- currentCommandTrace
  stores <- tracedStoreCounters
  storeCounts <- fmap concat . for stores $ \counters -> do
    snapshot <- snapshotCounters counters
    pure
      [ TraceCount CategoryStore (counterLabel counter) n (round (elapsed * 1.0e9)) 0 0
      | (counter, (n, elapsed)) <- Map.toAscList snapshot
      ]
  pure (documentFrom name outcome now recorded storeCounts)

-- | The document of a trace a test collected, as of now.
commandTraceDocument :: Text -> TraceOutcome -> CommandTrace -> IO TraceDocument
commandTraceDocument name outcome traced = do
  now <- getMonotonicTimeNSec
  pure (documentFrom name outcome now (Just traced) [])

documentFrom :: Text -> TraceOutcome -> Word64 -> Maybe CommandTrace -> [TraceCount] -> TraceDocument
documentFrom name outcome now recorded storeCounts =
  TraceDocument traceSchemaVersion name outcome elapsed spans (mergeStores <> wire <> others) operations
  where
    elapsed = maybe 0 (\traced -> now - min now (traced ^. #origin)) recorded
    spans = maybe [] (sortOn (^. #spanId) . (^. #spans)) recorded
    wire =
      [ TraceCount CategoryWire (requestLabel request <> " " <> classLabel objects) n 0 bodies bytes
      | Just traced <- [recorded]
      , ((request, objects), (n, bodies, bytes)) <- Map.toAscList (traced ^. #wire)
      ]
    others =
      [ TraceCount category counted n nanos 0 0
      | Just traced <- [recorded]
      , ((category, counted), (n, nanos)) <- Map.toAscList (traced ^. #counts)
      ]
    operations =
      [ OperationCount kind action executor n
      | Just traced <- [recorded]
      , ((kind, action, executor), n) <- Map.toAscList (traced ^. #operations)
      ]
    -- Several stores of one command sum into one count per counter.
    mergeStores =
      [ TraceCount CategoryStore counted n nanos 0 0
      | (counted, (n, nanos)) <- Map.toAscList (Map.fromListWith (\(a, b) (c, d) -> (a + c, b + d :: Word64)) [(entry ^. #name, (entry ^. #count, entry ^. #nanos)) | entry <- storeCounts])
      ]

-- | Write the document beside its destination and rename it into place, so
-- a reader sees the whole document or none. It is readable by its owner only.
writeTraceDocument :: FilePath -> TraceDocument -> IO ()
writeTraceDocument path document = do
  (temporary, handle) <- openBinaryTempFile (takeDirectory path) ("." <> takeFileName path <> "-")
  setFileMode temporary 0o600
  written <- try (BL.hPut handle (encode document) >> hClose handle >> renameFile temporary path)
  case written of
    Left (failure :: IOException) -> hClose handle >> void (try @IOException (removeFile temporary)) >> throwIO failure
    Right () -> pure ()
