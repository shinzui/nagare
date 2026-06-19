{-# LANGUAGE OverloadedStrings #-}

-- | Example: an app that exercises the extended application model (EP-29) so the
-- lifecycle walk-through in @docs/user/app-lifecycle.md@ has a real, committed
-- config to deploy and operate. On top of the shared 'webService' preset it sets:
--
--   * an HTTP health check on @\/healthz@, emitted as readiness + liveness +
--     startup probes;
--   * resource /limits/ (500m / 512Mi) alongside the preset's /requests/
--     (250m / 128Mi);
--   * two public domains, with @demo.example.com@ marked canonical (it drives the
--     printed URL) and @www.demo.example.com@ a second DomainMapping.
--
-- @nagarectl deploy --dry-run@ renders the probes, the @resources.limits@ block,
-- the @nagare.dev/managed-by: nagarectl@ label, and one DomainMapping per domain.
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types

deployment :: Either String Deployment
deployment = do
  base <-
    first
      show
      (webService "lifecycle-demo" "lifecycle-demo")

  -- Two public domains; exactly one is canonical and drives the reported URL.
  doms <- first show (mkDomains [("demo.example.com", True), ("www.demo.example.com", False)])

  -- A /healthz probe with defaults, promoted to also emit liveness + startup.
  baseHc <- first show (httpHealthCheck "/healthz")
  let hc = baseHc {asLiveness = True, asStartup = True}

  -- The webService preset sets requests (250m / 128Mi); add matching limits.
  cpuReq <- first show (mkQuantity "250m")
  memReq <- first show (mkQuantity "128Mi")
  cpuLim <- first show (mkQuantity "500m")
  memLim <- first show (mkQuantity "512Mi")
  let res =
        Resources
          { cpu = Just cpuReq
          , memory = Just memReq
          , cpuLimit = Just cpuLim
          , memoryLimit = Just memLim
          }

  Right
    base
      { domains = doms
      , resources = Just res
      , healthCheck = Just hc
      }

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
