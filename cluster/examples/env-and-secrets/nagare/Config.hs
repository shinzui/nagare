{-# LANGUAGE OverloadedStrings #-}

-- | Example: scoped env + managed env/secret stores, proven end to end (EP-28).
--
-- The app prints its NAGARE_* generated variables and any managed variable it
-- can see, so `curl`-ing the deployed URL shows env changes taking effect.
--
-- This config declares three variables across scopes:
--   * GREETING      — a Runtime literal (visible in the running container)
--   * BUILD_STAMP   — a Build-scoped literal (reaches `docker build`, NOT runtime)
--   * API_KEY       — a Runtime secret reference (resolved from a Kubernetes Secret)
--
-- See docs/user/env-and-secrets.md for the full walkthrough.
module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types

deployment :: Either String Deployment
deployment = do
  name' <- mapLeft show (mkServiceName "envdemo")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/envdemo")
  port' <- mapLeft show (mkPort 8080)
  sc <- mapLeft show (mkScale 0 2)
  bld <- mapLeft show defaultBuild

  greeting <- mapLeft show (mkEnvName "GREETING")
  buildStamp <- mapLeft show (mkEnvName "BUILD_STAMP")
  apiKey <- mapLeft show (mkEnvName "API_KEY")
  apiKeySecret <- mapLeft show (mkSecretName "envdemo-api-key")

  buildScoped <- mapLeft show (scopedEnv (Set.fromList [Build]) (EnvLiteral "dev-stamp"))

  let env' =
        Map.fromList
          [ (greeting, runtimeScoped (EnvLiteral "hello from Config.hs"))
          , (buildStamp, buildScoped)
          , (apiKey, runtimeScoped (EnvSecretRef apiKeySecret))
          ]
  Right
    Deployment
      { name = name'
      , namespace = ns'
      , image = img'
      , build = bld
      , domains = []
      , port = port'
      , env = env'
      , resources = Nothing
      , scale = Just sc
      , healthCheck = Nothing
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
