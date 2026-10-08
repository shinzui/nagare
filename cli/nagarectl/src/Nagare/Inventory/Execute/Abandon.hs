{-# LANGUAGE RankNTypes #-}

-- | F81: the backward exit of a reviewed migration that cannot go forward;
-- internal implementation behind Nagare.Inventory.Execute.
--
-- ADR 26 gives a migration stage resume and its forward exit, and keeps it out
-- of close. A source replaced outside review after admission, or a transfer
-- the copy script refuses, leaves no forward exit, and a fence stage that took
-- effect leaves the database's writer stopped. Abandon is allowed only while
-- no consumer may have switched to the destination and no write reached it. It releases
-- each fence stage's fence on the reviewed incarnation (the caller's release
-- is UID- and resourceVersion-preconditioned), marks every unfinished stage
-- abandoned in the journal, and ends the transaction through close's record:
-- an incomplete migration reverts its scopes to the review's base, so nothing
-- of it is accepted. No destination object is deleted. A repeat after a
-- partial run releases idempotently and completes the same close.
module Nagare.Inventory.Execute.Abandon
  ( AbandonInput (..)
  , MigrationExit (..)
  , abandonMigration
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( MigrationStage (FenceWriters)
  , OperationAction (MigrateResource)
  , PlannedOperation (plannedAction, plannedOperationId)
  , PreparedNative
  )
import Nagare.Inventory.Execute.AdapterEnv (withAdapterEnv)
import Nagare.Inventory.Execute.Claims (acquireResumeClaim, observeCurrentHead)
import Nagare.Inventory.Execute.Close (abandonedMarker, closeRolledBack, journalClass, reviewDigestOf)
import Nagare.Inventory.Execute.Inputs (preparedFor)
import Nagare.Inventory.Execute.Journal (appendEvent, readJournalAtHead)
import Nagare.Inventory.Execute.Types
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Plan.CloseRecord (CloseRecord, closedRecordDigest)
import Nagare.Inventory.Plan.Types (ReviewedPlan (..))
import Nagare.Inventory.Store
import Nagare.Resource.Types (ContentDigest, PhysicalIdentity, ResourceId)

data AbandonInput = AbandonInput
  { abandonTarget :: !TransactionId
  , abandonReview :: !ContentDigest
  , abandonTakeOver :: !Bool
  }
  deriving stock (Eq, Show)

-- | What the migration's adapter knows about going back.
data MigrationExit = MigrationExit
  { exitPastReturn :: !(PlannedOperation -> PreparedNative -> Bool)
  -- ^ Whether this stage, once started, may have let writes reach the
  -- destination; going back would then lose them.
  , exitRelease :: !(Map ResourceId PhysicalIdentity -> PlannedOperation -> PreparedNative -> IO (Either Text ()))
  -- ^ Release one fence stage's fence on the object its target's recorded
  -- incarnation names; 'Right' also when there is nothing of this stage's to
  -- release.
  }

abandonMigration :: InventoryStore -> MigrationExit -> AbandonInput -> IO (Either (NonEmpty AdmissionError) CloseRecord)
abandonMigration store exit input = do
  locked <- withProcessLock store abandonLocked
  pure $ case locked of
    Left err -> failure "process-lock" (showText err)
    Right result -> result
  where
    transaction = abandonTarget input
    abandonLocked :: forall s. LockedStore s -> IO (Either (NonEmpty AdmissionError) CloseRecord)
    abandonLocked lock = do
      headResult <- observeCurrentHead store
      case headResult of
        Left err -> pure (failure "store" (showText err))
        Right (_, Nothing) -> pure (failure "store" "inventory store is not initialized")
        Right (observed, Just headValue) -> do
          eventsResult <- readJournalAtHead store headValue
          case eventsResult of
            Left err -> pure (failure "journal" (showText err))
            Right events
              -- E2: after its close, the same exit releases a fence that names
              -- this migration on the writer now recorded, which a rebind of
              -- a replacement made outside review may have changed.
              | Just _ <- closedRecordDigest transaction events -> do
                  released <- releaseAfterClose (headIncarnations headValue) events
                  case released of
                    Left err -> pure (Left err)
                    Right () -> closeRolledBack lock transaction
              | headActiveTransaction headValue /= Just (transactionIdText transaction) ->
                  pure (failure "inactive-transaction" "abandon-migration requires the active transaction")
              | Just (abandonReview input) /= reviewDigestOf transaction ->
                  pure (failure "abandon-review" "the review digest differs from the transaction")
              | otherwise -> do
                  claimed <- acquireResumeClaim store transaction observed headValue (abandonTakeOver input)
                  case claimed of
                    Left err -> pure (Left err)
                    Right () -> withReview (proceed lock (headIncarnations headValue) events)
    releaseAfterClose recorded events = do
      bundle <- loadPublishedReview store (abandonReview input)
      case bundle of
        Left err -> pure (failure "review" (showText err))
        Right published -> do
          let reviewed = ReviewedPlan (reviewBundleDocument published) (reviewBundleNative published)
              states = operationStates transaction events
              fences =
                [ entry
                | entry <- reviewOperations (reviewBundleDocument published)
                , plannedAction (reviewPlannedOperation entry) == MigrateResource FenceWriters
                , isJust (Map.lookup (plannedOperationId (reviewPlannedOperation entry)) states)
                ]
          released <- traverse (releaseFence recorded reviewed) fences
          pure $ case [AdmissionError "release" reason | Left reason <- released] of
            err : more -> Left (err :| more)
            [] -> Right ()
    releaseFence recorded reviewed entry =
      let operation = reviewPlannedOperation entry
       in case preparedFor reviewed entry of
            Left reason -> pure (Left reason)
            Right prepared -> withAdapterEnv transaction operation (exitRelease exit recorded operation prepared)
    withReview continue = do
      bundle <- loadPublishedReview store (abandonReview input)
      snapshot <- readReviewSnapshot store (abandonReview input)
      case (bundle, snapshot) of
        (Left err, _) -> pure (failure "review" (showText err))
        (_, Left err) -> pure (failure "store" (showText err))
        (Right published, Right state) -> case verifyActiveReview state (transactionIdText transaction) published of
          Left errs -> pure (Left (fmap reviewAdmission errs))
          Right reviewed -> continue reviewed
    proceed :: forall s. LockedStore s -> Map ResourceId PhysicalIdentity -> [JournalEvent] -> ReviewedPlan -> IO (Either (NonEmpty AdmissionError) CloseRecord)
    proceed lock recorded events reviewed
      | null migrations = pure (failure "not-a-migration" "abandon-migration ends only a reviewed migration; use inventory close")
      | not (null pastFence) =
          pure (failure "migration-past-return" "the migration may have let writes reach its destination; resume it to its end")
      | otherwise = do
          released <- traverse (releaseFence recorded reviewed) [entry | entry <- migrations, stageOf entry == Just FenceWriters, started entry]
          case [AdmissionError "release" reason | Left reason <- released] of
            err : more -> pure (Left (err :| more))
            [] -> do
              marked <- traverse (markAbandoned lock) [entry | entry <- migrations, isNothing (journalClass states (reviewPlannedOperation entry))]
              case [err | Left err <- marked] of
                err : _ -> pure (failure "journal" (showText err))
                [] -> closeRolledBack lock transaction
      where
        document = reviewedDocument reviewed
        states = operationStates transaction events
        migrations = [entry | entry <- reviewOperations document, isJust (stageOf entry)]
        stageOf entry = case plannedAction (reviewPlannedOperation entry) of
          MigrateResource stage -> Just stage
          _ -> Nothing
        stateOf entry = Map.lookup (plannedOperationId (reviewPlannedOperation entry)) states
        started entry = case stateOf entry of
          Nothing -> False
          Just Pending -> False
          _ -> True
        pastFence =
          [ entry
          | entry <- migrations
          , started entry
          , either (const True) (exitPastReturn exit (reviewPlannedOperation entry)) (preparedFor reviewed entry)
          ]

        markAbandoned target entry =
          appendEvent
            target
            transaction
            (Just (plannedOperationId (reviewPlannedOperation entry)))
            (OperatorResolved abandonedMarker)
            "migration stage abandoned: its fence is released and nothing of the migration is accepted"
