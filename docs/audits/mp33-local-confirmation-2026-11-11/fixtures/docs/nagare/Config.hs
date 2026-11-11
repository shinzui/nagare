{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Access (requireLogin)
import Nagare.Dsl.Config (emitStaticSite)
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (mkDomains, mkImageRef, mkNamespace)

main :: IO ()
main = either (ioError . userError) emitStaticSite $ do
  name' <- first show (mkSiteName "docs")
  ns' <- first show (mkNamespace "team-a")
  img' <- first show (mkImageRef "k3d-registry.localhost:5000/tan-nb-exp/nagare/team-a/docs")
  dir' <- first show (mkFilePathText "public")
  cache' <- first show (mkCachePolicy True (Just 600))
  domains' <- first show (mkDomains [])
  Right
    StaticSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = NoBuild dir'
      , domains = domains'
      , redirects = []
      , headers = []
      , cache = cache'
      , notFound = Nothing
      , cdn = Nothing
      , access = Just requireLogin
      }
