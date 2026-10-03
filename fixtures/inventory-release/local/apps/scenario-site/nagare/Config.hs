{-# LANGUAGE OverloadedStrings #-}

-- | The static site whose reviewed preview the MP-23 local release run
-- creates, routes and then collects (EP-155, C2).
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitStaticSite)
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (mkImageRef, mkNamespace)

staticSite :: Either String StaticSite
staticSite = do
  name' <- first show (mkSiteName "scenario-site")
  namespace' <- first show (mkNamespace "personal")
  image' <- first show (mkImageRef "scenario-site")
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
main = either (ioError . userError) emitStaticSite staticSite
