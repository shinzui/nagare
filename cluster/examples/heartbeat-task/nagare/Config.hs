{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}

-- | The heartbeat-task example: a minimal app that co-locates a scheduled task
-- (MasterPlan 10). The @heartbeat-app@ web service declares one task,
-- @heartbeat@, that runs every 15 minutes in the app's own image (image =
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

import Data.Bifunctor (first)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
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
deployment = first show $ do
  dep <- webService "heartbeat-app" "heartbeat-app"
  app <- mkServiceName "heartbeat-app"
  taskN <- mkServiceName "heartbeat"
  ns <- mkNamespace "personal"
  sched <- mkSchedule "*/15 * * * *"
  heartbeat <-
    mkTask
      Task
        { name = taskN
        , logicalKey = Nothing
        , namespace = ns
        , schedule = sched
        , image = Nothing -- inherit heartbeat-app's image
        , app = Just app
        , command = ["sh", "-c", "date -u"]
        , args = []
        , env = Map.empty
        , resources = Nothing
        , timeoutSeconds = Just 60
        , concurrencyPolicy = Forbid
        , restartPolicy = Never
        , backoffLimit = 0
        , successfulJobsHistoryLimit = 3
        , failedJobsHistoryLimit = 1
        , startingDeadlineSeconds = Nothing
        }
  pure (dep & #tasks .~ [heartbeat])

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
