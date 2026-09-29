{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Lock-scoped admission, execution, and recovery of reviewed plans.
module Nagare.Inventory.Execute
  ( AdmissionError (..)
  , ExecutablePlan
  , TransactionResult (..)
  , withProcessLock
  , admit
  , execute
  , applyReviewed
  , resumeTransaction
  , resumeTransactionWithTakeover
  , OperatorRecoveryInput (..)
  , RecoveryAction (..)
  , decodeOperatorRecoveryInput
  , recordOperatorRecovery
  )
where

import Control.Exception (bracket)
import Control.Monad (foldM, forM, forM_)
import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.DataFence
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Inventory.Migration.Types (MigrationContract (..))
import Nagare.Inventory.Plan
import Nagare.Inventory.OperationStep
import Nagare.Inventory.Store
import Nagare.Resource.Inventory (Executor (..))
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Policy (DataPolicy (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope)
import System.Environment (lookupEnv, setEnv, unsetEnv)

data AdmissionError = AdmissionError
  { admissionErrorCode :: !Text
  , admissionErrorMessage :: !Text
  }
  deriving stock (Eq, Show, Generic)

data RecoveryAction
  = AcceptAdapterProof
  | RetryAfterAdapterProof
  | ContinueFencedOperation
  | VerifyFencedEffect
  | RecoverFencedBackup
  | ForwardFencedRelease
  | AbandonPartialPrune
  | AbandonPartialVolumeRestore
  | AbandonPartialDatabaseRestore
  deriving stock (Eq, Show)

data OperatorRecoveryInput = OperatorRecoveryInput
  { recoveryTransaction :: !TransactionId
  , recoveryOperation :: !OperationId
  , recoveryReview :: !ContentDigest
  , recoveryAction :: !RecoveryAction
  }
  deriving stock (Eq, Show)

decodeOperatorRecoveryInput :: ByteString -> Either Text OperatorRecoveryInput
decodeOperatorRecoveryInput = first T.pack . eitherDecodeStrict'

instance FromJSON OperatorRecoveryInput where
  parseJSON = withObject "OperatorRecoveryInput" $ \o -> do
    unless (all (`elem` ["version", "transaction", "operation", "review", "action"]) (KM.keys o))
      (fail "operator recovery input has an unknown field")
    version <- o .: "version" :: Parser Int
    unless (version == 1) (fail "unsupported operator recovery version")
    action <- o .: "action" :: Parser Text
    decision <- case action of
      "accept-adapter-proof" -> pure AcceptAdapterProof
      "retry-after-adapter-proof" -> pure RetryAfterAdapterProof
      "continue-fenced-operation" -> pure ContinueFencedOperation
      "verify-fenced-effect" -> pure VerifyFencedEffect
      "recover-fenced-backup" -> pure RecoverFencedBackup
      "forward-fenced-release" -> pure ForwardFencedRelease
      "abandon-partial-prune" -> pure AbandonPartialPrune
      "abandon-partial-volume-restore" -> pure AbandonPartialVolumeRestore
      "abandon-partial-database-restore" -> pure AbandonPartialDatabaseRestore
      _ -> fail "unsupported operator recovery action"
    OperatorRecoveryInput <$> o .: "transaction" <*> o .: "operation"
      <*> o .: "review" <*> pure decision

data ExecutablePlan s = ExecutablePlan
  { executableTransaction :: !TransactionId
  , executableReviewed :: !ReviewedPlan
  }

data TransactionResult
  = Converged !TransactionId
  | PausedAtBarrier !TransactionId !(NonEmpty ReviewBarrier)
  | StoppedFailed !TransactionId !OperationId !FailureClass
  | StoppedAmbiguous !TransactionId !OperationId
  deriving stock (Eq, Show, Generic)

admit :: LockedStore s -> AdapterRegistry -> ReviewedPlan -> IO (Either (NonEmpty AdmissionError) (ExecutablePlan s))
admit locked registry reviewed = do
  let store = lockedStore locked
      document = reviewedDocument reviewed
      transaction = transactionFor document
  headResult <- readHead store
  case headResult of
    Left err -> pure (failure "store" (showText err))
    Right Nothing -> pure (failure "store" "inventory store is not initialized")
    Right (Just headValue) -> do
      let staticErrors =
            [AdmissionError "context-binding" "review belongs to a different context or provider target" | reviewContextBinding document /= headBinding headValue]
              <> [AdmissionError "deferred-operation" "new live database restores and interactive maintenance sessions are deferred; recover an already-admitted transaction by its original ID"
                 | operation <- reviewOperations document
                 , plannedAction (reviewPlannedOperation operation) `elem`
                     [RestoreLiveDatabase, OpenMaintenanceSession]]
              <> [AdmissionError "stale-head" "review was issued against a different head generation or journal sequence" | reviewHeadGeneration document /= headGeneration headValue || reviewHeadSequence document /= headSequence headValue]
              <> [AdmissionError "stale-base" "review base revisions differ from accepted desired state" | reviewBaseRevisions document /= headAccepted headValue]
              <> [AdmissionError "active-transaction" "another transaction is unresolved" | isJust (headActiveTransaction headValue)]
              <> [AdmissionError "active-data-fence" "a live data target remains fenced; recover and verify it before applying another review" | isJust (headDataFence headValue)]
              <> [AdmissionError "retention-base" "retention proof does not name the accepted scope revision"
                 | (_, proof) <- Map.toAscList (reviewRetentions document)
                 , Map.lookup (retentionOwner proof) (headAccepted headValue) /= Just (retentionRevision proof)]
              <> [AdmissionError "retention-history" "retained resource already has a historical incarnation"
                 | resource <- Map.keys (reviewRetentions document), Map.member resource (headRetained headValue)]
              <> [AdmissionError "migration-base" "migration source differs from the accepted scope revision"
                 | (resource, proof) <- Map.toAscList (reviewMigrations document)
                 , Map.lookup (migrationProofOwner proof) (headAccepted headValue)
                     /= Just (migrationProofRevision proof)
                   || Map.member resource (headRetained headValue)
                   || Map.member resource (headCollected headValue)]
              <> validateOperationInputs registry reviewed Map.empty
      case staticErrors of
        firstError : rest -> pure (Left (firstError :| rest))
        [] -> do
          deferred <- deferredScheduledPrune store headValue document
          case deferred of
            Left err -> pure (failure "deferred-operation" err)
            Right True -> pure (failure "deferred-operation"
              "new scheduled pruning is deferred; recover an already-admitted partial prune by its original review")
            Right False -> do
              coverage <- retentionCoverage store document
              continueAdmission store document transaction headValue coverage
  where
    continueAdmission store document transaction headValue coverage = case coverage of
            Left err -> pure (failure "retention-coverage" err)
            Right retainedRequests -> do
              migrationChecked <- migrationCoverage store document
              migrationSourceErrors <- case migrationChecked of
                Left _ -> pure []
                Right () -> migrationAdmissionChecks registry reviewed
              let sourceChecked = case migrationSourceErrors of
                    [] -> Right ()
                    firstError : _ -> Left (admissionErrorMessage firstError)
              checked <- if Map.null retainedRequests
                then pure (Right ())
                else do
                  observed <- observeWithRegistry registry retainedRequests
                  pure $ do
                    facts <- observed
                    forM_ (Map.toAscList (reviewRetentions document)) $ \(resource, proof) ->
                      unless (Map.lookup resource (observationMap facts)
                        == Just (ObservedPresent (retentionPhysical proof)))
                        (Left "retained physical incarnation changed since review")
              case migrationChecked >> sourceChecked of
                Left err -> pure (failure "migration-coverage" err)
                Right () -> case checked of
                  Left _ -> pure (failure "retention-observation" "retained physical incarnation could not be reverified")
                  Right () -> do
                    now <- timestamp
                    let client = maybe (headClientIdentity headValue) id (storeClientIdentity store)
                        claim = ExecutorClaim (transactionIdText transaction) client 1 now
                        retained = Map.map (\proof -> RetainedIncarnation
                          (retentionOwner proof) (retentionRevision proof)
                          (retentionPhysical proof) now Nothing) (reviewRetentions document)
                        migrated = Map.map (\proof -> RetainedIncarnation
                          (migrationProofOwner proof) (migrationProofRevision proof)
                          (migrationProofPhysical proof) now
                          (Just (reviewDocumentDigest document))) (reviewMigrations document)
                        activated = headValue
                          { headGeneration = headGeneration headValue + 1
                          , headAccepted = reviewDesiredRevisions document
                          , headRetained = Map.unions [retained, migrated, headRetained headValue]
                          , headActiveTransaction = Just (transactionIdText transaction)
                          , headExecutorClaim = Just claim
                          }
                    activation <- replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) activated
                    case activation of
                      Left err -> pure (failure "head-condition" (showText err))
                      Right () -> do
                        event <- appendEvent locked transaction Nothing Pending ("admitted review " <> digestText (reviewDocumentDigest document))
                        pure $ case event of
                          Left err -> failure "journal" (showText err)
                          Right _ -> Right (ExecutablePlan transaction reviewed)

-- Inspect the stored scope member, rather than trusting a public review's
-- operation summary. Receipt-only recovery carries a distinct accepted failed
-- review and stays available through the existing provider preflight.
deferredScheduledPrune :: InventoryStore -> HeadManifest -> ReviewDocument
  -> IO (Either Text Bool)
deferredScheduledPrune store headValue document = do
  checked <- forM changed $ \(_, revision) -> do
    member <- readObject store (scopeKey (revisionDigest revision))
    pure $ do
      bytes <- first showText member >>= maybe
        (Left "reviewed scope member is missing") Right
      scope <- first showText (decodeScope bytes)
      let fields = Resource.scopeOverrides scope
      pure (Map.member "scheduled.prune.backup.scope" fields
        && Map.notMember "scheduled.prune.recovery.review" fields)
  pure (or <$> sequence checked)
  where
    changed = [(scope, revision)
      | (scope, revision) <- Map.toAscList (reviewDesiredRevisions document)
      , Map.lookup scope (headAccepted headValue) /= Just revision]

-- | No accepted managed declaration may disappear solely because a scope
-- revision was replaced. A reviewed retention proof is required for every
-- disappeared identity; a transferred identity remains in the desired set.
retentionCoverage :: InventoryStore -> ReviewDocument -> IO (Either Text (Map Executor [ResourceId]))
retentionCoverage store document = do
  historical <- loadInventoryHistory store
  desired <- traverse loadDesired (Map.elems (reviewDesiredRevisions document))
  pure $ do
    history <- first showText historical
    scopes <- sequence desired
    desiredDeclarations <- first showText (Resource.composedDeclarations
      (Map.fromList [(Resource.scopeId scope, scope) | scope <- scopes]))
    oldDeclarations <- first showText (Resource.composedDeclarations
      (fmap snd (historyAccepted history)))
    let desiredIds = Set.fromList (map Resource.declarationId desiredDeclarations)
        removedChildren =
          [resource | Resource.ObservedChild resource _ _ _ _ <- oldDeclarations,
            Set.notMember resource desiredIds]
        removed = Map.fromList
          [(resource ^. #identity, (resource ^. #owner, revision, resource ^. #executor))
          | Resource.Managed resource <- oldDeclarations
          , Just (revision, _) <- [Map.lookup (resource ^. #owner) (historyAccepted history)]
          , Set.notMember (resource ^. #identity) desiredIds]
        proofs = reviewRetentions document
    unless (null removedChildren)
      (Left "observed controller children cannot disappear without retained child claims")
    let previouslyActive = Set.fromList (map Resource.declarationId oldDeclarations)
    unless (Set.null (Set.difference
      (Set.intersection desiredIds (Map.keysSet (headRetained (historyHead history))))
      previouslyActive))
      (Left "retained logical identity cannot be reactivated without reviewed recovery")
    unless (Set.null (Set.intersection desiredIds (Map.keysSet (headCollected (historyHead history)))))
      (Left "collected logical identity cannot be reused after its deletion tombstone")
    unless (Map.keysSet removed == Map.keysSet proofs)
      (Left "removed managed resources require exactly one retained-incarnation proof")
    forM_ (Map.toAscList proofs) $ \(resource, proof) ->
      unless (fmap (\(owner, revision, _) -> (owner, revision)) (Map.lookup resource removed)
        == Just (retentionOwner proof, retentionRevision proof))
        (Left "retention proof differs from accepted resource ownership history")
    pure (Map.fromListWith (<>)
      [(executor, [resource]) | (resource, (_, _, executor)) <- Map.toAscList removed])
  where
    loadDesired revision = do
      let key = scopeKey (revisionDigest revision)
      loaded <- readObject store key
      pure $ do
        bytes <- first showText loaded >>= maybe (Left "desired scope member is missing") Right
        unless (contentDigest bytes == revisionDigest revision)
          (Left "desired scope member digest mismatch")
        first showText (decodeScope bytes)

-- | Migration admission transfers the old physical incarnation into retained
-- history. Its source-binding proof must still hold before that transfer. The
-- BackUpSource adapter contract checks that original source; it must not depend
-- on effects of PrepareDestination. This is an authority check, never a resume
-- prerequisite or a sweep of future operations' readiness conditions.
migrationAdmissionChecks :: AdapterRegistry -> ReviewedPlan -> IO [AdmissionError]
migrationAdmissionChecks registry reviewed = fmap concat $ forM sources $ \entry ->
  case (lookupAdapter registry (plannedExecutor (reviewPlannedOperation entry)), preparedFor reviewed entry) of
    (Right adapter, Right prepared) -> do
      checked <- adapterPreflight adapter (reviewPlannedOperation entry) prepared
      pure [AdmissionError "migration-source" reason | Left reason <- [checked]]
    (Left reason, _) -> pure [AdmissionError "adapter" reason]
    (_, Left reason) -> pure [AdmissionError "native-bundle" reason]
  where
    sources = [entry | entry <- reviewOperations (reviewedDocument reviewed),
      plannedAction (reviewPlannedOperation entry) == MigrateResource BackUpSource]

-- | Reconstruct both declarations from immutable scope members before the
-- accepted head can advance. migrationAdmissionChecks rechecks source identity
-- while the writer lock is held, before this authority transfer.
migrationCoverage :: InventoryStore -> ReviewDocument -> IO (Either Text ())
migrationCoverage _ document | Map.null (reviewMigrations document) = pure (Right ())
migrationCoverage store document = do
  historical <- loadInventoryHistory store
  desired <- traverse loadDesired (Map.elems (reviewDesiredRevisions document))
  pure $ do
    history <- first showText historical
    scopes <- sequence desired
    desiredDeclarations <- first showText (Resource.composedDeclarations
      (Map.fromList [(Resource.scopeId scope, scope) | scope <- scopes]))
    oldDeclarations <- first showText (Resource.composedDeclarations
      (fmap snd (historyAccepted history)))
    let oldManaged = Map.fromList
          [(resource ^. #identity, resource) | Resource.Managed resource <- oldDeclarations]
        newManaged = Map.fromList
          [(resource ^. #identity, resource) | Resource.Managed resource <- desiredDeclarations]
    forM_ (Map.toAscList (reviewMigrations document)) $ \(resourceId, proof) -> do
      source <- maybe (Left "migration source declaration is missing") Right
        (Map.lookup resourceId oldManaged)
      destination <- maybe (Left "migration destination declaration is missing") Right
        (Map.lookup resourceId newManaged)
      let sourceClaims = Set.fromList (map snd (NE.toList (Resource.claimsOf (Resource.Managed source))))
          destinationClaims = Set.fromList (map snd (NE.toList (Resource.claimsOf (Resource.Managed destination))))
      unless (source ^. #owner == migrationProofOwner proof
        && fmap fst (Map.lookup (migrationProofOwner proof) (historyAccepted history))
          == Just (migrationProofRevision proof)
        && source ^. #owner == destination ^. #owner
        && source ^. #address == migrationProofSourceAddress proof
        && destination ^. #address == migrationProofDestinationAddress proof
        && source ^. #dataPolicy == destination ^. #dataPolicy
        && Set.null (Set.intersection sourceClaims destinationClaims)
        && case (source ^. #dataPolicy, migrationProofContract proof) of
          (Stateless, StatelessMigration) -> True
          (Durable _, DurableMigration {}) -> True
          _ -> False)
        (Left "migration proof differs from historical or destination declaration")
    pure ()
  where
    loadDesired revision = do
      let key = scopeKey (revisionDigest revision)
      loaded <- readObject store key
      pure $ do
        bytes <- first showText loaded >>= maybe (Left "migration destination scope is missing") Right
        unless (contentDigest bytes == revisionDigest revision)
          (Left "migration destination scope digest mismatch")
        first showText (decodeScope bytes)

execute :: LockedStore s -> AdapterRegistry -> ExecutablePlan s -> IO TransactionResult
execute locked registry executable = executeWithJournal locked registry executable Nothing

executeWithJournal :: LockedStore s -> AdapterRegistry -> ExecutablePlan s
  -> Maybe [JournalEvent] -> IO TransactionResult
executeWithJournal locked registry executable knownEvents = do
  let transaction = executableTransaction executable
      reviewed = executableReviewed executable
      document = reviewedDocument reviewed
  if not (null (reviewBarriers document))
    then do
      let barriers = NE.fromList (reviewBarriers document)
      _ <- appendEvent locked transaction Nothing Pending "paused at review barrier"
      _ <- releaseClaim locked transaction False
      pure (PausedAtBarrier transaction barriers)
    else do
      eventsResult <- maybe (readJournal locked) (pure . Right) knownEvents
      case eventsResult of
        Left _ -> ambiguousFallback transaction document
        Right events -> do
          outcome <- runOperations locked registry transaction reviewed events (reviewOperations document)
          case outcome of
            Just result -> releaseClaim locked transaction False >> pure result
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
                          converged <- releaseClaim locked transaction True
                          pure $ if converged then Converged transaction else fallbackResult transaction document
                _ -> do
                  _ <- releaseClaim locked transaction False
                  pure (fallbackResult transaction document)

finalizeCollections :: LockedStore s -> TransactionId -> ReviewDocument -> IO Bool
finalizeCollections locked transaction document
  | Map.null (reviewCollections document) = pure True
  | otherwise = do
      let store = lockedStore locked
      current <- readHead store
      case current of
        Right (Just headValue)
          | headActiveTransaction headValue == Just (transactionIdText transaction) -> do
              now <- timestamp
              let proofMatches resource proof = case Map.lookup resource (headRetained headValue) of
                    Just retained -> retainedOwner retained == retentionOwner proof
                      && retainedRevision retained == retentionRevision proof
                      && retainedPhysical retained == retentionPhysical proof
                    Nothing -> case Map.lookup resource (headCollected headValue) of
                      Just tombstone -> tombstoneOwner tombstone == retentionOwner proof
                        && tombstoneRevision tombstone == retentionRevision proof
                        && tombstonePhysical tombstone == retentionPhysical proof
                        && tombstoneReview tombstone == reviewDocumentDigest document
                      Nothing -> False
              if not (all (uncurry proofMatches) (Map.toAscList (reviewCollections document)))
                then pure False
                else do
                  let collected = Map.map (\proof -> DeletionTombstone
                        (retentionOwner proof) (retentionRevision proof)
                        (retentionPhysical proof) now (reviewDocumentDigest document))
                        (Map.filterWithKey (\resource _ -> Map.member resource (headRetained headValue))
                          (reviewCollections document))
                      replacement = headValue
                        { headGeneration = headGeneration headValue + 1
                        , headRetained = Map.withoutKeys (headRetained headValue)
                            (Map.keysSet (reviewCollections document))
                        , headCollected = Map.union collected (headCollected headValue)
                        }
                  if Map.null collected then pure True else do
                    result <- replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) replacement
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
          headResult <- readHead store
          eventsResult <- readJournal lock
          case (headResult, eventsResult) of
            (Left err, _) -> pure (failure "store" (showText err))
            (_, Left err) -> pure (failure "journal" (showText err))
            (Right Nothing, _) -> pure (failure "store" "inventory store is not initialized")
            (Right (Just headValue), Right events)
              | headActiveTransaction headValue /= Just (transactionIdText transaction) ->
                  if transactionConverged transaction events
                    then pure (Right (Converged transaction))
                    else pure (failure "inactive-transaction" "transaction is not active in the store head")
              | isJust (headDataFence headValue) ->
                  pure (failure "active-data-fence" "recover and release the active data fence before resuming its reviewed transaction")
              | Just operation <- rollbackProvedOperation transaction events -> do
                  claimed <- acquireResumeClaim store transaction headValue takeOver
                  case claimed of
                    Left err -> pure (Left err)
                    Right () -> do
                      closed <- releaseAbortedClaim lock transaction
                      pure $ if closed
                        then Right (StoppedFailed transaction operation
                          (KnownNoEffect "fenced recovery backup restored; original review was abandoned"))
                        else failure "head-condition" "could not close recovered transaction"
              | otherwise -> do
                  claimed <- acquireResumeClaim store transaction headValue takeOver
                  case claimed of
                    Left err -> pure (Left err)
                    Right () -> do
                      bundleResult <- loadPublishedReview store digest
                      snapshotResult <- readStoreSnapshot store
                      case (bundleResult, snapshotResult) of
                        (Left err, _) -> releaseClaim lock transaction False >> pure (failure "review" (showText err))
                        (_, Left err) -> releaseClaim lock transaction False >> pure (failure "store" (showText err))
                        (Right bundle, Right snapshot) -> case verifyActiveReview snapshot (transactionIdText transaction) bundle of
                          Left errors -> releaseClaim lock transaction False >> pure (Left (fmap reviewAdmission errors))
                          Right reviewed -> do
                            let preflightErrors = validateOperationInputs registry reviewed (operationStates transaction events)
                            case preflightErrors of
                              firstError : rest -> releaseClaim lock transaction False >> pure (Left (firstError :| rest))
                              [] -> Right <$> executeWithJournal lock registry
                                (ExecutablePlan transaction reviewed) (Just events)

-- | The decision file selects an action; the adapter must independently prove
-- that action from the current provider state under the writer lock. An
-- unresolved adapter outcome never becomes operator authority.
recordOperatorRecovery
  :: InventoryStore -> AdapterRegistry -> OperatorRecoveryInput -> Bool
  -> IO (Either (NonEmpty AdmissionError) ())
recordOperatorRecovery store registry input takeOver = do
  locked <- withProcessLock store $ \lock -> recoverLocked lock
  pure $ case locked of
    Left err -> failure "process-lock" (showText err)
    Right result -> result
  where
    transaction = recoveryTransaction input
    operationId = recoveryOperation input
    recoverLocked :: forall s. LockedStore s -> IO (Either (NonEmpty AdmissionError) ())
    recoverLocked lock = do
      headResult <- readHead store
      eventsResult <- readJournal lock
      case (headResult, eventsResult) of
        (Left err, _) -> pure (failure "store" (showText err))
        (_, Left err) -> pure (failure "journal" (showText err))
        (Right Nothing, _) -> pure (failure "store" "inventory store is not initialized")
        (Right (Just headValue), Right events)
          | headActiveTransaction headValue /= Just (transactionIdText transaction) ->
              pure (failure "inactive-transaction" "operator recovery requires the active transaction")
          | isJust (headDataFence headValue)
              && not (fencedAction (recoveryAction input)) ->
              pure (failure "active-data-fence" "recover and release the data fence before recording adapter recovery")
          | isNothing (headDataFence headValue)
              && fencedAction (recoveryAction input)
              && not (recoveryAction input == RecoverFencedBackup
                && isJust (rollbackProof transaction operationId events)) ->
              pure (failure "data-fence" "reviewed transaction has no active data fence")
          | Just (recoveryReview input) /= transactionDigest transaction ->
              pure (failure "recovery-review" "decision file review digest differs from transaction")
          | not (recoverableState (Map.lookup operationId (operationStates transaction events))) ->
              pure (failure "recovery-state" "operation has no uncertain effect to resolve")
          | otherwise -> do
              claimed <- acquireResumeClaim store transaction headValue takeOver
              case claimed of
                Left err -> pure (Left err)
                Right () -> do
                  result <- inspectRecovery lock events (headDataFence headValue)
                  released <- if isRight result && isNothing (headDataFence headValue)
                    && (recoveryAction input `elem`
                      [AbandonPartialPrune, AbandonPartialVolumeRestore,
                       AbandonPartialDatabaseRestore]
                      || (recoveryAction input == RecoverFencedBackup
                        && isJust (rollbackProof transaction operationId events)))
                    then releaseAbortedClaim lock transaction
                    else do
                      current <- readHead store
                      case current of
                        Right (Just value) | isNothing (headActiveTransaction value) ->
                          pure True
                        _ -> releaseClaim lock transaction False
                  pure $ if released then result else failure "executor-claim" "could not release operator recovery claim"
    inspectRecovery :: forall s. LockedStore s -> [JournalEvent] -> Maybe DataFenceRecord
      -> IO (Either (NonEmpty AdmissionError) ())
    inspectRecovery lock events activeFence = do
      case (activeFence, recoveryAction input,
          rollbackProof transaction operationId events) of
        (Nothing, RecoverFencedBackup, Just _) -> pure (Right ())
        _ -> inspectReviewedRecovery lock events activeFence
    inspectReviewedRecovery :: forall s. LockedStore s -> [JournalEvent]
      -> Maybe DataFenceRecord
      -> IO (Either (NonEmpty AdmissionError) ())
    inspectReviewedRecovery lock events activeFence = do
      bundle <- loadPublishedReview store (recoveryReview input)
      snapshot <- readStoreSnapshot store
      case (bundle, snapshot) of
        (Left err, _) -> pure (failure "review" (showText err))
        (_, Left err) -> pure (failure "store" (showText err))
        (Right published, Right state) -> case verifyActiveReview state (transactionIdText transaction) published of
          Left errs -> pure (Left (fmap reviewAdmission errs))
          Right reviewed -> case find ((== operationId) . plannedOperationId . reviewPlannedOperation)
            (reviewOperations (reviewedDocument reviewed)) of
            Nothing -> pure (failure "recovery-operation" "operation is absent from the active review")
            Just reviewOperation -> case (preparedFor reviewed reviewOperation,
              lookupAdapter registry (plannedExecutor (reviewPlannedOperation reviewOperation))) of
              (Left err, _) -> pure (failure "native-bundle" err)
              (_, Left err) -> pure (failure "adapter" err)
              (Right prepared, Right adapter)
                | adapterIdentity adapter /= reviewAdapterIdentity reviewOperation
                  || adapterVersion adapter /= reviewAdapterVersion reviewOperation ->
                    pure (failure "adapter-version" "recovery adapter differs from the issued review")
                | otherwise -> case selectedFence registry reviewed reviewOperation prepared of
                  Left reason -> pure (failure "data-fence-capability" reason)
                  Right (Just (saved, controls)) | Just active <- activeFence
                    , sameReviewedFence transaction saved active ->
                      if recoveryAction input == RecoverFencedBackup
                        && not (all (\selected ->
                          plannedOperationId (reviewPlannedOperation selected) == operationId
                          || plannedAction (reviewPlannedOperation selected) == VerifyResource)
                          (reviewOperations (reviewedDocument reviewed)))
                      then pure (failure "recovery-review"
                        "backup rollback requires a review with no other mutating operations")
                      else recoverFenced lock adapter (reviewPlannedOperation reviewOperation)
                        prepared active controls (reviewFenceCapability reviewOperation)
                        events
                  Right (Just _) | isNothing activeFence
                    , recoveryAction input == RetryAfterAdapterProof
                    , Just lastEvent <- find
                        (\event -> eventTransaction event == transaction
                          && eventOperation event == Just operationId)
                        (reverse events)
                    , eventState lastEvent == Ambiguous
                    , "data fence acquisition or exclusion is unresolved"
                        `T.isPrefixOf` eventDetail lastEvent -> do
                          -- startFence returned before adapterExecute. With no
                          -- durable reservation, its read-only validation or
                          -- conditional reservation failed before any effect.
                          appended <- appendEvent lock transaction (Just operationId)
                            (OperatorResolved "fence-not-reserved-safe-retry")
                            "operator selected retry after unreserved fence start"
                          pure (first (\err -> AdmissionError "journal" (showText err) :| [])
                            (() <$ appended))
                  Right _ | isJust activeFence || fencedAction (recoveryAction input) ->
                    pure (failure "data-fence-capability"
                      "active data fence differs from the private reviewed member")
                  Right selection -> do
                    let operation = reviewPlannedOperation reviewOperation
                    decision <- withAdapterEnv transaction operation
                      (adapterRecover adapter operation prepared)
                    case (recoveryAction input, decision) of
                      (AbandonPartialPrune, RecoveryTerminalFailure physical)
                        | scheduledPruneOnlyReview published operation -> do
                            appended <- appendEvent lock transaction (Just operationId)
                              (OperatorResolved "abandoned-terminal-scheduled-prune")
                              ("terminal scheduled prune Job " <>
                                physicalIdentityText physical <>
                                " abandoned; exact provider members require separate recovery")
                            pure (first (\err -> AdmissionError "journal"
                              (showText err) :| []) (() <$ appended))
                      (AbandonPartialVolumeRestore, RecoveryTerminalFailure physical)
                        | volumeRestoreOnlyReview published operation -> do
                            appended <- appendEvent lock transaction (Just operationId)
                              (OperatorResolved "abandoned-terminal-volume-restore")
                              ("terminal volume restore Job " <>
                                physicalIdentityText physical <>
                                " abandoned; unaccepted scratch PVC requires separate reviewed recovery")
                            pure (first (\err -> AdmissionError "journal"
                              (showText err) :| []) (() <$ appended))
                      (AbandonPartialDatabaseRestore, RecoveryTerminalFailure physical)
                        | databaseRestoreOnlyReview published operation -> do
                            appended <- appendEvent lock transaction (Just operationId)
                              (OperatorResolved "abandoned-terminal-database-restore")
                              ("terminal database restore Job " <>
                                physicalIdentityText physical <>
                                " abandoned; unaccepted scratch database requires separate reviewed recovery")
                            pure (first (\err -> AdmissionError "journal"
                              (showText err) :| []) (() <$ appended))
                      (AcceptAdapterProof, RecoveryProvedComplete proof) -> do
                        appended <- appendEvent lock transaction (Just operationId)
                          (Completed proof) "operator accepted adapter recovery proof"
                        pure (first (\err -> AdmissionError "journal" (showText err) :| []) (() <$ appended))
                      (RetryAfterAdapterProof, RecoverySafeToRetry)
                        | isNothing selection -> do
                            appended <- appendEvent lock transaction (Just operationId)
                              (OperatorResolved "adapter-proved-safe-retry") "operator selected adapter-proved safe retry"
                            pure (first (\err -> AdmissionError "journal" (showText err) :| []) (() <$ appended))
                      _ -> pure (failure "unsupported-recovery" "adapter did not prove the operator's requested action")
    scheduledPruneOnlyReview published operation =
      let reviewed = reviewOperations (reviewBundleDocument published)
          resource = NE.toList (plannedResources operation)
          actions = map (plannedAction . reviewPlannedOperation) reviewed
          oneResource = case resource of
            [selected] -> all (\entry -> NE.toList
              (plannedResources (reviewPlannedOperation entry)) == [selected]) reviewed
            _ -> False
          scopes = mapMaybe (either (const Nothing) Just . decodeScope)
            (Map.elems (reviewBundleScopes published))
          owns selected scope = any (\bundle -> any (\case
            Resource.Managed member -> member ^. #identity == selected
            _ -> False) (Resource.declarations bundle)) (Resource.scopeBundles scope)
          selectedScope = case resource of
            [selected] -> [scope | scope <- scopes, owns selected scope]
            _ -> []
       in plannedAction operation `elem` [CreateResource, RunDeclaredOperation]
          && length reviewed == 2
          && Set.fromList actions == Set.fromList [CreateResource, RunDeclaredOperation]
          && oneResource
          && case selectedScope of
            [scope] -> Map.member "scheduled.prune.backup.scope"
              (Resource.scopeOverrides scope)
            _ -> False
    volumeRestoreOnlyReview published operation =
      let reviewed = map reviewPlannedOperation
            (reviewOperations (reviewBundleDocument published))
          selected = NE.toList (plannedResources operation)
          scopes = mapMaybe (either (const Nothing) Just . decodeScope)
            (Map.elems (reviewBundleScopes published))
          owns member scope = any (\bundle -> any (\case
            Resource.Managed resource -> resource ^. #identity == member
            _ -> False) (Resource.declarations bundle)) (Resource.scopeBundles scope)
       in case selected of
            [job] ->
              let restoreScopes = [scope | scope <- scopes, owns job scope,
                    all (\key -> Map.member key (Resource.scopeOverrides scope))
                      ["volume-restore.id", "volume-restore.backup.job.uid",
                       "volume-restore.target.pvc.uid", "volume-restore.scratch"]]
                  sameScope scope entry = all (`owns` scope)
                    (NE.toList (plannedResources entry))
                  actions = map plannedAction reviewed
                  created = [member | entry <- reviewed,
                    plannedAction entry == CreateResource,
                    member <- NE.toList (plannedResources entry)]
               in case (restoreScopes, created) of
                    ([scope], [firstCreated, secondCreated]) ->
                      let managed = [resource ^. #identity |
                            bundle <- Resource.scopeBundles scope,
                            Resource.Managed resource <- Resource.declarations bundle]
                       in plannedAction operation `elem` [CreateResource, RunDeclaredOperation]
                      && length reviewed == 3
                      && length (filter (== CreateResource) actions) == 2
                      && length (filter (== RunDeclaredOperation) actions) == 1
                      && job `elem` created
                      && T.isSuffixOf "/job" (resourceIdText job)
                      && any (T.isSuffixOf "/pvc" . resourceIdText) created
                      && firstCreated /= secondCreated
                      && length managed == 2
                      && Set.fromList managed == Set.fromList created
                      && all (sameScope scope) reviewed
                    _ -> False
            _ -> False
    databaseRestoreOnlyReview published operation =
      let reviewed = map reviewPlannedOperation
            (reviewOperations (reviewBundleDocument published))
          selected = NE.toList (plannedResources operation)
          scopes = mapMaybe (either (const Nothing) Just . decodeScope)
            (Map.elems (reviewBundleScopes published))
          owns member scope = any (\bundle -> any (\case
            Resource.Managed resource -> resource ^. #identity == member
            _ -> False) (Resource.declarations bundle)) (Resource.scopeBundles scope)
       in case selected of
            [job] ->
              let restoreScopes = [scope | scope <- scopes, owns job scope,
                    all (\key -> Map.member key (Resource.scopeOverrides scope))
                      ["restore.id", "restore.target.database",
                       "restore.backup.scope", "restore.target.statefulset.uid",
                       "restore.target.pvc.uid"]]
                  sameJob entry = NE.toList (plannedResources entry) == [job]
                  actions = map plannedAction reviewed
               in case restoreScopes of
                    [scope] ->
                      let managed = [resource ^. #identity |
                            bundle <- Resource.scopeBundles scope,
                            Resource.Managed resource <- Resource.declarations bundle]
                       in plannedAction operation `elem` [CreateResource, RunDeclaredOperation]
                          && length reviewed == 2
                          && Set.fromList actions == Set.fromList
                            [CreateResource, RunDeclaredOperation]
                          && T.isSuffixOf "/job" (resourceIdText job)
                          && managed == [job]
                          && all sameJob reviewed
                    _ -> False
            _ -> False
    recoverFenced :: forall s. LockedStore s -> Adapter -> PlannedOperation
      -> PreparedNative -> DataFenceRecord -> DataFenceControls -> Maybe Text
      -> [JournalEvent]
      -> IO (Either (NonEmpty AdmissionError) ())
    recoverFenced lock adapter operation prepared active controls capability events = do
      resumed <- resumeDataFence lock (fenceSession active)
      case resumed of
        Left reason -> pure (failure "data-fence" reason)
        Right token -> case recoveryAction input of
          ContinueFencedOperation
            | fencePhase active `elem` [FenceAcquiring, FenceExcluded] -> do
                acquired <- if fencePhase active == FenceAcquiring
                  then resumeDataFenceAcquisition lock controls token
                  else pure (Right ())
                case acquired of
                  Left reason -> pure (failure "data-fence" reason)
                  Right () -> do
                    preflight <- adapterPreflight adapter operation prepared
                    case preflight of
                      Left reason -> pure (failure "preflight" reason)
                      Right () -> continueAfterPreflight lock token controls
                        adapter operation prepared
          VerifyFencedEffect
            | fencePhase active `elem`
                [FenceChanging, FenceUnresolved, FenceVerifying, FenceReleasing] -> do
                if isJust (rollbackProof transaction operationId events)
                  then pure (failure "adapter-recovery"
                    "recovery backup was selected; finish that recovery before releasing writers")
                  else do
                    decision <- withAdapterEnv transaction operation
                      (resolveReviewedEffect adapter operation prepared active capability)
                    case decision of
                      RecoveryProvedComplete proof -> do
                        recovered <- recoverDataFence lock controls token
                        case recovered of
                          Left reason -> pure (failure "data-fence" reason)
                          Right () | fencePhase active == FenceReleasing ->
                            appendFencedCompletion lock proof
                          Right () -> completeFenced lock token controls proof
                      _ -> pure (failure "adapter-recovery"
                        "adapter has not proved the fenced data effect complete")
          RecoverFencedBackup
            | fencePhase active `elem`
                [FenceChanging, FenceUnresolved, FenceVerifying, FenceReleasing] ->
                case capability >>= lookupAdapterFenceByCapability registry
                    (plannedExecutor operation) of
                  Nothing -> pure (failure "data-fence-capability"
                    "reviewed recovery capability is unavailable")
                  Just hook -> case (fenceRestoreRecoveryBackup hook,
                      fenceVerifyRecoveryBackup hook) of
                    (Just restore, Just verify) -> do
                      let prior = rollbackProof transaction operationId events
                          recoveryControls proof = controls
                            { verifyRecoveredData = \record -> do
                                observed <- verify record operation prepared
                                pure ((== proof) <$> observed) }
                      safe <- if fencePhase active == FenceReleasing
                        then pure (if isJust prior then Right ()
                          else Left "recovery backup was not proved before writer release")
                        else checkDataFenceExclusion lock controls token
                      case safe of
                        Left reason -> pure (failure "data-fence" reason)
                        Right () -> do
                          restored <- case prior of
                            Just proof -> pure (Right proof)
                            Nothing -> withAdapterEnv transaction operation
                              (restore active operation prepared)
                          case restored of
                            Left reason -> pure (failure "adapter-recovery" reason)
                            Right proof -> do
                              observed <- withAdapterEnv transaction operation
                                (verify active operation prepared)
                              if observed /= Right proof
                                then pure (failure "adapter-recovery"
                                  "recovery backup content is not proved")
                                else do
                                  recorded <- case prior of
                                    Just saved | saved == proof -> pure (Right ())
                                    Just _ -> pure (Left "recovery proof changed")
                                    Nothing -> fmap (first showText . (() <$))
                                      (appendEvent lock transaction (Just operationId)
                                        (OperatorResolved ("fenced-recovery-proved:"
                                          <> digestText proof))
                                        "reviewed recovery backup content proved under data fence")
                                  case recorded of
                                    Left reason -> pure (failure "journal" reason)
                                    Right () -> do
                                      let selected = recoveryControls proof
                                      recovered <- recoverDataFence lock selected token
                                      case recovered of
                                        Left reason -> pure (failure "data-fence" reason)
                                        Right () | fencePhase active == FenceReleasing -> do
                                          closed <- releaseAbortedClaim lock transaction
                                          pure $ if closed then Right () else failure
                                            "head-condition" "could not close recovered transaction"
                                        Right () -> do
                                          released <- releaseDataFence lock selected token
                                          case released of
                                            Left reason -> pure (failure "data-fence" reason)
                                            Right () -> do
                                              closed <- releaseAbortedClaim lock transaction
                                              pure $ if closed then Right () else failure
                                                "head-condition" "could not close recovered transaction"
                    _ -> pure (failure "data-fence-capability"
                      "reviewed capability has no recovery backup verifier")
          ForwardFencedRelease
            | fencePhase active == FenceReleasing -> do
                case rollbackProof transaction operationId events of
                  Just proof -> case capability >>= lookupAdapterFenceByCapability registry
                      (plannedExecutor operation) >>= fenceVerifyRecoveryBackup of
                    Nothing -> pure (failure "data-fence-capability"
                      "reviewed recovery backup verifier is unavailable")
                    Just verify -> do
                      observed <- withAdapterEnv transaction operation
                        (verify active operation prepared)
                      if observed /= Right proof
                        then pure (failure "adapter-recovery"
                          "recovery backup content is not proved")
                        else do
                          recovered <- forwardRecoverDataFenceRelease lock controls token
                          case recovered of
                            Left reason -> pure (failure "data-fence" reason)
                            Right () -> do
                              closed <- releaseAbortedClaim lock transaction
                              pure $ if closed then Right () else failure
                                "head-condition" "could not close recovered transaction"
                  Nothing -> do
                    decision <- withAdapterEnv transaction operation
                      (resolveReviewedEffect adapter operation prepared active capability)
                    case decision of
                      RecoveryProvedComplete proof -> do
                        recovered <- forwardRecoverDataFenceRelease lock controls token
                        case recovered of
                          Left reason -> pure (failure "data-fence" reason)
                          Right () -> appendFencedCompletion lock proof
                      _ -> pure (failure "adapter-recovery"
                        "adapter has not proved the fenced data effect complete")
          _ -> pure (failure "data-fence"
            "recovery action does not match the durable data fence phase")
    resolveReviewedEffect adapter operation prepared active capability =
      case capability >>= lookupAdapterFenceByCapability registry
          (plannedExecutor operation) >>= fenceResolveUncertainEffect of
        Just resolve -> resolve active operation prepared
        Nothing -> adapterRecover adapter operation prepared
    continueAfterPreflight :: forall s. LockedStore s -> FenceToken
      -> DataFenceControls -> Adapter -> PlannedOperation -> PreparedNative
      -> IO (Either (NonEmpty AdmissionError) ())
    continueAfterPreflight lock token controls adapter operation prepared = do
      started <- beginDataChange lock controls token
      case started of
        Left reason -> pure (failure "data-fence" reason)
        Right () -> do
          effect <- withAdapterEnv transaction operation
            (adapterExecute adapter operation prepared)
          case effect of
            AdapterEffectCompleted -> do
              verified <- withAdapterEnv transaction operation
                (adapterVerify adapter operation prepared)
              case verified of
                Left reason -> do
                  _ <- markDataFenceUnresolved lock token
                  pure (failure "adapter-recovery" reason)
                Right proof -> finishFenced lock token controls proof
            AdapterEffectAmbiguous reason -> do
              _ <- markDataFenceUnresolved lock token
              _ <- appendEvent lock transaction (Just operationId) Ambiguous
                ("fenced adapter result was ambiguous: " <> reason)
              pure (failure "adapter-recovery"
                "fenced data effect is not proved complete")
            AdapterEffectFailed failureClass -> do
              _ <- markDataFenceUnresolved lock token
              _ <- appendEvent lock transaction (Just operationId) Ambiguous
                ("fenced adapter execution stopped: " <> showText failureClass)
              pure (failure "adapter-recovery"
                "fenced data effect is not proved complete")
    finishFenced :: forall s. LockedStore s -> FenceToken -> DataFenceControls
      -> ContentDigest -> IO (Either (NonEmpty AdmissionError) ())
    finishFenced lock token controls proof = do
      verified <- verifyDataChange lock controls token
      case verified of
        Left reason -> pure (failure "data-fence" reason)
        Right () -> completeFenced lock token controls proof
    completeFenced :: forall s. LockedStore s -> FenceToken -> DataFenceControls
      -> ContentDigest -> IO (Either (NonEmpty AdmissionError) ())
    completeFenced lock token controls proof = do
      released <- releaseDataFence lock controls token
      case released of
        Left reason -> pure (failure "data-fence" reason)
        Right () -> appendFencedCompletion lock proof
    appendFencedCompletion :: forall s. LockedStore s -> ContentDigest
      -> IO (Either (NonEmpty AdmissionError) ())
    appendFencedCompletion lock proof = do
      appended <- appendEvent lock transaction (Just operationId)
        (Completed proof) "reviewed fenced effect and writer release proved"
      pure (first (\err -> AdmissionError "journal" (showText err) :| []) (() <$ appended))
    fencedAction action = action `elem`
      [ContinueFencedOperation, VerifyFencedEffect, RecoverFencedBackup,
        ForwardFencedRelease]
    sameReviewedFence selectedTransaction saved active =
      fenceTransaction active == Just (transactionIdText selectedTransaction)
        && active {fenceTransaction = Nothing, fencePhase = fencePhase saved,
          fenceAcquiredAt = fenceAcquiredAt saved} == saved
    recoverableState state = case state of
      Just IntentRecorded -> True
      Just Ambiguous -> True
      Just (Failed (PartialOrUnknown _)) -> True
      Just (OperatorResolved marker) ->
        "fenced-recovery-proved:" `T.isPrefixOf` marker
      _ -> False
    transactionDigest token = either (const Nothing) Just
      (mkContentDigest (T.drop 3 (transactionIdText token)))

runOperations :: LockedStore s -> AdapterRegistry -> TransactionId -> ReviewedPlan -> [JournalEvent] -> [ReviewOperation] -> IO (Maybe TransactionResult)
runOperations locked registry transaction reviewed initialEvents operations = go initialEvents
  where
    go events = case nextOperation operations (operationStates transaction events) of
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
                | otherwise -> do
                    decision <-
                      withAdapterEnv
                        transaction
                        operation
                        (adapterRecover adapter operation prepared)
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
                        | otherwise ->
                            pure
                              ( Just
                                  ( StoppedAmbiguous
                                      transaction
                                      (plannedOperationId operation)
                                  )
                              )
                      RecoveryTerminalFailure _ ->
                        pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
                      RecoveryUnresolved _ ->
                        pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))
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
                      result <-
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

executorStillClaimed :: LockedStore s -> TransactionId -> IO Bool
executorStillClaimed locked transaction = do
  let store = lockedStore locked
  current <- readHead store
  pure $ case current of
    Right (Just headValue) -> case headExecutorClaim headValue of
      Just claim -> claimTransaction claim == transactionIdText transaction
        && claimClientIdentity claim == maybe (headClientIdentity headValue) id (storeClientIdentity store)
      Nothing -> False
    _ -> False

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

selectedFence :: AdapterRegistry -> ReviewedPlan -> ReviewOperation -> PreparedNative
  -> Either Text (Maybe (DataFenceRecord, DataFenceControls))
selectedFence registry plan operation prepared = do
  saved <- reviewedFenceRecord plan operation
  when (plannedAction (reviewPlannedOperation operation) `elem`
      [OpenMaintenanceSession, RestoreLiveDatabase]
      && isNothing saved)
    (Left "database data operation review has no data fence")
  case (reviewFenceCapability operation, reviewFenceDigest operation, saved) of
    (Nothing, Nothing, Nothing)
      | isNothing (reviewFenceSummary operation) -> Right Nothing
    (Just capability, Just digest, Just record)
      | isNothing (fenceTransaction record)
      , digest == dataFenceIntentDigest record
      , isJust (reviewFenceSummary operation) -> do
          hook <- maybe (Left "review requires an unavailable data fence capability")
            Right (lookupAdapterFenceByCapability registry
              (plannedExecutor (reviewPlannedOperation operation)) capability)
          controls <- fenceFromReviewedRecord hook record
            (reviewPlannedOperation operation) prepared
          Right (Just (record, controls))
    _ -> Left "data fence capability or reviewed intent changed"

appendEvent :: LockedStore s -> TransactionId -> Maybe OperationId -> OperationState -> Text -> IO (Either StoreError JournalEvent)
appendEvent locked transaction operation state detail = do
  let store = lockedStore locked
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue) -> do
      let claimed = case storeClientIdentity store of
            Nothing -> True
            Just client -> case headExecutorClaim headValue of
              Just owner -> claimClientIdentity owner == client
                && claimTransaction owner == transactionIdText transaction
              Nothing -> False
      if not claimed
        then pure (Left (StoreConditionFailed "inventory executor claim belongs to another client"))
        else do
          previous <- previousDigest store (headSequence headValue)
          case previous of
            Left err -> pure (Left err)
            Right prior -> do
              now <- timestamp
              let event = JournalEvent 1 (headSequence headValue) prior transaction operation state now detail
                  key = journalKey (headSequence headValue)
              published <- appendAtObservedHead store headValue (encodeJournalEvent event)
              case published of
                Right _ -> advance headValue event
                Left (StoreObjectConflict _) -> do
                  existing <- readObject store key
                  case existing of
                    Left err -> pure (Left err)
                    Right Nothing -> pure (Left (StoreInvalidObject key "conflicting journal event is missing"))
                    Right (Just bytes) -> case decodeJournalEvent bytes of
                      Left err -> pure (Left (StoreInvalidObject key err))
                      Right old
                        | sameEventMeaning old event -> advance headValue old
                        | otherwise -> pure (Left (StoreObjectConflict key))
                Left err -> pure (Left err)
  where
    advance headValue event = do
      let replacement = headValue {headGeneration = headGeneration headValue + 1, headSequence = headSequence headValue + 1}
      replaced <- replaceHeadIfGenerationMatches (lockedStore locked) (Just (headGeneration headValue)) replacement
      pure (event <$ replaced)
    sameEventMeaning left right =
      eventSequence left == eventSequence right
        && eventPreviousDigest left == eventPreviousDigest right
        && eventTransaction left == eventTransaction right
        && eventOperation left == eventOperation right
        && eventState left == eventState right

previousDigest :: InventoryStore -> Integer -> IO (Either StoreError (Maybe ContentDigest))
previousDigest _ 0 = pure (Right Nothing)
previousDigest store sequenceNumber = do
  loaded <- readObject store (journalKey (sequenceNumber - 1))
  pure $ do
    bytes <- loaded >>= maybe (Left (StoreInvalidObject (journalKey (sequenceNumber - 1)) "previous journal event is missing")) Right
    event <- first (StoreInvalidObject (journalKey (sequenceNumber - 1))) (decodeJournalEvent bytes)
    pure (Just (journalEventDigest event))

readJournal :: LockedStore s -> IO (Either StoreError [JournalEvent])
readJournal locked = do
  let store = lockedStore locked
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue) -> do
      loaded <- readJournalPrefix store (headSequence headValue)
      pure $ do
        bytes <- loaded
        events <- traverse (first (StoreInvalidObject "journal") . decodeJournalEvent) bytes
        first (StoreInvalidObject "journal") (validateJournal events)

operationStates :: TransactionId -> [JournalEvent] -> Map OperationId OperationState
operationStates transaction =
  foldl
    (\states event -> case eventOperation event of Just operation | eventTransaction event == transaction -> Map.insert operation (eventState event) states; _ -> states)
    Map.empty

-- | This journal proof is written before writer release. If the process dies
-- after release, a later recovery or resume can close the abandoned review
-- without replaying its original data effect.
rollbackProof :: TransactionId -> OperationId -> [JournalEvent]
  -> Maybe ContentDigest
rollbackProof transaction operation events = listToMaybe
  [proof | event <- reverse events
    , eventTransaction event == transaction
    , eventOperation event == Just operation
    , OperatorResolved marker <- [eventState event]
    , Just token <- [T.stripPrefix "fenced-recovery-proved:" marker]
    , Right proof <- [mkContentDigest token]]

rollbackProvedOperation :: TransactionId -> [JournalEvent] -> Maybe OperationId
rollbackProvedOperation transaction events = listToMaybe
  [operation | event <- reverse events
    , eventTransaction event == transaction
    , Just operation <- [eventOperation event]
    , isJust (rollbackProof transaction operation events)]

transactionConverged :: TransactionId -> [JournalEvent] -> Bool
transactionConverged transaction = any (\event -> eventTransaction event == transaction && isNothing (eventOperation event) && "converged" `T.isInfixOf` eventDetail event)

acquireResumeClaim :: InventoryStore -> TransactionId -> HeadManifest -> Bool -> IO (Either (NonEmpty AdmissionError) ())
acquireResumeClaim store transaction headValue takeOver = do
  now <- timestamp
  case headExecutorClaim headValue of
    Just claim | claimClientIdentity claim /= localClient && not takeOver ->
      pure (failure "executor-claim" "transaction is claimed by a different store client; explicit takeover is required")
    claim -> do
      let epoch = maybe 1 ((+ 1) . claimEpoch) claim
          replacement = headValue {headGeneration = headGeneration headValue + 1, headExecutorClaim = Just (ExecutorClaim (transactionIdText transaction) localClient epoch now)}
      result <- replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) replacement
      pure $ case result of Left err -> failure "head-condition" (showText err); Right () -> Right ()
  where
    localClient = maybe (headClientIdentity headValue) id (storeClientIdentity store)

releaseClaim :: LockedStore s -> TransactionId -> Bool -> IO Bool
releaseClaim locked transaction converged = do
  let store = lockedStore locked
  headResult <- readHead store
  case headResult of
    Right (Just headValue) | headActiveTransaction headValue == Just (transactionIdText transaction),
      maybe True (\client -> maybe False ((== client) . claimClientIdentity) (headExecutorClaim headValue)) (storeClientIdentity store) -> do
      if converged && isJust (headDataFence headValue)
        then pure False
        else do
          let replacement =
                headValue
                  { headGeneration = headGeneration headValue + 1
                  , headExecutorClaim = Nothing
                  , headActiveTransaction = if converged then Nothing else headActiveTransaction headValue
                  , headConverged = if converged then headAccepted headValue else headConverged headValue
                  }
          isRight <$> replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) replacement
    _ -> pure False

-- | A proved rollback abandons the reviewed candidate. The accepted map was
-- advanced at admission, so restore the prior converged map as well as
-- clearing the claim. Callers require a review with no other mutating work.
releaseAbortedClaim :: LockedStore s -> TransactionId -> IO Bool
releaseAbortedClaim locked transaction = do
  let store = lockedStore locked
  headResult <- readHead store
  case headResult of
    Right (Just headValue)
      | headActiveTransaction headValue == Just (transactionIdText transaction)
      , isNothing (headDataFence headValue)
      , maybe True (\client -> maybe False ((== client) . claimClientIdentity)
          (headExecutorClaim headValue)) (storeClientIdentity store) -> do
          let replacement = headValue
                { headGeneration = headGeneration headValue + 1
                , headExecutorClaim = Nothing
                , headActiveTransaction = Nothing
                , headAccepted = headConverged headValue }
          isRight <$> replaceHeadIfGenerationMatches store
            (Just (headGeneration headValue)) replacement
    _ -> pure False

transactionFor :: ReviewDocument -> TransactionId
transactionFor document =
  either (error . T.unpack) id (mkTransactionId ("tx-" <> digestText (reviewDocumentDigest document)))

reviewDocumentDigest :: ReviewDocument -> ContentDigest
reviewDocumentDigest = contentDigest . encodeReviewDocument

withAdapterEnv :: TransactionId -> PlannedOperation -> IO a -> IO a
withAdapterEnv transaction operation action = do
  previousTransaction <- lookupEnv transactionVariable
  previousChild <- lookupEnv childVariable
  let restore = do
        restoreVariable transactionVariable previousTransaction
        restoreVariable childVariable previousChild
  bracket install (const restore) (const action)
  where
    transactionVariable = "NAGARE_INVENTORY_TRANSACTION"
    childVariable = "NAGARE_INVENTORY_ADAPTER_CHILD"
    install = do
      setEnv transactionVariable (T.unpack (transactionIdText transaction))
      setEnv childVariable (executorChild (plannedExecutor operation))
    restoreVariable variable Nothing = unsetEnv variable
    restoreVariable variable (Just value) = setEnv variable value
    executorChild executor = case executor of
      KubernetesExecutor -> "kubernetes"
      PulumiExecutor -> "pulumi"
      CloudFoundationExecutor -> "cloud-foundation"
      HostExecutor -> "host"
      ArtifactExecutor -> "artifact"
      CacheExecutor -> "cache"
      BrokerExecutor -> "broker"
      HelmExecutor -> "helm"
      CdnExecutor -> "cdn"

timestamp :: IO Text
timestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime

failure :: Text -> Text -> Either (NonEmpty AdmissionError) a
failure code message = Left (AdmissionError code message :| [])

reviewAdmission :: ReviewError -> AdmissionError
reviewAdmission errorValue = AdmissionError (reviewErrorCode errorValue) (reviewErrorMessage errorValue)

showText :: (Show a) => a -> Text
showText = T.pack . show

ambiguousFallback :: TransactionId -> ReviewDocument -> IO TransactionResult
ambiguousFallback transaction document = pure (fallbackResult transaction document)

fallbackResult :: TransactionId -> ReviewDocument -> TransactionResult
fallbackResult transaction document =
  case reviewOperations document of
    operation : _ -> StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation operation))
    [] -> StoppedAmbiguous transaction fallbackOperation
  where
    fallbackOperation = either (error . T.unpack) id (mkOperationId "op-store")
