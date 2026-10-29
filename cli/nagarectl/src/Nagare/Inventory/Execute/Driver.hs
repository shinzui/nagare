{-# LANGUAGE RankNTypes #-}

-- | Driver responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Driver
  ( runOperations
  , runOperationsJournal
  )
where

import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (find, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Contract.Trace (OperationRecord (..), noLabels)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( Adapter
      ( adapterExecute
      , adapterIdentity
      , adapterPreflight
      , adapterRecover
      , adapterVerify
      , adapterVersion
      )
  , AdapterExecution
    ( AdapterEffectAmbiguous
    , AdapterEffectCompleted
    , AdapterEffectFailed
    )
  , AdapterRecovery (recoveryExecute, recoveryValidate)
  , AdapterRegistry
  , EffectOutcome (..)
  , OperationAction (CreateResource, VerifyResource)
  , PlannedOperation
    ( plannedAction
    , plannedExecutor
    , plannedOperationId
    , plannedResources
    )
  , RecoveryDecision
    ( RecoveryAwaitingReadiness
    , RecoveryLandedUnready
    , RecoveryProvedComplete
    , RecoverySafeToRetry
    , RecoveryTargetReplaced
    , RecoveryTerminalFailure
    , RecoveryUnresolved
    )
  , effectIdentity
  , lookupAdapter
  , lookupAdapterRecovery
  )
import Nagare.Inventory.DataFence
  ( acquireDataFence
  , beginDataChange
  , markDataFenceUnresolved
  , releaseDataFence
  , verifyDataChange
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute.AdapterEnv (withAdapterEnv)
import Nagare.Inventory.Execute.Claims (executorStillClaimed)
import Nagare.Inventory.Execute.Inputs
  ( preparedFor
  , selectedFence
  )
import Nagare.Inventory.Execute.Journal (appendEvent, appendEventWith)
import Nagare.Inventory.Execute.Types
  ( RecoveryAction (..)
  , TransactionResult (..)
  , showText
  )
import Nagare.Inventory.Journal
  ( FailureClass (KnownNoEffect, PartialOrUnknown)
  , JournalEvent (eventOperation, eventState)
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
  , operationIdText
  , operationStates
  , transactionIdText
  )
import Nagare.Inventory.OperationStep
  ( OperationStep
      ( ExecuteOperation
      , OperationBlocked
      , OperationsFinished
      , RecoverOperation
      )
  , bootstrapRecoveryMarker
  , dependenciesComplete
  , nextOperation
  )
import Nagare.Inventory.Plan
  ( ReviewDocument (reviewDesiredRevisions)
  , ReviewOperation
    ( reviewAdapterIdentity
    , reviewAdapterVersion
    , reviewFenceDigest
    , reviewPlannedOperation
    )
  , ReviewedPlan
  , reviewedDocument
  )
import Nagare.Inventory.Store
  ( DataFenceRecord (fenceTransaction)
  , LockedStore
  , ScopeRevision (revisionDigest)
  , lockedStore
  , objectKeyFor
  , readObject
  , scopeKey
  )
import Nagare.Inventory.Store.Counters (labelled, traceOperations, withSpan)
import Nagare.Resource.Inventory (Executor (..))
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Policy (DataPolicy (..))
import Nagare.Resource.Types
  ( ProviderAddress (Kubernetes)
  , digestText
  , nameText
  , physicalIdentityText
  )
import Nagare.Resource.Wire (decodeScope)

runOperations ::
  LockedStore s ->
  AdapterRegistry ->
  TransactionId ->
  ReviewedPlan ->
  [JournalEvent] ->
  [ReviewOperation] ->
  Maybe (OperationId, RecoveryAction) ->
  IO (Maybe TransactionResult)
runOperations locked registry transaction reviewed initialEvents operations recoveryDecision =
  fst <$> runOperationsJournal locked registry transaction reviewed initialEvents operations recoveryDecision

-- | 'runOperations', also returning the journal as the run left it, so
-- convergence can bind identities without reading the journal again.
runOperationsJournal ::
  LockedStore s ->
  AdapterRegistry ->
  TransactionId ->
  ReviewedPlan ->
  [JournalEvent] ->
  [ReviewOperation] ->
  Maybe (OperationId, RecoveryAction) ->
  IO (Maybe TransactionResult, [JournalEvent])
runOperationsJournal locked registry transaction reviewed initialEvents operations recoveryDecision = do
  latest <- newIORef initialEvents
  result <- runOperationsWith latest locked registry transaction reviewed initialEvents operations recoveryDecision
  (result,) <$> readIORef latest

runOperationsWith ::
  IORef [JournalEvent] ->
  LockedStore s ->
  AdapterRegistry ->
  TransactionId ->
  ReviewedPlan ->
  [JournalEvent] ->
  [ReviewOperation] ->
  Maybe (OperationId, RecoveryAction) ->
  IO (Maybe TransactionResult)
runOperationsWith latest locked registry transaction reviewed initialEvents operations recoveryDecision = go initialEvents
  where
    go events = writeIORef latest events >> step events
    step events = case recoveryDecision of
      Just (selected, _) -> case find ((== selected) . operationId) operations of
        Just operation -> recoverOrStop events operation
        Nothing -> pure (Just (StoppedAmbiguous transaction selected "the recovery decision names an operation outside this review"))
      Nothing -> case nextOperation operations (operationStates transaction events) of
        OperationsFinished -> pure Nothing
        OperationBlocked operation reason ->
          pure
            ( Just
                (StoppedFailed transaction operation (PartialOrUnknown reason))
            )
        RecoverOperation operation -> recoverOrStop events operation
        ExecuteOperation operation -> executeOne events operation
    recoverOrStop events reviewOperation =
      let operation = reviewPlannedOperation reviewOperation
       in case preparedFor reviewed reviewOperation of
            Left reason -> pure (Just (StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation reviewOperation)) ("the reviewed native input is unavailable: " <> reason)))
            Right prepared -> case lookupAdapter registry (plannedExecutor (reviewPlannedOperation reviewOperation)) of
              Left reason -> pure (Just (StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation reviewOperation)) ("no adapter can recover the operation: " <> reason)))
              Right adapter
                | adapterIdentity adapter /= reviewAdapterIdentity reviewOperation
                    || adapterVersion adapter /= reviewAdapterVersion reviewOperation ->
                    pure (Just (StoppedAmbiguous transaction (plannedOperationId operation) "the installed adapter is not the reviewed identity and version"))
                | Left reason <- selectedFence registry reviewed reviewOperation prepared ->
                    pure (Just (StoppedAmbiguous transaction (plannedOperationId operation) ("the reviewed data fence capability changed: " <> reason)))
                | otherwise -> case recoveryDecision of
                    Just (selected, RecoverBootstrapRegistry native)
                      | selected == plannedOperationId operation ->
                          recoverBootstrapDecision events reviewOperation adapter prepared native
                      | otherwise -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation) "the recovery decision names another operation"))
                    Just _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation) "the recovery decision does not apply to this operation"))
                    Nothing -> ordinaryRecovery events reviewOperation operation adapter prepared
    ordinaryRecovery events reviewOperation operation adapter prepared = do
      decision <- withAdapterEnv transaction operation (adapterRecover adapter operation prepared)
      case decision of
        RecoveryProvedComplete proof -> do
          appended <-
            appendEvent
              locked
              transaction
              (Just (plannedOperationId operation))
              (Completed proof)
              "adapter recovery proved completion"
          case appended of
            Left failure -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation) ("the recovery proof could not be journalled: " <> showText failure)))
            Right event -> go (events <> [event])
        RecoverySafeToRetry
          | isNothing (reviewFenceDigest reviewOperation)
          , dependenciesComplete (operationStates transaction events) reviewOperation ->
              executeOne events reviewOperation
          | otherwise -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation) "a retry is safe, but the operation is fenced or waits for an unfinished dependency"))
        RecoveryAwaitingReadiness _ -> continueReadiness events reviewOperation
        -- Resume cannot make a landed update Ready; only a reviewed stop or a
        -- corrected review ends it.
        RecoveryLandedUnready physical -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation) ("the update landed on " <> physicalIdentityText physical <> " but never became ready; close the transaction and review the change again")))
        RecoveryTargetReplaced physical -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation) ("the target was replaced outside Nagare by " <> physicalIdentityText physical <> "; close the transaction and review the change again")))
        RecoveryTerminalFailure physical -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation) ("the operation failed terminally on " <> physicalIdentityText physical <> "; close the transaction and review the change again")))
        RecoveryUnresolved reason -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation) reason))
    -- The operator decision supplies the immutable capsule, but this shared
    -- driver still owns intent, claim recheck, effect execution, and receipt.
    -- A successful prerequisite deliberately stops here: workload readiness is
    -- independently proved by the normal resume path.
    recoverBootstrapDecision events reviewOperation adapter prepared native = do
      decision <-
        withAdapterEnv
          transaction
          (reviewPlannedOperation reviewOperation)
          (adapterRecover adapter (reviewPlannedOperation reviewOperation) prepared)
      case decision of
        RecoveryAwaitingReadiness _ -> executeBootstrapRecovery
        RecoveryProvedComplete _ -> executeBootstrapRecovery
        _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation reviewOperation)) "the adapter did not prove the registry credential recovery"))
      where
        operation = reviewPlannedOperation reviewOperation
        operationId = plannedOperationId operation
        executeBootstrapRecovery = case lookupAdapterRecovery registry "bootstrap-registry-credentials" of
          Nothing -> pure (Just (StoppedAmbiguous transaction operationId "no registry credential recovery capability is installed"))
          Just capability -> do
            let prior = Map.lookup operationId (operationStates transaction events)
                selected = case prior of
                  Just (OperatorResolved marker) -> case bootstrapRecoveryMarker marker of
                    Just (saved, _) -> saved == native
                    _ -> False
                  _ -> True
            saved <- readObject (lockedStore locked) (objectKeyFor "native" native)
            case saved of
              Right (Just bytes) | selected && contentDigest bytes == native -> do
                validated <- recoveryValidate capability operation prepared bytes
                case validated of
                  Left reason -> pure (Just (StoppedAmbiguous transaction operationId ("the saved recovery input was refused: " <> reason)))
                  Right () -> do
                    intent <-
                      appendEvent
                        locked
                        transaction
                        (Just operationId)
                        (OperatorResolved ("bootstrap-registry-intent:" <> digestText native))
                        "bounded registry credential recovery selected; workload completion remains unproved"
                    case intent of
                      Left failure -> pure (Just (StoppedAmbiguous transaction operationId ("the recovery intent could not be journalled: " <> showText failure)))
                      Right _ -> do
                        claimed <- executorStillClaimed locked transaction
                        if not claimed
                          then pure (Just (StoppedAmbiguous transaction operationId "the executor claim was lost"))
                          else do
                            proved <-
                              withAdapterEnv
                                transaction
                                operation
                                (recoveryExecute capability operation prepared bytes)
                            case proved of
                              Left reason -> pure (Just (StoppedAmbiguous transaction operationId ("the registry credential recovery failed: " <> reason)))
                              Right receipt -> do
                                appended <-
                                  appendEvent
                                    locked
                                    transaction
                                    (Just operationId)
                                    ( OperatorResolved
                                        ( "bootstrap-registry-proved:"
                                            <> digestText native
                                            <> ":"
                                            <> digestText receipt
                                        )
                                    )
                                    "accepted host registry policy recovered; resume must independently prove workload readiness"
                                pure (either (const (Just (StoppedAmbiguous transaction operationId "the recovery receipt could not be journalled"))) (const Nothing) appended)
              _ -> pure (Just (StoppedAmbiguous transaction operationId "the saved recovery input is missing or is not the selected one"))
    -- Keep the original ambiguous operation and its readiness requirement.
    -- Only an untouched, independent stateless Deployment create may proceed;
    -- no retry, data operation, fence, or dependent work is authorized here.
    -- Each completed create re-enters recovery and freshly proves the waiting
    -- object's ownership/digest before considering another original operation.
    continueReadiness events waiting = do
      scopes <-
        traverse
          loadDesiredScope
          (Map.elems (reviewDesiredRevisions (reviewedDocument reviewed)))
      let states = operationStates transaction events
          remaining = filter ((/= operationId waiting) . operationId) operations
          declarations = do
            loaded <- sequence scopes
            first
              showText
              ( Resource.composedDeclarations
                  (Map.fromList [(Resource.scopeId scope, scope) | scope <- loaded])
              )
          safeCreate members entry =
            let planned = reviewPlannedOperation entry
                selected = NE.toList (plannedResources planned)
             in plannedAction planned == CreateResource
                  && plannedExecutor planned == KubernetesExecutor
                  && isNothing (reviewFenceDigest entry)
                  && case [ member
                          | Resource.Managed member <- members
                          , member ^. #identity `elem` selected
                          ] of
                    [member]
                      | selected == [member ^. #identity]
                      , member ^. #dataPolicy == Stateless -> case member ^. #address of
                          Kubernetes _ "apps" kind _ _ -> nameText kind == "deployment"
                          _ -> False
                    _ -> False
          untouched entry = case Map.lookup (operationId entry) states of
            Nothing -> True
            Just Pending -> True
            _ -> False
          candidate = do
            members <- either (const Nothing) Just declarations
            if not (safeCreate members waiting)
              then Nothing
              else case nextOperation remaining states of
                ExecuteOperation _ ->
                  find
                    ( \entry ->
                        untouched entry
                          && safeCreate members entry
                          && dependenciesComplete states entry
                    )
                    (sortOn operationId remaining)
                _ -> Nothing
      case candidate of
        Just entry -> executeOne events entry
        Nothing -> pure (Just (StoppedAmbiguous transaction (operationId waiting) "the operation waits for readiness; resume once it is ready, or close the transaction"))
    operationId = plannedOperationId . reviewPlannedOperation
    loadDesiredScope revision = do
      result <- readObject (lockedStore locked) (scopeKey (revisionDigest revision))
      pure $ do
        bytes <- first showText result >>= maybe (Left "missing desired scope") Right
        if contentDigest bytes /= revisionDigest revision
          then Left "desired scope digest mismatch"
          else first showText (decodeScope bytes)
    executeOne events reviewOperation = do
      let operation = reviewPlannedOperation reviewOperation
          operationId = plannedOperationId operation
      case (lookupAdapter registry (plannedExecutor operation), preparedFor reviewed reviewOperation) of
        (Left reason, _) -> pure (Just (StoppedAmbiguous transaction operationId ("no adapter can execute the operation: " <> reason)))
        (_, Left reason) -> pure (Just (StoppedAmbiguous transaction operationId ("the reviewed native input is unavailable: " <> reason)))
        (Right adapter, Right prepared) -> case selectedFence registry reviewed reviewOperation prepared of
          Left _ ->
            pure
              ( Just
                  ( StoppedFailed
                      transaction
                      operationId
                      (KnownNoEffect "reviewed data fence capability changed")
                  )
              )
          Right fenceSelection ->
            executePrepared
              events
              operation
              operationId
              adapter
              prepared
              fenceSelection
    -- EP-224: each attempt of an operation is one span labelled with the
    -- operation and its attempt; its preflight, effect and verification are
    -- child spans. Labels are passed down, never read from a global.
    executePrepared events operation operationId adapter prepared fenceSelection = do
      let action = T.pack (show (plannedAction operation))
          attempt = 1 + length [() | event <- events, eventOperation event == Just operationId, eventState event == IntentRecorded]
          labels = noLabels & #operation ?~ operationIdText operationId & #attempt ?~ attempt
      traceOperations RecordExecuted [(action, T.pack (show (plannedExecutor operation)))]
      withSpan (labelled labels) ("operation " <> action) $ \context ->
        executeAttempt context events operation operationId adapter prepared fenceSelection
    executeAttempt context events operation operationId adapter prepared fenceSelection = do
      preflight <- withSpan context "preflight" (const (adapterPreflight adapter operation prepared))
      case preflight of
        Left reason
          | Map.findWithDefault Pending operationId (operationStates transaction events) /= Pending -> do
              -- F57: a retry the adapter proved safe (the earlier attempt had
              -- no effect) refused again before any new effect. Journal that
              -- no-effect refusal so the operator can abandon it.
              appended <-
                appendEvent
                  locked
                  transaction
                  (Just operationId)
                  (Failed (KnownNoEffect ("adapter preflight refused: " <> reason)))
                  "retried operation refused by adapter preflight"
              pure $ Just $ case appended of
                Left failure -> StoppedAmbiguous transaction operationId ("the preflight refusal could not be journalled: " <> showText failure)
                Right _ -> StoppedFailed transaction operationId (KnownNoEffect ("adapter preflight refused: " <> reason))
        -- F88: a first refusal is not journalled (nothing started), but the
        -- operator still gets the adapter's reason.
        Left reason -> pure (Just (StoppedFailed transaction operationId (KnownNoEffect ("adapter preflight refused: " <> reason))))
        Right () -> do
          intent <- appendEvent locked transaction (Just operationId) IntentRecorded "operation intent recorded"
          case intent of
            Left failure -> pure (Just (StoppedAmbiguous transaction operationId ("the operation intent could not be journalled: " <> showText failure)))
            Right intentEvent -> do
              currentClaim <- executorStillClaimed locked transaction
              if not currentClaim
                then pure (Just (StoppedAmbiguous transaction operationId "the executor claim was lost"))
                else do
                  started <- startFence fenceSelection
                  case started of
                    Left reason -> do
                      _ <-
                        appendEvent
                          locked
                          transaction
                          (Just operationId)
                          Ambiguous
                          ("data fence acquisition or exclusion is unresolved: " <> reason)
                      pure (Just (StoppedAmbiguous transaction operationId ("data fence acquisition or exclusion is unresolved: " <> reason)))
                    Right activeFence -> do
                      -- ADR 26 (O6): a verification is effect-free by
                      -- construction; only its adapterVerify step runs.
                      result <-
                        if plannedAction operation == VerifyResource
                          then pure AdapterEffectCompleted
                          else
                            withSpan context "effect" . const $
                              withAdapterEnv
                                transaction
                                operation
                                (adapterExecute adapter operation prepared)
                      -- ADR 27: every event that ends this operation keeps the
                      -- identity the provider returned for its write.
                      let (physical, outcome) = effectIdentity result
                      case outcome of
                        OutcomeFailed failureClass -> do
                          markUnknown activeFence
                          let state = case (activeFence, failureClass) of
                                (Just _, _) -> Ambiguous
                                (_, KnownNoEffect _) -> Failed failureClass
                                _ -> Ambiguous
                          appended <-
                            appendEventWith
                              physical
                              locked
                              transaction
                              (Just operationId)
                              state
                              "adapter execution stopped"
                          pure $ Just $ case (activeFence, failureClass, appended) of
                            (Nothing, KnownNoEffect _, Right _) ->
                              StoppedFailed transaction operationId failureClass
                            _ -> StoppedAmbiguous transaction operationId ("the adapter stopped with " <> showText failureClass <> " while the outcome cannot be proved")
                        OutcomeAmbiguous reason -> do
                          markUnknown activeFence
                          _ <-
                            appendEventWith
                              physical
                              locked
                              transaction
                              (Just operationId)
                              Ambiguous
                              ("adapter result was ambiguous: " <> reason)
                          pure (Just (StoppedAmbiguous transaction operationId ("adapter result was ambiguous: " <> reason)))
                        OutcomeCompleted -> do
                          verification <-
                            withSpan context "verify" . const $
                              withAdapterEnv
                                transaction
                                operation
                                (adapterVerify adapter operation prepared)
                          case verification of
                            Left reason -> do
                              markUnknown activeFence
                              _ <-
                                appendEventWith
                                  physical
                                  locked
                                  transaction
                                  (Just operationId)
                                  Ambiguous
                                  "adapter completion could not be verified"
                              pure (Just (StoppedAmbiguous transaction operationId ("adapter completion could not be verified: " <> reason)))
                            Right proof -> do
                              fenceVerified <- finishFence activeFence
                              case fenceVerified of
                                Left reason -> do
                                  _ <-
                                    appendEventWith
                                      physical
                                      locked
                                      transaction
                                      (Just operationId)
                                      Ambiguous
                                      "data fence verification or release is unresolved"
                                  pure (Just (StoppedAmbiguous transaction operationId ("data fence verification or release is unresolved: " <> reason)))
                                Right () -> do
                                  appended <-
                                    appendEventWith
                                      physical
                                      locked
                                      transaction
                                      (Just operationId)
                                      (Completed proof)
                                      "operation completion verified"
                                  case appended of
                                    Left failure -> pure (Just (StoppedAmbiguous transaction operationId ("the completion could not be journalled: " <> showText failure)))
                                    Right completedEvent -> go (events <> [intentEvent, completedEvent])
    startFence Nothing = pure (Right Nothing)
    startFence (Just (requested, controls)) = do
      acquired <-
        acquireDataFence
          locked
          controls
          requested
            { fenceTransaction = Just (transactionIdText transaction)
            }
      case acquired of
        Left reason -> pure (Left reason)
        Right token -> do
          started <- beginDataChange locked controls token
          pure (Just (token, controls) <$ started)
    markUnknown Nothing = pure ()
    markUnknown (Just (token, _)) = do
      _ <- markDataFenceUnresolved locked token
      pure ()
    finishFence Nothing = pure (Right ())
    finishFence (Just (token, controls)) = do
      verified <- verifyDataChange locked controls token
      case verified of
        Left reason -> pure (Left reason)
        Right () -> releaseDataFence locked controls token
