{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Worker-only variant for the local Kubernetes CLI isolation probe.
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Build (BuildSpec (PrebuiltImage), mkTag)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Types (mkImageRef, mkNamespace, mkServiceName)
import Nagare.Dsl.Worker (webWorker)

applicationConfig :: Either Text.Text Application
applicationConfig = do
  appName <- mkServiceName "isolated-app"
  namespace <- mkNamespace "personal"
  image <- mkImageRef "k3d-registry.localhost:5000/isolated"
  tag <- mkTag "v1"
  worker <- first Text.pack (webWorker "isolated-app" "k3d-registry.localhost:5000/isolated")
  mkApplication Application
    { name = appName
    , logicalKey = Nothing
    , namespace = namespace
    , image = image
    , env = Map.empty
    , databases = []
    , brokers = []
    , access = Nothing
    , service = Nothing
    , workers = [worker & #namespace .~ namespace & #build .~ PrebuiltImage tag]
    , tasks = []
    }

main :: IO ()
main = either (ioError . userError . Text.unpack) emitApplication applicationConfig
