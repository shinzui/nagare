-- | Commands / Bootstrap. Executable-private CLI boundary.
module Nagare.Cli.Commands.Bootstrap
  ( runPlatformBootstrapApply
  , runPlatformBootstrapPlan
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Bootstrap.Foundation
  ( buildCloudFoundationCandidate
  , cloudFoundationPendingAt
  , foundationStageTarget
  )
import Nagare.Cli.Bootstrap.Sequence (planNextStage)
import Nagare.Cli.Bootstrap.Stage (StageMode (FreshBootstrap))
import Nagare.Cli.Inventory.Execution (inventoryExecutionRegistry)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistry)
import Nagare.Cli.Platform.Versions (refreshVersionsAfterReview)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Platform.Workspace (readPayloadManifest, renderWorkspaceError)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Target
  ( InventoryStoreKind (InventoryStoreGcs, InventoryStoreLocal)
  , effectiveInventoryStore
  )

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
  let identity = "nagare-bootstrap:" <> manifest ^. #payloadId
  if foundationPending
    then do
      snapshot <- Inventory.loadTargetSnapshot stageTarget
      candidate <- buildCloudFoundationCandidate active paths workspace snapshot
      Inventory.planInventoryCandidateWithPayloadIdentity
        (inventoryPlanRegistry active workspace)
        identity
        stageTarget
        candidate
        output
    else planNextStage FreshBootstrap active paths workspace identity output

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
    ( \inventory bundle -> do
        unless
          ( "nagare-bootstrap:"
              `T.isPrefixOf` InventoryPlan.reviewPayloadIdentity (InventoryPlan.reviewBundleDocument bundle)
          )
          (dieT "platform bootstrap apply requires a payload-bound bootstrap review")
        inventoryExecutionRegistry mctx inventory bundle
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
  -- Reached only when the apply converged (EP-236).
  refreshVersionsAfterReview mctx reviewDirectory
