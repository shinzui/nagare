{-# LANGUAGE OverloadedStrings #-}

{- | Minimal protected web service for the identity-aware access example.

This is deliberately close to the hello-knative-service example, but it opts
into the shared shomei+en auth plane with `access = Just requireLogin`.
-}
module Main (main) where

import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import Nagare.Dsl.Access (requireLogin)
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types

deployment :: Either String Deployment
deployment = do
    name' <- first show (mkServiceName "protected-hello")
    ns' <- first show (mkNamespace "personal")
    img' <- first show (mkImageRef "gcr.io/knative-samples/helloworld-go")
    tag' <- first show (mkTag "latest")
    doms <- first show (mkDomains [("protected-hello.apps.example.com", True)])
    port' <- first show (mkPort 8080)
    target <- first show (mkEnvName "TARGET")
    sc <- first show (mkScale 0 3)
    cpuQ <- first show (mkQuantity "250m")
    memQ <- first show (mkQuantity "128Mi")
    Right
        Deployment
            { name = name'
            , namespace = ns'
            , image = img'
            , build = PrebuiltImage tag'
            , domains = doms
            , port = port'
            , env = Map.singleton target (runtimeScoped (EnvLiteral "Nagare"))
            , resources = Just Resources{cpu = Just cpuQ, memory = Just memQ, cpuLimit = Nothing, memoryLimit = Nothing}
            , scale = Just sc
            , healthCheck = Nothing
            , volumes = []
            , databases = []
            , brokers = []
            , access = Just requireLogin
            , tasks = []
            , cdn = Nothing
            }

main :: IO ()
main = case deployment of
    Left err -> ioError (userError err)
    Right dep -> emitDeployment dep
