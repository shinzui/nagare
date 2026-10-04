{-# LANGUAGE OverloadedStrings #-}

-- | The static site whose reviewed preview the MP-23 local release run
-- creates, routes and then collects (EP-155, C2).
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitStaticSite)
import Nagare.Dsl.Static.Types
import Data.Text qualified as T
import Nagare.Dsl.Types (mkImageRef, mkNamespace)
import System.Environment (lookupEnv)

staticSite :: T.Text -> Either String StaticSite
staticSite registry = do
  name' <- first show (mkSiteName "scenario-site")
  namespace' <- first show (mkNamespace "personal")
  image' <- first show (mkImageRef (registry <> "/scenario-site"))
  directory <- first show (mkFilePathText "public")
  cache' <- first show (mkCachePolicy True (Just 60))
  notFound' <- first show (mkFilePathText "404.html")
  Right
    StaticSite
      { name = name'
      , namespace = namespace'
      , image = image'
      , build = NoBuild directory
      , domains = []
      , redirects = []
      , headers = []
      , cache = cache'
      , notFound = Just notFound'
      , cdn = Nothing
      }

main :: IO ()
main = do
  -- Cloud copy for the MP-23 C3 run (EP-156): Artifact Registry images live at
  -- <host>/<project>/<repository>, not directly under the registry host.
  host <- maybe "k3d-registry.localhost:5000" T.pack <$> lookupEnv "NAGARE_REGISTRY_HOST"
  mode <- lookupEnv "NAGARE_MODE"
  project <- maybe "" T.pack <$> lookupEnv "CLOUDSDK_CORE_PROJECT"
  repository <- maybe "" T.pack <$> lookupEnv "NAGARE_ARTIFACT_REGISTRY_ID"
  let registry = if mode == Just "cloud" && not (T.null project) && not (T.null repository) then host <> "/" <> project <> "/" <> repository else host
  either (ioError . userError) emitStaticSite (staticSite registry)
