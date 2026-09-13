{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}

-- | Nixpacks build mode (EP-21): build the image from source with **no
-- Dockerfile** and push it to the deployment's registry path.
--
-- This directory holds a tiny Node HTTP server (@package.json@ + @server.js@)
-- and no @Dockerfile@. @nagarectl deploy@ runs @nixpacks build .@, which inspects
-- the source tree, detects Node, and produces a runnable OCI image; Nagare then
-- pushes and deploys it exactly like the Dockerfile path. The app listens on
-- @$PORT@ (Knative injects the container port).
--
-- Prerequisite: the @nixpacks@ CLI must be on @PATH@ (see
-- @docs/user/build-modes.md@). Like the other examples, it follows the
-- project-wide overloaded-label update convention.
module Main (main) where

import Data.Bifunctor (first)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Build (BuildSpec (..))
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..))

deployment :: Either String Deployment
deployment = do
  base <- first show (webService "nixpacks-app" "nixpacks-app")
  ctx <- first show (mkFilePathText ".")
  Right (base & #build .~ NixpacksBuild {context = ctx, buildArgs = Map.empty})

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
