{-# LANGUAGE OverloadedLabels #-}
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
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Database qualified as DB
import Nagare.Dsl.Prelude
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
import Nagare.Dsl.Worker (webWorker)
import Nagare.Dsl.Worker qualified as W

sharedImage :: Text
sharedImage = "gcr.io/knative-samples/helloworld-go"

application :: Either Text Application
application = do
  appNm <- mkServiceName "kizashi"
  ns <- mkNamespace "personal"
  img <- mkImageRef sharedImage
  logLevel <- mkEnvName "LOG_LEVEL"

  dbn <- DB.mkDatabaseName "kizashi-db"
  ver <- DB.mkEngineVersion DB.Postgres "18"
  dbSize <- mkQuantity "10Gi"
  let db =
        DB.Database
          { DB.name = dbn
          , DB.logicalKey = Nothing
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
  let bindDb w = w & #databases .~ [dbn]

  migrateNm <- mkServiceName "kizashi-migrate"
  sched <- mkSchedule "0 0 * * *"
  migrate <-
    mkTask
      Task
        { name = migrateNm
        , logicalKey = Nothing
        , namespace = ns
        , schedule = sched
        , image = Nothing
        , app = Just appNm
        , command = ["migrate"]
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
        }

  mkApplication
    Application
      { name = appNm
      , logicalKey = Nothing
      , namespace = ns
      , image = img
      , env = Map.fromList [(logLevel, runtimeScoped (EnvLiteral "info"))]
      , databases = [db]
      , brokers = []
      , access = Nothing
      , service = Just svc
      , workers = [bindDb worker, bindDb escalation, bindDb agent]
      , tasks = [migrate]
      }

main :: IO ()
main = either (ioError . userError . Text.unpack) emitApplication application
