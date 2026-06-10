{-# LANGUAGE OverloadedStrings #-}

-- | The managed Redis database for the redis-cache example (MasterPlan 9).
-- Provision with: nagarectl db create redis cache --size 2Gi
module Main (main) where

import Nagare.Dsl.Config (emitDatabase)
import Nagare.Dsl.Database (Database (..), Engine (..), mkDatabaseName, mkEngineVersion)
import Nagare.Dsl.Types (RetentionPolicy (..), defaultNamespace, mkQuantity)

database :: Either String Database
database = do
  name' <- mapLeft show (mkDatabaseName "cache")
  ver' <- mapLeft show (mkEngineVersion Redis "8")
  size' <- mapLeft show (mkQuantity "2Gi")
  pure
    Database
      { dbName = name'
      , engine = Redis
      , version = ver'
      , namespace = defaultNamespace
      , size = size'
      , resources = Nothing
      , retention = Retain
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case database of
  Left err -> ioError (userError err)
  Right db -> emitDatabase db
