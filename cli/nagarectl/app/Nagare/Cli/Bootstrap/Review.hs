-- | Bootstrap / Review. Plan the next pending platform stage under a review identity, and apply a
-- saved stage review whose identity a caller accepts. @platform bootstrap@ and @context move@
-- (EP-243) share them. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Review
  ( planStageReview
  , applyStageReview
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
import Nagare.Cli.Runtime.Target (resolvePlatformWorkspace)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Platform.Workspace (readPayloadManifest, renderWorkspaceError)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Target
  ( ActiveTarget
  , InventoryStoreKind (InventoryStoreGcs, InventoryStoreLocal)
  , effectiveInventoryStore
  )

-- | Plan the pending foundation stage, or else the next pending platform stage, under the review
-- identity @identityFor payloadId@. The flag is the reviewed field-takeover opt-in of the platform
-- stage (F37, EP-280).
planStageReview :: Bool -> ActiveTarget -> (Text -> Text) -> FilePath -> IO ()
planStageReview takeOver active identityFor output = do
  stageTarget <- foundationStageTarget active
  (paths, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  foundationPending <- cloudFoundationPendingAt active stageTarget
  let identity = identityFor (manifest ^. #payloadId)
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
    else planNextStage FreshBootstrap takeOver active paths workspace identity output

-- | Apply a saved stage review whose payload identity @accepted@ admits, refusing with @refusal@
-- otherwise.
applyStageReview :: Maybe String -> ActiveTarget -> (Text -> Bool) -> Text -> FilePath -> Bool -> IO ()
applyStageReview mctx active accepted refusal reviewDirectory yes = do
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
          (accepted (InventoryPlan.reviewPayloadIdentity (InventoryPlan.reviewBundleDocument bundle)))
          (dieT refusal)
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
