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

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types

deployment :: Either String Deployment
deployment = do
  name' <- first show (mkServiceName "envdemo")
  ns' <- first show (mkNamespace "personal")
  img' <- first show (mkImageRef "envdemo")
  port' <- first show (mkPort 8080)
  sc <- first show (mkScale 0 2)
  bld <- first show defaultBuild

  greeting <- first show (mkEnvName "GREETING")
  buildStamp <- first show (mkEnvName "BUILD_STAMP")
  apiKey <- first show (mkEnvName "API_KEY")
  apiKeySecret <- first show (mkSecretName "envdemo-api-key")

  buildScoped <- first show (scopedEnv (Set.fromList [Build]) (EnvLiteral "dev-stamp"))

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
      , volumes = []
      , databases = []
      , tasks = []
      , cdn = Nothing
      }

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
