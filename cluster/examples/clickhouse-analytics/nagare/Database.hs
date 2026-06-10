{-# LANGUAGE OverloadedStrings #-}

-- | The managed ClickHouse database for the clickhouse-analytics example
-- (MasterPlan 9). ClickHouse MUST be given explicit memory limits on the small
-- e2-standard-2 VM (the renderer also mounts a config.d max_server_memory_usage
-- cap of ~1.5 GiB). Provision with:
--   nagarectl db create clickhouse events --size 5Gi --memory 2Gi
module Main (main) where

import Nagare.Dsl.Config (emitDatabase)
import Nagare.Dsl.Database (Database (..), Engine (..), mkDatabaseName, mkEngineVersion)
import Nagare.Dsl.Types (Resources (..), RetentionPolicy (..), defaultNamespace, mkQuantity)

database :: Either String Database
database = do
  name' <- mapLeft show (mkDatabaseName "events")
  ver' <- mapLeft show (mkEngineVersion ClickHouse "25.8")
  size' <- mapLeft show (mkQuantity "5Gi")
  memReq <- mapLeft show (mkQuantity "512Mi")
  memLim <- mapLeft show (mkQuantity "2Gi")
  pure
    Database
      { dbName = name'
      , engine = ClickHouse
      , version = ver'
      , namespace = defaultNamespace
      , size = size'
      , resources =
          Just
            Resources
              { cpu = Nothing
              , memory = Just memReq
              , cpuLimit = Nothing
              , memoryLimit = Just memLim -- the hard cap for the e2-standard-2
              }
      , retention = Retain
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case database of
  Left err -> ioError (userError err)
  Right db -> emitDatabase db
