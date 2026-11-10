{-# LANGUAGE OverloadedStrings #-}

-- | The invalid SDK consumer (EP-253): the worker's image disagrees with the
-- Application's shared image, so 'mkApplication' rejects it and the packaged
-- CLI must fail without emitting anything.
module Main (main) where

import Data.Bifunctor (first)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (mkImageRef, mkNamespace, mkServiceName)
import Nagare.Dsl.Worker (webWorker)

sharedImage :: Text
sharedImage = "gcr.io/knative-samples/helloworld-go"

applicationConfig :: Either Text Application
applicationConfig = do
  appName <- mkServiceName "sdk-consumer-invalid"
  ns <- mkNamespace "personal"
  img <- mkImageRef sharedImage
  svc <- webService "sdk-consumer-invalid-serve" sharedImage
  worker <- first Text.pack (webWorker "sdk-consumer-invalid-worker" "gcr.io/knative-samples/other-image")
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
      , tasks = []
      }

main :: IO ()
main = either (ioError . userError . Text.unpack) emitApplication applicationConfig
