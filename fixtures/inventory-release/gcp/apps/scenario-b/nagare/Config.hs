{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Scenario application B for the MP-23 cloud release run (EP-156, C3; cloud copy of the EP-155 local fixture).
--
-- A public web Service owned independently of application A. It owns the
-- Redis @scenario-redis@ and consumes topic @jobs@ of the standalone Redpanda
-- broker @scenario-events@. Updating A must leave B's accepted revision and
-- Service incarnation unchanged.
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Broker (BrokerBinding (..), mkBrokerName, mkTopicName)
import Nagare.Dsl.Build (BuildSpec (..))
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Database qualified as DB
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (RetentionPolicy (..), mkImageRef, mkNamespace, mkQuantity, mkServiceName)
import System.Environment (lookupEnv)

applicationConfig :: Text -> Either Text Application
applicationConfig registry = do
  appName <- mkServiceName "scenario-b"
  namespace' <- mkNamespace "personal"
  image' <- mkImageRef (registry <> "/scenario-b")
  cacheName <- DB.mkDatabaseName "scenario-redis"
  version' <- DB.mkEngineVersion DB.Redis "8"
  cacheSize <- mkQuantity "1Gi"
  let cache =
        DB.Database
          { DB.name = cacheName
          , DB.logicalKey = Nothing
          , DB.engine = DB.Redis
          , DB.version = version'
          , DB.namespace = namespace'
          , DB.size = cacheSize
          , DB.resources = Nothing
          , DB.retention = Retain
          }
  web <- webService "scenario-b" (registry <> "/scenario-b")
  dockerfile <- mkFilePathText "Dockerfile"
  context <- mkFilePathText "."
  broker <- mkBrokerName "scenario-events"
  topic <- mkTopicName "jobs"
  mkApplication
    Application
      { name = appName
      , logicalKey = Nothing
      , namespace = namespace'
      , image = image'
      , env = Map.empty
      , databases = [cache]
      , brokers = [BrokerBinding {name = broker, topics = [topic]}]
      , access = Nothing
      , service =
          Just
            ( web
                & #build .~ DockerfileBuild {dockerfile = dockerfile, context = context, buildArgs = Map.empty}
                & #databases .~ [cacheName]
            )
      , workers = []
      , tasks = []
      }

main :: IO ()
main = do
  -- Cloud copy for the MP-23 C3 run (EP-156): Artifact Registry images live at
  -- <host>/<project>/<repository>, not directly under the registry host.
  host <- maybe "k3d-registry.localhost:5000" Text.pack <$> lookupEnv "NAGARE_REGISTRY_HOST"
  mode <- lookupEnv "NAGARE_MODE"
  project <- maybe "" Text.pack <$> lookupEnv "CLOUDSDK_CORE_PROJECT"
  repository <- maybe "" Text.pack <$> lookupEnv "NAGARE_ARTIFACT_REGISTRY_ID"
  let registry = if mode == Just "cloud" && not (Text.null project) && not (Text.null repository) then host <> "/" <> project <> "/" <> repository else host
  either (ioError . userError . Text.unpack) emitApplication (applicationConfig registry)
