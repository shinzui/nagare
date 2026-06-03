{-# LANGUAGE OverloadedStrings #-}

-- | The "tasks" web service — reuses the exact same 'webService' preset and
-- 'production' overlay as preset-app-a (no copy-paste), differing only in name,
-- image, and one environment variable sourced from a Kubernetes Secret via
-- 'secretEnv'. Proof that one definition is shared across two apps.
module Main (main) where

import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (production, secretEnv, webService)
import Nagare.Dsl.Types (Deployment)

deployment :: Either String Deployment
deployment = do
  base <- mapLeft show (webService "tasks" "gcr.io/myproject/tasks")
  withDb <- mapLeft show (secretEnv "DATABASE_URL" "tasks-db" base)
  mapLeft show (production withDb)
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
