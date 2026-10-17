-- | The machine-readable outcome of a command run with @--contract 1@
-- (EP-192).
--
-- The sink is set once, when the flag is parsed. While it is set, a refusal
-- prints one @transaction-outcome@ document on stdout instead of its stderr
-- line: @refused@ (exit 2) before admission completes, so no provider was
-- touched, and @interrupted@ (exit 7) with the transaction once execution may
-- have written intent. A transaction result prints its own outcome and exit
-- code. Without the sink every refusal behaves exactly as before.
module Nagare.Contract.Sink
  ( setContractSink
  , setContractSinkTo
  , clearContractSink
  , contractSinkSet
  , markExecuting
  , refuseWith
  , reportTransaction
  , emitDocument
  , progressLine
  , withContractOutcome
  , withContract
  , withReadContract
  , transactionOutcome
  , transactionExitCode
  )
where

import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Data.Aeson (ToJSON, encode)
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Contract.Problem (ProblemDetails, ProblemSpec, problemFor, unclassified, unsupportedContractVersion)
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), nullable)
import Nagare.Contract.V1 (FailureClass (..), Outcome (..), TransactionOutcome (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (ReviewBarrier (..))
import Nagare.Inventory.Execute.Types (TransactionResult (..))
import Nagare.Inventory.Journal (operationIdText, transactionIdText)
import Nagare.Inventory.Journal qualified as Journal
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (stderr)
import System.IO.Unsafe (unsafePerformIO)

-- | Where a contract command is: admitting (nothing touched yet), executing
-- a transaction, or reading, where a refusal is a bare problem document.
data Phase = Admitting | Executing !Text | Reading

sink :: IORef (Maybe Phase)
sink = unsafePerformIO (newIORef Nothing)
{-# NOINLINE sink #-}

-- | Where the document goes: stdout, unless a test collects it.
output :: IORef (LBC.ByteString -> IO ())
output = unsafePerformIO (newIORef LBC.putStrLn)
{-# NOINLINE output #-}

setContractSink :: IO ()
setContractSink = writeIORef sink (Just Admitting)

setReadSink :: IO ()
setReadSink = writeIORef sink (Just Reading)

-- | Set the sink with another destination for its documents.
setContractSinkTo :: (LBC.ByteString -> IO ()) -> IO ()
setContractSinkTo destination = writeIORef output destination >> setContractSink

clearContractSink :: IO ()
clearContractSink = writeIORef sink Nothing >> writeIORef output LBC.putStrLn

contractSinkSet :: IO Bool
contractSinkSet = isJust <$> readIORef sink

-- | Admission completed; a later failure may follow an effect.
markExecuting :: Text -> IO ()
markExecuting transaction = do
  current <- readIORef sink
  when (isJust current) (writeIORef sink (Just (Executing transaction)))

-- | Refuse with @line@ on stderr, or, under the sink, with the outcome
-- document whose problem has @spec@'s code and @detail@.
refuseWith :: Text -> ProblemSpec -> Text -> IO a
refuseWith line spec detailText = do
  current <- readIORef sink
  case current of
    Nothing -> TIO.hPutStrLn stderr line >> exitFailure
    Just Admitting -> emit (refused (problemFor spec detailText)) (ExitFailure 2)
    Just (Executing transaction) -> emit (interrupted transaction detailText) (ExitFailure 7)
    Just Reading -> emitDocument (problemFor spec detailText) >> exitWith (ExitFailure 2)

-- | Print a transaction's result: its human line (exit 1 unless converged),
-- or under the sink its outcome document and distinct exit code. A converged
-- result returns, so the caller can finish its own work.
reportTransaction :: Text -> TransactionResult -> IO ()
reportTransaction line result = do
  current <- readIORef sink
  case current of
    Nothing -> TIO.putStrLn line >> unless (isConverged result) exitFailure
    Just _ -> do
      emitDocument (transactionOutcome result)
      case transactionExitCode result of
        ExitSuccess -> pure ()
        code -> exitWith code
  where
    isConverged = \case
      Converged _ -> True
      _ -> False

-- | Print a contract document on the sink's destination.
emitDocument :: (ToJSON a) => a -> IO ()
emitDocument document = readIORef output >>= \destination -> destination (encode document)

-- | A human progress line: stdout, or stderr under the sink, where stdout
-- holds only the document.
progressLine :: Text -> IO ()
progressLine line = contractSinkSet >>= \set -> if set then TIO.hPutStrLn stderr line else TIO.putStrLn line

-- | Under the sink, an unexpected exception is a refusal before admission
-- and an interruption after it, never an unformatted crash.
withContractOutcome :: IO a -> IO a
withContractOutcome action = do
  outcome <- try action
  case outcome of
    Right value -> pure value
    Left (failure :: SomeException)
      | Just (_ :: ExitCode) <- fromException failure -> throwIO failure
      | Just (_ :: SomeAsyncException) <- fromException failure -> throwIO failure
      | otherwise -> do
          set <- contractSinkSet
          if set then refuseWith "" unclassified (T.pack (displayException failure)) else throwIO failure

-- | Run a command under @--contract VERSION@: version 1 sets the sink;
-- any other version is refused with the supported list.
withContract :: Maybe Int -> IO () -> IO ()
withContract = withContractIn setContractSink

-- | 'withContract' for a read command: a refusal prints a problem document
-- and exits 2; the read document itself exits 0.
withReadContract :: Maybe Int -> IO () -> IO ()
withReadContract = withContractIn setReadSink

withContractIn :: IO () -> Maybe Int -> IO () -> IO ()
withContractIn set requested action = case requested of
  Nothing -> action
  Just 1 -> set >> withContractOutcome action
  Just other -> do
    set
    refuseWith "" unsupportedContractVersion ("contract version " <> T.pack (show other) <> " is not supported; supported versions: 1")

emit :: TransactionOutcome -> ExitCode -> IO a
emit document code = emitDocument document >> exitWith code

-- | 0 converged, 3 paused, 4 stopped, 5 ambiguous, 6 closed; a refusal is 2
-- and an interruption 7.
transactionExitCode :: TransactionResult -> ExitCode
transactionExitCode = \case
  Converged _ -> ExitSuccess
  PausedAtBarrier _ _ -> ExitFailure 3
  StoppedFailed {} -> ExitFailure 4
  StoppedAmbiguous {} -> ExitFailure 5
  Closed _ -> ExitFailure 6

transactionOutcome :: TransactionResult -> TransactionOutcome
transactionOutcome = \case
  Converged transaction -> base OutcomeConverged (Just transaction) Nothing
  PausedAtBarrier transaction barriers ->
    (base OutcomePaused (Just transaction) Nothing) {barriers = [operationIdText (barrierOperation barrier) <> ": " <> barrierReason barrier | barrier <- NE.toList barriers]}
  StoppedFailed transaction operation failureClass ->
    (base OutcomeStopped (Just transaction) (Just operation))
      { failureClass = nullable (Just (classOf failureClass))
      , detail = nullable (Just (reasonOf failureClass))
      }
  StoppedAmbiguous transaction operation reason ->
    (base OutcomeAmbiguous (Just transaction) (Just operation)) {detail = nullable (Just reason)}
  Closed transaction -> base OutcomeClosed (Just transaction) Nothing
  where
    base result transaction operation =
      TransactionOutcome
        { contractVersion = ContractVersion1
        , document = DocumentName
        , outcome = result
        , transaction = nullable (transactionIdText <$> transaction)
        , operation = nullable (operationIdText <$> operation)
        , failureClass = nullable Nothing
        , barriers = []
        , detail = nullable Nothing
        , problem = nullable Nothing
        }
    classOf = \case
      Journal.KnownNoEffect _ -> FailureKnownNoEffect
      Journal.PartialOrUnknown _ -> FailurePartialOrUnknown
    reasonOf = \case
      Journal.KnownNoEffect reason -> reason
      Journal.PartialOrUnknown reason -> reason

refused :: ProblemDetails -> TransactionOutcome
refused problemValue = (blank OutcomeRefused) {problem = nullable (Just problemValue)}

interrupted :: Text -> Text -> TransactionOutcome
interrupted transaction reason = (blank OutcomeInterrupted) {transaction = nullable (Just transaction), detail = nullable (Just reason)}

blank :: Outcome -> TransactionOutcome
blank result =
  TransactionOutcome
    { contractVersion = ContractVersion1
    , document = DocumentName
    , outcome = result
    , transaction = nullable Nothing
    , operation = nullable Nothing
    , failureClass = nullable Nothing
    , barriers = []
    , detail = nullable Nothing
    , problem = nullable Nothing
    }
