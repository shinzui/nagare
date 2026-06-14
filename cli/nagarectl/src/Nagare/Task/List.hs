-- | @nagarectl task list [APP]@ (MasterPlan 10, EP-51): print a table of scheduled
-- tasks in a namespace, discovered by the IP3 labels. Read-only. With no @APP@ it
-- lists every task; with @APP@ it lists only that app's tasks; with the @-@ sentinel
-- it lists only app-less tasks.
module Nagare.Task.List
  ( runTaskList
  ) where

import Nagare.Dsl.Prelude

import Data.Text.IO qualified as TIO
import Nagare.Task.Discover (AppScope, formatTaskTable, listTasks)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Print the @NAME APP SCHEDULE LAST-RUN LAST-SUCCESS ACTIVE@ table for the
-- namespace and app scope.
runTaskList :: Text -> AppScope -> IO ()
runTaskList ns scope = do
  erows <- listTasks ns scope
  case erows of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right rows -> TIO.putStr (formatTaskTable rows)
