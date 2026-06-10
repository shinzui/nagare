{-# LANGUAGE OverloadedStrings #-}

-- | Dockerfile build mode (EP-19/EP-20): build the image from a hand-written
-- @Dockerfile@ and push it to the deployment's registry path.
--
-- This config exercises the build mode beyond the default: it passes a
-- @buildArgs@ entry (@SITE_MESSAGE@) that the @Dockerfile@'s @ARG SITE_MESSAGE@
-- bakes into the served page. @nagarectl deploy@ runs
-- @docker build -f Dockerfile -t <ref> --build-arg SITE_MESSAGE=... .@.
--
-- @webService@ already defaults @build@ to a Dockerfile build with no build
-- args; here we set @build@ explicitly to add the @buildArgs@ entry. As with the
-- prebuilt example, a plain record update is used because the loader's @runghc@
-- compiles under @-XGHC2024@ (no @OverloadedLabels@).
module Main (main) where

import Data.Map.Strict qualified as Map
import Nagare.Dsl.Build (BuildSpec (..))
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..))

deployment :: Either String Deployment
deployment = do
  base <- mapLeft show (webService "dockerfile-app" "dockerfile-app")
  df <- mapLeft show (mkFilePathText "Dockerfile")
  ctx <- mapLeft show (mkFilePathText ".")
  let buildArgs' = Map.fromList [("SITE_MESSAGE", "hello from a Dockerfile build with a build arg")]
  Right (base {build = DockerfileBuild {dockerfile = df, context = ctx, buildArgs = buildArgs'}})
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
