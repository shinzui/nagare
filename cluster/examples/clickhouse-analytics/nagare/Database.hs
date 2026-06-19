{-# LANGUAGE OverloadedStrings #-}

-- | The managed ClickHouse database for the clickhouse-analytics example
-- (MasterPlan 9). ClickHouse MUST be given explicit memory limits on the small
-- e2-standard-2 VM (the renderer also mounts a config.d max_server_memory_usage
-- cap of ~1.5 GiB). Provision with:
--   nagarectl db create clickhouse events --size 5Gi --memory 2Gi
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDatabase)
import Nagare.Dsl.Database (Database (..), Engine (..), mkDatabaseName, mkEngineVersion)
import Nagare.Dsl.Types (Resources (..), RetentionPolicy (..), defaultNamespace, mkQuantity)

database :: Either String Database
database = do
  name' <- first show (mkDatabaseName "events")
  ver' <- first show (mkEngineVersion ClickHouse "25.8")
  size' <- first show (mkQuantity "5Gi")
  memReq <- first show (mkQuantity "512Mi")
  memLim <- first show (mkQuantity "2Gi")
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

main :: IO ()
main = case database of
  Left err -> ioError (userError err)
  Right db -> emitDatabase db
