{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Access (requireLogin)
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (mkImageRef, mkNamespace, mkServiceName)

helloImage :: Text.Text
helloImage = "k3d-registry.localhost:5000/tan-nb-exp/nagare/op-hello"

main :: IO ()
main = either (ioError . userError . Text.unpack) emitApplication $ do
  name' <- mkServiceName "op-hello"
  ns <- mkNamespace "personal"
  img <- mkImageRef helloImage
  svc <- webService "op-hello" helloImage
  mkApplication
    Application
      { name = name'
      , logicalKey = Nothing
      , namespace = ns
      , image = img
      , env = Map.empty
      , databases = []
      , brokers = []
      , access = Just requireLogin
      , service = Just (svc & #namespace .~ ns & #access .~ Just requireLogin)
      , workers = []
      , tasks = []
      }
