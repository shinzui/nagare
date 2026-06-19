{-# LANGUAGE OverloadedStrings #-}

-- | The redis-cache example app: references the managed Redis database "cache"
-- and receives REDIS_HOST/REDIS_PORT (literals) and REDIS_PASSWORD/REDIS_URL
-- (Secret references) at deploy time (MasterPlan 9, EP-46).
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..), mkDatabaseName)

deployment :: Either String Deployment
deployment = do
  dep <- first show (webService "redis-cache" "redis-cache")
  db <- first show (mkDatabaseName "cache")
  pure dep {databases = [db]}

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
