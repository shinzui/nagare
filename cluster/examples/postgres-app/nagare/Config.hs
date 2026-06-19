{-# LANGUAGE OverloadedStrings #-}

-- | The postgres-app example app: a web service that references the managed
-- Postgres database "pg-main". At deploy time it receives POSTGRES_HOST/PORT/
-- USER/DB as literals and POSTGRES_PASSWORD/DATABASE_URL as Secret references
-- (MasterPlan 9, EP-46). Deploy with:
--   nagarectl deploy -f cluster/examples/postgres-app/nagare/Config.hs
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..), mkDatabaseName)

deployment :: Either String Deployment
deployment = do
  dep <- first show (webService "postgres-app" "postgres-app")
  db <- first show (mkDatabaseName "pg-main")
  pure dep {databases = [db]}

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
