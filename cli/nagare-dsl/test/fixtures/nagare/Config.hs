{-# LANGUAGE OverloadedStrings #-}

-- | Hello app deployment descriptor — the config-as-program surface file an
-- app author ships. @nagarectl@/the loader compiles-and-runs it; every field is
-- built through EP-9's smart constructors, so a bad value is a compile-time or
-- load-time error, never a silent cluster rejection. Mirrors
-- cluster/examples/hello-knative-service/nagare/Config.hs.
module Main (main) where

import Data.Map.Strict qualified as Map
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types

deployment :: Either String Deployment
deployment = do
  name' <- mapLeft show (mkServiceName "hello")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "gcr.io/knative-samples/helloworld-go")
  dom' <- mapLeft show (mkDomain "hello.example.com")
  port' <- mapLeft show (mkPort 8080)
  target <- mapLeft show (mkEnvName "TARGET")
  sc <- mapLeft show (mkScale 0 3)
  cpuQ <- mapLeft show (mkQuantity "250m")
  memQ <- mapLeft show (mkQuantity "128Mi")
  bld <- mapLeft show defaultBuild
  Right
    Deployment
      { name = name'
      , namespace = ns'
      , image = img'
      , build = bld
      , domain = Just dom'
      , port = port'
      , env = Map.singleton target (EnvLiteral "Nagare")
      , resources = Just Resources {cpu = Just cpuQ, memory = Just memQ}
      , scale = Just sc
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
