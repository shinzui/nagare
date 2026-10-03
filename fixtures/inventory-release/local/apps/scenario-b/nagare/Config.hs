{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Scenario application B for the MP-23 local release run (EP-155, C2).
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

applicationConfig :: Either Text Application
applicationConfig = do
  appName <- mkServiceName "scenario-b"
  namespace' <- mkNamespace "personal"
  image' <- mkImageRef "scenario-b"
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
  web <- webService "scenario-b" "scenario-b"
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
main = either (ioError . userError . Text.unpack) emitApplication applicationConfig
