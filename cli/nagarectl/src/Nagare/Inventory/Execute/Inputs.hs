{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Inputs responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Inputs
  ( preparedFor
  , selectedFence
  , validateOperationInputs
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( Adapter (adapterIdentity, adapterVersion)
  , AdapterFence (fenceFromReviewedRecord)
  , AdapterRegistry
  , OperationAction (OpenMaintenanceSession, RestoreLiveDatabase)
  , PlannedOperation
    ( plannedAction
    , plannedExecutor
    , plannedOperationId
    )
  , PreparedNative (PreparedNative)
  , lookupAdapter
  , lookupAdapterFenceByCapability
  )
import Nagare.Inventory.DataFence
  ( DataFenceControls
  , dataFenceIntentDigest
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute.Types (AdmissionError (..))
import Nagare.Inventory.Journal
  ( OperationId
  , OperationState (Completed)
  )
import Nagare.Inventory.OperationStep (validateOperationGraph)
import Nagare.Inventory.Plan
  ( ReviewDocument (reviewOperations)
  , ReviewOperation
    ( reviewAdapterIdentity
    , reviewAdapterVersion
    , reviewFenceCapability
    , reviewFenceDigest
    , reviewFenceSummary
    , reviewNativeDigest
    , reviewPlannedOperation
    , reviewPublicSummary
    )
  , ReviewedPlan
  , reviewedDocument
  , reviewedFenceRecord
  , reviewedNativeBundles
  )
import Nagare.Inventory.Store (DataFenceRecord (fenceTransaction))

-- Structural validation is independent of live operation preconditions. Those
-- run only in the interpreter after dependency and recovery selection.
validateOperationInputs :: AdapterRegistry -> ReviewedPlan -> Map OperationId OperationState -> [AdmissionError]
validateOperationInputs registry reviewed previous =
  [ AdmissionError "operation-graph" reason
  | Left reason <- [validateOperationGraph operations]
  ]
    <> concatMap validate operations
  where
    operations = reviewOperations (reviewedDocument reviewed)
    validate reviewOperation
      | Just (Completed _) <- Map.lookup (plannedOperationId operation) previous = []
      | isNothing (reviewNativeDigest reviewOperation) = []
      | otherwise = case (lookupAdapter registry (plannedExecutor operation), preparedFor reviewed reviewOperation) of
          (Left err, _) -> [AdmissionError "adapter" err]
          (_, Left err) -> [AdmissionError "native-bundle" err]
          (Right adapter, Right prepared)
            | adapterIdentity adapter /= reviewAdapterIdentity reviewOperation || adapterVersion adapter /= reviewAdapterVersion reviewOperation ->
                [AdmissionError "adapter-version" "review adapter identity or version differs from the active registry"]
            | otherwise ->
                [ AdmissionError "data-fence-capability" reason
                | Left reason <- [selectedFence registry reviewed reviewOperation prepared]
                ]
      where
        operation = reviewPlannedOperation reviewOperation

preparedFor :: ReviewedPlan -> ReviewOperation -> Either Text PreparedNative
preparedFor reviewed reviewOperation = do
  digest <- maybe (Left "operation is stopped at a review barrier") Right (reviewNativeDigest reviewOperation)
  bytes <- maybe (Left "native bundle is absent") Right (Map.lookup digest (reviewedNativeBundles reviewed))
  unless (contentDigest bytes == digest) (Left "native bundle digest changed")
  pure (PreparedNative bytes (reviewPublicSummary reviewOperation))

selectedFence ::
  AdapterRegistry ->
  ReviewedPlan ->
  ReviewOperation ->
  PreparedNative ->
  Either Text (Maybe (DataFenceRecord, DataFenceControls))
selectedFence registry plan operation prepared = do
  saved <- reviewedFenceRecord plan operation
  when
    ( plannedAction (reviewPlannedOperation operation)
        `elem` [OpenMaintenanceSession, RestoreLiveDatabase]
        && isNothing saved
    )
    (Left "database data operation review has no data fence")
  case (reviewFenceCapability operation, reviewFenceDigest operation, saved) of
    (Nothing, Nothing, Nothing)
      | isNothing (reviewFenceSummary operation) -> Right Nothing
    (Just capability, Just digest, Just record)
      | isNothing (fenceTransaction record)
      , digest == dataFenceIntentDigest record
      , isJust (reviewFenceSummary operation) -> do
          hook <-
            maybe
              (Left "review requires an unavailable data fence capability")
              Right
              ( lookupAdapterFenceByCapability
                  registry
                  (plannedExecutor (reviewPlannedOperation operation))
                  capability
              )
          controls <-
            fenceFromReviewedRecord
              hook
              record
              (reviewPlannedOperation operation)
              prepared
          Right (Just (record, controls))
    _ -> Left "data fence capability or reviewed intent changed"
