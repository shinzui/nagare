{-# LANGUAGE RankNTypes #-}

-- | Transaction responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Transaction
  ( applyReviewed
  , execute
  , resumeTransaction
  , resumeTransactionWithTakeover
  )
where

import Data.Either (isRight)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterRegistry)
import Nagare.Inventory.Execute.Admission (admit)
import Nagare.Inventory.Execute.Claims
  ( acquireResumeClaim
  , observeCurrentHead
  , releaseClaim
  , releaseClaimWith
  )
import Nagare.Inventory.Execute.Close (closeRolledBack, releaseClosedTransaction)
import Nagare.Inventory.Execute.Driver (runOperations)
import Nagare.Inventory.Execute.Incarnations (convergedIncarnations)
import Nagare.Inventory.Execute.Inputs (validateOperationInputs)
import Nagare.Inventory.Execute.Journal
  ( appendEvent
  , readJournal
  , readJournalAtHead
  , rollbackProvedOperation
  , transactionConverged
  )
import Nagare.Inventory.Execute.Types
  ( AdmissionError (..)
  , ExecutablePlan (..)
  , TransactionResult (..)
  , ambiguousFallback
  , failure
  , fallbackResult
  , reviewAdmission
  , reviewDocumentDigest
  , showText
  , timestamp
  )
import Nagare.Inventory.Journal
  ( FailureClass (KnownNoEffect)
  , JournalEvent
  , OperationState (Completed, Pending)
  , TransactionId
  , operationStates
  , transactionIdText
  )
import Nagare.Inventory.Plan
  ( RetentionProof
      ( retentionOwner
      , retentionPhysical
      , retentionRevision
      )
  , ReviewDocument
    ( reviewBarriers
    , reviewCollections
    , reviewOperations
    )
  , ReviewedPlan
  , loadPublishedReview
  , reviewedDocument
  , verifyActiveReview
  )
import Nagare.Inventory.Plan.CloseRecord (closedRecordDigest, loadCloseRecord)
import Nagare.Inventory.Store
  ( DeletionTombstone
      ( DeletionTombstone
      , tombstoneOwner
      , tombstonePhysical
      , tombstoneReview
      , tombstoneRevision
      )
  , HeadManifest
    ( headActiveTransaction
    , headCollected
    , headDataFence
    , headGeneration
    , headRetained
    )
  , InventoryStore
  , LockedStore
  , RetainedIncarnation
    ( retainedOwner
    , retainedPhysical
    , retainedRevision
    )
  , StoreError (StoreConditionFailed)
  , lockedStore
  , readHead
  , readReviewSnapshot
  , replaceObservedHead
  , withProcessLock
  )
import Nagare.Resource.Types (mkContentDigest)

execute :: LockedStore s -> AdapterRegistry -> ExecutablePlan s -> IO TransactionResult
execute locked registry executable = executeWithJournal locked registry executable Nothing

executeWithJournal ::
  LockedStore s ->
  AdapterRegistry ->
  ExecutablePlan s ->
  Maybe [JournalEvent] ->
  IO TransactionResult
executeWithJournal locked registry executable knownEvents = do
  let transaction = executableTransaction executable
      reviewed = executableReviewed executable
      document = reviewedDocument reviewed
  if not (null (reviewBarriers document))
    then do
      let barriers = NE.fromList (reviewBarriers document)
      _ <- appendEvent locked transaction Nothing Pending "paused at review barrier"
      _ <- releaseClaim locked transaction Nothing
      pure (PausedAtBarrier transaction barriers)
    else do
      eventsResult <- maybe (readJournal locked) (pure . Right) knownEvents
      case eventsResult of
        Left _ -> ambiguousFallback transaction document
        Right events -> do
          outcome <- runOperations locked registry transaction reviewed events (reviewOperations document) Nothing
          case outcome of
            Just result -> releaseClaim locked transaction Nothing >> pure result
            Nothing -> do
              current <- readHead (lockedStore locked)
              case current of
                Right (Just headValue) | isNothing (headDataFence headValue) -> do
                  completed <- appendEvent locked transaction Nothing (Completed (reviewDocumentDigest document)) "transaction converged"
                  case completed of
                    Left _ -> ambiguousFallback transaction document
                    Right _ -> do
                      finalized <- finalizeCollections locked transaction document
                      if not finalized
                        then pure (fallbackResult transaction document)
                        else do
                          bindings <- convergedIncarnations locked registry document
                          converged <- releaseClaimWith locked transaction (Just document) bindings
                          pure $ if converged then Converged transaction else fallbackResult transaction document
                _ -> do
                  _ <- releaseClaim locked transaction Nothing
                  pure (fallbackResult transaction document)

