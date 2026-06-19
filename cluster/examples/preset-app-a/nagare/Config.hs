{-# LANGUAGE OverloadedStrings #-}

-- | The "notes" web service — a config-as-program deployment that reuses the
-- shared 'webService' preset and 'production' overlay from
-- 'Nagare.Dsl.Presets'. The only app-specific information is the name and image;
-- everything else comes from the shared building blocks. @nagarectl@/the loader
-- compiles-and-runs this and reads the emitted JSON.
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (production, webService)
import Nagare.Dsl.Types (Deployment)

deployment :: Either String Deployment
deployment = do
  base <- first show (webService "notes" "gcr.io/myproject/notes")
  first show (production base)

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
