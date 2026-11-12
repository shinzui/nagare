{-# LANGUAGE OverloadedStrings #-}

-- | The isolated SDK consumer (EP-253): one typed Application with a service,
-- a worker and a migration task, compiled by the packaged CLI and SDK from a
-- directory with no Nagare checkout, Cabal environment or network access.
module Main (main) where

import Data.Bifunctor (first)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task
  ( ConcurrencyPolicy (..)
  , RestartPolicy (..)
  , Task (..)
  , mkSchedule
  , mkTask
  )
import Nagare.Dsl.Types (mkImageRef, mkNamespace, mkServiceName)
import Nagare.Dsl.Worker (webWorker)

sharedImage :: Text
sharedImage = "gcr.io/knative-samples/helloworld-go"

applicationConfig :: Either Text Application
applicationConfig = do
  appName <- mkServiceName "sdk-consumer"
  ns <- mkNamespace "personal"
  img <- mkImageRef sharedImage
  svc <- webService "sdk-consumer-serve" sharedImage
  worker <- first Text.pack (webWorker "sdk-consumer-worker" sharedImage)
  migrateName <- mkServiceName "sdk-consumer-migrate"
  sched <- mkSchedule "0 0 * * *"
  migrate <-
    mkTask
      Task
        { name = migrateName
        , logicalKey = Nothing
        , namespace = ns
        , schedule = sched
        , image = Nothing
        , app = Just appName
        , command = ["/app/migrate"]
        , args = []
        , env = Map.empty
        , resources = Nothing
        , timeoutSeconds = Nothing
        , concurrencyPolicy = Forbid
        , restartPolicy = Never
        , backoffLimit = 0
        , successfulJobsHistoryLimit = 3
        , failedJobsHistoryLimit = 1
        , startingDeadlineSeconds = Nothing
        , serviceAccount = Nothing
        , appDatabases = []
        }
  mkApplication
    Application
      { name = appName
      , logicalKey = Nothing
      , namespace = ns
      , image = img
      , env = Map.empty
      , databases = []
      , brokers = []
      , access = Nothing
      , service = Just svc
      , workers = [worker]
      , tasks = [migrate]
      }

main :: IO ()
main = either (ioError . userError . Text.unpack) emitApplication applicationConfig
