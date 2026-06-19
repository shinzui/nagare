{-# LANGUAGE OverloadedStrings #-}

-- | Static site fronted by Cloudflare (MasterPlan 11 / EP-59) — the headline
-- "static + Cloudflare" worked example.
--
-- It is the @static-site@ example plus one new field: @cdn = Just …@. The deploy
-- builds and applies the Nginx Service and the DomainMapping exactly as before,
-- and then — because @cdn@ is set — provisions a Cloudflare edge in front of the
-- @blog.apps.example.com@ origin: a proxied DNS record, the origin-TLS mode, and
-- the declared cache rules. @nagarectl site deploy --dry-run@ prints the planned
-- CDN changes with no cloud side effects (the VM may be powered off).
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Cdn.Types (cloudflareCdn, withCacheRule, withDefaultTtl)
import Nagare.Dsl.Config (emitStaticSite)
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (mkDomain, mkImageRef, mkNamespace)

staticSite :: Either String StaticSite
staticSite = do
  name' <- first show (mkSiteName "static-cdn-site")
  ns' <- first show (mkNamespace "personal")
  img' <- first show (mkImageRef "static-cdn-site")
  dir' <- first show (mkFilePathText "public")
  blog <- first show (mkDomain "blog.apps.example.com")
  header' <- first show (mkHeaderRule "/assets/" "X-Content-Type-Options" "nosniff")
  cache' <- first show (mkCachePolicy True (Just 600))
  notFound' <- first show (mkFilePathText "404.html")
  -- Cloudflare CDN: a 1-hour default edge TTL, a 1-year cache for fingerprinted
  -- assets under /assets/, and never cache /api/. withCacheRule validates the
  -- per-path TTL, so it is threaded in the Either do-block (=<<); withDefaultTtl
  -- is total. Nothing TTL = "never cache this path".
  cdn' <-
    first show
      ( withCacheRule "/api/" Nothing
          =<< withCacheRule "/assets/" (Just 31536000) (withDefaultTtl 3600 cloudflareCdn)
      )
  Right
    StaticSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = NoBuild dir'
      , domains = [blog]
      , redirects = []
      , headers = [header']
      , cache = cache'
      , notFound = Just notFound'
      , cdn = Just cdn'
      }

main :: IO ()
main = case staticSite of
  Left err -> ioError (userError err)
  Right s -> emitStaticSite s
