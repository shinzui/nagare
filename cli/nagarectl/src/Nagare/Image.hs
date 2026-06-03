{-# LANGUAGE PackageImports #-}

-- | Container image operations for a deployment: tag computation, the full
-- image reference, building, Docker auth, and pushing to Artifact Registry.
--
-- All shell-outs go through the @cradle@ process library. The image repository
-- path comes from the 'Deployment' value (EP-9's 'Nagare.Dsl.Types.ImageRef');
-- the tag is appended here so the renderer and the pushed image agree.
module Nagare.Image
  ( computeTag
  , buildImage
  , configureDockerAuth
  , pushImage
  , imageRef
  ) where

import Nagare.Dsl.Prelude

import "generic-lens" Data.Generics.Labels ()

import Cradle
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Dsl.Types (Deployment, imageRefText)

-- | Artifact Registry host for Docker credential configuration.
registryHost :: String
registryHost = "us-west1-docker.pkg.dev"

-- | Compute a deploy tag: UTC timestamp in @YYYYMMDD-HHMMSS@ format.
computeTag :: IO Text
computeTag = do
  now <- getCurrentTime
  pure (T.pack (formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now))

-- | The full image reference for a deployment, e.g.
-- @"gcr.io/knative-samples/helloworld-go:20260602-120000"@. The repository
-- path is read from the deployment's 'Nagare.Dsl.Types.ImageRef'; the @tag@ is
-- the value 'computeTag' (or @--tag@) produced.
imageRef :: Deployment -> Text -> Text
imageRef dep tag = imageRefText (dep ^. #image) <> ":" <> tag

-- | Run @docker build -t \<image:tag\> \<context\>@.
-- The @context@ argument is the build-context directory (typically @"."@).
buildImage :: Text -> FilePath -> IO ()
buildImage ref context =
  run_ $ cmd "docker" & addArgs ["build", "-t", T.unpack ref, context]

-- | Run @gcloud auth configure-docker us-west1-docker.pkg.dev --quiet@. This
-- writes a Docker credential-helper entry so subsequent pushes authenticate
-- automatically against Artifact Registry.
configureDockerAuth :: IO ()
configureDockerAuth =
  run_ $
    cmd "gcloud"
      & addArgs ["auth", "configure-docker", registryHost, "--quiet"]

-- | Run @docker push \<image:tag\>@.
pushImage :: Text -> IO ()
pushImage ref =
  run_ $ cmd "docker" & addArgs ["push", T.unpack ref]
