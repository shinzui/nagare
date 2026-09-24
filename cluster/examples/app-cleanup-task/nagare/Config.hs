{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}

-- | The app-cleanup-task example: the postgres-app web service that co-locates an
-- app-associated scheduled task (MasterPlan 10, IP5). The @cleanup@ task runs
-- nightly (03:00) in the app's deployed image (image = Nothing => inherit) and
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
import Nagare.Dsl.Types (Deployment (..), mkDatabaseName, mkNamespace, mkServiceName)

deployment :: Either String Deployment
deployment = first show $ do
  dep <- webService "postgres-app" "postgres-app"
  db <- mkDatabaseName "pg-main"
  app <- mkServiceName "postgres-app"
  taskN <- mkServiceName "cleanup"
  ns <- mkNamespace "personal"
  sched <- mkSchedule "0 3 * * *"
  cleanup <-
    mkTask
      Task
        { name = taskN
        , logicalKey = Nothing
        , namespace = ns
        , schedule = sched
        , image = Nothing -- inherit postgres-app's image
        , app = Just app
        , command =
            [ "python"
            , "-c"
            , "import os; print('cleanup would run against', os.environ.get('DATABASE_URL', '<unset>'))"
            ]
        , args = []
        , env = Map.empty
        , resources = Nothing
        , timeoutSeconds = Just 300
        , concurrencyPolicy = Forbid
        , restartPolicy = Never
        , backoffLimit = 0
        , successfulJobsHistoryLimit = 3
        , failedJobsHistoryLimit = 1
        , startingDeadlineSeconds = Nothing
        }
  pure (dep & #databases .~ [db] & #tasks .~ [cleanup])

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
