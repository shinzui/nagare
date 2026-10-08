{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Section 4 drill application: the scenario-a image bound to one of its PostgreSQL databases.
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Build (BuildSpec (..))
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Database qualified as DB
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (RetentionPolicy (..), mkImageRef, mkNamespace, mkQuantity, mkServiceName)
import System.Environment (lookupEnv)

postgres :: (Text, Text) -> Either Text DB.Database
postgres (n, v) = do
  name' <- DB.mkDatabaseName n
  version' <- DB.mkEngineVersion DB.Postgres v
  namespace' <- mkNamespace "personal"
  size' <- mkQuantity "1Gi"
  pure
    DB.Database
      { DB.name = name'
      , DB.logicalKey = Nothing
      , DB.engine = DB.Postgres
      , DB.version = version'
      , DB.namespace = namespace'
      , DB.size = size'
      , DB.resources = Nothing
      , DB.retention = Retain
      }

applicationConfig :: Text -> Either Text Application
applicationConfig registry = do
  appName <- mkServiceName "upg2-app"
  namespace' <- mkNamespace "personal"
  image' <- mkImageRef (registry <> "/upg2-app")
  databases' <- traverse postgres [("upg2-pg18", "18")]
  bound <- DB.mkDatabaseName "upg2-pg18"
  web <- webService "upg2-app" (registry <> "/upg2-app")
  dockerfile <- mkFilePathText "Dockerfile"
  context <- mkFilePathText "."
  mkApplication
    Application
      { name = appName
      , logicalKey = Nothing
      , namespace = namespace'
      , image = image'
      , env = Map.empty
      , databases = databases'
      , brokers = []
      , access = Nothing
      , service =
          Just
            ( web
                & #build .~ DockerfileBuild {dockerfile = dockerfile, context = context, buildArgs = Map.empty}
                & #databases .~ [bound]
            )
      , workers = []
      , tasks = []
      }

main :: IO ()
main = do
  registry <- maybe "k3d-registry.localhost:5000" Text.pack <$> lookupEnv "NAGARE_REGISTRY_HOST"
  either (ioError . userError . Text.unpack) emitApplication (applicationConfig registry)
