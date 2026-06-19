{-# LANGUAGE OverloadedStrings #-}

-- | A standalone scheduled-task descriptor — the config-as-program surface a
-- task author ships. @nagarectl@/the loader compiles-and-runs it; every field
-- is built through EP-50's smart constructors, so a bad value is a compile-time
-- or load-time error. This task runs in its own image with its own env; it does
-- not reference an app.
module Main (main) where

import Data.Bifunctor (first)
import Data.Map qualified as Map
import Nagare.Dsl.Config (emitTask)
import Nagare.Dsl.Task
import Nagare.Dsl.Types
  ( EnvVar (EnvLiteral)
  , mkEnvName
  , mkImageRef
  , mkNamespace
  , mkServiceName
  , runtimeScoped
  )

task :: Either String Task
task = first show $ do
  n <- mkServiceName "cleanup"
  ns <- mkNamespace "personal"
  sched <- mkSchedule "0 3 * * *"
  img <- mkImageRef "gcr.io/myproject/notes"
  varName <- mkEnvName "DRY_RUN"
  mkTask
    Task
      { taskName = n
      , taskNamespace = ns
      , taskSchedule = sched
      , taskImage = Just img
      , taskApp = Nothing
      , taskCommand = ["python", "manage.py", "cleanup"]
      , taskArgs = []
      , taskEnv = Map.fromList [(varName, runtimeScoped (EnvLiteral "false"))]
      , taskResources = Nothing
      , taskTimeoutSeconds = Just 600
      , taskConcurrencyPolicy = Forbid
      , taskRestartPolicy = Never
      , taskBackoffLimit = 0
      , taskSuccessfulJobsHistoryLimit = 3
      , taskFailedJobsHistoryLimit = 1
      , taskStartingDeadlineSeconds = Nothing
      }

main :: IO ()
main = case task of
  Left err -> ioError (userError err)
  Right t -> emitTask t