finalizeCollections :: LockedStore s -> TransactionId -> ReviewDocument -> IO Bool
finalizeCollections locked transaction document
  | Map.null (reviewCollections document) = pure True
  | otherwise = do
      let store = lockedStore locked
      current <- observeCurrentHead store
      case current of
        Right (observed, Just headValue)
          | headActiveTransaction headValue == Just (transactionIdText transaction) -> do
              now <- timestamp
              let proofMatches resource proof = case Map.lookup resource (headRetained headValue) of
                    Just retained ->
                      retainedOwner retained == retentionOwner proof
                        && retainedRevision retained == retentionRevision proof
                        && retainedPhysical retained == retentionPhysical proof
                    Nothing -> case Map.lookup resource (headCollected headValue) of
                      Just tombstone ->
                        tombstoneOwner tombstone == retentionOwner proof
                          && tombstoneRevision tombstone == retentionRevision proof
                          && tombstonePhysical tombstone == retentionPhysical proof
                          && tombstoneReview tombstone == reviewDocumentDigest document
                      Nothing -> False
              if not (all (uncurry proofMatches) (Map.toAscList (reviewCollections document)))
                then pure False
                else do
                  let collected =
                        Map.map
                          ( \proof ->
                              DeletionTombstone
                                (retentionOwner proof)
                                (retentionRevision proof)
                                (retentionPhysical proof)
                                now
                                (reviewDocumentDigest document)
                          )
                          ( Map.filterWithKey
                              (\resource _ -> Map.member resource (headRetained headValue))
                              (reviewCollections document)
                          )
                      replacement =
                        headValue
                          { headGeneration = headGeneration headValue + 1
                          , headRetained =
                              Map.withoutKeys
                                (headRetained headValue)
                                (Map.keysSet (reviewCollections document))
                          , headCollected = Map.union collected (headCollected headValue)
                          }
                  if Map.null collected
                    then pure True
                    else do
                      result <- replaceObservedHead observed replacement
                      pure (isRight result)
        _ -> pure False

applyReviewed :: InventoryStore -> AdapterRegistry -> ReviewedPlan -> IO (Either (NonEmpty AdmissionError) TransactionResult)
applyReviewed store registry reviewed = do
  locked <- withProcessLock store $ \lock -> do
    admitted <- admit lock registry reviewed
    case admitted of
      Left errors -> pure (Left errors)
      Right executable -> Right <$> execute lock registry executable
  pure $ case locked of
    Left err -> failure "process-lock" (showText err)
    Right result -> result

resumeTransaction :: InventoryStore -> AdapterRegistry -> TransactionId -> IO (Either (NonEmpty AdmissionError) TransactionResult)
resumeTransaction store registry transaction = resumeTransactionWithTakeover store registry transaction False

resumeTransactionWithTakeover :: InventoryStore -> AdapterRegistry -> TransactionId -> Bool -> IO (Either (NonEmpty AdmissionError) TransactionResult)
resumeTransactionWithTakeover store registry transaction takeOver = do
  locked <- withProcessLock store $ \lock -> resumeLocked lock
  pure $ case locked of
    Left err -> failure "process-lock" (showText err)
    Right result -> result
  where
    resumeLocked :: forall s. LockedStore s -> IO (Either (NonEmpty AdmissionError) TransactionResult)
    resumeLocked lock = do
      let digestToken = T.drop 3 (transactionIdText transaction)
      case mkContentDigest digestToken of
        Left err -> pure (failure "transaction-id" err)
        Right digest -> do
          headResult <- observeCurrentHead store
          eventsResult <- case headResult of
            Left err -> pure (Left err)
            Right (_, Nothing) -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
            Right (_, Just headValue) -> readJournalAtHead store headValue
          case (headResult, eventsResult) of
            (Left err, _) -> pure (failure "store" (showText err))
            (_, Left err) -> pure (failure "journal" (showText err))
            (Right (_, Nothing), _) -> pure (failure "store" "inventory store is not initialized")
            (Right (observed, Just headValue), Right events)
              | headActiveTransaction headValue /= Just (transactionIdText transaction) ->
                  if transactionConverged transaction events
                    then pure (Right (Converged transaction))
                    else pure (failure "inactive-transaction" "transaction is not active in the store head")
              | isJust (headDataFence headValue) ->
                  pure (failure "active-data-fence" "recover and release the active data fence before resuming its reviewed transaction")
              -- ADR 26: a journalled close only completes its head release.
              | Just recordDigest <- closedRecordDigest transaction events -> do
                  loaded <- loadCloseRecord store recordDigest
                  case loaded of
                    Left err -> pure (failure "close-record" err)
                    Right record -> do
                      released <- releaseClosedTransaction lock record
                      pure (if released then Right (Closed transaction) else failure "head-condition" "the closed transaction's head release did not land; run close again")
              | Just operation <- rollbackProvedOperation transaction events -> do
                  claimed <- acquireResumeClaim store transaction observed headValue takeOver
                  case claimed of
                    Left err -> pure (Left err)
                    Right () -> do
                      closed <- isRight <$> closeRolledBack lock transaction
                      pure $
                        if closed
                          then
                            Right
                              ( StoppedFailed
                                  transaction
                                  operation
                                  (KnownNoEffect "fenced recovery backup restored; original review was abandoned")
                              )
                          else failure "head-condition" "could not close recovered transaction"
              | otherwise -> do
                  claimed <- acquireResumeClaim store transaction observed headValue takeOver
                  case claimed of
                    Left err -> pure (Left err)
                    Right () -> do
                      bundleResult <- loadPublishedReview store digest
                      snapshotResult <- readReviewSnapshot store digest
                      case (bundleResult, snapshotResult) of
                        (Left err, _) -> releaseClaim lock transaction Nothing >> pure (failure "review" (showText err))
                        (_, Left err) -> releaseClaim lock transaction Nothing >> pure (failure "store" (showText err))
                        (Right bundle, Right snapshot) -> case verifyActiveReview snapshot (transactionIdText transaction) bundle of
                          Left errors -> releaseClaim lock transaction Nothing >> pure (Left (fmap reviewAdmission errors))
                          Right reviewed -> do
                            let preflightErrors = validateOperationInputs registry reviewed (operationStates transaction events)
                            case preflightErrors of
                              firstError : rest -> releaseClaim lock transaction Nothing >> pure (Left (firstError :| rest))
                              [] ->
                                Right
                                  <$> executeWithJournal
                                    lock
                                    registry
                                    (ExecutablePlan transaction reviewed)
                                    (Just events)
