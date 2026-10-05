{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Reviewer throwaway rvf16 (MP-23 phase 3a, F16/F30), derived from scenario application B for the MP-23 cloud release run (EP-156, C3; cloud copy of the EP-155 local fixture).
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
import Nagare.Dsl.Build (BuildSpec (..))
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Database qualified as DB
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (EnvVar (EnvLiteral), Resources (..), RetentionPolicy (..), mkEnvName, mkImageRef, mkNamespace, mkQuantity, mkServiceName, runtimeScoped)
import System.Environment (lookupEnv)

applicationConfig :: Bool -> Text -> Either Text Application
applicationConfig hungry registry = do
  appName <- mkServiceName "rvf16"
  namespace' <- mkNamespace "personal"
  image' <- mkImageRef (registry <> "/scenario-b")
  cacheName <- DB.mkDatabaseName "rvf16-pg"
  version' <- DB.mkEngineVersion DB.Postgres "18"
  cacheSize <- mkQuantity "1Gi"
  let cache =
        DB.Database
          { DB.name = cacheName
          , DB.logicalKey = Nothing
          , DB.engine = DB.Postgres
          , DB.version = version'
          , DB.namespace = namespace'
          , DB.size = cacheSize
          , DB.resources = Nothing
          , DB.retention = Retain
          }
  web <- webService "rvf16" (registry <> "/scenario-b")
  dockerfile <- mkFilePathText "Dockerfile"
  context <- mkFilePathText "."
  cpuQ <- mkQuantity (if hungry then "64" else "100m")
  memQ <- mkQuantity "128Mi"
  -- F54 correction: the scenario-b image reads REDIS_URL at import; redis-py
  -- connects lazily, so a literal loopback URL lets it start and serve /.
  redisUrl <- mkEnvName "REDIS_URL"
  mkApplication
    Application
      { name = appName
      , logicalKey = Nothing
      , namespace = namespace'
      , image = image'
      , env = Map.empty
      , databases = [cache]
      , brokers = []
      , access = Nothing
      , service =
          Just
            ( web
                & #build .~ DockerfileBuild {dockerfile = dockerfile, context = context, buildArgs = Map.empty}
                & #databases .~ [cacheName]
                & #env .~ Map.singleton redisUrl (runtimeScoped (EnvLiteral "redis://127.0.0.1:6379/0"))
                & #resources .~ Just Resources {cpu = Just cpuQ, memory = Just memQ, cpuLimit = Nothing, memoryLimit = Nothing}
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
  let hungry = False
  either (ioError . userError . Text.unpack) emitApplication (applicationConfig hungry registry)
