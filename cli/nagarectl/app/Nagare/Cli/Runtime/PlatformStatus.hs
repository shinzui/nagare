-- | Runtime / PlatformStatus. Executable-private CLI boundary.
module Nagare.Cli.Runtime.PlatformStatus
  ( gatherPlatformStatus
  , gatherPlatformStatusWithImages
  , ingressNoticeFor
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Contract.ReleaseImages (ReleaseImageKey (..))
import Nagare.Dsl.Prelude
import Nagare.Host.Config (hostConfigDir)
import Nagare.Ops.Probe (captureTool)
import Nagare.Platform.Deployment
  ( DeploymentState (..)
  , defaultDeploymentOps
  , observeHostDeployment
  )
import Nagare.Platform.ImageStatus (assessWorkloadImages, observeWorkloads)
import Nagare.Platform.Status
  ( PlatformStatus
  , ReleaseIdentity (ReleaseIdentity)
  , assessPlatformStatus
  , identityFromBuild
  , identityFromContext
  , identityFromPayload
  , parseClusterIdentity
  , parseHostIdentity
  , withImageAssessment
  )
import Nagare.Platform.Workspace
  ( readPayloadManifest
  , renderWorkspaceError
  )
import Nagare.Target (ActiveTarget, IngressMode (IngressCloudflareTunnel), Mode (Cloud, Local), contextFilePath, readContextMap)
import Nagare.Target.Kinds (directIngressNotice)
import Nagare.Version (currentBuildVersion)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

gatherPlatformStatus :: Maybe String -> IO (ActiveTarget, PlatformStatus)
gatherPlatformStatus mctx = do
  active <- activeTarget mctx
  (paths, _) <- resolvePlatformWorkspace (active ^. #contextName)
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  hostRoot <- hostConfigDir (active ^. #contextName)
  let hostFlake = hostRoot </> "flake.nix"
  hostExists <- doesFileExist hostFlake
  hostIdentity <- if hostExists then parseHostIdentity <$> TIO.readFile hostFlake else pure unknownIdentity
  hostDeployment <- case active ^. #profile . #mode of
    Cloud -> observeHostDeployment defaultDeploymentOps (active ^. #profile)
    Local -> pure (DeploymentUnknown "local contexts do not have a GCE deployment")
  (clusterIdentity, clusterDeployment) <- case hostDeployment of
    NotDeployed -> pure (unknownIdentity, NotDeployed)
    _ -> do
      clusterBytes <- captureTool "kubectl" ["get", "configmap", "nagare-platform-version", "-n", "nagare-system", "-o", "json", "--request-timeout=5s"]
      pure $ case clusterBytes >>= parseClusterIdentity of
        Just identity -> (identity, Deployed)
        Nothing -> (unknownIdentity, DeploymentUnknown "cluster release identity is unreachable or absent")
  let status =
        assessPlatformStatus
          (identityFromBuild currentBuildVersion)
          (identityFromPayload manifest)
          (identityFromContext (active ^. #profile))
          hostIdentity
          hostDeployment
          clusterIdentity
          clusterDeployment
  pure (active, status)
  where
    unknownIdentity = ReleaseIdentity Nothing Nothing Nothing

-- | 'gatherPlatformStatus' plus the release workloads' images (EP-237): what
-- @platform status@ reports and release acceptance reads. Mutation guards do
-- not pay for these reads; image skew never blocks a mutation.
-- | The direct-ingress note for this context, read from its own file only.
ingressNoticeFor :: ActiveTarget -> IO (Maybe Text)
ingressNoticeFor active = do
  stored <- readContextMap =<< contextFilePath (active ^. #contextName)
  pure
    ( directIngressNotice
        (active ^. #profile . #mode)
        (active ^. #profile . #ingress)
        (stored >>= Map.lookup "NAGARE_INGRESS_NOTICE")
    )

gatherPlatformStatusWithImages :: Maybe String -> IO (ActiveTarget, PlatformStatus)
gatherPlatformStatusWithImages mctx = do
  (active, status) <- gatherPlatformStatus mctx
  (paths, _) <- resolvePlatformWorkspace (active ^. #contextName)
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  case status ^. #clusterDeployment of
    NotDeployed -> pure (active, status)
    _ -> do
      let list namespace resource = do
            bytes <- captureTool "kubectl" ["get", resource, "-n", namespace, "-o", "json", "--request-timeout=5s"]
            pure (maybe (Left ("kubectl get " <> T.pack resource <> " failed")) Right bytes)
          profile = active ^. #profile
          tunnel = profile ^. #ingress == IngressCloudflareTunnel
      deployments <- list "nagare-system" "deployments.apps"
      services <- list "nagare-system" "services.serving.knative.dev"
      pods <- list "nagare-system" "pods"
      -- The connector is the one release workload in its own namespace.
      connector <-
        if tunnel
          then do
            connectorDeployments <- list "cloudflare-tunnel" "deployments.apps"
            connectorPods <- list "cloudflare-tunnel" "pods"
            pure (Map.restrictKeys (observeWorkloads connectorDeployments services connectorPods) (Set.singleton CloudflaredImage))
          else pure Map.empty
      let release = manifest ^. #releaseImages
          enabled = \case
            AdminApiImage -> profile ^. #adminApiEnabled
            CloudflaredImage -> tunnel
            _ -> True
          statuses =
            assessWorkloadImages
              enabled
              release
              (Map.union connector (observeWorkloads deployments services pods))
      pure (active, withImageAssessment release statuses status)
