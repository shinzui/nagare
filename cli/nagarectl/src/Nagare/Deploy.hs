{-# LANGUAGE PackageImports #-}

-- | Cluster operations for a deployment: apply rendered manifests, wait for
-- readiness, and compute the service URL.
--
-- All shell-outs go through @cradle@ and @kubectl@. Manifests are written to a
-- temp file and applied with @kubectl apply -f@ (simpler than stdin piping).
module Nagare.Deploy
  ( applyManifests
  , waitForReady
  , serviceUrl
  ) where

import Nagare.Dsl.Prelude

import "generic-lens" Data.Generics.Labels ()

import Cradle
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Nagare.Dsl.Types
  ( Deployment
  , canonicalDomain
  , domainText
  , namespaceText
  , serviceNameText
  )
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)

-- | Apply each manifest by writing it to a temp file and running
-- @kubectl apply -f \<file\>@. Using a temp file (rather than stdin piping)
-- keeps the cradle invocation simple and avoids handle-management complexity.
applyManifests :: [BS.ByteString] -> IO ()
applyManifests = mapM_ applyOne
  where
    applyOne m = withSystemTempFile "nagare-manifest.yaml" $ \fp h -> do
      BS.hPut h m
      hClose h
      run_ $ cmd "kubectl" & addArgs ["apply", "-f", fp]

-- | Run @kubectl wait --for=condition=Ready --timeout=300s ksvc/\<name\> -n \<namespace\>@.
-- Blocks until the Knative Service is Ready or the 5-minute timeout expires.
waitForReady :: Text -> Text -> IO ()
waitForReady name namespace =
  run_ $
    cmd "kubectl"
      & addArgs
        [ "wait"
        , "--for=condition=Ready"
        , "--timeout=300s"
        , "ksvc/" <> T.unpack name
        , "-n"
        , T.unpack namespace
        ]

-- | Compute the service URL.
--
-- If the deployment has a custom domain, returns @https://\<domain\>@.
-- Otherwise returns the Knative wildcard URL
-- @https://\<name\>.\<namespace\>.\<baseDomain\>@. The @baseDomain@ argument is
-- the resolved base (e.g. @"apps.example.com"@), supplied via @--base-domain@
-- or the @NAGARE_BASE_DOMAIN@ env var, defaulting to @"apps.example.com"@.
serviceUrl :: Deployment -> Text -> Text
serviceUrl dep baseDomain =
  case canonicalDomain (dep ^. #domains) of
    Just d -> "https://" <> domainText d
    Nothing ->
      "https://"
        <> serviceNameText (dep ^. #name)
        <> "."
        <> namespaceText (dep ^. #namespace)
        <> "."
        <> baseDomain
