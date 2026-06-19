{-# LANGUAGE OverloadedStrings #-}

-- | Prebuilt-image build mode (EP-19/EP-20): deploy an image that already
-- exists in a registry, building and pushing nothing.
--
-- The image @gcr.io/knative-samples/helloworld-go@ is public and pullable, and
-- the @build@ field carries the tag to deploy (@latest@). @nagarectl deploy@
-- skips Docker entirely and renders a Knative Service whose container image is
-- @gcr.io/knative-samples/helloworld-go:latest@ — the embedded tag, not a
-- freshly computed deploy timestamp.
--
-- Note: a config run by the loader's @runghc@ compiles under @-XGHC2024@, which
-- does not enable @OverloadedLabels@, so this uses a plain record update
-- (@base {build = ...}@) rather than the @#build@ lens.
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..))

deployment :: Either String Deployment
deployment = do
  base <- first show (webService "prebuilt-image-app" "gcr.io/knative-samples/helloworld-go")
  tag <- first show (mkTag "latest")
  Right (base {build = PrebuiltImage tag})

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
