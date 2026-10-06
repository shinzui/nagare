{-# LANGUAGE RankNTypes #-}

-- | ADR 26: close a stopped transaction by per-operation proof; internal
-- implementation behind Nagare.Inventory.Execute.
--
-- Every operation of the active review is classified once, from the journal
-- or from its adapter's settlement. When resume cannot progress and no
-- operation is unknown, the close publishes a record of the classes and writes
-- one head: the transaction ends, scopes the review did not change are
-- untouched, a changed scope in which nothing took effect reverts to the
-- review's base (with its own retained additions removed), and every other
-- changed scope keeps its desired revision. Close never writes to a provider,
-- converges nothing and binds no incarnation.
module Nagare.Inventory.Execute.Close
  ( CloseInput (..)
  , closeTransaction
  , closeRolledBack
  , releaseClosedTransaction
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Either (isRight)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
  ( Adapter (adapterIdentity, adapterObserve, adapterPreflight, adapterRecover, adapterVersion)
  , AdapterRegistry
  , OperationAction (CreateResource, VerifyResource)
  , PlannedOperation (plannedAction, plannedExecutor, plannedOperationId, plannedResources)
  , RecoveryDecision (RecoveryProvedComplete, RecoverySafeToRetry)
  , ResourceObservation (ConfirmedAbsent)
  , Settlement (..)
  , lookupAdapter
  , observationMap
  , settleOperationWith
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute.AdapterEnv (withAdapterEnv)
import Nagare.Inventory.Execute.Claims (acquireResumeClaim, observeCurrentHead)
import Nagare.Inventory.Execute.Inputs (preparedFor)
import Nagare.Inventory.Execute.Journal (appendEvent, readJournalAtHead)
import Nagare.Inventory.Execute.Types
  ( AdmissionError (..)
  , failure
  , reviewAdmission
  , showText
  )
import Nagare.Inventory.Journal
  ( FailureClass (KnownNoEffect)
  , JournalEvent (eventOperation, eventState, eventTransaction)
  , OperationId
  , OperationState (..)
  , TransactionId
  , operationStates
  , transactionIdText
  )
import Nagare.Inventory.OperationStep (OperationStep (..), nextOperation)
import Nagare.Inventory.Plan
  ( ReviewDocument (reviewBaseRevisions, reviewDesiredRevisions, reviewMigrations, reviewOperations, reviewRetentions)
  , ReviewOperation (reviewAdapterIdentity, reviewAdapterVersion, reviewPlannedOperation)
  , ReviewedPlan
  , loadPublishedReview
  , reviewBundleDocument
  , reviewedDocument
  , verifyActiveReview
  )
import Nagare.Inventory.Plan.CloseRecord
  ( Attestation
  , CloseRecord (..)
  , OperationClass (..)
  , ScopeDisposition (..)
  , closedMarker
  , closedRecordDigest
  , loadCloseRecord
  , publishCloseRecord
  )
import Nagare.Inventory.Store
  ( HeadManifest (..)
  , InventoryStore
  , LockedStore
  , ObservedHead
  , ScopeRevision
  , lockedStore
  , observeHead
  , observedHeadManifest
  , publishIfAbsent
  , readObject
  , readReviewSnapshot
  , replaceObservedHead
  , withProcessLock
  )
import Nagare.Resource.Types
  ( ContentDigest
  , PhysicalIdentity
  , ResourceId
  , ScopeId
  , digestText
  , mkContentDigest
  , resourceIdText
  , scopeIdText
  )
import Nagare.Resource.Wire (canonicalValue)

data CloseInput = CloseInput
  { closeTarget :: !TransactionId
  , closeReview :: !ContentDigest
  , closeTakeOver :: !Bool
  , closeAttestation :: !(Maybe Attestation)
  }
  deriving stock (Eq, Show)

-- | Close the active transaction when every operation is proved and resume
-- cannot progress. A repeated close, after its event was journalled, only
-- completes the head release. With an attestation, close is admissible when
-- unknown operations are all that block it, and it accepts nothing (§5).
closeTransaction :: InventoryStore -> AdapterRegistry -> CloseInput -> IO (Either (NonEmpty AdmissionError) CloseRecord)
closeTransaction store registry input = do
  locked <- withProcessLock store closeLocked
  pure $ case locked of
    Left err -> failure "process-lock" (showText err)
    Right result -> result
  where
    transaction = closeTarget input
    closeLocked :: forall s. LockedStore s -> IO (Either (NonEmpty AdmissionError) CloseRecord)
    closeLocked lock = do
      headResult <- observeCurrentHead store
      case headResult of
        Left err -> pure (failure "store" (showText err))
        Right (_, Nothing) -> pure (failure "store" "inventory store is not initialized")
        Right (observed, Just headValue) -> do
          eventsResult <- readJournalAtHead store headValue
          case eventsResult of
            Left err -> pure (failure "journal" (showText err))
            Right events
              | Just recordDigest <- closedRecordDigest transaction events -> reenter lock recordDigest
              | headActiveTransaction headValue /= Just (transactionIdText transaction) ->
                  pure (failure "inactive-transaction" "close requires the active transaction")
              | isJust (headDataFence headValue) ->
                  pure (failure "active-data-fence" "a fenced data operation keeps its own recovery phases; recover the fence first")
              | isJust (headMigration headValue) ->
                  pure (failure "active-migration" "a migration is excluded from close; resume it or use its forward exit")
              | Just (closeReview input) /= reviewDigestOf transaction ->
                  pure (failure "close-review" "the review digest differs from the transaction")
              | otherwise -> do
                  claimed <- acquireResumeClaim store transaction observed headValue (closeTakeOver input)
                  case claimed of
                    Left err -> pure (Left err)
                    Right () -> withReview (proceed lock events)
    reenter :: forall s. LockedStore s -> ContentDigest -> IO (Either (NonEmpty AdmissionError) CloseRecord)
    reenter lock recordDigest = do
      loaded <- loadCloseRecord store recordDigest
      case loaded of
        Left err -> pure (failure "close-record" err)
        Right record -> do
          released <- releaseClosedTransaction lock record
          pure (if released then Right record else failure "head-condition" "the closed transaction's head release did not land; run close again")
    withReview continue = do
      bundle <- loadPublishedReview store (closeReview input)
      snapshot <- readReviewSnapshot store (closeReview input)
      case (bundle, snapshot) of
        (Left err, _) -> pure (failure "review" (showText err))
        (_, Left err) -> pure (failure "store" (showText err))
        (Right published, Right state) -> case verifyActiveReview state (transactionIdText transaction) published of
          Left errs -> pure (Left (fmap reviewAdmission errs))
          Right reviewed -> continue reviewed
    proceed :: forall s. LockedStore s -> [JournalEvent] -> ReviewedPlan -> IO (Either (NonEmpty AdmissionError) CloseRecord)
    proceed lock events reviewed = do
      let document = reviewedDocument reviewed
          states = operationStates transaction events
          entries = reviewOperations document
          versionErrors =
            [ AdmissionError "adapter-version" ("the adapter differs from the issued review for " <> T.pack (show (plannedOperationId (reviewPlannedOperation entry))))
            | entry <- entries
            , Right adapter <- [lookupAdapter registry (plannedExecutor (reviewPlannedOperation entry))]
            , adapterIdentity adapter /= reviewAdapterIdentity entry || adapterVersion adapter /= reviewAdapterVersion entry
            ]
      progress <- resumeProgress registry reviewed transaction entries states
      case (versionErrors, progress) of
        (err : more, _) -> pure (Left (err :| more))
        (_, Just why) -> pure (failure "resume-progresses" ("resume can still progress: " <> why <> "; run inventory resume first"))
        (_, Nothing) -> do
          classes <- Map.fromList <$> traverse (\entry -> (plannedOperationId (reviewPlannedOperation entry),) <$> classify registry reviewed transaction states entry) entries
          case [(operation, reason, resolvesBy) | (operation, ClassUnknown reason resolvesBy) <- Map.toList classes] of
            unknowns@(_ : _)
              | Just attestation <- closeAttestation input ->
                  commitClose lock (attestedRecord attestation (closeRecordFor transaction (closeReview input) document classes Set.empty))
              | otherwise ->
                  pure
                    ( Left
                        ( NE.fromList
                            [ AdmissionError "unknown-operation" (T.pack (show operation) <> " is not proved: " <> reason <> " (resolved by " <> resolvesBy <> ")")
                            | (operation, reason, resolvesBy) <- unknowns
                            ]
                        )
                    )
            []
              | isJust (closeAttestation input) ->
                  pure (failure "attestation-unneeded" "every operation is proved; close without --attest so the proof decides each scope")
            [] -> do
              absent <- neverStartedAbsent registry entries classes
              commitClose lock (closeRecordFor transaction (closeReview input) document classes absent)

-- | Publish the record, journal it and write the head. The journal event is
-- the commit point: a repeat only redoes the head write.
commitClose :: LockedStore s -> CloseRecord -> IO (Either (NonEmpty AdmissionError) CloseRecord)
commitClose lock record = do
  published <- publishCloseRecord (lockedStore lock) record
  case published of
    Left err -> pure (failure "close-record" err)
    Right recordDigest -> do
      appended <- appendEvent lock (closedTransaction record) Nothing (OperatorResolved (closedMarker <> digestText recordDigest)) "transaction closed by per-operation proof"
      case appended of
        Left err -> pure (failure "journal" (showText err))
        Right _ -> do
          released <- releaseClosedTransaction lock record
          pure (if released then Right record else failure "head-condition" "the close was journalled but its head release did not land; run close again")

-- | A proved fenced rollback ends its transaction through the same record and
-- head write as close. Its review has no other mutating work, so every class
-- comes from the journal; any operation the journal cannot class refuses.
-- The caller holds the claim and has released the fence.
closeRolledBack :: LockedStore s -> TransactionId -> IO (Either (NonEmpty AdmissionError) CloseRecord)
closeRolledBack lock transaction = case reviewDigestOf transaction of
  Nothing -> pure (failure "close-review" "the transaction names no review digest")
  Just review -> do
    let store = lockedStore lock
    headResult <- observeCurrentHead store
    published <- loadPublishedReview store review
    case (headResult, published) of
      (Left err, _) -> pure (failure "store" (showText err))
      (Right (_, Nothing), _) -> pure (failure "store" "inventory store is not initialized")
      (_, Left err) -> pure (failure "review" (showText err))
      (Right (_, Just headValue), Right bundle) -> do
        eventsResult <- readJournalAtHead store headValue
        case eventsResult of
          Left err -> pure (failure "journal" (showText err))
          Right events
            | Just recordDigest <- closedRecordDigest transaction events ->
                loadCloseRecord store recordDigest >>= \case
                  Left err -> pure (failure "close-record" err)
                  Right record -> do
                    released <- releaseClosedTransaction lock record
                    pure (if released then Right record else failure "head-condition" "the closed transaction's head release did not land; run close again")
            | otherwise -> do
                let document = reviewBundleDocument bundle
                    states = operationStates transaction events
                    classes =
                      Map.fromList
                        [ (plannedOperationId operation, fromMaybe (ClassUnknown "a fenced rollback classes only from its journal" "inventory close") (journalClass states operation))
                        | entry <- reviewOperations document
                        , let operation = reviewPlannedOperation entry
                        ]
                case [operation | (operation, ClassUnknown _ _) <- Map.toList classes] of
                  [] -> commitClose lock (closeRecordFor transaction review document classes Set.empty)
                  unknowns -> pure (failure "unknown-operation" ("a fenced rollback left unproved operations: " <> T.pack (show unknowns)))

reviewDigestOf :: TransactionId -> Maybe ContentDigest
reviewDigestOf transaction = either (const Nothing) Just (mkContentDigest (T.drop 3 (transactionIdText transaction)))

-- | Whether resume could still progress, and why. Resume runs the same serial
-- step: a recovery that the adapter proves complete or safe to retry, or a
-- pending operation whose fresh preflight passes, is progress.
resumeProgress :: AdapterRegistry -> ReviewedPlan -> TransactionId -> [ReviewOperation] -> Map OperationId OperationState -> IO (Maybe Text)
resumeProgress registry reviewed transaction entries states = case nextOperation entries states of
  OperationsFinished -> pure (Just "every operation is complete")
  OperationBlocked _ _ -> pure Nothing
  RecoverOperation entry -> withPrepared entry $ \adapter operation prepared -> do
    decision <- withAdapterEnv transaction operation (adapterRecover adapter operation prepared)
    pure $ case decision of
      RecoveryProvedComplete _ -> Just ("the adapter proves " <> operationText operation <> " complete")
      RecoverySafeToRetry -> Just ("the adapter proves " <> operationText operation <> " safe to retry")
      _ -> Nothing
  ExecuteOperation entry
    -- A retry of an operation already refused with no effect repeats the same
    -- refused write; a passing preflight is not progress.
    | Just (Failed (KnownNoEffect _)) <- Map.lookup (plannedOperationId (reviewPlannedOperation entry)) states -> pure Nothing
  ExecuteOperation entry -> withPrepared entry $ \adapter operation prepared -> do
    checked <- withAdapterEnv transaction operation (adapterPreflight adapter operation prepared)
    pure (either (const Nothing) (const (Just (operationText operation <> " passes a fresh preflight"))) checked)
  where
    withPrepared entry action =
      let operation = reviewPlannedOperation entry
       in case (lookupAdapter registry (plannedExecutor operation), preparedFor reviewed entry) of
            (Right adapter, Right prepared) -> action adapter operation prepared
            _ -> pure Nothing
    operationText = T.pack . show . plannedOperationId

-- | ADR 26 §1: first match wins. Journal classes need no adapter call.
classify :: AdapterRegistry -> ReviewedPlan -> TransactionId -> Map OperationId OperationState -> ReviewOperation -> IO OperationClass
classify registry reviewed transaction states entry = case journalClass states operation of
  Just cls -> pure cls
  Nothing -> case (lookupAdapter registry (plannedExecutor operation), preparedFor reviewed entry) of
    (Left reason, _) -> pure (ClassUnknown reason "an installed adapter")
    (_, Left reason) -> pure (ClassUnknown reason "the saved review's native bundle")
    (Right adapter, Right prepared) -> do
      settled <- withAdapterEnv transaction operation (settleOperationWith adapter operation prepared)
      pure $ case settled of
        SettledNoEffect evidence -> ClassNoEffect evidence
        SettledLanded physical -> ClassLanded physical
        SettledTargetGone physical -> ClassTargetGone physical
        SettledTerminalPartial physical -> ClassTerminalPartial physical
        SettledUnknown reason resolvesBy -> ClassUnknown reason resolvesBy
  where
    operation = reviewPlannedOperation entry

-- | The classes the journal alone proves.
journalClass :: Map OperationId OperationState -> PlannedOperation -> Maybe OperationClass
journalClass states operation = case Map.lookup (plannedOperationId operation) states of
  Just (Completed _) -> Just ClassCompleted
  Nothing -> Just ClassNeverStarted
  Just Pending -> Just ClassNeverStarted
  Just (Failed (KnownNoEffect _)) -> Just ClassRefused
  Just (OperatorResolved marker)
    | "fenced-recovery-proved" `T.isPrefixOf` marker -> Just ClassReverted
  _
    | plannedAction operation == VerifyResource -> Just (ClassNoEffect "a verification writes nothing")
    | otherwise -> Nothing

-- | Creates that never started or were refused, confirmed absent now (O8).
neverStartedAbsent :: AdapterRegistry -> [ReviewOperation] -> Map OperationId OperationClass -> IO (Set ResourceId)
neverStartedAbsent registry entries classes = do
  observed <- traverse observe candidates
  pure (Set.fromList (concat observed))
  where
    candidates =
      [ operation
      | entry <- entries
      , let operation = reviewPlannedOperation entry
      , plannedAction operation == CreateResource
      , Map.lookup (plannedOperationId operation) classes `elem` [Just ClassNeverStarted, Just ClassRefused]
      ]
    observe operation = case lookupAdapter registry (plannedExecutor operation) of
      Left _ -> pure []
      Right adapter -> do
        let resources = NE.toList (plannedResources operation)
        facts <- adapterObserve adapter resources
        pure $ case facts of
          Left _ -> []
          Right set -> [resource | resource <- resources, Just (ConfirmedAbsent _) <- [Map.lookup resource (observationMap set)]]

closeRecordFor :: TransactionId -> ContentDigest -> ReviewDocument -> Map OperationId OperationClass -> Set ResourceId -> CloseRecord
closeRecordFor transaction review document classes absent =
  CloseRecord
    { closedTransaction = transaction
    , closedReview = review
    , closedClasses = classes
    , closedScopes = dispositions
    , closedDesired = desired
    , closedRetainedRemoved =
        Set.fromList
          [ resource
          | resource <- Map.keys (reviewRetentions document) <> Map.keys (reviewMigrations document)
          , any reverted [Map.lookup scope dispositions | scope <- changed, ownedBy scope resource]
          ]
    , closedNeverStarted = absent
    , closedAttestation = Nothing
    }
  where
    base = reviewBaseRevisions document
    desired = reviewDesiredRevisions document
    changed = [scope | scope <- Set.toList (Map.keysSet base <> Map.keysSet desired), Map.lookup scope base /= Map.lookup scope desired]
    dispositions = Map.fromList [(scope, disposition scope) | scope <- changed]
    disposition scope
      | all noEffect (classesOf scope) = RevertTo (Map.lookup scope base)
      | otherwise = KeepDesired
    classesOf scope =
      [ cls
      | entry <- reviewOperations document
      , let operation = reviewPlannedOperation entry
      , any (ownedBy scope) (NE.toList (plannedResources operation))
      , Just cls <- [Map.lookup (plannedOperationId operation) classes]
      ]
    noEffect cls = case cls of
      ClassNeverStarted -> True
      ClassRefused -> True
      ClassReverted -> True
      ClassNoEffect _ -> True
      _ -> False
    ownedBy scope resource = (scopeIdText scope <> "/") `T.isPrefixOf` resourceIdText resource
    reverted = \case
      Just (RevertTo _) -> True
      _ -> False

-- | An attested close accepts nothing: every changed scope keeps the
-- admitted desired revision, no retained entry is removed and no create is
-- recorded as never-started, so the next plan re-observes every member.
attestedRecord :: Attestation -> CloseRecord -> CloseRecord
attestedRecord attestation record =
  record
    { closedScopes = Map.map (const KeepDesired) (closedScopes record)
    , closedRetainedRemoved = Set.empty
    , closedNeverStarted = Set.empty
    , closedAttestation = Just attestation
    }

-- | The single head write of a close: clear the transaction and claim, revert
-- reverted scopes to the review's base and remove their retained additions.
-- Converged revisions and incarnations are untouched. Retried like a journal
-- head advance; a head that no longer names the transaction is already
-- released.
releaseClosedTransaction :: LockedStore s -> CloseRecord -> IO Bool
releaseClosedTransaction locked record = attempt (3 :: Int)
  where
    store = lockedStore locked
    attempt retries = do
      current <- observeCurrentHead store
      case current of
        Right (observed, Just headValue)
          | headActiveTransaction headValue /= Just (transactionIdText (closedTransaction record)) -> pure True
          | otherwise -> do
              written <- replaceObservedHead observed (released headValue)
              case written of
                Right () -> pure True
                Left _ -> do
                  reread <- observeHead store
                  case reread of
                    Right now
                      | fmap headActiveTransaction (observedHeadManifest now) == Just Nothing -> pure True
                      | retries > 0 -> threadDelay (250000 * (4 - retries)) >> attempt (retries - 1)
                    _ -> pure False
        _ -> pure False
    released headValue =
      headValue
        { headGeneration = headGeneration headValue + 1
        , headActiveTransaction = Nothing
        , headExecutorClaim = Nothing
        , headAccepted = Map.foldrWithKey revert (headAccepted headValue) (closedScopes record)
        , headRetained = Map.withoutKeys (headRetained headValue) (closedRetainedRemoved record)
        }
    revert scope disposition accepted = case disposition of
      RevertTo (Just revision) -> Map.insert scope revision accepted
      RevertTo Nothing -> Map.delete scope accepted
      KeepDesired -> accepted
