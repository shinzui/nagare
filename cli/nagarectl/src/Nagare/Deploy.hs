-- | Cluster operations for a deployment: apply rendered manifests, wait for
-- readiness, and compute the service URL.
--
-- All shell-outs go through @cradle@ and @kubectl@. Manifests are written to a
-- temp file and applied with @kubectl apply -f@ (simpler than stdin piping).
module Nagare.Deploy
  ( applyManifests
  , applyPVCs
  , pvcPhases
  , waitForReady
  , waitForRollout
  , waitForWorkerRollout
  , requireWait
  , serviceUrl
  )
where

import Cradle
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( Deployment
  , canonicalDomain
  , domainText
  , namespaceText
  , serviceNameText
  )
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hClose, stderr)
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

-- | Apply the rendered PVC manifests for an app, *before* the Service, so the
-- PVC objects exist when Knative schedules the consuming pod (the @local-path@
-- StorageClass binds @WaitForFirstConsumer@, so a PVC stays @Pending@ until a
-- pod mounts it — see EP-35 Decision Log). A no-op on the empty list (the common
-- zero-volume case). Idempotent: re-applying an existing PVC is a no-op for
-- unchanged fields and never recreates the underlying disk.
applyPVCs :: [BS.ByteString] -> IO ()
applyPVCs [] = pure ()
applyPVCs pvcs = applyManifests pvcs

-- | After the Service is Ready, read each PVC's @.status.phase@ for an
-- informational summary. Returns @(pvcName, phase)@ pairs in the input order; a
-- missing PVC yields @(name, "NotFound")@. Never throws and never gates the
-- deploy — by the time this runs the consuming pod has scheduled, so a healthy
-- volume reads @Bound@.
pvcPhases :: Text -> [Text] -> IO [(Text, Text)]
pvcPhases ns = traverse one
  where
    one n = do
      (code, StdoutRaw out) <-
        run $
          cmd "kubectl"
            & addArgs
              [ "get"
              , "pvc"
              , T.unpack n
              , "-n"
              , T.unpack ns
              , "-o"
              , "jsonpath={.status.phase}"
              ]
            & silenceStderr
      pure $ case code of
        ExitSuccess -> (n, phaseOr out)
        ExitFailure _ -> (n, "NotFound")
    phaseOr raw =
      let p = T.strip (TE.decodeUtf8 raw)
       in if T.null p then "Pending" else p

-- | Run @kubectl wait --for=condition=Ready --timeout=300s ksvc/\<name\> -n \<namespace\>@.
-- Blocks until the Knative Service is Ready or the 5-minute timeout expires.
waitForReady :: Text -> Text -> IO ExitCode
waitForReady name namespace =
  run $
    cmd "kubectl"
      & addArgs
        [ "wait"
        , "--for=condition=Ready"
        , "--timeout=300s"
        , "ksvc/" <> T.unpack name
        , "-n"
        , T.unpack namespace
        ]

-- | Run @kubectl rollout status statefulset/\<name\> -n \<namespace\> --timeout=300s@.
-- Blocks until the database StatefulSet's single replica is Ready or the timeout
-- expires (MasterPlan 9, EP-45). Unlike 'waitForReady' (a Knative @ksvc@), a
-- database is a StatefulSet, so the readiness gate is a rollout-status wait.
waitForRollout :: Text -> Text -> IO ExitCode
waitForRollout namespace name =
  run $
    cmd "kubectl"
      & addArgs
        [ "rollout"
        , "status"
        , "statefulset/" <> T.unpack name
        , "-n"
        , T.unpack namespace
        , "--timeout=300s"
        ]

-- | Run @kubectl rollout status deployment/\<name\> -n \<namespace\> --timeout=300s@.
-- The readiness gate for a worker (EP-71): a worker is an @apps/v1@ Deployment,
-- which exposes rollout status exactly as the database StatefulSet does
-- ('waitForRollout'); this is the parallel @deployment/\<name\>@ form. Blocks
-- until the requested replicas are Ready or the 5-minute timeout expires.
waitForWorkerRollout :: Text -> Text -> IO ExitCode
waitForWorkerRollout namespace name =
  run $
    cmd "kubectl"
      & addArgs
        [ "rollout"
        , "status"
        , "deployment/" <> T.unpack name
        , "-n"
        , T.unpack namespace
        , "--timeout=300s"
        ]

-- | Exit with a clean one-line error when a readiness wait failed. @what@ is a
-- human description such as @service 'api'@ or @database 'pg-main'@.
requireWait :: Text -> ExitCode -> IO ()
requireWait _ ExitSuccess = pure ()
requireWait what (ExitFailure code) = do
  TIO.hPutStrLn
    stderr
    ( "nagarectl: "
        <> what
        <> " did not become ready within the timeout (kubectl exited "
        <> T.pack (show code)
        <> ")"
    )
  exitFailure

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
