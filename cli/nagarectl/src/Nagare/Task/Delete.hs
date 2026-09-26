-- | Read-only preview of scheduled task retirement (EP-51).
-- Live task deletion saves suspension, retention, and exact collection reviews.
module Nagare.Task.Delete
  ( previewTaskDelete
  )
where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude
import Nagare.Task.Discover (AppScope, getTask)
import System.Exit (exitFailure)
import System.IO (stderr)

previewTaskDelete :: Text -> AppScope -> Text -> IO ()
previewTaskDelete ns scope name = do
  erow <- getTask ns scope name
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right _ ->
      TIO.putStr $
        T.unlines
          [ "Would review CronJob suspension, retention, and conditional collection:"
          , "  cronjob/nagare-task-" <> name
          , "Run task delete --save-plan DIR, apply it, and repeat for each stage."
          ]
