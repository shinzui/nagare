{-# LANGUAGE RankNTypes #-}

-- | RecoveryPolicy responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.RecoveryPolicy
  ( fencedAction
  , recoverableState
  , sameReviewedFence
  , transactionDigest
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( OperationAction (CreateResource, RunDeclaredOperation)
  , PlannedOperation (plannedAction, plannedResources)
  )
import Nagare.Inventory.Execute.Types (RecoveryAction (..))
import Nagare.Inventory.Journal
  ( FailureClass (PartialOrUnknown)
  , OperationState
    ( Ambiguous
    , Failed
    , IntentRecorded
    , OperatorResolved
    )
  , TransactionId
  , transactionIdText
  )
import Nagare.Inventory.OperationStep (bootstrapRecoveryMarker)
import Nagare.Inventory.Plan
  ( ReviewBundle
  , ReviewDocument (reviewOperations)
  , ReviewOperation (reviewPlannedOperation)
  , reviewBundleDocument
  , reviewBundleScopes
  )
import Nagare.Inventory.Store
  ( DataFenceRecord (fenceAcquiredAt, fencePhase, fenceTransaction)
  )
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Types
  ( ContentDigest
  , mkContentDigest
  , resourceIdText
  )
import Nagare.Resource.Wire (decodeScope)

fencedAction :: RecoveryAction -> Bool
fencedAction action =
  action
    `elem` [ ContinueFencedOperation
           , VerifyFencedEffect
           , RecoverFencedBackup
           , ForwardFencedRelease
           ]

sameReviewedFence :: TransactionId -> DataFenceRecord -> DataFenceRecord -> Bool
sameReviewedFence selectedTransaction saved active =
  fenceTransaction active == Just (transactionIdText selectedTransaction)
    && active
      { fenceTransaction = Nothing
      , fencePhase = fencePhase saved
      , fenceAcquiredAt = fenceAcquiredAt saved
      }
      == saved

recoverableState :: Maybe OperationState -> Bool
recoverableState state = case state of
  Just IntentRecorded -> True
  Just Ambiguous -> True
  Just (Failed (PartialOrUnknown _)) -> True
  Just (OperatorResolved marker) ->
    "fenced-recovery-proved:" `T.isPrefixOf` marker
      || isJust (bootstrapRecoveryMarker marker)
  _ -> False

transactionDigest :: TransactionId -> Maybe ContentDigest
transactionDigest token =
  either
    (const Nothing)
    Just
    (mkContentDigest (T.drop 3 (transactionIdText token)))
