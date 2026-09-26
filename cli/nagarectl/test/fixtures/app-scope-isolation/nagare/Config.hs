{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Small reviewed application used by the CLI provider-isolation probe.
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Build (BuildSpec (PrebuiltImage), mkTag)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (mkImageRef, mkNamespace, mkServiceName)

applicationConfig :: Either Text.Text Application
applicationConfig = do
  appName <- mkServiceName "isolated-app"
  namespace <- mkNamespace "personal"
  image <- mkImageRef "k3d-registry.localhost:5000/isolated"
  tag <- mkTag "v1"
  service <- webService "isolated-app" "k3d-registry.localhost:5000/isolated"
  mkApplication Application
    { name = appName
    , logicalKey = Nothing
    , namespace = namespace
    , image = image
    , env = Map.empty
    , databases = []
    , brokers = []
    , access = Nothing
    , service = Just (service & #build .~ PrebuiltImage tag)
    , workers = []
    , tasks = []
    }

main :: IO ()
main = either (ioError . userError . Text.unpack) emitApplication applicationConfig
