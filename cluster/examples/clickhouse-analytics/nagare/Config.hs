{-# LANGUAGE OverloadedStrings #-}

-- | The clickhouse-analytics example app: references the managed ClickHouse
-- database "events" and receives CLICKHOUSE_HOST/PORT/USER (literals) and
-- CLICKHOUSE_PASSWORD/CLICKHOUSE_URL (Secret references) at deploy time
-- (MasterPlan 9, EP-46).
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..), mkDatabaseName)

deployment :: Either String Deployment
deployment = do
  dep <- first show (webService "clickhouse-analytics" "clickhouse-analytics")
  db <- first show (mkDatabaseName "events")
  pure dep {databases = [db]}

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
