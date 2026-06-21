{-# LANGUAGE OverloadedStrings #-}

-- | Deployment descriptor for the hello-knative-service example — the
-- config-as-program surface file an app author ships (EP-8's chosen substrate).
--
-- @nagarectl deploy@ compiles-and-runs this file with @runghc@; every field is
-- built through EP-9's smart constructors, so an invalid value (a non-DNS name,
-- @max < min@ scale, a malformed quantity, an env entry that is both a literal
-- and a secret ref) is a compile-time or load-time error here — never a silent
-- cluster rejection. This replaces the former @nagare.yaml@ in this directory.
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
      , brokers = []
      , tasks = []
      , cdn = Nothing
      }

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
