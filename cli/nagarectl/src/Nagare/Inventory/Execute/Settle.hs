-- | ADR 26 settlement of reviewed operations; internal implementation behind
-- Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Settle
  ( settleReviewedOperation
  )
where

import Data.List (find)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( AdapterRegistry
  , PlannedOperation (plannedExecutor, plannedOperationId)
  , Settlement
  , lookupAdapter
  , settleOperationWith
  )
import Nagare.Inventory.Execute.Inputs (preparedFor)
import Nagare.Inventory.Journal (OperationId)
import Nagare.Inventory.Plan
  ( ReviewDocument (reviewOperations)
  , ReviewOperation (reviewPlannedOperation)
  , ReviewedPlan
  , reviewedDocument
  )

-- | Settle one operation of a reviewed plan through its executor's adapter.
settleReviewedOperation :: AdapterRegistry -> ReviewedPlan -> OperationId -> IO (Either Text Settlement)
settleReviewedOperation registry reviewed operationId =
  case find ((== operationId) . plannedOperationId . reviewPlannedOperation) (reviewOperations (reviewedDocument reviewed)) of
    Nothing -> pure (Left "operation is absent from the review")
    Just entry -> do
      let operation = reviewPlannedOperation entry
      case (lookupAdapter registry (plannedExecutor operation), preparedFor reviewed entry) of
        (Left reason, _) -> pure (Left reason)
        (_, Left reason) -> pure (Left reason)
        (Right adapter, Right prepared) -> Right <$> settleOperationWith adapter operation prepared
