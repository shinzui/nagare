{-# LANGUAGE OverloadedStrings #-}

-- | A kizashi-shaped multi-workload Application fixture (MasterPlan 14, EP-2):
-- one web Service (@kizashi-serve@), three background Workers (@kizashi-worker@,
-- @kizashi-escalation-worker@, @kizashi-agent-worker@ — all binding the managed
-- database), one managed Postgres (@kizashi-db@), and one image-inheriting
-- migration Task (@kizashi-migrate@, the pre-deploy hook). All share one image
-- and namespace; a public, pullable image keeps the render offline.
--
-- Note: run by the loader's @runghc -XGHC2024@, so no @DuplicateRecordFields@ —
-- the embedded Database/Worker records use qualified imports (@DB.@/@W.@).
module Main (main) where

import Data.Bifunctor (first)
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
  , mkEnvName
  , mkImageRef
  , mkNamespace
  , mkQuantity
  , mkServiceName
  , runtimeScoped
  )
import Nagare.Dsl.Worker qualified as W
import Nagare.Dsl.Worker (webWorker)

sharedImage :: Text
sharedImage = "gcr.io/knative-samples/helloworld-go"

app :: Either Text Application
app = do
  appNm <- mkServiceName "kizashi"
  ns <- mkNamespace "personal"
  img <- mkImageRef sharedImage
  logLevel <- mkEnvName "LOG_LEVEL"

  dbn <- DB.mkDatabaseName "kizashi-db"
  ver <- DB.mkEngineVersion DB.Postgres "18"
  dbSize <- mkQuantity "10Gi"
  let db =
        DB.Database
          { DB.dbName = dbn
          , DB.engine = DB.Postgres
          , DB.version = ver
          , DB.namespace = ns
          , DB.size = dbSize
          , DB.resources = Nothing
          , DB.retention = Retain
          }

  svc <- webService "kizashi-serve" sharedImage

  worker <- first Text.pack (webWorker "kizashi-worker" sharedImage)
  escalation <- first Text.pack (webWorker "kizashi-escalation-worker" sharedImage)
  agent <- first Text.pack (webWorker "kizashi-agent-worker" sharedImage)
  let bindDb w = w {W.databases = [dbn]}

  migrateNm <- mkServiceName "kizashi-migrate"
  sched <- mkSchedule "0 0 * * *"
  migrate <-
    mkTask
      Task
        { taskName = migrateNm
        , taskNamespace = ns
        , taskSchedule = sched
        , taskImage = Nothing
        , taskApp = Just appNm
        , taskCommand = ["migrate"]
        , taskArgs = []
        , taskEnv = Map.empty
        , taskResources = Nothing
        , taskTimeoutSeconds = Nothing
        , taskConcurrencyPolicy = Forbid
        , taskRestartPolicy = Never
        , taskBackoffLimit = 0
        , taskSuccessfulJobsHistoryLimit = 3
        , taskFailedJobsHistoryLimit = 1
        , taskStartingDeadlineSeconds = Nothing
        }

  mkApplication
    Application
      { appName = appNm
      , namespace = ns
      , image = img
      , env = Map.fromList [(logLevel, runtimeScoped (EnvLiteral "info"))]
      , appDatabases = [db]
      , brokers = []
      , service = Just svc
      , workers = [bindDb worker, bindDb escalation, bindDb agent]
      , tasks = [migrate]
      }

main :: IO ()
main = either (ioError . userError . Text.unpack) emitApplication app
