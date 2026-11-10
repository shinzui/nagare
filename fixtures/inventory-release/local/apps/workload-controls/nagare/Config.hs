{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The live-confirmation fixture of EP-256 M2: one Application with every
-- workload control of @cluster/examples/workload-controls@, on a real image
-- (see this directory's @Dockerfile@ for the three entrypoints) with a real
-- SQL migration task and one replica each.
--
-- With no account named, each Pod runs tokenless. Set
-- @WORKLOAD_CONTROLS_SERVICE_ACCOUNT@ when loading this file to run web, worker
-- and task under that existing account; it must exist before the review is
-- applied because Knative refuses the Service at admission otherwise.
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Database qualified as DB
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task
  ( ConcurrencyPolicy (..)
  , RestartPolicy (..)
  , Task (..)
  , mkSchedule
  , mkTask
  )
import Nagare.Dsl.Types
  ( EnvVar (..)
  , RetentionPolicy (..)
  , WebProbes (..)
  , httpCheck
  , mkEnvName
  , mkImageRef
  , mkNamespace
  , mkQuantity
  , mkScale
  , mkSecretName
  , mkServiceAccountName
  , mkServiceName
  , runtimeScoped
  )
import Nagare.Dsl.Worker (execProbe, mkCommand, mkShutdownSeconds, webWorker)
import System.Environment (lookupEnv)

applicationConfig :: Text -> Maybe Text -> Either Text Application
applicationConfig registry accountName = do
  appName <- mkServiceName "workload-controls"
  ns <- mkNamespace "personal"
  let sharedImage = registry <> "/workload-controls"
  img <- mkImageRef sharedImage
  account <- traverse mkServiceAccountName accountName

  dbName <- DB.mkDatabaseName "workload-controls-db"
  ver <- DB.mkEngineVersion DB.Postgres "18"
  dbSize <- mkQuantity "1Gi"
  let db =
        DB.Database
          { DB.name = dbName
          , DB.logicalKey = Nothing
          , DB.engine = DB.Postgres
          , DB.version = ver
          , DB.namespace = ns
          , DB.size = dbSize
          , DB.resources = Nothing
          , DB.retention = Delete
          }

  -- Readiness fails while the database is away; liveness does not depend on it.
  ready <- httpCheck "/ready"
  alive <- httpCheck "/healthz"
  started <- httpCheck "/started"
  scale <- mkScale 1 1
  serviceBase <- webService "workload-controls-web" sharedImage
  let service =
        serviceBase
          & #databases .~ [dbName]
          & #scale .~ Just scale
          & #serviceAccount .~ account
          & #probes
            .~ Just
              WebProbes
                { readiness = ready & #period .~ 5 & #timeout .~ 3 & #failureThreshold .~ 3
                , liveness = Just alive
                , startup = Just (started & #failureThreshold .~ 30)
                }

  -- The worker creates the marker once initialization is done and removes it to
  -- report itself unready, without being restarted.
  workerReady <- execProbe ["test", "-f", "/tmp/ready"]
  workerAlive <- execProbe ["test", "-f", "/tmp/alive"]
  shutdownAllowance <- mkShutdownSeconds 60
  workerCommand <- mkCommand ["python", "/app/worker.py"]
  workerBase <- first Text.pack (webWorker "workload-controls-worker" sharedImage)
  let worker =
        workerBase
          & #command .~ Just workerCommand
          & #databases .~ [dbName]
          & #readiness .~ Just workerReady
          & #liveness .~ Just workerAlive
          & #shutdown .~ Just shutdownAllowance
          & #serviceAccount .~ account

  -- A pre-deploy Task sees only the app's env; it names the database's owned
  -- Secret directly to reach the same database.
  databaseUrl <- mkEnvName "DATABASE_URL"
  credential <- mkSecretName (DB.dbSecretName (DB.databaseNameText dbName))
  migrateName <- mkServiceName "workload-controls-migrate"
  sched <- mkSchedule "0 0 * * *"
  migrate <-
    mkTask
      Task
        { name = migrateName
        , logicalKey = Nothing
        , namespace = ns
        , schedule = sched
        , image = Nothing
        , app = Just appName
        , command = ["python", "/app/migrate.py"]
        , args = []
        , env = Map.singleton databaseUrl (runtimeScoped (EnvSecretRef credential))
        , resources = Nothing
        , timeoutSeconds = Nothing
        , concurrencyPolicy = Forbid
        , restartPolicy = Never
        , backoffLimit = 0
        , successfulJobsHistoryLimit = 3
        , failedJobsHistoryLimit = 1
        , startingDeadlineSeconds = Nothing
        , serviceAccount = account
        }

  mkApplication
    Application
      { name = appName
      , logicalKey = Nothing
      , namespace = ns
      , image = img
      , env = Map.empty
      , databases = [db]
      , brokers = []
      , access = Nothing
      , service = Just service
      , workers = [worker]
      , tasks = [migrate]
      }

main :: IO ()
main = do
  registry <- maybe "k3d-registry.localhost:5000" Text.pack <$> lookupEnv "NAGARE_REGISTRY_HOST"
  account <- fmap Text.pack <$> lookupEnv "WORKLOAD_CONTROLS_SERVICE_ACCOUNT"
  either (ioError . userError . Text.unpack) emitApplication (applicationConfig registry account)
