{-# LANGUAGE OverloadedStrings #-}

-- | The app-cleanup-task example: the postgres-app web service that co-locates an
-- app-associated scheduled task (MasterPlan 10, IP5). The @cleanup@ task runs
-- nightly (03:00) in the app's deployed image (taskImage = Nothing => inherit) and
-- inherits the app's runtime env/secrets via @envFrom@ — including the
-- @DATABASE_URL@ that EP-46 injects for the referenced @pg-main@ database — so the
-- cleanup reaches the same database the app uses. Its CronJob carries the
-- @nagare.dev/app: postgres-app@ label.
--
-- `nagarectl deploy` provisions the app's Service, its database connection env,
-- AND the task's CronJob in one pass. Run it once on demand with
-- `nagarectl task run postgres-app cleanup`.
--
-- Provision it with:
--   nagarectl deploy -f cluster/examples/app-cleanup-task/nagare/Config.hs
module Main (main) where

import Data.Map qualified as Map
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task
  ( ConcurrencyPolicy (Forbid)
  , RestartPolicy (Never)
  , Task (..)
  , mkSchedule
  , mkTask
  )
import Nagare.Dsl.Types (Deployment (..), mkDatabaseName, mkNamespace, mkServiceName)

deployment :: Either String Deployment
deployment = mapLeft show $ do
  dep <- webService "postgres-app" "postgres-app"
  db <- mkDatabaseName "pg-main"
  app <- mkServiceName "postgres-app"
  taskN <- mkServiceName "cleanup"
  ns <- mkNamespace "personal"
  sched <- mkSchedule "0 3 * * *"
  cleanup <-
    mkTask
      Task
        { taskName = taskN
        , taskNamespace = ns
        , taskSchedule = sched
        , taskImage = Nothing -- inherit postgres-app's image
        , taskApp = Just app
        , taskCommand =
            [ "python"
            , "-c"
            , "import os; print('cleanup would run against', os.environ.get('DATABASE_URL', '<unset>'))"
            ]
        , taskArgs = []
        , taskEnv = Map.empty
        , taskResources = Nothing
        , taskTimeoutSeconds = Just 300
        , taskConcurrencyPolicy = Forbid
        , taskRestartPolicy = Never
        , taskBackoffLimit = 0
        , taskSuccessfulJobsHistoryLimit = 3
        , taskFailedJobsHistoryLimit = 1
        , taskStartingDeadlineSeconds = Nothing
        }
  pure dep {databases = [db], tasks = [cleanup]}
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
