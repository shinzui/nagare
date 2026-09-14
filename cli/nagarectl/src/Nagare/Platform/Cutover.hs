{-# LANGUAGE OverloadedStrings #-}

-- | Deadline-bound replacement cutover, rollback, reconciliation, and cleanup.
--
-- Every mutating phase persists intent before invoking an injected operation and
-- persists observed completion afterwards.  Provider-specific code is expected
-- to make each operation idempotent by observing actual state before mutation.
module Nagare.Platform.Cutover
  ( VerificationMode (..)
  , WriteGate (..)
  , Revalidation (..)
  , QuiesceSnapshot (..)
  , QuiesceResult (..)
  , PublicEvidence (..)
  , CutoverObservation (..)
  , CutoverOps (..)
  , CutoverError (..)
  , Reconciliation (..)
  , CleanupOps (..)
  , CleanupError (..)
  , runCutover
  , runRollback
  , reconcileCutover
  , finalizeReplacement
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Nagare.Dsl.Prelude
import Nagare.Platform.Replacement
import Nagare.Platform.StateTransfer
import Numeric.Natural (Natural)

data VerificationMode = CandidateMaintenanceBypass | OldPublicService
  deriving stock (Eq, Show)

data WriteGate = WritesFenced | WritesAdmitted
  deriving stock (Eq, Show)

data Revalidation = Revalidation
  { revalidatedDriftToken :: !Text
  , revalidatedIdentitiesMatch :: !Bool
  , revalidatedEvidenceValidUntil :: !(Maybe UTCTime)
  , revalidatedQuiesceContractComplete :: !Bool
  }
  deriving stock (Eq, Show)

newtype QuiesceSnapshot = QuiesceSnapshot {quiesceSnapshotToken :: Text}
  deriving stock (Eq, Show)

data QuiesceResult = QuiesceResult
  { quiesceSnapshot :: !QuiesceSnapshot
  , firstWriteDeniedAt :: !UTCTime
  , firstWriteDeniedMonotonic :: !MonotonicTime
  }
  deriving stock (Eq, Show)

data PublicEvidence = PublicEvidence
  { publicEvidenceToken :: !Text
  , publicDnsUnchanged :: !Bool
  , publicTlsValid :: !Bool
  , publicAuthValid :: !Bool
  , publicRoutingValid :: !Bool
  , publicDataValid :: !Bool
  }
  deriving stock (Eq, Show)

data CutoverObservation = CutoverObservation
  { observedAddressOwner :: !AddressOwner
  , observedOldPower :: !InstancePower
  , observedCandidateFenced :: !Bool
  , observedContextCommitted :: !Bool
  , observedCandidateWritesAdmitted :: !Bool
  , observedOldPublicHealthy :: !Bool
  }
  deriving stock (Eq, Show)

data CutoverOps = CutoverOps
  { cutoverConfirmation :: !Text
  , cutoverStatePlan :: !StateTransferPlan
  , monotonicNow :: !(IO MonotonicTime)
  , wallNow :: !(IO UTCTime)
  , persistCutover :: !(ReplacementTransaction -> IO ())
  , revalidate :: !(ReplacementTransaction -> IO (Either Text Revalidation))
  , armCandidate :: !(ReplacementTransaction -> IO (Either Text Text))
  , quiesceOld :: !(ReplacementTransaction -> IO (Either Text QuiesceResult))
  , finalizeState :: !(Deadline -> StateTransferPlan -> IO (Either Text FinalStateEvidence))
  , prepareCandidateIngress :: !(ReplacementTransaction -> IO (Either Text Text))
  , observeCutover :: !(ReplacementTransaction -> IO (Either Text CutoverObservation))
  , detachAddress :: !(HostIdentity -> IO (Either Text ()))
  , attachAddress :: !(HostIdentity -> IO (Either Text ()))
  , verifyPublic :: !(VerificationMode -> IO (Either Text PublicEvidence))
  , commitContext :: !(ReplacementTransaction -> IO (Either Text ()))
  , restoreContext :: !(ReplacementTransaction -> IO (Either Text ()))
  , setWriteGate :: !(HostIdentity -> WriteGate -> IO (Either Text ()))
  , setInstancePower :: !(HostIdentity -> InstancePower -> IO (Either Text ()))
  , restoreOldWorkloads :: !(QuiesceSnapshot -> IO (Either Text ()))
  , cancelForwardWork :: !(IO ())
  }

data CutoverError = CutoverError
  { cutoverErrorPhase :: !(Maybe CutoverPhase)
  , cutoverErrorMessage :: !Text
  , cutoverRecoveryAttempted :: !Bool
  , cutoverRecoveryError :: !(Maybe Text)
  , cutoverErrorTransaction :: !ReplacementTransaction
  }
  deriving stock (Eq, Show)

data Reconciliation
  = ResumePreDowntime
  | RollbackRequired ReplacementTransaction
  | OldServiceRestored ReplacementTransaction
  | CommitPointObserved ReplacementTransaction
  | ManualRecoveryRequired ReplacementTransaction Text
  deriving stock (Eq, Show)

data CleanupOps = CleanupOps
  { cleanupConfirmation :: !Text
  , cleanupNow :: !(IO UTCTime)
  , persistCleanup :: !(ReplacementTransaction -> IO ())
  , cleanupPublicHealthy :: !(IO (Either Text Bool))
  , cleanupEvidenceRetained :: !(ReplacementTransaction -> IO (Either Text Bool))
  , cleanupResourceOwned :: !(ReplacementTransaction -> RetainedResource -> IO (Either Text Bool))
  , deleteRecordedResource :: !(RetainedResource -> IO (Either Text ()))
  , convergeActiveOnly :: !(ReplacementTransaction -> IO (Either Text ()))
  , pruneTransactionArtifacts :: !(ReplacementTransaction -> IO (Either Text ()))
  }

data CleanupError = CleanupError
  { cleanupErrorMessage :: !Text
  , cleanupErrorTransaction :: !ReplacementTransaction
  }
  deriving stock (Eq, Show)

runCutover :: CutoverOps -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
runCutover ops initial
  | cutoverConfirmation ops /= replacementConfirmation initial = pure (Left (plainError Nothing "confirmation token does not match context/transaction" initial))
  | replacementState initial /= Ready = pure (Left (plainError Nothing "replacement transaction is not ready" initial))
  | replacementWritesAdmitted initial = pure (Left (plainError Nothing "candidate writes were already admitted; automatic cutover replay is unsafe" initial))
  | Left message <- validateStateTransferPlan (cutoverStatePlan ops) = pure (Left (plainError Nothing message initial))
  | stateTransferDriftToken (cutoverStatePlan ops) /= replacementExpectedDriftToken initial = pure (Left (plainError Nothing "state-transfer plan drift token does not match the transaction" initial))
  | stateTransferPredictedSeconds (cutoverStatePlan ops) /= replacementPredictedStateSeconds initial = pure (Left (plainError Nothing "state-transfer prediction does not match the transaction budget input" initial))
  | otherwise = do
      checked <- runRevalidation ops initial
      case checked of
        Left err -> pure (Left err)
        Right preflight -> do
          armed <- runSimpleStep ops Nothing ArmCandidate (armCandidate ops preflight) preflight
          case armed of
            Left err -> pure (Left err)
            Right armedTx -> do
              rechecked <- runRevalidation ops armedTx
              case rechecked of
                Left err -> pure (Left err)
                Right readyTx -> beginDowntime ops readyTx

beginDowntime :: CutoverOps -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
beginDowntime ops tx = do
  now <- wallNow ops
  let intended = (recordPhaseIntent now QuiesceOld tx) {replacementState = CuttingOver}
  persistCutover ops intended
  outcome <- quiesceOld ops intended
  case outcome of
    Left message -> autoRollback ops QuiesceOld message intended
    Right result -> do
      completedAt <- wallNow ops
      let started = firstWriteDeniedMonotonic result
          deadline = beginDeadline started (replacementBudget tx)
          quiesced =
            (recordPhaseComplete completedAt QuiesceOld (quiesceSnapshotToken (quiesceSnapshot result)) intended)
              { replacementDowntimeStartedAt = Just (firstWriteDeniedAt result)
              , replacementDowntimeStartedMonotonic = Just started
              }
      persistCutover ops quiesced
      finalResult <- guardedStep ops deadline FinalizeState (finalizeState ops deadline (cutoverStatePlan ops)) finalEvidence quiesced
      continue deadline finalResult
  where
    finalEvidence evidence
      | finalStateVerified evidence = Right (T.intercalate "," (finalStateCommitTokens evidence))
      | otherwise = Left "final state transfer returned unverified evidence"
    continue _ (Left err) = pure (Left err)
    continue deadline (Right finalized) = do
      ingress <- guardedSimple ops deadline PrepareCandidateIngress (prepareCandidateIngress ops finalized) finalized
      case ingress of
        Left err -> pure (Left err)
        Right prepared -> handoffAndCommit ops deadline prepared

handoffAndCommit :: CutoverOps -> Deadline -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
handoffAndCommit ops deadline tx = do
  detached <- guardedUnit ops deadline DetachOldAddress (detachAddress ops (replacementOldHost tx)) tx
  case detached of
    Left err -> pure (Left err)
    Right oldDetached -> do
      observedDetached <- requireAddress ops deadline DetachOldAddress AddressUnattached oldDetached
      case observedDetached of
        Left err -> pure (Left err)
        Right verifiedDetached -> do
          attached <- guardedUnit ops deadline AttachCandidateAddress (attachAddress ops (replacementCandidateHost tx)) verifiedDetached
          case attached of
            Left err -> pure (Left err)
            Right candidateAttached -> do
              observedAttached <- requireAddress ops deadline AttachCandidateAddress AddressOnCandidate candidateAttached
              case observedAttached of
                Left err -> pure (Left err)
                Right verifiedAttached -> verifyAndCommit ops deadline verifiedAttached

verifyAndCommit :: CutoverOps -> Deadline -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
verifyAndCommit ops deadline tx = do
  verified <- guardedStep ops deadline VerifyPublic (verifyPublic ops CandidateMaintenanceBypass) validatePublic tx
  case verified of
    Left err -> pure (Left err)
    Right publicTx -> do
      contextResult <- guardedUnit ops deadline CommitContext (commitContext ops publicTx) publicTx
      case contextResult of
        Left err -> pure (Left err)
        Right contextTx -> do
          let committedContext = contextTx {replacementContextCommitted = True}
          persistCutover ops committedContext
          admission <- admitCandidateWrites ops deadline committedContext
          case admission of
            Left err -> pure (Left err)
            Right admitted -> do
              committedAt <- wallNow ops
              current <- monotonicNow ops
              let committed =
                    admitted
                      { replacementState = Committed
                      , replacementCandidateFenced = False
                      , replacementWritesAdmitted = True
                      , replacementRollbackEligible = False
                      , replacementObservedDowntimeSeconds = elapsedFrom admitted current
                      , replacementUpdatedAt = committedAt
                      }
              persistCutover ops committed
              stopped <- runSimpleStep ops Nothing StopOld (unitEvidence "old instance stopped" (setInstancePower ops (replacementOldHost tx) InstanceStopped)) committed
              case stopped of
                Left err -> pure (Left err {cutoverRecoveryAttempted = False})
                Right final -> do
                  let retained = final {replacementOldPower = InstanceStopped}
                  persistCutover ops retained
                  pure (Right retained)
  where
    validatePublic evidence
      | and [publicDnsUnchanged evidence, publicTlsValid evidence, publicAuthValid evidence, publicRoutingValid evidence, publicDataValid evidence] = Right (publicEvidenceToken evidence)
      | otherwise = Left "public verification evidence is incomplete"

runRollback :: CutoverOps -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
runRollback = rollbackInternal

rollbackInternal :: CutoverOps -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
rollbackInternal ops initial = do
  observed <- observeCutover ops initial
  case observed of
    Left message -> rollbackFailure ops FenceCandidate ("could not observe write admission before rollback: " <> message) initial
    Right actual
      | replacementWritesAdmitted initial || observedCandidateWritesAdmitted actual -> fenceForManualRecovery actual
      | otherwise -> rollbackPreCommit actual
  where
    fenceForManualRecovery actual = do
      gateResult <- setWriteGate ops (replacementCandidateHost initial) WritesFenced
      afterFence <- observeCutover ops initial
      now <- wallNow ops
      let actuallyFenced = either (const False) observedCandidateFenced afterFence
          detail = case gateResult of
            Left message -> "automatic rollback is disabled after candidate write admission; fencing also failed: " <> message
            Right () | actuallyFenced -> "automatic rollback is disabled after candidate write admission; candidate writes were fenced for manual recovery"
            Right () -> "automatic rollback is disabled after candidate write admission; the candidate write gate could not be observed fenced"
      let fenced =
            initial
              { replacementCandidateFenced = actuallyFenced
              , replacementWritesAdmitted = observedCandidateWritesAdmitted actual
              , replacementState = ReplacementFailed
              , replacementLastError = Just detail
              , replacementUpdatedAt = now
              }
      persistCutover ops fenced
      pure (Left (plainError (Just FenceCandidate) detail fenced))
    rollbackPreCommit actual = do
      cancelForwardWork ops
      now <- wallNow ops
      let rolling =
            initial
              { replacementState = RollingBack
              , replacementRollbackEligible = True
              , replacementAddressOwner = observedAddressOwner actual
              , replacementOldPower = observedOldPower actual
              , replacementCandidateFenced = observedCandidateFenced actual
              , replacementContextCommitted = observedContextCommitted actual
              , replacementUpdatedAt = now
              }
      persistCutover ops rolling
      fencedResult <- runSimpleStep ops Nothing FenceCandidate (unitEvidence "candidate fenced" (setWriteGate ops (replacementCandidateHost rolling) WritesFenced)) rolling
      case fencedResult of
        Left err -> pure (Left err)
        Right fenced -> do
          observed <- observeCutover ops fenced
          case observed of
            Left message -> rollbackFailure ops RestoreOldAddress message fenced
            Right afterFence ->
              let observedTx =
                    fenced
                      { replacementAddressOwner = observedAddressOwner afterFence
                      , replacementOldPower = observedOldPower afterFence
                      , replacementCandidateFenced = observedCandidateFenced afterFence
                      , replacementContextCommitted = observedContextCommitted afterFence
                      , replacementWritesAdmitted = observedCandidateWritesAdmitted afterFence
                      }
               in if observedCandidateWritesAdmitted afterFence
                    then fenceForManualRecovery afterFence
                    else restoreAddress ops observedTx afterFence
    restoreAddress localOps tx actual = do
      addressResult <- case observedAddressOwner actual of
        AddressOnOld -> pure (Right tx)
        AddressOnCandidate -> do
          detached <- runSimpleStep localOps Nothing RestoreOldAddress (unitEvidence "candidate address detached" (detachAddress localOps (replacementCandidateHost tx))) tx
          case detached of
            Left err -> pure (Left err)
            Right detachedTx -> runSimpleStep localOps Nothing RestoreOldAddress (unitEvidence "old address restored" (attachAddress localOps (replacementOldHost tx))) detachedTx
        AddressUnattached -> runSimpleStep localOps Nothing RestoreOldAddress (unitEvidence "old address restored" (attachAddress localOps (replacementOldHost tx))) tx
        AddressAmbiguous -> rollbackFailure localOps RestoreOldAddress "reserved address attachment is ambiguous" tx
      case addressResult of
        Left err -> pure (Left err)
        Right addressed -> finishRollback localOps addressed

finishRollback :: CutoverOps -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
finishRollback ops tx = do
  powered <- runSimpleStep ops Nothing RestoreOldWorkloads (unitEvidence "old instance running" (setInstancePower ops (replacementOldHost tx) InstanceRunning)) tx
  case powered of
    Left err -> pure (Left err)
    Right running -> do
      contextRestored <-
        if replacementContextCommitted running
          then runSimpleStep ops Nothing RestoreOldWorkloads (unitEvidence "old context restored" (restoreContext ops running)) running
          else pure (Right running)
      case contextRestored of
        Left err -> pure (Left err)
        Right contextTx -> do
          let snapshot = QuiesceSnapshot (maybe "captured-quiesce-snapshot" id (checkpointEvidence (phaseCheckpoint QuiesceOld contextTx)))
          workloads <- runSimpleStep ops Nothing RestoreOldWorkloads (unitEvidence "old workloads restored" (restoreOldWorkloads ops snapshot)) contextTx
          case workloads of
            Left err -> pure (Left err)
            Right restored -> do
              healthy <- runSimpleStep ops Nothing VerifyRollback (verifyPublic ops OldPublicService >>= pure . (>>= validateOld)) restored
              case healthy of
                Left err -> pure (Left err)
                Right verified -> do
                  now <- wallNow ops
                  mono <- monotonicNow ops
                  let rolledBack =
                        verified
                          { replacementState = RolledBack
                          , replacementAddressOwner = AddressOnOld
                          , replacementOldPower = InstanceRunning
                          , replacementCandidateFenced = True
                          , replacementContextCommitted = False
                          , replacementWritesAdmitted = False
                          , replacementObservedDowntimeSeconds = elapsedFrom verified mono
                          , replacementSloBreached = maybe False (> totalSeconds (replacementBudget verified)) (elapsedFrom verified mono)
                          , replacementUpdatedAt = now
                          }
                  persistCutover ops rolledBack
                  pure (Right rolledBack)
  where
    validateOld evidence
      | and [publicDnsUnchanged evidence, publicTlsValid evidence, publicAuthValid evidence, publicRoutingValid evidence, publicDataValid evidence] = Right (publicEvidenceToken evidence)
      | otherwise = Left "old public service did not pass rollback verification"

reconcileCutover :: CutoverOps -> ReplacementTransaction -> IO (Either CutoverError Reconciliation)
reconcileCutover ops tx = do
  observation <- observeCutover ops tx
  case observation of
    Left message -> pure (Left (plainError (replacementPhase tx) ("could not reconcile actual cutover state: " <> message) tx))
    Right actual -> do
      now <- wallNow ops
      let reconciled =
            tx
              { replacementAddressOwner = observedAddressOwner actual
              , replacementOldPower = observedOldPower actual
              , replacementCandidateFenced = observedCandidateFenced actual
              , replacementContextCommitted = observedContextCommitted actual
              , replacementWritesAdmitted = observedCandidateWritesAdmitted actual
              , replacementUpdatedAt = now
              }
      persistCutover ops reconciled
      pure . Right $
        if observedCandidateWritesAdmitted actual
          then CommitPointObserved reconciled
          else case replacementState tx of
            CuttingOver -> RollbackRequired reconciled
            RollingBack -> RollbackRequired reconciled
            _
              | observedAddressOwner actual == AddressOnOld && observedOldPublicHealthy actual -> OldServiceRestored reconciled
              | replacementDowntimeStartedAt tx == Nothing -> ResumePreDowntime
              | otherwise -> ManualRecoveryRequired reconciled "observed state is not a safe old-service state and no write-admission commit point was observed"

finalizeReplacement :: Bool -> CleanupOps -> ReplacementTransaction -> IO (Either CleanupError ReplacementTransaction)
finalizeReplacement nowOverride ops initial
  | cleanupConfirmation ops /= replacementConfirmation initial = pure (Left (cleanupFailure "confirmation token does not match context/transaction" initial))
  | replacementState initial `notElem` [Committed, Finalizing] = pure (Left (cleanupFailure "only a committed or partially finalizing replacement can be finalized" initial))
  | replacementState initial == Committed && null (replacementRetainedResources initial) = pure (Left (cleanupFailure "transaction records no former-active resources to finalize" initial))
  | otherwise = do
      now <- cleanupNow ops
      case replacementRetentionUntil initial of
        Just retention | not nowOverride && now < retention -> pure (Left (cleanupFailure "former-active retention period has not elapsed; pass --now only after explicit acceptance" initial))
        _ -> do
          health <- cleanupPublicHealthy ops
          evidence <- cleanupEvidenceRetained ops initial
          case (health, evidence) of
            (Left err, _) -> pure (Left (cleanupFailure ("public health check failed: " <> err) initial))
            (_, Left err) -> pure (Left (cleanupFailure ("evidence retention check failed: " <> err) initial))
            (Right False, _) -> pure (Left (cleanupFailure "current public service is unhealthy" initial))
            (_, Right False) -> pure (Left (cleanupFailure "required backup or replacement evidence is not retained" initial))
            (Right True, Right True) -> validateOwnership now
  where
    validateOwnership now = do
      checks <- mapM (cleanupResourceOwned ops initial) (replacementRetainedResources initial)
      case sequence checks of
        Left err -> pure (Left (cleanupFailure ("resource ownership check failed: " <> err) initial))
        Right owned
          | not (and owned) -> pure (Left (cleanupFailure "cleanup refused an unrecorded or role-mismatched resource" initial))
          | otherwise -> do
              let finalizing = (recordPhaseIntent now CleanupFormerActive initial) {replacementState = Finalizing}
              persistCleanup ops finalizing
              deleted <- runCleanupList ops finalizing (replacementRetainedResources initial)
              case deleted of
                Left err -> pure (Left err)
                Right cleaned -> do
                  converged <- convergeActiveOnly ops cleaned
                  pruned <- pruneTransactionArtifacts ops cleaned
                  case (converged, pruned) of
                    (Left err, _) -> pure (Left (cleanupFailure ("active-only convergence failed: " <> err) cleaned))
                    (_, Left err) -> pure (Left (cleanupFailure ("transaction artifact pruning failed: " <> err) cleaned))
                    (Right (), Right ()) -> do
                      finishedAt <- cleanupNow ops
                      let complete =
                            (recordPhaseComplete finishedAt CleanupFormerActive "recorded former-active resources deleted; active-only convergence verified" cleaned)
                              { replacementState = Complete
                              , replacementRetainedResources = []
                              }
                      persistCleanup ops complete
                      pure (Right complete)

runCleanupList :: CleanupOps -> ReplacementTransaction -> [RetainedResource] -> IO (Either CleanupError ReplacementTransaction)
runCleanupList _ tx [] = pure (Right tx)
runCleanupList ops tx (resource : rest) = do
  deleted <- deleteRecordedResource ops resource
  case deleted of
    Left err -> pure (Left (cleanupFailure ("failed to delete recorded resource " <> retainedResourceId resource <> ": " <> err) tx))
    Right () -> do
      let remaining = tx {replacementRetainedResources = filter ((/= retainedResourceId resource) . retainedResourceId) (replacementRetainedResources tx)}
      persistCleanup ops remaining
      runCleanupList ops remaining rest

runRevalidation :: CutoverOps -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
runRevalidation ops tx = do
  now <- wallNow ops
  let intended = recordPhaseIntent now Revalidate tx
  persistCutover ops intended
  result <- revalidate ops intended
  case result of
    Left message -> pure (Left (plainError (Just Revalidate) message intended))
    Right evidence -> do
      observedAt <- wallNow ops
      let checked =
            (recordPhaseComplete observedAt Revalidate (revalidatedDriftToken evidence) intended)
              { replacementObservedDriftToken = revalidatedDriftToken evidence
              , replacementIdentitiesMatch = revalidatedIdentitiesMatch evidence
              , replacementEvidenceValidUntil = revalidatedEvidenceValidUntil evidence
              , replacementQuiesceContractComplete = revalidatedQuiesceContractComplete evidence
              }
          report = readiness observedAt checked
      persistCutover ops checked
      if ready report
        then pure (Right checked)
        else pure (Left (plainError (Just Revalidate) ("cutover readiness failed: " <> T.intercalate "; " (blockers report)) checked))

guardedSimple :: CutoverOps -> Deadline -> CutoverPhase -> IO (Either Text Text) -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
guardedSimple ops deadline phase action tx = guardedStep ops deadline phase action Right tx

guardedUnit :: CutoverOps -> Deadline -> CutoverPhase -> IO (Either Text ()) -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
guardedUnit ops deadline phase action tx = guardedSimple ops deadline phase (unitEvidence (phaseLabel phase <> " complete") action) tx

guardedStep :: CutoverOps -> Deadline -> CutoverPhase -> IO (Either Text a) -> (a -> Either Text Text) -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
guardedStep ops deadline phase action evidence tx = do
  before <- monotonicNow ops
  if deadlineExpired before deadline
    then autoRollback ops phase "forward-work cutoff reached; rollback reserve preserved" tx
    else do
      result <- runStep ops phase action evidence tx
      case result of
        Left err -> autoRollback ops phase (cutoverErrorMessage err) (cutoverErrorTransaction err)
        Right completed -> do
          after <- monotonicNow ops
          if deadlineExpired after deadline
            then autoRollback ops phase "forward-work cutoff reached after phase completion; entering rollback" completed
            else pure (Right completed)

runSimpleStep :: CutoverOps -> Maybe Deadline -> CutoverPhase -> IO (Either Text Text) -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
runSimpleStep ops _ phase action = runStep ops phase action Right

runStep :: CutoverOps -> CutoverPhase -> IO (Either Text a) -> (a -> Either Text Text) -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
runStep ops phase action evidence tx = do
  now <- wallNow ops
  let intended = recordPhaseIntent now phase tx
  persistCutover ops intended
  result <- action
  case result >>= evidence of
    Left message -> pure (Left (plainError (Just phase) message intended))
    Right token -> do
      completedAt <- wallNow ops
      let completed = recordPhaseComplete completedAt phase token intended
      persistCutover ops completed
      pure (Right completed)

requireAddress :: CutoverOps -> Deadline -> CutoverPhase -> AddressOwner -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
requireAddress ops deadline phase expected tx = do
  now <- monotonicNow ops
  if deadlineExpired now deadline
    then autoRollback ops phase "forward-work cutoff reached while observing the reserved address" tx
    else do
      observed <- observeCutover ops tx
      case observed of
        Left message -> autoRollback ops phase ("address observation failed: " <> message) tx
        Right actual
          | observedAddressOwner actual /= expected -> autoRollback ops phase ("reserved address observation was " <> T.pack (show (observedAddressOwner actual)) <> ", expected " <> T.pack (show expected)) tx
          | otherwise -> do
              let checked = tx {replacementAddressOwner = expected}
              persistCutover ops checked
              pure (Right checked)

admitCandidateWrites :: CutoverOps -> Deadline -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
admitCandidateWrites ops deadline tx = do
  before <- monotonicNow ops
  if deadlineExpired before deadline
    then autoRollback ops AdmitCandidateWrites "forward-work cutoff reached before write admission" tx
    else do
      now <- wallNow ops
      let intended = recordPhaseIntent now AdmitCandidateWrites tx
      persistCutover ops intended
      result <- setWriteGate ops (replacementCandidateHost tx) WritesAdmitted
      observed <- observeCutover ops intended
      case observed of
        Right actual | observedCandidateWritesAdmitted actual -> do
          completedAt <- wallNow ops
          let admitted =
                (recordPhaseComplete completedAt AdmitCandidateWrites "candidate write admission observed" intended)
                  { replacementCandidateFenced = False
                  , replacementWritesAdmitted = True
                  , replacementRollbackEligible = False
                  , replacementLastError = either Just (const Nothing) result
                  }
          persistCutover ops admitted
          pure (Right admitted)
        _ -> case result of
          Left message -> autoRollback ops AdmitCandidateWrites message intended
          Right () -> autoRollback ops AdmitCandidateWrites "write-admission command succeeded but the candidate gate remained fenced" intended

autoRollback :: CutoverOps -> CutoverPhase -> Text -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
autoRollback ops phase message tx = do
  rolled <- rollbackInternal ops (tx {replacementLastError = Just message})
  case rolled of
    Right recovered -> pure (Left (CutoverError (Just phase) message True Nothing recovered))
    Left recovery ->
      pure
        ( Left
            ( CutoverError
                (Just phase)
                message
                True
                (Just (cutoverErrorMessage recovery))
                (cutoverErrorTransaction recovery)
            )
        )

rollbackFailure :: CutoverOps -> CutoverPhase -> Text -> ReplacementTransaction -> IO (Either CutoverError ReplacementTransaction)
rollbackFailure ops phase message tx = do
  now <- wallNow ops
  let failed = tx {replacementState = ReplacementFailed, replacementLastError = Just message, replacementUpdatedAt = now}
  persistCutover ops failed
  pure (Left (plainError (Just phase) message failed))

elapsedFrom :: ReplacementTransaction -> MonotonicTime -> Maybe Natural
elapsedFrom tx (MonotonicTime now) = do
  MonotonicTime started <- replacementDowntimeStartedMonotonic tx
  pure (if now >= started then now - started else 0)

unitEvidence :: Text -> IO (Either Text ()) -> IO (Either Text Text)
unitEvidence label action = fmap (fmap (const label)) action

phaseLabel :: CutoverPhase -> Text
phaseLabel = T.pack . show

plainError :: Maybe CutoverPhase -> Text -> ReplacementTransaction -> CutoverError
plainError phase message tx = CutoverError phase message False Nothing tx

cleanupFailure :: Text -> ReplacementTransaction -> CleanupError
cleanupFailure = CleanupError
