-- | The version-one run index (EP-229): one JSON file per release run that
-- names the candidate, its source, each step, each reviewed stage with its
-- review and plan log, each apply or resume attempt with its transaction and
-- outcome, the records the run wrote and the indexes of the runs it started.
-- It is rewritten atomically after every step, stage and attempt, so an
-- interrupted run leaves an index that says how far it got. Paths are
-- relative to the index's directory unless they lie outside it.
--
-- EP-224 M2's cost collector reads it and EP-228 M3 extends it; a field that
-- changes meaning bumps 'runIndexVersion'.
module Nagare.Harness.Release.RunIndex
  ( RunIndex
  , RunStatus (..)
  , Revisioned (Revisioned)
  , StepEntry
  , StageEntry (StageEntry)
  , Attempt (Attempt)
  , IndexWriter
  , runIndexVersion
  , newRunIndex
  , openIndex
  , indexPath
  , relativeIn
  , updateIndex
  , withRunIndex
  , indexStep
  , beginStep
  , advance
  , endStep
  , addStage
  , addAttempt
  , setRecord
  , setChild
  )
where

import Control.Exception (SomeException, fromException, throwIO, try)
import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), camelTo2, defaultOptions, genericParseJSON, genericToJSON)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (stripPrefix)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime)
import Nagare.Harness.Prelude
import Nagare.Harness.Release.Process (Refusal (..), Runtime)
import Nagare.Harness.Release.Records (writeSortedAtomically)
import System.FilePath (addTrailingPathSeparator, takeDirectory)

runIndexVersion :: Int
runIndexVersion = 1

data RunStatus = Running | Passed | Failed
  deriving stock (Eq, Show, Generic)

instance ToJSON RunStatus where toJSON = genericToJSON defaultOptions {constructorTagModifier = camelTo2 '-'}

instance FromJSON RunStatus where parseJSON = genericParseJSON defaultOptions {constructorTagModifier = camelTo2 '-'}

