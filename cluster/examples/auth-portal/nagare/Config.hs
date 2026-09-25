{-# LANGUAGE OverloadedStrings #-}

-- | Deployable reference implementation of Nagare's authentication portal contract.
module Main (main) where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Access (authPortal)
import Nagare.Dsl.Build (BuildSpec (..))
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Types
import System.Environment (lookupEnv)

mkDeployment :: T.Text -> Either String Deployment
mkDeployment baseDomain = do
  name' <- first show (mkServiceName "auth-portal")
  ns' <- first show (mkNamespace "personal")
  image' <- first show (mkImageRef "auth-portal")
  dockerfile' <- first show (mkFilePathText "Dockerfile")
  context' <- first show (mkFilePathText ".")
  domains' <- first show (mkDomains [("auth." <> baseDomain, True)])
  port' <- first show (mkPort 8080)
  scale' <- first show (mkScale 0 3)
  health' <- first show (httpHealthCheck "/healthz")
  shomeiUrl <- first show (mkEnvName "SHOMEI_URL")
  portalTitle <- first show (mkEnvName "PORTAL_TITLE")
  allowSignup <- first show (mkEnvName "PORTAL_ALLOW_SIGNUP")
  Right
    Deployment
      { name = name'
      , logicalKey = Nothing
      , namespace = ns'
      , image = image'
      , build = DockerfileBuild {dockerfile = dockerfile', context = context', buildArgs = Map.empty}
      , domains = domains'
      , port = port'
      , env =
          Map.fromList
            [ (shomeiUrl, runtimeScoped (EnvLiteral "http://shomei.nagare-system.svc.cluster.local"))
            , (portalTitle, runtimeScoped (EnvLiteral "Nagare"))
            , (allowSignup, runtimeScoped (EnvLiteral "false"))
            ]
      , resources = Nothing
      , scale = Just scale'
      , healthCheck = Just health'
      , volumes = []
      , databases = []
      , brokers = []
      , access = Just authPortal
      , tasks = []
      , cdn = Nothing
      }

main :: IO ()
main = do
  baseDomain <- maybe "apps.example.com" T.pack <$> lookupEnv "NAGARE_BASE_DOMAIN"
  either (ioError . userError) emitDeployment (mkDeployment baseDomain)
