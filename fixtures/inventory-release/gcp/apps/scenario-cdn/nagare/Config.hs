{-# LANGUAGE OverloadedStrings #-}

-- | Google CDN server site for the MP-23 cloud release run (EP-156 C3, EP-158 B3).
--
-- It serves the scenario-site nginx image on a more specific hostname under the
-- context base domain, fronted by the platform Google CDN backend that the
-- context enables with @NAGARE_CDN_ENABLED=1@. The shared backend uses the
-- standing Pulumi cache policy, so no per-site TTL or path rule is declared.
-- Deploy with @site deploy --skip-build --image-resource …
-- --cdn-backend-resource platform:cloud/nagare-cdn-backend/nagare-cdn-backend@.
module Main (main) where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Cdn.Types (gcpCloudCdn)
import Nagare.Dsl.Config (emitServerSite)
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types (mkSiteName)
import Nagare.Dsl.Types
import System.Environment (lookupEnv)

serverSite :: Text.Text -> Text.Text -> Either String ServerSite
serverSite registry baseDomain = do
  name' <- first show (mkSiteName "scenario-cdn")
  ns' <- first show (mkNamespace "personal")
  img' <- first show (mkImageRef (registry <> "/scenario-site"))
  domains' <- first show (mkDomains [("scenario-cdn." <> baseDomain, True)])
  Right
    ServerSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = tanstackStartBuild
      , runtime = defaultServerRuntime
      , port = defaultPort
      , env = Map.empty
      , resources = Nothing
      , scale = Nothing
      , domains = domains'
      , volumes = []
      , cdn = Just gcpCloudCdn
      }

main :: IO ()
main = do
  host <- maybe "k3d-registry.localhost:5000" Text.pack <$> lookupEnv "NAGARE_REGISTRY_HOST"
  mode <- lookupEnv "NAGARE_MODE"
  project <- maybe "" Text.pack <$> lookupEnv "CLOUDSDK_CORE_PROJECT"
  repository <- maybe "" Text.pack <$> lookupEnv "NAGARE_ARTIFACT_REGISTRY_ID"
  baseDomain <- maybe "apps.example.com" Text.pack <$> lookupEnv "NAGARE_BASE_DOMAIN"
  let registry = if mode == Just "cloud" && not (Text.null project) && not (Text.null repository) then host <> "/" <> project <> "/" <> repository else host
  either (ioError . userError) emitServerSite (serverSite registry baseDomain)
