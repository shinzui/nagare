{-# LANGUAGE RankNTypes #-}

-- | Driver responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Driver
  ( runOperations
  )
where

import Data.Generics.Labels ()
import Data.List (find, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
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
import Nagare.Inventory.Execute.Journal (appendEvent)
import Nagare.Inventory.Execute.Types
  ( RecoveryAction (..)
  , TransactionResult (..)
  , showText
  )
import Nagare.Inventory.Journal
  ( FailureClass (KnownNoEffect, PartialOrUnknown)
  , JournalEvent
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
import Nagare.Resource.Inventory (Executor (..))
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Policy (DataPolicy (..))
import Nagare.Resource.Types
  ( ProviderAddress (Kubernetes)
  , digestText
  , nameText
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
runOperations locked registry transaction reviewed initialEvents operations recoveryDecision = go initialEvents
  where
    go events = case recoveryDecision of
      Just (selected, _) -> case find ((== selected) . operationId) operations of
        Just operation -> recoverOrStop events operation
        Nothing -> pure (Just (StoppedAmbiguous transaction selected))
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
            Left _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation reviewOperation))))
            Right prepared -> case lookupAdapter registry (plannedExecutor (reviewPlannedOperation reviewOperation)) of
              Left _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation reviewOperation))))
              Right adapter
                | adapterIdentity adapter /= reviewAdapterIdentity reviewOperation
                    || adapterVersion adapter /= reviewAdapterVersion reviewOperation ->
                    pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
                | Left _ <- selectedFence registry reviewed reviewOperation prepared ->
                    pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
                | otherwise -> case recoveryDecision of
                    Just (selected, RecoverBootstrapRegistry native)
                      | selected == plannedOperationId operation ->
                          recoverBootstrapDecision events reviewOperation adapter prepared native
                      | otherwise -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
                    Just _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
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
            Left _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
            Right event -> go (events <> [event])
        RecoverySafeToRetry
          | isNothing (reviewFenceDigest reviewOperation)
          , dependenciesComplete (operationStates transaction events) reviewOperation ->
              executeOne events reviewOperation
          | otherwise -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
        RecoveryAwaitingReadiness _ -> continueReadiness events reviewOperation
        -- Resume cannot make a landed update Ready; only a reviewed stop or a
        -- corrected review ends it.
        RecoveryLandedUnready _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
        RecoveryTargetReplaced _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
        RecoveryTerminalFailure _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
        RecoveryUnresolved _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
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
        _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation reviewOperation))))
      where
        operation = reviewPlannedOperation reviewOperation
        operationId = plannedOperationId operation
        executeBootstrapRecovery = case lookupAdapterRecovery registry "bootstrap-registry-credentials" of
          Nothing -> pure (Just (StoppedAmbiguous transaction operationId))
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
                  Left _ -> pure (Just (StoppedAmbiguous transaction operationId))
                  Right () -> do
                    intent <-
                      appendEvent
                        locked
                        transaction
                        (Just operationId)
                        (OperatorResolved ("bootstrap-registry-intent:" <> digestText native))
                        "bounded registry credential recovery selected; workload completion remains unproved"
                    case intent of
                      Left _ -> pure (Just (StoppedAmbiguous transaction operationId))
                      Right _ -> do
                        claimed <- executorStillClaimed locked transaction
                        if not claimed
                          then pure (Just (StoppedAmbiguous transaction operationId))
                          else do
                            proved <-
                              withAdapterEnv
                                transaction
                                operation
                                (recoveryExecute capability operation prepared bytes)
                            case proved of
                              Left _ -> pure (Just (StoppedAmbiguous transaction operationId))
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
                                pure (either (const (Just (StoppedAmbiguous transaction operationId))) (const Nothing) appended)
              _ -> pure (Just (StoppedAmbiguous transaction operationId))
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
        Nothing -> pure (Just (StoppedAmbiguous transaction (operationId waiting)))
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
        (Left _, _) -> pure (Just (StoppedAmbiguous transaction operationId))
        (_, Left _) -> pure (Just (StoppedAmbiguous transaction operationId))
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
    executePrepared events operation operationId adapter prepared fenceSelection = do
      preflight <- adapterPreflight adapter operation prepared
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
                Left _ -> StoppedAmbiguous transaction operationId
                Right _ -> StoppedFailed transaction operationId (KnownNoEffect "adapter preflight refused")
        Left _ -> pure (Just (StoppedFailed transaction operationId (KnownNoEffect "adapter preflight refused")))
        Right () -> do
          intent <- appendEvent locked transaction (Just operationId) IntentRecorded "operation intent recorded"
          case intent of
            Left _ -> pure (Just (StoppedAmbiguous transaction operationId))
            Right intentEvent -> do
              currentClaim <- executorStillClaimed locked transaction
              if not currentClaim
                then pure (Just (StoppedAmbiguous transaction operationId))
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
                      pure (Just (StoppedAmbiguous transaction operationId))
                    Right activeFence -> do
                      -- ADR 26 (O6): a verification is effect-free by
                      -- construction; only its adapterVerify step runs.
                      result <-
                        if plannedAction operation == VerifyResource
                          then pure AdapterEffectCompleted
                          else
                            withAdapterEnv
                              transaction
                              operation
                              (adapterExecute adapter operation prepared)
                      case result of
                        AdapterEffectFailed failureClass -> do
                          markUnknown activeFence
                          let state = case (activeFence, failureClass) of
                                (Just _, _) -> Ambiguous
                                (_, KnownNoEffect _) -> Failed failureClass
                                _ -> Ambiguous
                          appended <-
                            appendEvent
                              locked
                              transaction
                              (Just operationId)
                              state
                              "adapter execution stopped"
                          pure $ Just $ case (activeFence, failureClass, appended) of
                            (Nothing, KnownNoEffect _, Right _) ->
                              StoppedFailed transaction operationId failureClass
                            _ -> StoppedAmbiguous transaction operationId
                        AdapterEffectAmbiguous reason -> do
                          markUnknown activeFence
                          _ <-
                            appendEvent
                              locked
                              transaction
                              (Just operationId)
                              Ambiguous
                              ("adapter result was ambiguous: " <> reason)
                          pure (Just (StoppedAmbiguous transaction operationId))
                        AdapterEffectCompleted -> do
                          verification <-
                            withAdapterEnv
                              transaction
                              operation
                              (adapterVerify adapter operation prepared)
                          case verification of
                            Left _ -> do
                              markUnknown activeFence
                              _ <-
                                appendEvent
                                  locked
                                  transaction
                                  (Just operationId)
                                  Ambiguous
                                  "adapter completion could not be verified"
                              pure (Just (StoppedAmbiguous transaction operationId))
                            Right proof -> do
                              fenceVerified <- finishFence activeFence
                              case fenceVerified of
                                Left _ -> do
                                  _ <-
                                    appendEvent
                                      locked
                                      transaction
                                      (Just operationId)
                                      Ambiguous
                                      "data fence verification or release is unresolved"
                                  pure (Just (StoppedAmbiguous transaction operationId))
                                Right () -> do
                                  appended <-
                                    appendEvent
                                      locked
                                      transaction
                                      (Just operationId)
                                      (Completed proof)
                                      "operation completion verified"
                                  case appended of
                                    Left _ -> pure (Just (StoppedAmbiguous transaction operationId))
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
