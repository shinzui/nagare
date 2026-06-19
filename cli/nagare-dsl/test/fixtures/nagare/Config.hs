{-# LANGUAGE OverloadedStrings #-}

-- | Hello app deployment descriptor — the config-as-program surface file an
-- app author ships. @nagarectl@/the loader compiles-and-runs it; every field is
-- built through EP-9's smart constructors, so a bad value is a compile-time or
-- load-time error, never a silent cluster rejection. Mirrors
-- cluster/examples/hello-knative-service/nagare/Config.hs.
module Main (main) where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types

deployment :: Either String Deployment
deployment = do
  name' <- first show (mkServiceName "hello")
  ns' <- first show (mkNamespace "personal")
  img' <- first show (mkImageRef "gcr.io/knative-samples/helloworld-go")
  doms <- first show (mkDomains [("hello.example.com", True)])
  port' <- first show (mkPort 8080)
  target <- first show (mkEnvName "TARGET")
  sc <- first show (mkScale 0 3)
  cpuQ <- first show (mkQuantity "250m")
  memQ <- first show (mkQuantity "128Mi")
  bld <- first show defaultBuild
  Right
    Deployment
      { name = name'
      , namespace = ns'
      , image = img'
      , build = bld
      , domains = doms
      , port = port'
      , env = Map.singleton target (runtimeScoped (EnvLiteral "Nagare"))
      , resources = Just Resources {cpu = Just cpuQ, memory = Just memQ, cpuLimit = Nothing, memoryLimit = Nothing}
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
