{-# LANGUAGE OverloadedStrings #-}

-- | The heartbeat-task example: a minimal app that co-locates a scheduled task
-- (MasterPlan 10). The @heartbeat-app@ web service declares one task,
-- @heartbeat@, that runs every 15 minutes in the app's own image (taskImage =
-- Nothing => inherit) and prints the current UTC time. `nagarectl deploy`
-- provisions the app's Knative Service AND the task's CronJob in one pass.
--
-- A scheduled task is provisioned by co-locating it in an app's @tasks@ list and
-- running `nagarectl deploy` — there is no separate "apply a standalone task"
-- command. The task carries the @nagare.dev/app: heartbeat-app@ label, so
-- `nagarectl task list heartbeat-app` scopes to it.
--
-- Provision it with:
--   nagarectl deploy -f cluster/examples/heartbeat-task/nagare/Config.hs
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
import Nagare.Dsl.Types (Deployment (..), mkNamespace, mkServiceName)

deployment :: Either String Deployment
deployment = mapLeft show $ do
  dep <- webService "heartbeat-app" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/heartbeat-app"
  app <- mkServiceName "heartbeat-app"
  taskN <- mkServiceName "heartbeat"
  ns <- mkNamespace "personal"
  sched <- mkSchedule "*/15 * * * *"
  heartbeat <-
    mkTask
      Task
        { taskName = taskN
        , taskNamespace = ns
        , taskSchedule = sched
        , taskImage = Nothing -- inherit heartbeat-app's image
        , taskApp = Just app
        , taskCommand = ["sh", "-c", "date -u"]
        , taskArgs = []
        , taskEnv = Map.empty
        , taskResources = Nothing
        , taskTimeoutSeconds = Just 60
        , taskConcurrencyPolicy = Forbid
        , taskRestartPolicy = Never
        , taskBackoffLimit = 0
        , taskSuccessfulJobsHistoryLimit = 3
        , taskFailedJobsHistoryLimit = 1
        , taskStartingDeadlineSeconds = Nothing
        }
  pure dep {tasks = [heartbeat]}
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
