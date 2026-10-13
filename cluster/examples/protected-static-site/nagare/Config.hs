{-# LANGUAGE OverloadedStrings #-}

-- | Static-site descriptor for the @protected-static-site@ example
-- (MasterPlan 27): the @static-site@ example with one more field. A
-- @StaticSite@ opts into identity-aware access exactly as a @Deployment@
-- does, with @access = Just requireLogin@, and nothing else changes.
--
-- With no custom domain the site answers on its default hostname,
-- @protected-static-site.personal.<base-domain>@, which the reviewed deploy
-- routes through the shared @nagare-access@ enforcer while the origin
-- Service stays cluster-local. That hostname is its own authorization
-- object: grant it to a user or a team with @nagarectl access grant --host@;
-- a preview of this site is another hostname with its own grants.
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Access (requireLogin)
import Nagare.Dsl.Config (emitStaticSite)
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (mkImageRef, mkNamespace)

staticSite :: Either String StaticSite
staticSite = do
  name' <- first show (mkSiteName "protected-static-site")
  ns' <- first show (mkNamespace "personal")
  img' <- first show (mkImageRef "protected-static-site")
  dir' <- first show (mkFilePathText "public")
  cache' <- first show (mkCachePolicy True (Just 600))
  notFound' <- first show (mkFilePathText "404.html")
  Right
    StaticSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = NoBuild dir'
      , domains = []
      , redirects = []
      , headers = []
      , cache = cache'
      , notFound = Just notFound'
      , cdn = Nothing
      , access = Just requireLogin
      }

main :: IO ()
main = case staticSite of
  Left err -> ioError (userError err)
  Right s -> emitStaticSite s
