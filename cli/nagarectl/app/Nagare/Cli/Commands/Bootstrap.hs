-- | Commands / Bootstrap. Executable-private CLI boundary.
module Nagare.Cli.Commands.Bootstrap
  ( runPlatformBootstrapApply
  , runPlatformBootstrapPlan
  )
where

import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Bootstrap.Cloud (buildCloudStageCandidate)
import Nagare.Cli.Bootstrap.Foundation
  ( buildCloudFoundationCandidate
  , cloudFoundationPendingAt
  , foundationStageTarget
  )
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
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistry
  , inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Pulumi (selectReviewedPulumiForContext)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Cluster.Kubeconfig (kubeconfigPath)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Platform.Paths (PlatformPaths)
import Nagare.Platform.Workspace
  ( PayloadManifest
  , PlatformWorkspace
  , readPayloadManifest
  , renderWorkspaceError
  )
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target
  ( ActiveTarget
  , InventoryStoreKind (InventoryStoreGcs, InventoryStoreLocal)
  , Mode (Cloud, Local)
  , effectiveInventoryStore
  )
import System.Directory (doesFileExist)
import System.Environment (setEnv)

-- | Build the production cloud adapter from the same composed declarations the
-- generic planner sees. Other domains retain their refusing adapters until
-- their production runtimes are registered by this child or later children.
runPlatformBootstrapPlan :: Maybe String -> FilePath -> IO ()
runPlatformBootstrapPlan mctx output = do
  active <- activeTarget mctx
  stageTarget <- foundationStageTarget active
  (paths, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  foundationPending <- cloudFoundationPendingAt active stageTarget
  if foundationPending
    then do
      snapshot <- Inventory.loadTargetSnapshot stageTarget
      candidate <- buildCloudFoundationCandidate active paths workspace snapshot
      Inventory.planInventoryCandidateWithPayloadIdentity
        (inventoryPlanRegistry active workspace)
        ("nagare-bootstrap:" <> manifest ^. #payloadId)
        stageTarget
        candidate
        output
    else do
      snapshot <- Inventory.loadTargetSnapshot active
      when
        (active ^. #profile . #mode == Cloud)
        (void (selectReviewedPulumiForContext (active ^. #contextName) (active ^. #profile)))
      localStage <- buildLocalSubstrateCandidate active workspace snapshot
      case localStage of
        Just candidate -> do
          Inventory.planInventoryCandidateWithPayloadIdentity
            (inventoryPlanRegistry active workspace)
            ("nagare-bootstrap:" <> manifest ^. #payloadId)
            active
            candidate
            output
        Nothing -> do
          cloudStage <- buildCloudStageCandidate active workspace snapshot
          case cloudStage of
            Just candidate ->
              Inventory.planInventoryCandidateWithPayloadIdentity
                (inventoryPlanRegistry active workspace)
                ("nagare-bootstrap:" <> manifest ^. #payloadId)
                active
                candidate
                output
            Nothing -> runAfterCloudStage active paths workspace snapshot manifest output

runAfterCloudStage ::
  ActiveTarget ->
  PlatformPaths ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  PayloadManifest ->
  FilePath ->
  IO ()
runAfterCloudStage active paths workspace snapshot manifest output = do
  hostOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "host")
  -- Once the host is accepted, installation media is no longer a prerequisite
  -- for adding cluster scopes. Still validate the exact accepted host inputs;
  -- a changed configuration requires an explicit reviewed host transition.
  if active ^. #profile . #mode == Cloud
    && Map.member hostOwner (ResourceInventory.snapshotScopes snapshot)
    then afterImages
    else do
      imageBuild <- buildImageBuildStageCandidate active workspace snapshot
      case imageBuild of
        Just candidate -> plan candidate
        Nothing -> do
          imagePublication <- buildImagePublicationStageCandidate active workspace snapshot
          case imagePublication of
            Just candidate -> plan candidate
            Nothing -> afterImages
  where
    plan = \candidate ->
      Inventory.planInventoryCandidateWithPayloadIdentity
        (inventoryPlanRegistry active workspace)
        ("nagare-bootstrap:" <> manifest ^. #payloadId)
        active
        candidate
        output
    afterImages = do
      hostStage <- buildHostStageCandidate active workspace snapshot
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
                ("nagare-bootstrap:" <> manifest ^. #payloadId)
                active
                candidate
                output

runPlatformBootstrapApply :: Maybe String -> FilePath -> Bool -> IO ()
runPlatformBootstrapApply mctx reviewDirectory yes = do
  active <- activeTarget mctx
  publicBundle <- InventoryPlan.loadReviewBundle reviewDirectory >>= either dieT pure
  let foundationStage =
        any
          ( (== ResourceInventory.CloudFoundationExecutor)
              . InventoryAdapter.plannedExecutor
              . InventoryPlan.reviewPlannedOperation
          )
          (InventoryPlan.reviewOperations (InventoryPlan.reviewBundleDocument publicBundle))
  stageTarget <- if foundationStage then foundationStageTarget active else pure active
  Inventory.applyInventoryWithFactory
    ( \store bundle -> do
        unless
          ( "nagare-bootstrap:"
              `T.isPrefixOf` InventoryPlan.reviewPayloadIdentity (InventoryPlan.reviewBundleDocument bundle)
          )
          (dieT "platform bootstrap apply requires a payload-bound bootstrap review")
        inventoryExecutionRegistry mctx store bundle
    )
    stageTarget
    reviewDirectory
    yes
  when
    ( foundationStage
        && effectiveInventoryStore (active ^. #profile) == InventoryStoreGcs
        && effectiveInventoryStore (stageTarget ^. #profile) == InventoryStoreLocal
    )
    $ do
      migrated <- Inventory.migrateTargetStore stageTarget InventoryStoreGcs False
      either (dieT . T.pack . show) TIO.putStrLn migrated
