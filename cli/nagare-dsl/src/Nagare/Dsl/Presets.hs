{-# LANGUAGE PackageImports #-}

-- | Reusable building blocks for Nagare deployments.
--
-- An app author imports this module and composes presets and overlays to
-- describe a service without boilerplate:
--
-- @
--   deployment =
--     production =<< secretEnv "DATABASE_URL" "my-db-secret"
--       =<< webService "notes" "gcr.io/myproject/notes"
-- @
--
-- The type system guarantees the result is a valid 'Deployment': every overlay
-- is @Deployment -> Either Text Deployment@ and goes through the smart
-- constructors for any constrained field it touches, so an overlay that would
-- produce an invalid value (e.g. @max < min@) is rejected at the point of
-- composition, never silently applied.
module Nagare.Dsl.Presets
  ( -- * Web-service preset
    webService

    -- * Environment overlays
  , development
  , production

    -- * Helpers
  , secretEnv
  , stdResources
  , teamDefaults
  ) where

import "generic-lens" Data.Generics.Labels ()

import Data.Map qualified as Map
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types

-- | Build a standard HTTP web-service deployment from just a name and image.
--
-- Defaults: namespace @personal@, port @8080@, scale @0..3@ (scale-to-zero),
-- 'stdResources' (250m CPU / 128Mi memory), no env, no domain. Returns 'Left'
-- if the name is not DNS-safe or the image path carries a tag.
webService :: Text -> Text -> Either Text Deployment
webService nameText imageText = do
  name' <- mkServiceName nameText
  img <- mkImageRef imageText
  sc <- mkScale 0 3
  res <- stdResources
  bld <- defaultBuild
  pure
    Deployment
      { name = name'
      , namespace = defaultNamespace
      , image = img
      , build = bld
      , domains = []
      , port = defaultPort
      , env = Map.empty
      , resources = Just res
      , scale = Just sc
      , healthCheck = Nothing
      }

-- | Development overlay: scale @0..1@ (still scale-to-zero, at most one
-- replica). The 'mkScale' call keeps the validation path explicit so a future
-- variable-driven overlay cannot bypass it.
development :: Deployment -> Either Text Deployment
development dep = do
  sc <- mkScale 0 1
  pure (dep & #scale .~ Just sc)

-- | Production overlay: scale @1..5@ (always-warm) and larger resources
-- (500m CPU / 256Mi memory). Goes through 'mkScale'/'mkQuantity'.
production :: Deployment -> Either Text Deployment
production dep = do
  sc <- mkScale 1 5
  cpuQ <- mkQuantity "500m"
  memQ <- mkQuantity "256Mi"
  let res = Resources {cpu = Just cpuQ, memory = Just memQ, cpuLimit = Nothing, memoryLimit = Nothing}
  pure (dep & #scale .~ Just sc & #resources .~ Just res)

-- | Add a Kubernetes Secret reference as an environment variable, preserving
-- existing entries. Returns 'Left' if the variable or secret name is empty.
secretEnv :: Text -> Text -> Deployment -> Either Text Deployment
secretEnv varName secretNameText dep = do
  en <- mkEnvName varName
  sn <- mkSecretName secretNameText
  pure (dep & #env %~ Map.insert en (runtimeScoped (EnvSecretRef sn)))

-- | Standard resource block for small web services: 250m CPU, 128Mi memory.
stdResources :: Either Text Resources
stdResources = do
  cpuQ <- mkQuantity "250m"
  memQ <- mkQuantity "128Mi"
  pure Resources {cpu = Just cpuQ, memory = Just memQ, cpuLimit = Nothing, memoryLimit = Nothing}

-- | Team-wide defaults applied on top of any preset: namespace @personal@ and
-- no custom domain. Extend as conventions evolve.
teamDefaults :: Deployment -> Deployment
teamDefaults dep =
  dep
    & #namespace .~ defaultNamespace
    & #domains .~ []
