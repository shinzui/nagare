{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}

-- | The multi-workload Application example (MasterPlan 14, EP-1): ONE logical app
-- described as ONE typed 'Application', fanned out into several Kubernetes objects
-- across four kinds under one shared identity (the @nagare.dev/app@ label).
--
-- This is the @shinzui/kizashi@ shape the aggregate was built for:
--
--   * one web Service     — @kizashi-serve@ (the HTTP API)
--   * two background Workers — @kizashi-worker@, @kizashi-agent-worker@
--     (NOTIFY/timer reactors; both bind the managed database)
--   * one managed Database — @kizashi-db@ (Postgres 18)
--   * one migration Task   — @kizashi-migrate@ (inherits the app image; EP-2 runs
--     it as a pre-deploy hook, before the Service and Workers boot)
--
-- The image, namespace, env, and database binding are declared ONCE on the
-- 'Application' and validated to agree with every workload (a worker pointing at
-- an undeclared database, or disagreeing on the shared image, is rejected at
-- config-load time). A public, pullable image is used so the @examples-compile@
-- flake check needs no private registry.
--
-- Note: a config run by the loader's @runghc@ compiles under @-XGHC2024@, which
-- does NOT enable @DuplicateRecordFields@, so the embedded 'Database' and 'Worker'
-- records are built through QUALIFIED imports (@DB.@ / @W.@) to avoid their
-- @namespace@/@image@ field labels clashing with the 'Application' record's.
--
-- Provision it with (EP-2):
--   nagarectl app deploy -f cluster/examples/multi-workload-app/nagare/Config.hs
module Main (main) where

import Data.Bifunctor (first)
import Control.Lens ((&), (.~))
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
  , mkEnvName
  , mkImageRef
  , mkNamespace
  , mkQuantity
  , mkServiceName
  , runtimeScoped
  )
import Nagare.Dsl.Worker qualified as W
import Nagare.Dsl.Worker (webWorker)

-- | The one shared image every workload runs. Declared once here and on the
-- 'Application'; 'mkApplication' checks every workload agrees.
sharedImage :: Text
sharedImage = "gcr.io/knative-samples/helloworld-go"

applicationConfig :: Either Text Application
applicationConfig = do
  appNm <- mkServiceName "kizashi"
  ns <- mkNamespace "personal"
  img <- mkImageRef sharedImage
  logLevel <- mkEnvName "LOG_LEVEL"

  -- The managed Postgres the app owns. Workers reference it by name below.
  dbn <- DB.mkDatabaseName "kizashi-db"
  ver <- DB.mkEngineVersion DB.Postgres "18"
  dbSize <- mkQuantity "10Gi"
  let db =
        DB.Database
          { DB.name = dbn
          , DB.engine = DB.Postgres
          , DB.version = ver
          , DB.namespace = ns
          , DB.size = dbSize
          , DB.resources = Nothing
          , DB.retention = Retain
          }

  -- The HTTP front (a Knative Service).
  svc <- webService "kizashi-serve" sharedImage

  -- Two background reactors, each binding the managed database.
  w1base <- first Text.pack (webWorker "kizashi-worker" sharedImage)
  w2base <- first Text.pack (webWorker "kizashi-agent-worker" sharedImage)
  let w1 = w1base & #databases .~ [dbn]
      w2 = w2base & #databases .~ [dbn]

  -- The migration task. It pins no image of its own (image = Nothing) and so
  -- inherits the app's shared image; EP-2 runs it to completion before the
  -- Service and Workers are applied.
  migrateNm <- mkServiceName "kizashi-migrate"
  sched <- mkSchedule "0 0 * * *"
  migrate <-
    mkTask
      Task
        { name = migrateNm
        , namespace = ns
        , schedule = sched
        , image = Nothing
        , app = Just appNm
        , command = ["python", "manage.py", "migrate"]
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
      , namespace = ns
      , image = img
      , env = Map.fromList [(logLevel, runtimeScoped (EnvLiteral "info"))]
      , databases = [db]
      , brokers = []
      , access = Nothing
      , service = Just svc
      , workers = [w1, w2]
      , tasks = [migrate]
      }

main :: IO ()
main = either (ioError . userError . Text.unpack) emitApplication applicationConfig
