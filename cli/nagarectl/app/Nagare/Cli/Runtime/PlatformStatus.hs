-- | Runtime / PlatformStatus. Executable-private CLI boundary.
module Nagare.Cli.Runtime.PlatformStatus
  ( gatherPlatformStatus
  )
where

import Data.Generics.Labels ()
import Data.Text.IO qualified as TIO
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Host.Config (hostConfigDir)
import Nagare.Ops.Probe (captureTool)
import Nagare.Platform.Deployment
  ( DeploymentState (..)
  , defaultDeploymentOps
  , observeHostDeployment
  )
import Nagare.Platform.Status
  ( PlatformStatus
  , ReleaseIdentity (ReleaseIdentity)
  , assessPlatformStatus
  , identityFromBuild
  , identityFromContext
  , identityFromPayload
  , parseClusterIdentity
  , parseHostIdentity
  )
import Nagare.Platform.Workspace
  ( readPayloadManifest
  , renderWorkspaceError
  )
import Nagare.Target (ActiveTarget, Mode (Cloud, Local))
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
