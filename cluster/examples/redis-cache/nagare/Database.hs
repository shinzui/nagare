{-# LANGUAGE OverloadedStrings #-}

-- | The managed Redis database for the redis-cache example (MasterPlan 9).
-- Provision with: nagarectl db create redis cache --size 2Gi
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDatabase)
import Nagare.Dsl.Database (Database (..), Engine (..), mkDatabaseName, mkEngineVersion)
import Nagare.Dsl.Types (RetentionPolicy (..), defaultNamespace, mkQuantity)

database :: Either String Database
database = do
  name' <- first show (mkDatabaseName "cache")
  ver' <- first show (mkEngineVersion Redis "8")
  size' <- first show (mkQuantity "2Gi")
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

main :: IO ()
main = case database of
  Left err -> ioError (userError err)
  Right db -> emitDatabase db
