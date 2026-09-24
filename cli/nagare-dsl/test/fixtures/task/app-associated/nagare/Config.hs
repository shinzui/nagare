{-# LANGUAGE OverloadedStrings #-}

-- | A task associated with the @notes@ app. It inherits @notes@'s image
-- (@image = Nothing@) and its runtime env/secret (rendered as an @envFrom@
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
      { name = n
      , logicalKey = Nothing
      , namespace = ns
      , schedule = sched
      , image = Nothing
      , app = Just app
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

main :: IO ()
main = case task of
  Left err -> ioError (userError err)
  Right t -> emitTask t
