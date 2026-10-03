{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A deliberately conflicting owner for the collision check of the MP-23
-- local release run (EP-155, C2). It claims application A's route host from a
-- different scope. Composition must refuse it before any review is published.
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (mkDomains, mkImageRef, mkNamespace, mkServiceName)
import System.Environment (lookupEnv)

applicationConfig :: Text -> Either Text Application
applicationConfig baseDomain = do
  appName <- mkServiceName "scenario-collision"
  namespace' <- mkNamespace "personal"
  image' <- mkImageRef "scenario-b"
  web <- webService "scenario-collision" "scenario-b"
  domains' <- mkDomains [("scenario-a." <> baseDomain, True)]
  mkApplication
    Application
      { name = appName
      , logicalKey = Nothing
      , namespace = namespace'
      , image = image'
      , env = Map.empty
      , databases = []
      , brokers = []
      , access = Nothing
      , service = Just (web & #domains .~ domains')
      , workers = []
      , tasks = []
      }

main :: IO ()
main = do
  baseDomain <- maybe "apps.example.com" Text.pack <$> lookupEnv "NAGARE_BASE_DOMAIN"
  either (ioError . userError . Text.unpack) emitApplication (applicationConfig baseDomain)
