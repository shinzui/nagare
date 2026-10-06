{-# LANGUAGE RankNTypes #-}

-- | FencedRecovery responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.FencedRecovery
  ( recoverFenced
  )
where

import Data.Either (isRight)
import Data.List.NonEmpty (NonEmpty (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( Adapter
      ( adapterExecute
      , adapterPreflight
      , adapterRecover
      , adapterVerify
      )
  , AdapterExecution
    ( AdapterEffectAmbiguous
    , AdapterEffectCompleted
    , AdapterEffectFailed
    )
  , AdapterFence
    ( fenceResolveUncertainEffect
    , fenceRestoreRecoveryBackup
    , fenceVerifyRecoveryBackup
    )
  , AdapterRegistry
  , PlannedOperation (plannedExecutor)
  , PreparedNative
  , RecoveryDecision (RecoveryProvedComplete)
  , lookupAdapterFenceByCapability
  )
import Nagare.Inventory.DataFence
  ( DataFenceControls (verifyRecoveredData)
  , FenceToken
  , beginDataChange
  , checkDataFenceExclusion
  , forwardRecoverDataFenceRelease
  , markDataFenceUnresolved
  , recoverDataFence
  , releaseDataFence
  , resumeDataFence
  , resumeDataFenceAcquisition
  , verifyDataChange
  )
import Nagare.Inventory.Execute.AdapterEnv (withAdapterEnv)
import Nagare.Inventory.Execute.Close (closeRolledBack)
import Nagare.Inventory.Execute.Journal
  ( appendEvent
  , rollbackProof
  )
import Nagare.Inventory.Execute.Types
  ( AdmissionError (..)
  , OperatorRecoveryInput (..)
  , RecoveryAction (..)
  , failure
  , showText
  )
import Nagare.Inventory.Journal
  ( JournalEvent
  , OperationState (Ambiguous, Completed, OperatorResolved)
  )
import Nagare.Inventory.Store
  ( DataFencePhase
      ( FenceAcquiring
      , FenceChanging
      , FenceExcluded
      , FenceReleasing
      , FenceUnresolved
      , FenceVerifying
      )
  , DataFenceRecord (fencePhase, fenceSession)
  , LockedStore
  )
import Nagare.Resource.Types (ContentDigest, digestText)

recoverFenced ::
  forall s.
  AdapterRegistry ->
  OperatorRecoveryInput ->
  LockedStore s ->
  Adapter ->
  PlannedOperation ->
  PreparedNative ->
  DataFenceRecord ->
  DataFenceControls ->
  Maybe Text ->
  [JournalEvent] ->
  IO (Either (NonEmpty AdmissionError) ())
recoverFenced registry input lock adapter operation prepared active controls capability events = do
  resumed <- resumeDataFence lock (fenceSession active)
  case resumed of
    Left reason -> pure (failure "data-fence" reason)
    Right token -> case recoveryAction input of
      ContinueFencedOperation
        | fencePhase active `elem` [FenceAcquiring, FenceExcluded] -> do
            acquired <-
              if fencePhase active == FenceAcquiring
                then resumeDataFenceAcquisition lock controls token
                else pure (Right ())
            case acquired of
              Left reason -> pure (failure "data-fence" reason)
              Right () -> do
                preflight <- adapterPreflight adapter operation prepared
                case preflight of
                  Left reason -> pure (failure "preflight" reason)
                  Right () ->
                    continueAfterPreflight
                      lock
                      token
                      controls
                      adapter
                      operation
                      prepared
      VerifyFencedEffect
        | fencePhase active
            `elem` [FenceChanging, FenceUnresolved, FenceVerifying, FenceReleasing] -> do
            if isJust (rollbackProof transaction operationId events)
              then
                pure
                  ( failure
                      "adapter-recovery"
                      "recovery backup was selected; finish that recovery before releasing writers"
                  )
              else do
                decision <-
                  withAdapterEnv
                    transaction
                    operation
                    (resolveReviewedEffect adapter operation prepared active capability)
                case decision of
                  RecoveryProvedComplete proof -> do
                    recovered <- recoverDataFence lock controls token
                    case recovered of
                      Left reason -> pure (failure "data-fence" reason)
                      Right ()
                        | fencePhase active == FenceReleasing ->
                            appendFencedCompletion lock proof
                      Right () -> completeFenced lock token controls proof
                  _ ->
                    pure
                      ( failure
                          "adapter-recovery"
                          "adapter has not proved the fenced data effect complete"
                      )
      RecoverFencedBackup
        | fencePhase active
            `elem` [FenceChanging, FenceUnresolved, FenceVerifying, FenceReleasing] ->
            case capability
              >>= lookupAdapterFenceByCapability
                registry
                (plannedExecutor operation) of
              Nothing ->
                pure
                  ( failure
                      "data-fence-capability"
                      "reviewed recovery capability is unavailable"
                  )
              Just hook -> case ( fenceRestoreRecoveryBackup hook
                                , fenceVerifyRecoveryBackup hook
                                ) of
                (Just restore, Just verify) -> do
                  let prior = rollbackProof transaction operationId events
                      recoveryControls proof =
                        controls
                          { verifyRecoveredData = \record -> do
                              observed <- verify record operation prepared
                              pure ((== proof) <$> observed)
                          }
                  safe <-
                    if fencePhase active == FenceReleasing
                      then
                        pure
                          ( if isJust prior
                              then Right ()
                              else Left "recovery backup was not proved before writer release"
                          )
                      else checkDataFenceExclusion lock controls token
                  case safe of
                    Left reason -> pure (failure "data-fence" reason)
                    Right () -> do
                      restored <- case prior of
                        Just proof -> pure (Right proof)
                        Nothing ->
                          withAdapterEnv
                            transaction
                            operation
                            (restore active operation prepared)
                      case restored of
                        Left reason -> pure (failure "adapter-recovery" reason)
                        Right proof -> do
                          observed <-
                            withAdapterEnv
                              transaction
                              operation
                              (verify active operation prepared)
                          if observed /= Right proof
                            then
                              pure
                                ( failure
                                    "adapter-recovery"
                                    "recovery backup content is not proved"
                                )
                            else do
                              recorded <- case prior of
                                Just saved | saved == proof -> pure (Right ())
                                Just _ -> pure (Left "recovery proof changed")
                                Nothing ->
                                  fmap
                                    (first showText . (() <$))
                                    ( appendEvent
                                        lock
                                        transaction
                                        (Just operationId)
                                        ( OperatorResolved
                                            ( "fenced-recovery-proved:"
                                                <> digestText proof
                                            )
                                        )
                                        "reviewed recovery backup content proved under data fence"
                                    )
                              case recorded of
                                Left reason -> pure (failure "journal" reason)
                                Right () -> do
                                  let selected = recoveryControls proof
                                  recovered <- recoverDataFence lock selected token
                                  case recovered of
                                    Left reason -> pure (failure "data-fence" reason)
                                    Right () | fencePhase active == FenceReleasing -> do
                                      closed <- isRight <$> closeRolledBack lock transaction
                                      pure $
                                        if closed
                                          then Right ()
                                          else
                                            failure
                                              "head-condition"
                                              "could not close recovered transaction"
                                    Right () -> do
                                      released <- releaseDataFence lock selected token
                                      case released of
                                        Left reason -> pure (failure "data-fence" reason)
                                        Right () -> do
                                          closed <- isRight <$> closeRolledBack lock transaction
                                          pure $
                                            if closed
                                              then Right ()
                                              else
                                                failure
                                                  "head-condition"
                                                  "could not close recovered transaction"
                _ ->
                  pure
                    ( failure
                        "data-fence-capability"
                        "reviewed capability has no recovery backup verifier"
                    )
      ForwardFencedRelease
        | fencePhase active == FenceReleasing -> do
            case rollbackProof transaction operationId events of
              Just proof -> case capability
                >>= lookupAdapterFenceByCapability
                  registry
                  (plannedExecutor operation)
                >>= fenceVerifyRecoveryBackup of
                Nothing ->
                  pure
                    ( failure
                        "data-fence-capability"
                        "reviewed recovery backup verifier is unavailable"
                    )
                Just verify -> do
                  observed <-
                    withAdapterEnv
                      transaction
                      operation
                      (verify active operation prepared)
                  if observed /= Right proof
                    then
                      pure
                        ( failure
                            "adapter-recovery"
                            "recovery backup content is not proved"
                        )
                    else do
                      recovered <- forwardRecoverDataFenceRelease lock controls token
                      case recovered of
                        Left reason -> pure (failure "data-fence" reason)
                        Right () -> do
                          closed <- isRight <$> closeRolledBack lock transaction
                          pure $
                            if closed
                              then Right ()
                              else
                                failure
                                  "head-condition"
                                  "could not close recovered transaction"
              Nothing -> do
                decision <-
                  withAdapterEnv
                    transaction
                    operation
                    (resolveReviewedEffect adapter operation prepared active capability)
                case decision of
                  RecoveryProvedComplete proof -> do
                    recovered <- forwardRecoverDataFenceRelease lock controls token
                    case recovered of
                      Left reason -> pure (failure "data-fence" reason)
                      Right () -> appendFencedCompletion lock proof
                  _ ->
                    pure
                      ( failure
                          "adapter-recovery"
                          "adapter has not proved the fenced data effect complete"
                      )
      _ ->
        pure
          ( failure
              "data-fence"
              "recovery action does not match the durable data fence phase"
          )
  where
    transaction = recoveryTransaction input
    operationId = recoveryOperation input
    resolveReviewedEffect adapter operation prepared active capability =
      case capability
        >>= lookupAdapterFenceByCapability
          registry
          (plannedExecutor operation)
        >>= fenceResolveUncertainEffect of
        Just resolve -> resolve active operation prepared
        Nothing -> adapterRecover adapter operation prepared
    continueAfterPreflight ::
      forall s.
      LockedStore s ->
      FenceToken ->
      DataFenceControls ->
      Adapter ->
      PlannedOperation ->
      PreparedNative ->
      IO (Either (NonEmpty AdmissionError) ())
    continueAfterPreflight lock token controls adapter operation prepared = do
      started <- beginDataChange lock controls token
      case started of
        Left reason -> pure (failure "data-fence" reason)
        Right () -> do
          effect <-
            withAdapterEnv
              transaction
              operation
              (adapterExecute adapter operation prepared)
          case effect of
            AdapterEffectCompleted -> do
              verified <-
                withAdapterEnv
                  transaction
                  operation
                  (adapterVerify adapter operation prepared)
              case verified of
                Left reason -> do
                  _ <- markDataFenceUnresolved lock token
                  pure (failure "adapter-recovery" reason)
                Right proof -> finishFenced lock token controls proof
            AdapterEffectAmbiguous reason -> do
              _ <- markDataFenceUnresolved lock token
              _ <-
                appendEvent
                  lock
                  transaction
                  (Just operationId)
                  Ambiguous
                  ("fenced adapter result was ambiguous: " <> reason)
              pure
                ( failure
                    "adapter-recovery"
                    "fenced data effect is not proved complete"
                )
            AdapterEffectFailed failureClass -> do
              _ <- markDataFenceUnresolved lock token
              _ <-
                appendEvent
                  lock
                  transaction
                  (Just operationId)
                  Ambiguous
                  ("fenced adapter execution stopped: " <> showText failureClass)
              pure
                ( failure
                    "adapter-recovery"
                    "fenced data effect is not proved complete"
                )
    finishFenced ::
      forall s.
      LockedStore s ->
      FenceToken ->
      DataFenceControls ->
      ContentDigest ->
      IO (Either (NonEmpty AdmissionError) ())
    finishFenced lock token controls proof = do
      verified <- verifyDataChange lock controls token
      case verified of
        Left reason -> pure (failure "data-fence" reason)
        Right () -> completeFenced lock token controls proof
    completeFenced ::
      forall s.
      LockedStore s ->
      FenceToken ->
      DataFenceControls ->
      ContentDigest ->
      IO (Either (NonEmpty AdmissionError) ())
    completeFenced lock token controls proof = do
      released <- releaseDataFence lock controls token
      case released of
        Left reason -> pure (failure "data-fence" reason)
        Right () -> appendFencedCompletion lock proof
    appendFencedCompletion ::
      forall s.
      LockedStore s ->
      ContentDigest ->
      IO (Either (NonEmpty AdmissionError) ())
    appendFencedCompletion lock proof = do
      appended <-
        appendEvent
          lock
          transaction
          (Just operationId)
          (Completed proof)
          "reviewed fenced effect and writer release proved"
      pure (first (\err -> AdmissionError "journal" (showText err) :| []) (() <$ appended))
