{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | One Application that uses every workload control: a web Service with
-- independent readiness, liveness and startup checks, a worker that reports
-- readiness from a marker file and gets a 60-second shutdown allowance, and a
-- migration task. None of the three names a service account, so each Pod runs
-- with no Kubernetes API token.
--
-- A public, pullable image keeps the @examples-compile@ flake check free of a
-- private registry. See this example's README before deploying it.
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
  ( RetentionPolicy (..)
  , WebProbes (..)
  , httpCheck
  , mkImageRef
  , mkNamespace
  , mkQuantity
  , mkServiceName
  )
import Nagare.Dsl.Worker (execProbe, mkShutdownSeconds, webWorker)

sharedImage :: Text
sharedImage = "gcr.io/knative-samples/helloworld-go"

applicationConfig :: Either Text Application
applicationConfig = do
  appName <- mkServiceName "workload-controls"
  ns <- mkNamespace "personal"
  img <- mkImageRef sharedImage

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
  serviceBase <- webService "workload-controls-web" sharedImage
  let service =
        serviceBase
          & #databases .~ [dbName]
          & #probes
            .~ Just
              WebProbes
                { readiness = ready
                , liveness = Just alive
                , startup = Just (started & #failureThreshold .~ 30)
                }

  -- The worker creates the marker once initialization is done and removes it to
  -- report itself unready, without being restarted.
  workerReady <- execProbe ["test", "-f", "/tmp/ready"]
  workerAlive <- execProbe ["test", "-f", "/tmp/alive"]
  shutdownAllowance <- mkShutdownSeconds 60
  workerBase <- first Text.pack (webWorker "workload-controls-worker" sharedImage)
  let worker =
        workerBase
          & #databases .~ [dbName]
          & #readiness .~ Just workerReady
          & #liveness .~ Just workerAlive
          & #shutdown .~ Just shutdownAllowance

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
        , command = ["/app/migrate"]
        , args = []
        , env = Map.empty
        , resources = Nothing
        , timeoutSeconds = Nothing
        , concurrencyPolicy = Forbid
        , restartPolicy = Never
        , backoffLimit = 0
        , successfulJobsHistoryLimit = 3
        , failedJobsHistoryLimit = 1
        , startingDeadlineSeconds = Nothing
        , serviceAccount = Nothing
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
main = either (ioError . userError . Text.unpack) emitApplication applicationConfig
