{-# LANGUAGE OverloadedStrings #-}

-- | The managed Postgres database for the postgres-app example (MasterPlan 9).
-- Provision it with:
--   nagarectl db create postgres pg-main --config cluster/examples/postgres-app/nagare/Database.hs
-- or simply: nagarectl db create postgres pg-main --size 10Gi
module Main (main) where

import Nagare.Dsl.Config (emitDatabase)
import Nagare.Dsl.Database (Database (..), Engine (..), mkDatabaseName, mkEngineVersion)
import Nagare.Dsl.Types (RetentionPolicy (..), defaultNamespace, mkQuantity)

database :: Either String Database
database = do
  name' <- mapLeft show (mkDatabaseName "pg-main")
  ver' <- mapLeft show (mkEngineVersion Postgres "18")
  size' <- mapLeft show (mkQuantity "10Gi")
  pure
    Database
      { dbName = name'
      , engine = Postgres
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
