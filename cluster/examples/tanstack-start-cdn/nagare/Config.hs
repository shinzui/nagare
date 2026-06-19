{-# LANGUAGE OverloadedStrings #-}

-- | TanStack Start app fronted by Google Cloud CDN (MasterPlan 11 / EP-59) — the
-- headline "TanStack Start + Google Cloud CDN" worked example.
--
-- It is the @tanstack-start@ example plus one new field: @cdn = Just …@. The
-- deploy builds the Node image and applies the Service/DomainMapping as before,
-- and then provisions Google Cloud CDN: a more-specific Cloud DNS A record for
-- @app.apps.example.com@ pointing at the load balancer's anycast IP (which wins
-- over the @*.apps.example.com@ wildcard that points at the VM), plus the
-- per-path cache behaviour on the backend service. The standing Google load
-- balancer is provisioned once with @pulumi config set nagare:enableCdn true &&
-- pulumi up@ (see the README).
module Main (main) where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Cdn.Types (gcpCloudCdn, withCacheRule, withDefaultTtl)
import Nagare.Dsl.Config (emitServerSite)
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types (mkSiteName)
import Nagare.Dsl.Types

serverSite :: Either String ServerSite
serverSite = do
  name' <- first show (mkSiteName "tanstack-start-cdn")
  ns' <- first show (mkNamespace "personal")
  img' <- first show (mkImageRef "tanstack-start-cdn")
  host <- first show (mkEnvName "HOSTNAME")
  app <- first show (mkDomain "app.apps.example.com")
  -- Google Cloud CDN: a 10-minute default edge TTL, a 1-year cache for
  -- fingerprinted assets, never cache /api/.
  cdn' <-
    first show
      ( withCacheRule "/api/" Nothing
          =<< withCacheRule "/assets/" (Just 31536000) (withDefaultTtl 600 gcpCloudCdn)
      )
  Right
    ServerSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = tanstackStartBuild
      , runtime = defaultServerRuntime
      , port = defaultPort
      , env = Map.fromList [(host, runtimeScoped (EnvLiteral "0.0.0.0"))]
      , resources = Nothing
      , scale = Nothing
      , domains = [app]
      , volumes = []
      , cdn = Just cdn'
      }

main :: IO ()
main = case serverSite of
  Left err -> ioError (userError err)
  Right s -> emitServerSite s
