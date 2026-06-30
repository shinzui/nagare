{-# LANGUAGE OverloadedStrings #-}

{- | Minimal protected web service for the identity-aware access example.

This is deliberately close to the hello-knative-service example, but it opts
into the shared shomei+en auth plane with `access = Just requireLogin`.
-}
module Main (main) where

import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Nagare.Dsl.Access (requireLogin)
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types
import System.Environment (lookupEnv)

-- | The protected public host is @protected-hello.\<baseDomain\>@. The base
-- domain is read from @NAGARE_BASE_DOMAIN@ so this one example works against any
-- target: in the cloud it stays @protected-hello.apps.example.com@ (the default),
-- and in local mode (@NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io@) it becomes
-- @protected-hello.127-0-0-1.sslip.io@, which resolves to 127.0.0.1 with no DNS
-- setup so a browser can complete the login. A protected app needs an explicit
-- custom domain mapped to the enforcer; deriving it from the base domain keeps
-- that domain reachable in whichever target nagarectl is pointed at.
mkDeployment :: T.Text -> Either String Deployment
mkDeployment baseDomain = do
    name' <- first show (mkServiceName "protected-hello")
    ns' <- first show (mkNamespace "personal")
    img' <- first show (mkImageRef "gcr.io/knative-samples/helloworld-go")
    tag' <- first show (mkTag "latest")
    doms <- first show (mkDomains [("protected-hello." <> baseDomain, True)])
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
main = do
    baseDomain <- maybe "apps.example.com" T.pack <$> lookupEnv "NAGARE_BASE_DOMAIN"
    case mkDeployment baseDomain of
        Left err -> ioError (userError err)
        Right dep -> emitDeployment dep
