{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Scenario application A for the MP-23 local release run (EP-155, C2).
--
-- One typed Application: a web Service behind the shared login enforcer, the
-- application-owned PostgreSQL @scenario-pg@ (retained, with scheduled
-- backups), the @uploads@ volume, a scheduled report Task, and one value on
-- each environment channel: a Runtime literal, a Preview literal and a
-- Runtime value from the encrypted Secret store. The image is built from
-- this directory and published to the context registry.
--
-- Embedded records use qualified imports because the loader's GHC2024 does
-- not enable DuplicateRecordFields.
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Access (requireLogin)
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Build (BuildSpec (..))
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Database qualified as DB
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (attachVolume, webService)
import Nagare.Dsl.Task (ConcurrencyPolicy (..), RestartPolicy (..), Task (..), mkSchedule, mkTask)
import Nagare.Dsl.Types
  ( EnvScope (..)
  , EnvVar (..)
  , RetentionPolicy (..)
  , mkDomains
  , mkEnvName
  , mkImageRef
  , mkNamespace
  , mkQuantity
  , mkSecretName
  , mkServiceName
  , runtimeScoped
  , scopedEnv
  )
import System.Environment (lookupEnv)

applicationConfig :: Text -> Either Text Application
applicationConfig baseDomain = do
  appName <- mkServiceName "scenario-a"
  namespace' <- mkNamespace "personal"
  image' <- mkImageRef "scenario-a"
  databaseName <- DB.mkDatabaseName "scenario-pg"
  version' <- DB.mkEngineVersion DB.Postgres "18"
  databaseSize <- mkQuantity "1Gi"
  let database =
        DB.Database
          { DB.name = databaseName
          , DB.logicalKey = Nothing
          , DB.engine = DB.Postgres
          , DB.version = version'
          , DB.namespace = namespace'
          , DB.size = databaseSize
          , DB.resources = Nothing
          , DB.retention = Retain
          }
  web <- webService "scenario-a" "scenario-a" >>= attachVolume "uploads" "1Gi" "/uploads"
  dockerfile <- mkFilePathText "Dockerfile"
  context <- mkFilePathText "."
  domains' <- mkDomains [("scenario-a." <> baseDomain, True)]
  mode <- mkEnvName "SCENARIO_MODE"
  banner <- mkEnvName "SCENARIO_PREVIEW_BANNER"
  token <- mkEnvName "SCENARIO_API_TOKEN"
  tokenStore <- mkSecretName "scenario-a-api"
  previewOnly <- scopedEnv (Set.fromList [Preview]) (EnvLiteral "preview build")
  reportName <- mkServiceName "scenario-a-report"
  schedule' <- mkSchedule "*/30 * * * *"
  report <-
    mkTask
      Task
        { name = reportName
        , logicalKey = Nothing
        , namespace = namespace'
        , schedule = schedule'
        , image = Nothing
        , app = Just appName
        , command = ["python", "-c", "print('scenario-a report')"]
        , args = []
        , env = Map.empty
        , resources = Nothing
        , timeoutSeconds = Just 300
        , concurrencyPolicy = Forbid
        , restartPolicy = Never
        , backoffLimit = 0
        , successfulJobsHistoryLimit = 1
        , failedJobsHistoryLimit = 1
        , startingDeadlineSeconds = Nothing
        }
  mkApplication
    Application
      { name = appName
      , logicalKey = Nothing
      , namespace = namespace'
      , image = image'
      , env =
          Map.fromList
            [ (mode, runtimeScoped (EnvLiteral "scenario"))
            , (banner, previewOnly)
            , (token, runtimeScoped (EnvSecretRef tokenStore))
            ]
      , databases = [database]
      , brokers = []
      , access = Just requireLogin
      , service =
          Just
            ( web
                & #build .~ DockerfileBuild {dockerfile = dockerfile, context = context, buildArgs = Map.empty}
                & #domains .~ domains'
                & #databases .~ [databaseName]
            )
      , workers = []
      , tasks = [report]
      }

main :: IO ()
main = do
  baseDomain <- maybe "apps.example.com" Text.pack <$> lookupEnv "NAGARE_BASE_DOMAIN"
  either (ioError . userError . Text.unpack) emitApplication (applicationConfig baseDomain)
