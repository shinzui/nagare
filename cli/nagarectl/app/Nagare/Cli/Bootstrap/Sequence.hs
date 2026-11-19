-- | Bootstrap / Sequence. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Sequence (planNextStage) where

import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Nagare.Cli.Bootstrap.Cloud (buildCloudStageCandidate)
import Nagare.Cli.Bootstrap.CloudflareZone (buildCloudflareZoneStageCandidate)
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
import Nagare.Cli.Runtime.Posture (postureOf)
import Nagare.Cli.Runtime.Pulumi (selectReviewedPulumiForContext)
import Nagare.Cluster.Kubeconfig (kubeconfigPath)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Store (HeadManifest (..))
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
  (snapshot, headValue) <- Inventory.loadTargetSnapshotWithHead active
  -- EP-243: one posture for every stage of this plan, from the head the snapshot came from.
  let ingress = postureOf active (headMove headValue)
  when
    (active ^. #profile . #mode == Cloud)
    (void (selectReviewedPulumiForContext (active ^. #contextName) (active ^. #profile)))
  localStage <- buildLocalSubstrateCandidate mode active workspace snapshot
  case localStage of
    Just candidate -> plan candidate
    Nothing -> do
      cloudStage <- buildCloudStageCandidate ingress active workspace snapshot
      case cloudStage of
        Just candidate -> plan candidate
        Nothing -> afterCloud ingress snapshot
  where
    plan candidate =
      Inventory.planInventoryCandidateWithPayloadIdentity
        (inventoryPlanRegistry active workspace)
        identity
        active
        candidate
        output
    afterCloud ingress snapshot = do
      hostOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "host")
      -- Once the host is accepted, installation media is no longer a prerequisite
      -- for adding cluster scopes. Still validate the exact accepted host inputs;
      -- a changed configuration requires an explicit reviewed host transition.
      if active ^. #profile . #mode == Cloud
        && Map.member hostOwner (ResourceInventory.snapshotScopes snapshot)
        then afterImages ingress snapshot
        else do
          imageBuild <- buildImageBuildStageCandidate active workspace snapshot
          case imageBuild of
            Just candidate -> plan candidate
            Nothing -> do
              imagePublication <- buildImagePublicationStageCandidate active workspace snapshot
              case imagePublication of
                Just candidate -> plan candidate
                Nothing -> afterImages ingress snapshot
    afterImages ingress snapshot = do
      hostStage <- buildHostStageCandidate mode paths active workspace snapshot
      case hostStage of
        Just candidate -> plan candidate
        Nothing -> do
          kubeconfigStage <- buildKubeconfigStageCandidate active workspace snapshot
          case kubeconfigStage of
            Just candidate -> plan candidate
            Nothing -> afterKubeconfig ingress snapshot
    afterKubeconfig ingress snapshot = do
      zoneStage <- buildCloudflareZoneStageCandidate ingress active workspace snapshot
      case zoneStage of
        Just candidate -> plan candidate
        Nothing -> do
          when (active ^. #profile . #mode == Local) $ do
            selectedKubeconfig <- kubeconfigPath (active ^. #contextName)
            exists <- doesFileExist selectedKubeconfig
            unless exists (dieT "reviewed local context kubeconfig is missing")
            setEnv "KUBECONFIG" selectedKubeconfig
          (candidate, native) <- buildPlatformCandidate ingress active paths workspace snapshot
          -- EP-246: a route the admin API no longer declares (an old base's, once its grants are
          -- retired) is retired by its own decision; a context move's retirement then collects it.
          let desired = Set.fromList [resource ^. #identity | ResourceInventory.Managed resource <- ResourceInventory.inventoryDeclarations (ResourceInventory.candidateInventory candidate)]
              droppedRoutes =
                [ resource ^. #identity
                | (owner, (_, scope)) <- Map.toList (ResourceInventory.snapshotScopes snapshot)
                , Resource.scopeIdText owner == "platform:admin-api"
                , bundle <- ResourceInventory.scopeBundles scope
                , ResourceInventory.Managed resource <- bundle ^. #declarations
                , Resource.Kubernetes _ "serving.knative.dev" kind _ _ <- [resource ^. #address]
                , Resource.nameText kind == "domainmapping"
                , Set.notMember (resource ^. #identity) desired
                ]
          Inventory.planInventoryCandidateWithRetirementsPayload
            (inventoryPlanRegistryWithNative active workspace native)
            identity
            active
            candidate
            droppedRoutes
            output
