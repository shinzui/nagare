-- | @nagarectl task delete APP TASK@ (MasterPlan 10, EP-51): remove a scheduled
-- task. Deletes its CronJob @nagare-task-<task>@ and any run-history ConfigMap
-- @nagare-task-runs-<task>@, each @--ignore-not-found@ so the command is idempotent.
-- Guarded by @--yes@: without it (or with @--dry-run@), the deletion plan is printed
-- and nothing is deleted. Verifies the task exists first (scoped by @APP@) so a typo
-- fails clearly instead of silently deleting nothing.
module Nagare.Task.Delete
  ( TaskDeleteParams (..)
  , runTaskDelete
  )
where

import Cradle
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude
import Nagare.Task.Discover (AppScope, getTask)
import System.Exit (exitFailure)
import System.IO (stderr)

data TaskDeleteParams = TaskDeleteParams
  { name :: !Text
  , namespace :: !Text
  , scope :: !AppScope
  , yes :: !Bool
  , dryRun :: !Bool
  }
  deriving stock (Generic, Show)

runTaskDelete :: TaskDeleteParams -> IO ()
runTaskDelete p = do
  erow <- getTask (p ^. #namespace) (p ^. #scope) (p ^. #name)
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right _ -> do
      let ns = p ^. #namespace
          objs = objectsToDelete (p ^. #name)
      if not (p ^. #yes) || p ^. #dryRun
        then
          TIO.putStr $
            T.unlines (["Would delete (run again with --yes):"] <> map ("  " <>) objs)
        else do
          mapM_ (deleteObj ns) objs
          TIO.putStrLn ("Deleted task " <> p ^. #name)

-- | The objects deleted for one task: its CronJob, then any run-history ConfigMap.
objectsToDelete :: Text -> [Text]
objectsToDelete task =
  [ "cronjob/nagare-task-" <> task
  , "configmap/nagare-task-runs-" <> task
  ]

deleteObj :: Text -> Text -> IO ()
deleteObj ns obj =
  run_ $
    cmd "kubectl"
      & addArgs ["delete", T.unpack obj, "-n", T.unpack ns, "--ignore-not-found"]
