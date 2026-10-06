{-# LANGUAGE RankNTypes #-}

-- | Recovery responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Recovery
  ( prepareBootstrapRegistryRecovery
  , recordOperatorRecovery
  )
where

import Data.Either (isRight)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( Adapter (adapterIdentity, adapterPreflight, adapterRecover, adapterVersion)
  , AdapterRecovery (recoveryPrepare)
  , AdapterRegistry
  , OperationAction (VerifyResource)
  , PlannedOperation
    ( plannedAction
    , plannedExecutor
    , plannedOperationId
    )
  , PreparedNative (preparedNativeBytes)
  , RecoveryDecision
    ( RecoveryAwaitingReadiness
    , RecoveryLandedUnready
    , RecoveryProvedComplete
    , RecoverySafeToRetry
    , RecoveryTargetReplaced
    , RecoveryTerminalFailure
    , RecoveryUnresolved
    )
  , lookupAdapter
  , lookupAdapterRecovery
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute.AdapterEnv (withAdapterEnv)
import Nagare.Inventory.Execute.Claims
  ( acquireResumeClaim
  , observeCurrentHead
  , releaseClaim
  )
import Nagare.Inventory.Execute.Close (CloseInput (..), closeRolledBack, closeTransaction)
import Nagare.Inventory.Execute.Driver (runOperations)
import Nagare.Inventory.Execute.FencedRecovery (recoverFenced)
import Nagare.Inventory.Execute.Inputs
  ( preparedFor
  , selectedFence
  )
import Nagare.Inventory.Execute.Journal
  ( appendEvent
  , readJournalAtHead
  , rollbackProof
  )
import Nagare.Inventory.Execute.RecoveryPolicy
  ( fencedAction
  , recoverableState
  , sameReviewedFence
  , transactionDigest
  )
import Nagare.Inventory.Execute.Types
  ( AdmissionError (..)
  , OperatorRecoveryInput (..)
  , RecoveryAction (..)
  , failure
  , reviewAdmission
  , showText
  )
import Nagare.Inventory.Journal
  ( FailureClass (KnownNoEffect, PartialOrUnknown)
  , JournalEvent
    ( eventDetail
    , eventOperation
    , eventState
    , eventTransaction
    )
  , OperationId
  , OperationState
    ( Ambiguous
    , Completed
    , Failed
    , IntentRecorded
    , OperatorResolved
    , Pending
    )
  , TransactionId
  , operationStates
  , transactionIdText
  )
import Nagare.Inventory.OperationStep (bootstrapRecoveryMarker)
import Nagare.Inventory.Plan
  ( ReviewDocument (reviewOperations)
  , ReviewOperation
    ( reviewAdapterIdentity
    , reviewAdapterVersion
    , reviewFenceCapability
    , reviewPlannedOperation
    )
  , ReviewedPlan
  , loadPublishedReview
  , reviewBundleDocument
  , reviewedDocument
  , verifyActiveReview
  )
import Nagare.Inventory.Plan.CloseRecord (closedRecordDigest)
import Nagare.Inventory.Store
  ( DataFenceRecord
  , HeadManifest
    ( headActiveTransaction
    , headDataFence
    , headExecutorClaim
    , headMigration
    )
  , InventoryStore
  , LockedStore
  , StoreError (StoreConditionFailed)
  , StoreSnapshot (storeSnapshotHead)
  , objectKeyFor
  , publishIfAbsent
  , readHead
  , readReviewSnapshot
  , withProcessLock
  )
import Nagare.Resource.Types
  ( ContentDigest
  , digestText
  , mkContentDigest
  , physicalIdentityText
  )

-- | Save one bounded prerequisite recovery without changing accepted desired
-- state. Provider inspection is read-only; publication is conditional and the
-- head must remain exact across inspection.
prepareBootstrapRegistryRecovery ::
  InventoryStore ->
  AdapterRegistry ->
  TransactionId ->
  OperationId ->
  IO (Either Text OperatorRecoveryInput)
prepareBootstrapRegistryRecovery store registry transaction operationId = do
  before <- readHead store
  case before of
    Right (Just headValue)
      | headActiveTransaction headValue == Just (transactionIdText transaction)
      , isNothing (headExecutorClaim headValue)
      , isNothing (headDataFence headValue)
      , isNothing (headMigration headValue) -> do
          let digestResult = mkContentDigest (T.drop 3 (transactionIdText transaction))
          case digestResult of
            Left reason -> pure (Left reason)
            Right digest -> do
              bundle <- loadPublishedReview store digest
              snapshot <- readReviewSnapshot store digest
              events <- readJournalAtHead store headValue
              let checked = do
                    published <- first showText bundle
                    state <- first showText snapshot
                    journal <- first showText events
                    unless
                      (storeSnapshotHead state == headValue)
                      (Left "inventory history changed during recovery preparation")
                    reviewed <-
                      first
                        (showText . NE.toList)
                        (verifyActiveReview state (transactionIdText transaction) published)
                    selected <-
                      maybe
                        (Left "recovery operation is absent")
                        Right
                        ( find
                            ((== operationId) . plannedOperationId . reviewPlannedOperation)
                            (reviewOperations (reviewedDocument reviewed))
                        )
                    unless
                      ( Map.lookup operationId (operationStates transaction journal)
                          `elem` [Just IntentRecorded, Just Ambiguous]
                          || case Map.lookup operationId (operationStates transaction journal) of
                            Just (Failed (PartialOrUnknown _)) -> True
                            _ -> False
                      )
                      (Left "recovery requires an uncertain original effect")
                    prepared <- preparedFor reviewed selected
                    fence <- selectedFence registry reviewed selected prepared
                    unless (isNothing fence) (Left "registry recovery refuses a fenced operation")
                    adapter <-
                      lookupAdapter
                        registry
                        (plannedExecutor (reviewPlannedOperation selected))
                    unless
                      ( adapterIdentity adapter == reviewAdapterIdentity selected
                          && adapterVersion adapter == reviewAdapterVersion selected
                      )
                      (Left "recovery adapter differs from the original review")
                    capability <-
                      maybe
                        (Left "bootstrap registry recovery is not registered")
                        Right
                        (lookupAdapterRecovery registry "bootstrap-registry-credentials")
                    pure (reviewPlannedOperation selected, prepared, adapter, capability)
              case checked of
                Left reason -> pure (Left reason)
                Right (operation, prepared, adapter, capability) -> do
                  decision <- adapterRecover adapter operation prepared
                  case decision of
                    RecoveryAwaitingReadiness _ -> do
                      proof <- recoveryPrepare capability operation prepared
                      after <- readHead store
                      case proof of
                        Right bytes | after == before -> do
                          let native = contentDigest bytes
                          published <- publishIfAbsent store (objectKeyFor "native" native) bytes
                          pure
                            ( OperatorRecoveryInput
                                transaction
                                operationId
                                digest
                                (RecoverBootstrapRegistry native)
                                <$ first showText published
                            )
                        Left reason -> pure (Left reason)
                        _ -> pure (Left "inventory history changed during recovery preparation")
                    _ -> pure (Left "registry recovery requires the exact original created Deployment awaiting readiness")
    _ -> pure (Left "registry recovery requires an idle active transaction with no fence or migration")

closeAliases :: [RecoveryAction]
closeAliases = [StopIncompleteApplication, AbandonRefusedOperation, AbandonPartialPrune, AbandonPartialVolumeRestore, AbandonPartialDatabaseRestore]

-- | The decision file selects an action; the adapter must independently prove
-- that action from the current provider state under the writer lock. An
-- unresolved adapter outcome never becomes operator authority.
recordOperatorRecovery ::
  InventoryStore ->
  AdapterRegistry ->
  OperatorRecoveryInput ->
  Bool ->
  IO (Either (NonEmpty AdmissionError) ())
recordOperatorRecovery store registry input takeOver
  -- ADR 26: the stop and abandon decisions are aliases of close, which names
  -- the transaction; the operation only has to belong to its review.
  | recoveryAction input `elem` closeAliases = do
      published <- loadPublishedReview store (recoveryReview input)
      case published of
        Left err -> pure (failure "review" (showText err))
        Right bundle
          | recoveryOperation input `notElem` map (plannedOperationId . reviewPlannedOperation) (reviewOperations (reviewBundleDocument bundle)) ->
              pure (failure "recovery-operation" "the decision names an operation outside the transaction's review")
          | otherwise -> fmap (const ()) <$> closeTransaction store registry (CloseInput (recoveryTransaction input) (recoveryReview input) takeOver Nothing)
  | otherwise = do
      locked <- withProcessLock store $ \lock -> recoverLocked lock
      pure $ case locked of
        Left err -> failure "process-lock" (showText err)
        Right result -> result
  where
    transaction = recoveryTransaction input
    operationId = recoveryOperation input
    recoverLocked :: forall s. LockedStore s -> IO (Either (NonEmpty AdmissionError) ())
    recoverLocked lock = do
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
              pure (failure "inactive-transaction" "operator recovery requires the active transaction")
          -- A closed transaction is final: only close itself completes its release.
          | isJust (closedRecordDigest transaction events) ->
              pure (failure "closed-transaction" "the transaction is closed; run inventory close again to release it")
          | isJust (headDataFence headValue)
              && not (fencedAction (recoveryAction input)) ->
              pure (failure "active-data-fence" "recover and release the data fence before recording adapter recovery")
          | isNothing (headDataFence headValue)
              && fencedAction (recoveryAction input)
              && not
                ( recoveryAction input == RecoverFencedBackup
                    && isJust (rollbackProof transaction operationId events)
                ) ->
              pure (failure "data-fence" "reviewed transaction has no active data fence")
          | Just (recoveryReview input) /= transactionDigest transaction ->
              pure (failure "recovery-review" "decision file review digest differs from transaction")
          | not (recoverableState (Map.lookup operationId (operationStates transaction events))) ->
              pure (failure "recovery-state" "operation has no uncertain effect to resolve")
          | Just (OperatorResolved marker) <- Map.lookup operationId (operationStates transaction events)
          , Just (native, Nothing) <- bootstrapRecoveryMarker marker
          , recoveryAction input /= RecoverBootstrapRegistry native ->
              pure (failure "recovery-prerequisite" "resolve the exact saved host recovery intent before accepting workload completion")
          | otherwise -> do
              claimed <- acquireResumeClaim store transaction observed headValue takeOver
              case claimed of
                Left err -> pure (Left err)
                Right () -> do
                  result <- inspectRecovery lock events (headDataFence headValue)
                  released <-
                    if isRight result
                      && isNothing (headDataFence headValue)
                      && recoveryAction input == RecoverFencedBackup
                      && isJust (rollbackProof transaction operationId events)
                      then isRight <$> closeRolledBack lock transaction
                      else do
                        current <- readHead store
                        case current of
                          Right (Just value)
                            | isNothing (headActiveTransaction value) ->
                                pure True
                          _ -> releaseClaim lock transaction Nothing
                  pure $ if released then result else failure "executor-claim" "could not release operator recovery claim"
    inspectRecovery ::
      forall s.
      LockedStore s ->
      [JournalEvent] ->
      Maybe DataFenceRecord ->
      IO (Either (NonEmpty AdmissionError) ())
    inspectRecovery lock events activeFence = do
      case ( activeFence
           , recoveryAction input
           , rollbackProof transaction operationId events
           ) of
        (Nothing, RecoverFencedBackup, Just _) -> pure (Right ())
        _ -> inspectReviewedRecovery lock events activeFence
    inspectReviewedRecovery ::
      forall s.
      LockedStore s ->
      [JournalEvent] ->
      Maybe DataFenceRecord ->
      IO (Either (NonEmpty AdmissionError) ())
    inspectReviewedRecovery lock events activeFence = do
      bundle <- loadPublishedReview store (recoveryReview input)
      snapshot <- readReviewSnapshot store (recoveryReview input)
      case (bundle, snapshot) of
        (Left err, _) -> pure (failure "review" (showText err))
        (_, Left err) -> pure (failure "store" (showText err))
        (Right published, Right state) -> case verifyActiveReview state (transactionIdText transaction) published of
          Left errs -> pure (Left (fmap reviewAdmission errs))
          Right reviewed -> case find
            ((== operationId) . plannedOperationId . reviewPlannedOperation)
            (reviewOperations (reviewedDocument reviewed)) of
            Nothing -> pure (failure "recovery-operation" "operation is absent from the active review")
            Just reviewOperation -> case ( preparedFor reviewed reviewOperation
                                         , lookupAdapter registry (plannedExecutor (reviewPlannedOperation reviewOperation))
                                         ) of
              (Left err, _) -> pure (failure "native-bundle" err)
              (_, Left err) -> pure (failure "adapter" err)
              (Right prepared, Right adapter)
                | adapterIdentity adapter /= reviewAdapterIdentity reviewOperation
                    || adapterVersion adapter /= reviewAdapterVersion reviewOperation ->
                    pure (failure "adapter-version" "recovery adapter differs from the issued review")
                | otherwise -> case selectedFence registry reviewed reviewOperation prepared of
                    Left reason -> pure (failure "data-fence-capability" reason)
                    Right (Just (saved, controls))
                      | Just active <- activeFence
                      , sameReviewedFence transaction saved active ->
                          if recoveryAction input == RecoverFencedBackup
                            && not
                              ( all
                                  ( \selected ->
                                      plannedOperationId (reviewPlannedOperation selected) == operationId
                                        || plannedAction (reviewPlannedOperation selected) == VerifyResource
                                  )
                                  (reviewOperations (reviewedDocument reviewed))
                              )
                            then
                              pure
                                ( failure
                                    "recovery-review"
                                    "backup rollback requires a review with no other mutating operations"
                                )
                            else
                              recoverFenced
                                registry
                                input
                                lock
                                adapter
                                (reviewPlannedOperation reviewOperation)
                                prepared
                                active
                                controls
                                (reviewFenceCapability reviewOperation)
                                events
                    Right (Just _)
                      | isNothing activeFence
                      , recoveryAction input == RetryAfterAdapterProof
                      , Just lastEvent <-
                          find
                            ( \event ->
                                eventTransaction event == transaction
                                  && eventOperation event == Just operationId
                            )
                            (reverse events)
                      , eventState lastEvent == Ambiguous
                      , "data fence acquisition or exclusion is unresolved"
                          `T.isPrefixOf` eventDetail lastEvent -> do
                          -- startFence returned before adapterExecute. With no
                          -- durable reservation, its read-only validation or
                          -- conditional reservation failed before any effect.
                          appended <-
                            appendEvent
                              lock
                              transaction
                              (Just operationId)
                              (OperatorResolved "fence-not-reserved-safe-retry")
                              "operator selected retry after unreserved fence start"
                          pure
                            ( first
                                (\err -> AdmissionError "journal" (showText err) :| [])
                                (() <$ appended)
                            )
                    Right _
                      | isJust activeFence || fencedAction (recoveryAction input) ->
                          pure
                            ( failure
                                "data-fence-capability"
                                "active data fence differs from the private reviewed member"
                            )
                    Right selection -> do
                      let operation = reviewPlannedOperation reviewOperation
                      decision <- withAdapterEnv transaction operation (adapterRecover adapter operation prepared)
                      case (recoveryAction input, decision) of
                        (RecoverBootstrapRegistry native, RecoveryAwaitingReadiness _)
                          | isNothing selection -> runBootstrapThroughDriver lock events reviewed native
                        (RecoverBootstrapRegistry native, RecoveryProvedComplete _)
                          | isNothing selection -> runBootstrapThroughDriver lock events reviewed native
                        (AcceptAdapterProof, RecoveryProvedComplete proof) -> do
                          appended <-
                            appendEvent
                              lock
                              transaction
                              (Just operationId)
                              (Completed proof)
                              "operator accepted adapter recovery proof"
                          pure (first (\err -> AdmissionError "journal" (showText err) :| []) (() <$ appended))
                        (RetryAfterAdapterProof, RecoverySafeToRetry)
                          | isNothing selection -> do
                              appended <-
                                appendEvent
                                  lock
                                  transaction
                                  (Just operationId)
                                  (OperatorResolved "adapter-proved-safe-retry")
                                  "operator selected adapter-proved safe retry"
                              pure (first (\err -> AdmissionError "journal" (showText err) :| []) (() <$ appended))
                        _ -> pure (failure "unsupported-recovery" "adapter did not prove the operator's requested action")
    runBootstrapThroughDriver ::
      forall s.
      LockedStore s ->
      [JournalEvent] ->
      ReviewedPlan ->
      ContentDigest ->
      IO (Either (NonEmpty AdmissionError) ())
    runBootstrapThroughDriver lock events reviewed native = do
      outcome <-
        runOperations
          lock
          registry
          transaction
          reviewed
          events
          (reviewOperations (reviewedDocument reviewed))
          (Just (operationId, RecoverBootstrapRegistry native))
      pure $ case outcome of
        Nothing -> Right ()
        Just _ -> failure "recovery-prerequisite" "registry recovery driver could not prove the selected action"
