{-# LANGUAGE OverloadedStrings #-}

-- | A `notes` app that co-locates an inheriting scheduled task (MasterPlan 10,
-- EP-52): every 15 minutes run `python manage.py sync` in `notes`'s own image
-- (image = Nothing), with `notes`'s runtime env/secret (envFrom) and the
-- predefined NAGARE_* task vars. `nagarectl deploy` resolves the inherited image
-- tag and applies the rendered CronJob alongside the app's Knative Service.
module Main (main) where

import Data.Bifunctor (first)
import Data.Map qualified as Map
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Task
  ( ConcurrencyPolicy (Forbid)
  , RestartPolicy (Never)
  , Task (..)
  , mkSchedule
  , mkTask
  )
import Nagare.Dsl.Types
  ( Deployment (..)
  , mkImageRef
  , mkNamespace
  , mkPort
  , mkServiceName
  )

dep :: Either String Deployment
dep = first show $ do
  name <- mkServiceName "notes"
  ns <- mkNamespace "personal"
  img <- mkImageRef "gcr.io/myproject/notes"
  prt <- mkPort 8080
  bld <- defaultBuild
  sched <- mkSchedule "*/15 * * * *"
  taskN <- mkServiceName "sync"
  syncTask <-
    mkTask
      Task
        { name = taskN
        , logicalKey = Nothing
        , namespace = ns
        , schedule = sched
        , image = Nothing
        , app = Just name
        , command = ["python", "manage.py", "sync"]
        , args = []
        , env = Map.empty
        , resources = Nothing
        , timeoutSeconds = Nothing
        , concurrencyPolicy = Forbid
        , restartPolicy = Never
        , backoffLimit = 2
        , successfulJobsHistoryLimit = 3
        , failedJobsHistoryLimit = 1
        , startingDeadlineSeconds = Nothing
        }
  pure
    Deployment
      { name = name
      , logicalKey = Nothing
      , namespace = ns
      , image = img
      , build = bld
      , domains = []
      , port = prt
      , env = Map.empty
      , resources = Nothing
      , scale = Nothing
      , healthCheck = Nothing
      , volumes = []
      , databases = []
      , tasks = [syncTask]
      , cdn = Nothing
      }

main :: IO ()
main = either (ioError . userError) emitDeployment dep
