{-# LANGUAGE OverloadedStrings #-}

-- | Server-site descriptor for the @tanstack-start@ example (EP-18) — the
-- config-as-program surface file a full-stack project author ships.
--
-- @nagarectl site deploy@ compiles-and-runs this file, sees @kind = ServerSite@,
-- builds the app with the runtime's build command, packages the self-contained
-- @.output@ directory into a Node image, and deploys it as a Knative Service. The
-- TanStack Start defaults (`tanstackStartBuild`, `defaultServerRuntime`) mean the
-- common case is almost no configuration; only the name/image and an env var are
-- set here.
--
-- @HOSTNAME=0.0.0.0@ makes the Nitro server bind the wildcard address; Knative
-- injects @PORT=8080@ to match the container port, so it is not set here.
-- @scale = Nothing@ takes the platform default (scale-to-zero); set
-- @scale = Just (mkScale 1 n)@ to avoid cold starts.
module Main (main) where

import Data.Map.Strict qualified as Map
import Nagare.Dsl.Config (emitServerSite)
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types (mkSiteName)
import Nagare.Dsl.Types

serverSite :: Either String ServerSite
serverSite = do
  name' <- mapLeft show (mkSiteName "tanstack-start")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "tanstack-start")
  host <- mapLeft show (mkEnvName "HOSTNAME")
  Right
    ServerSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = tanstackStartBuild
      , runtime = defaultServerRuntime
      , port = defaultPort
      , env = Map.fromList [(host, runtimeScoped (EnvLiteral "0.0.0.0"))]
      , resources = Nothing
      , scale = Nothing
      , domains = []
      , volumes = []
      , cdn = Nothing
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case serverSite of
  Left err -> ioError (userError err)
  Right s -> emitServerSite s
