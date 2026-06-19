{-# LANGUAGE OverloadedStrings #-}

-- | A task associated with the @notes@ app. It inherits @notes@'s image
-- (@taskImage = Nothing@) and its runtime env/secret (rendered as an @envFrom@
-- block), and carries the @nagare.dev/app@ label. EP-52 resolves the inherited
-- image tag and the managed env/secret resources at deploy time; this fixture
-- proves the model and the rendered shape.
module Main (main) where

import Data.Bifunctor (first)
import Data.Map qualified as Map
import Nagare.Dsl.Config (emitTask)
import Nagare.Dsl.Task
import Nagare.Dsl.Types (mkNamespace, mkServiceName)

task :: Either String Task
task = first show $ do
  n <- mkServiceName "sync"
  ns <- mkNamespace "personal"
  sched <- mkSchedule "*/15 * * * *"
  app <- mkServiceName "notes"
  mkTask
    Task
      { taskName = n
      , taskNamespace = ns
      , taskSchedule = sched
      , taskImage = Nothing
      , taskApp = Just app
      , taskCommand = ["python", "manage.py", "sync"]
      , taskArgs = []
      , taskEnv = Map.empty
      , taskResources = Nothing
      , taskTimeoutSeconds = Nothing
      , taskConcurrencyPolicy = Forbid
      , taskRestartPolicy = Never
      , taskBackoffLimit = 2
      , taskSuccessfulJobsHistoryLimit = 3
      , taskFailedJobsHistoryLimit = 1
      , taskStartingDeadlineSeconds = Nothing
      }

main :: IO ()
main = case task of
  Left err -> ioError (userError err)
  Right t -> emitTask t
