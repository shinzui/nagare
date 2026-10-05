-- | One gate step: an external command run from the repository root with its
-- output captured to a log file, timed, and reduced to an exit code.
module Nagare.Harness.Step
  ( Step (..)
  , StepResult (..)
  , renderCommand
  , runStep
  , runSteps
  , stepSucceeded
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON, ToJSON)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Nagare.Harness.Prelude
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hPutStrLn, withFile)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)

-- | A command the gate runs. @program@ is resolved on @PATH@; @directory@ is
-- relative to the repository root.
data Step = Step
  { name :: !Text
  , directory :: !FilePath
  , program :: !FilePath
  , arguments :: ![String]
  }
  deriving stock (Eq, Show, Generic)

-- | What one step did. @exit@ is the process exit code; 127 means the program
-- could not be started (its reason is in the log).
data StepResult = StepResult
  { name :: !Text
  , command :: !Text
  , exit :: !Int
  , seconds :: !Double
  , logPath :: !FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

stepSucceeded :: StepResult -> Bool
stepSucceeded result = result ^. #exit == 0

renderCommand :: Step -> Text
renderCommand step = T.unwords (map T.pack (step ^. #program : step ^. #arguments))

-- | Run a step in @root@'s @directory@, writing its stdout and stderr to
-- @logDir/<name>.log@.
runStep :: FilePath -> FilePath -> Step -> IO StepResult
runStep root logDir step = do
  let path = logDir </> (T.unpack (step ^. #name) <> ".log")
  started <- getCurrentTime
  code <- withFile path WriteMode $ \handle -> do
    launched <-
      try @IOException $
        createProcess
          (proc (step ^. #program) (step ^. #arguments))
            { cwd = Just (root </> step ^. #directory)
            , std_in = NoStream
            , std_out = UseHandle handle
            , std_err = UseHandle handle
            }
    case launched of
      Left failure -> do
        hPutStrLn handle ("could not start " <> step ^. #program <> ": " <> show failure)
        pure 127
      Right (_, _, _, process) -> do
        exitCode <- waitForProcess process
        pure $ case exitCode of
          ExitSuccess -> 0
          ExitFailure n -> n
  finished <- getCurrentTime
  pure
    StepResult
      { name = step ^. #name
      , command = renderCommand step
      , exit = code
      , seconds = realToFrac (diffUTCTime finished started)
      , logPath = path
      }

-- | Run steps in order, reporting each result, and stop after the first
-- failure. The returned list ends with that failure when there is one.
runSteps :: (StepResult -> IO ()) -> FilePath -> FilePath -> [Step] -> IO [StepResult]
runSteps report workdir logDir = go
  where
    go [] = pure []
    go (step : rest) = do
      result <- runStep workdir logDir step
      report result
      if stepSucceeded result
        then (result :) <$> go rest
        else pure [result]
