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
      { name = n
      , namespace = ns
      , schedule = sched
      , image = Just img
      , app = Nothing
      , command = ["python", "manage.py", "cleanup"]
      , args = []
      , env = Map.fromList [(varName, runtimeScoped (EnvLiteral "false"))]
      , resources = Nothing
      , timeoutSeconds = Just 600
      , concurrencyPolicy = Forbid
      , restartPolicy = Never
      , backoffLimit = 0
      , successfulJobsHistoryLimit = 3
      , failedJobsHistoryLimit = 1
      , startingDeadlineSeconds = Nothing
      }

main :: IO ()
main = case task of
  Left err -> ioError (userError err)
  Right t -> emitTask t
