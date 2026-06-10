{-# LANGUAGE OverloadedStrings #-}

-- | Server-site config-as-program fixture (EP-18) — a TanStack Start app. Uses
-- the TanStack Start defaults (`tanstackStartBuild`, `defaultServerRuntime`),
-- one custom domain, two env vars (including HOSTNAME=0.0.0.0), a non-zero
-- minScale, and a Resources block. Every field is built through a smart
-- constructor, so an invalid value is a compile-time or load-time error.
module Main (main) where

import Data.Map.Strict qualified as Map
import Nagare.Dsl.Cdn.Types
import Nagare.Dsl.Config (emitServerSite)
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types (mkSiteName)
import Nagare.Dsl.Types

serverSite :: Either String ServerSite
serverSite = do
  name' <- mapLeft show (mkSiteName "notes-app")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes-app")
  dom' <- mapLeft show (mkDomain "notes-app.example.com")
  host <- mapLeft show (mkEnvName "HOSTNAME")
  apiBase <- mapLeft show (mkEnvName "API_BASE")
  sc <- mapLeft show (mkScale 1 3)
  cpuQ <- mapLeft show (mkQuantity "500m")
  memQ <- mapLeft show (mkQuantity "256Mi")
  Right
    ServerSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = tanstackStartBuild
      , runtime = defaultServerRuntime
      , port = defaultPort
      , env =
          Map.fromList
            [ (host, runtimeScoped (EnvLiteral "0.0.0.0"))
            , (apiBase, runtimeScoped (EnvLiteral "https://api.example.com"))
            ]
      , resources = Just Resources {cpu = Just cpuQ, memory = Just memQ, cpuLimit = Nothing, memoryLimit = Nothing}
      , scale = Just sc
      , domains = [dom']
      , volumes = []
      , -- Front the origin with Google Cloud CDN (a global HTTP(S) load
        -- balancer) with a 10-minute default edge TTL.
        cdn = Just (withDefaultTtl 600 gcpCloudCdn)
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case serverSite of
  Left err -> ioError (userError err)
  Right s -> emitServerSite s
