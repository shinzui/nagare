{-# LANGUAGE PackageImports #-}

-- | @nagarectl task delete APP TASK@ (MasterPlan 10, EP-51): remove a scheduled
-- task. Deletes its CronJob @nagare-task-<task>@ and any run-history ConfigMap
-- @nagare-task-runs-<task>@, each @--ignore-not-found@ so the command is idempotent.
-- Guarded by @--yes@: without it (or with @--dry-run@), the deletion plan is printed
-- and nothing is deleted. Verifies the task exists first (scoped by @APP@) so a typo
-- fails clearly instead of silently deleting nothing.
module Nagare.Task.Delete
  ( TaskDeleteParams (..)
  , runTaskDelete
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Task.Discover (AppScope, getTask)
import System.Exit (exitFailure)
import System.IO (stderr)

data TaskDeleteParams = TaskDeleteParams
  { tdpName :: !Text
  , tdpNamespace :: !Text
  , tdpScope :: !AppScope
  , tdpYes :: !Bool
  , tdpDryRun :: !Bool
  }
  deriving stock (Generic, Show)

runTaskDelete :: TaskDeleteParams -> IO ()
runTaskDelete p = do
  erow <- getTask (tdpNamespace p) (tdpScope p) (tdpName p)
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right _ -> do
      let ns = tdpNamespace p
          objs = objectsToDelete (tdpName p)
      if not (tdpYes p) || tdpDryRun p
        then
          TIO.putStr $
            T.unlines (["Would delete (run again with --yes):"] <> map ("  " <>) objs)
        else do
          mapM_ (deleteObj ns) objs
          TIO.putStrLn ("Deleted task " <> tdpName p)

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
