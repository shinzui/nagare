{-# LANGUAGE OverloadedStrings #-}

-- | The clickhouse-analytics example app: references the managed ClickHouse
-- database "events" and receives CLICKHOUSE_HOST/PORT/USER (literals) and
-- CLICKHOUSE_PASSWORD/CLICKHOUSE_URL (Secret references) at deploy time
-- (MasterPlan 9, EP-46).
module Main (main) where

import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..), mkDatabaseName)

deployment :: Either String Deployment
deployment = do
  dep <- mapLeft show (webService "clickhouse-analytics" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/clickhouse-analytics")
  db <- mapLeft show (mkDatabaseName "events")
  pure dep {databases = [db]}
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