-- | A release as far as the run knows it.
data Revisioned = Revisioned
  { version :: !(Maybe Text)
  , revision :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One named step of a candidate or rehearsal run.
data StepEntry = StepEntry
  { name :: !Text
  , status :: !RunStatus
  , startedAt :: !UTCTime
  , finishedAt :: !(Maybe UTCTime)
  , logFile :: !(Maybe FilePath)
  , background :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One apply or resume of a stage's review.
data Attempt = Attempt
  { attemptId :: !Text
  , action :: !Text
  , transaction :: !(Maybe Text)
  , outcome :: !Text
  , logFile :: !FilePath
  , document :: !(Maybe FilePath)
  , startedAt :: !UTCTime
  , finishedAt :: !UTCTime
  , trace :: !(Maybe FilePath)
  -- ^ EP-224: the command trace nagarectl wrote for this attempt.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One planned stage: its review, what the plan counted, whether it was the
-- converged one, and the attempts that applied it.
data StageEntry = StageEntry
  { stageId :: !Text
  , loop :: !Text
  , number :: !Int
  , review :: !FilePath
  , planLog :: !FilePath
  , summary :: !(Maybe FilePath)
  , operations :: !Int
  , reaccepted :: !Int
  , converged :: !Bool
  , plannedAt :: !UTCTime
  , attempts :: ![Attempt]
  , trace :: !(Maybe FilePath)
  -- ^ EP-224: the command trace of the stage's plan.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @kind@ is @candidate@, @intranet@, @rehearsal@ or @drill@; @profile@ is
-- @release@, @intranet@ or @local-rehearsal@, so measurements of a local
-- rehearsal and of the intranet are never conflated.
data RunIndex = RunIndex
  { schemaVersion :: !Int
  , kind :: !Text
  , profile :: !Text
  , context :: !(Maybe Text)
  , candidate :: !Revisioned
  , source :: !Revisioned
  , status :: !RunStatus
  , detail :: !(Maybe Text)
  , startedAt :: !UTCTime
  , updatedAt :: !UTCTime
  , steps :: ![StepEntry]
  , stages :: ![StageEntry]
  , records :: !(Map Text FilePath)
  , children :: !(Map Text FilePath)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newRunIndex :: Text -> Text -> UTCTime -> RunIndex
newRunIndex kind' profile' at' =
  RunIndex
    { schemaVersion = runIndexVersion
    , kind = kind'
    , profile = profile'
    , context = Nothing
    , candidate = Revisioned Nothing Nothing
    , source = Revisioned Nothing Nothing
    , status = Running
    , detail = Nothing
    , startedAt = at'
    , updatedAt = at'
    , steps = []
    , stages = []
    , records = Map.empty
    , children = Map.empty
    }

data IndexWriter = IndexWriter
  { file :: !FilePath
  , current :: !(IORef RunIndex)
  , clock :: !(IO UTCTime)
  }
  deriving stock (Generic)

-- | Start an index at @path@ and write it.
openIndex :: Runtime -> FilePath -> RunIndex -> IO IndexWriter
openIndex runtime path initial = do
  ref <- newIORef initial
  let writer = IndexWriter {file = path, current = ref, clock = runtime ^. #now}
  updateIndex writer id
  pure writer

indexPath :: IndexWriter -> FilePath
indexPath writer = writer ^. #file

-- | @path@ relative to the index's directory when it lies inside it.
relativeIn :: IndexWriter -> FilePath -> FilePath
relativeIn writer path = fromMaybe path (stripPrefix (addTrailingPathSeparator (takeDirectory (writer ^. #file))) path)

updateIndex :: IndexWriter -> (RunIndex -> RunIndex) -> IO ()
updateIndex writer change = do
  at' <- writer ^. #clock
  value <- (& #updatedAt .~ at') . change <$> readIORef (writer ^. #current)
  writeIORef (writer ^. #current) value
  writeSortedAtomically (writer ^. #file) (toJSON value)

-- | Run the whole command: the index ends @passed@, or @failed@ with the
-- refusal that stopped it.
withRunIndex :: IndexWriter -> IO a -> IO a
withRunIndex writer action = do
  outcome <- try action
  case outcome of
    Right value -> do
      at' <- writer ^. #clock
      let finish entry
            | entry ^. #status == Running = entry & #status .~ Passed & #finishedAt ?~ at'
            | otherwise = entry
      updateIndex writer ((#status .~ Passed) . (#steps %~ map finish))
      pure value
    Left (failure :: SomeException) -> do
      let reason = case fromException failure of
            Just (Refusal text) -> text
            Nothing -> T.pack (show failure)
      at' <- writer ^. #clock
      let stopped entry
            | entry ^. #status == Running = entry & #status .~ Failed & #finishedAt ?~ at'
            | otherwise = entry
      updateIndex writer ((#status .~ Failed) . (#detail ?~ reason) . (#steps %~ map stopped))
      throwIO failure

-- | Record a named step around an action.
indexStep :: IndexWriter -> Text -> Maybe FilePath -> IO a -> IO a
indexStep writer name' logFile' action = do
  beginStep writer name' logFile' False
  outcome <- try action
  case outcome of
    Right value -> endStep writer name' True >> pure value
    Left (failure :: SomeException) -> endStep writer name' False >> throwIO failure

beginStep :: IndexWriter -> Text -> Maybe FilePath -> Bool -> IO ()
beginStep writer name' logFile' background' = do
  at' <- writer ^. #clock
  updateIndex writer (#steps %~ (<> [StepEntry name' Running at' Nothing (relativeIn writer <$> logFile') background']))

-- | End the running foreground step, if any, and begin the next one.
advance :: IndexWriter -> Text -> Maybe FilePath -> IO ()
advance writer name' logFile' = do
  at' <- writer ^. #clock
  let finish entry
        | entry ^. #status == Running && not (entry ^. #background) = entry & #status .~ Passed & #finishedAt ?~ at'
        | otherwise = entry
  updateIndex writer (#steps %~ map finish)
  beginStep writer name' logFile' False

endStep :: IndexWriter -> Text -> Bool -> IO ()
endStep writer name' passed = do
  at' <- writer ^. #clock
  let finish entry
        | entry ^. #name == name' && entry ^. #status == Running = entry & #status .~ (if passed then Passed else Failed) & #finishedAt ?~ at'
        | otherwise = entry
  updateIndex writer (#steps %~ map finish)

addStage :: IndexWriter -> StageEntry -> IO ()
addStage writer stage = updateIndex writer (#stages %~ (<> [stage]))

-- | Append an attempt to the stage with this id.
addAttempt :: IndexWriter -> Text -> Attempt -> IO ()
addAttempt writer stage attempt =
  updateIndex writer (#stages %~ map (\entry -> if entry ^. #stageId == stage then entry & #attempts %~ (<> [attempt]) else entry))

setRecord :: IndexWriter -> Text -> FilePath -> IO ()
setRecord writer key path = updateIndex writer (#records %~ Map.insert key (relativeIn writer path))

setChild :: IndexWriter -> Text -> FilePath -> IO ()
setChild writer key path = updateIndex writer (#children %~ Map.insert key (relativeIn writer path))
