{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A multi-workload Application fixture (MasterPlan 14, EP-1): one logical app
-- that is, in Nagare terms, several objects across four kinds — one web Service
-- (@kizashi-serve@), two background Workers (both referencing the managed
-- database), one managed Postgres (@kizashi-db@), and one image-inheriting
-- migration Task (@kizashi-migrate@) — all on the one shared image and namespace.
--
-- Note: a config run by the loader's @runghc@ compiles under @-XGHC2024@, which
-- does NOT enable @DuplicateRecordFields@. So the embedded 'Database' and
-- 'Worker' records are built through QUALIFIED imports (@DB.@ / @W.@) — their
-- @namespace@/@image@ field labels would otherwise clash with the 'Application'
-- record's own fields. The 'Application' record itself is built unqualified, and
-- every constrained field still goes through its smart constructor.
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

applicationConfig :: Either Text Application
applicationConfig = do
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

  w1base <- first Text.pack (webWorker "kizashi-worker" sharedImage)
  w2base <- first Text.pack (webWorker "kizashi-agent-worker" sharedImage)
  let w1 = w1base & #databases .~ [dbn]
      w2 = w2base & #databases .~ [dbn]

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
      , logicalKey = Nothing
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
