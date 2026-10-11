-- | Bootstrap / Sequence. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Sequence (planNextStage) where

import Data.Generics.Labels ()
import Data.Map qualified as Map
import Nagare.Cli.Bootstrap.Cloud (buildCloudStageCandidate)
import Nagare.Cli.Bootstrap.Host
  ( buildHostStageCandidate
  , buildKubeconfigStageCandidate
  )
import Nagare.Cli.Bootstrap.Image
  ( buildImageBuildStageCandidate
  , buildImagePublicationStageCandidate
  )
import Nagare.Cli.Bootstrap.Local (buildLocalSubstrateCandidate)
import Nagare.Cli.Bootstrap.Platform (buildPlatformCandidate)
import Nagare.Cli.Bootstrap.Stage (StageMode (..))
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistry
  , inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Pulumi (selectReviewedPulumiForContext)
import Nagare.Cluster.Kubeconfig (kubeconfigPath)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Platform.Paths (PlatformPaths)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, Mode (Cloud, Local))
import System.Directory (doesFileExist)
import System.Environment (setEnv)

-- | Plan the first pending stage after the cloud foundation under the given
-- review identity: the local substrate, the cloud perimeter, the host image
-- build and publication (before the host is accepted), the host, the
-- kubeconfig, then the platform scopes. Bootstrap and the release transition
-- (EP-172) share this order; a transition re-pins the accepted host instead of
-- publishing a new image, which only fresh installations use.
planNextStage :: StageMode -> ActiveTarget -> PlatformPaths -> PlatformWorkspace -> Text -> FilePath -> IO ()
planNextStage mode active paths workspace identity output = do
  snapshot <- Inventory.loadTargetSnapshot active
  when
    (active ^. #profile . #mode == Cloud)
    (void (selectReviewedPulumiForContext (active ^. #contextName) (active ^. #profile)))
  localStage <- buildLocalSubstrateCandidate active workspace snapshot
  case localStage of
    Just candidate -> plan candidate
    Nothing -> do
      cloudStage <- buildCloudStageCandidate active workspace snapshot
      case cloudStage of
        Just candidate -> plan candidate
        Nothing -> afterCloud snapshot
  where
    plan candidate =
      Inventory.planInventoryCandidateWithPayloadIdentity
        (inventoryPlanRegistry active workspace)
        identity
        active
        candidate
        output
    afterCloud snapshot = do
      hostOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "host")
      -- Once the host is accepted, installation media is no longer a prerequisite
      -- for adding cluster scopes. Still validate the exact accepted host inputs;
      -- a changed configuration requires an explicit reviewed host transition.
      if active ^. #profile . #mode == Cloud
        && Map.member hostOwner (ResourceInventory.snapshotScopes snapshot)
        then afterImages snapshot
        else do
          imageBuild <- buildImageBuildStageCandidate active workspace snapshot
          case imageBuild of
            Just candidate -> plan candidate
            Nothing -> do
              imagePublication <- buildImagePublicationStageCandidate active workspace snapshot
              case imagePublication of
                Just candidate -> plan candidate
                Nothing -> afterImages snapshot
    afterImages snapshot = do
      hostStage <- buildHostStageCandidate mode paths active workspace snapshot
      case hostStage of
        Just candidate -> plan candidate
        Nothing -> do
          kubeconfigStage <- buildKubeconfigStageCandidate active workspace snapshot
          case kubeconfigStage of
            Just candidate -> plan candidate
            Nothing -> do
              when (active ^. #profile . #mode == Local) $ do
                selectedKubeconfig <- kubeconfigPath (active ^. #contextName)
                exists <- doesFileExist selectedKubeconfig
                unless exists (dieT "reviewed local context kubeconfig is missing")
                setEnv "KUBECONFIG" selectedKubeconfig
              (candidate, native) <- buildPlatformCandidate active paths workspace snapshot
              Inventory.planInventoryCandidateWithPayloadIdentity
                (inventoryPlanRegistryWithNative active workspace native)
                identity
                active
                candidate
                output
