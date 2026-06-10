{-# LANGUAGE OverloadedStrings #-}

-- | The postgres-app example app: a web service that references the managed
-- Postgres database "pg-main". At deploy time it receives POSTGRES_HOST/PORT/
-- USER/DB as literals and POSTGRES_PASSWORD/DATABASE_URL as Secret references
-- (MasterPlan 9, EP-46). Deploy with:
--   nagarectl deploy -f cluster/examples/postgres-app/nagare/Config.hs
module Main (main) where

import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..), mkDatabaseName)

deployment :: Either String Deployment
deployment = do
  dep <- mapLeft show (webService "postgres-app" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/postgres-app")
  db <- mapLeft show (mkDatabaseName "pg-main")
  pure dep {databases = [db]}
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
