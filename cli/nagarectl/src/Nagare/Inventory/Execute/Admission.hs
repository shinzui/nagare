{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Admission responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Admission
  ( admit
  )
where

import Control.Monad (forM, forM_)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( Adapter (adapterPreflight)
  , AdapterRegistry
  , MigrationStage (BackUpSource)
  , OperationAction
    ( MigrateResource
    , OpenMaintenanceSession
    , RestoreLiveDatabase
    )
  , PlannedOperation (plannedAction, plannedExecutor)
  , ResourceObservation (ObservedPresent)
  , lookupAdapter
  , observationMap
  , observeWithRegistry
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute.Claims (observeCurrentHead)
import Nagare.Inventory.Execute.Inputs
  ( preparedFor
  , validateOperationInputs
  )
import Nagare.Inventory.Execute.Journal (appendEvent)
import Nagare.Inventory.Execute.Types
  ( AdmissionError (..)
  , ExecutablePlan (..)
  , failure
  , reviewDocumentDigest
  , showText
  , timestamp
  , transactionFor
  )
import Nagare.Inventory.Journal
  ( OperationState (Pending)
  , transactionIdText
  )
import Nagare.Inventory.Migration.Types (MigrationContract (..))
import Nagare.Inventory.Plan
  ( InventoryHistory (historyAccepted, historyHead)
  , MigrationProof
    ( migrationProofContract
    , migrationProofDestinationAddress
    , migrationProofOwner
    , migrationProofPhysical
    , migrationProofRevision
    , migrationProofSourceAddress
    )
  , RetentionProof
    ( retentionOwner
    , retentionPhysical
    , retentionRevision
    )
  , ReviewDocument
    ( reviewBaseRevisions
    , reviewContextBinding
    , reviewDesiredRevisions
    , reviewHeadGeneration
    , reviewHeadSequence
    , reviewMigrations
    , reviewOperations
    , reviewRetentions
    )
  , ReviewOperation (reviewPlannedOperation)
  , ReviewedPlan
  , loadInventoryHistory
  , reviewedDocument
  )
import Nagare.Inventory.Store
  ( ExecutorClaim (ExecutorClaim)
  , HeadManifest
    ( headAccepted
    , headActiveTransaction
    , headBinding
    , headClientIdentity
    , headCollected
    , headDataFence
    , headExecutorClaim
    , headGeneration
    , headRetained
    , headSequence
    )
  , InventoryStore
  , LockedStore
  , RetainedIncarnation (RetainedIncarnation)
  , ScopeRevision (revisionDigest)
  , lockedStore
  , readObject
  , replaceObservedHead
  , scopeKey
  , storeClientIdentity
  )
import Nagare.Resource.Inventory (Executor (..))
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Policy (DataPolicy (..))
import Nagare.Resource.Types (ResourceId, digestText)
import Nagare.Resource.Wire (decodeScope)

admit :: LockedStore s -> AdapterRegistry -> ReviewedPlan -> IO (Either (NonEmpty AdmissionError) (ExecutablePlan s))
admit locked registry reviewed = do
  let store = lockedStore locked
      document = reviewedDocument reviewed
      transaction = transactionFor document
  headResult <- observeCurrentHead store
  case headResult of
    Left err -> pure (failure "store" (showText err))
    Right (_, Nothing) -> pure (failure "store" "inventory store is not initialized")
    Right (observed, Just headValue) -> do
      let staticErrors =
            [AdmissionError "context-binding" "review belongs to a different context or provider target" | reviewContextBinding document /= headBinding headValue]
              <> [ AdmissionError "deferred-operation" "new live database restores and interactive maintenance sessions are deferred; recover an already-admitted transaction by its original ID"
                 | operation <- reviewOperations document
                 , plannedAction (reviewPlannedOperation operation)
                     `elem` [RestoreLiveDatabase, OpenMaintenanceSession]
                 ]
              <> [AdmissionError "stale-head" "review was issued against a different head generation or journal sequence" | reviewHeadGeneration document /= headGeneration headValue || reviewHeadSequence document /= headSequence headValue]
              <> [AdmissionError "stale-base" "review base revisions differ from accepted desired state" | reviewBaseRevisions document /= headAccepted headValue]
              <> [AdmissionError "active-transaction" "another transaction is unresolved" | isJust (headActiveTransaction headValue)]
              <> [AdmissionError "active-data-fence" "a live data target remains fenced; recover and verify it before applying another review" | isJust (headDataFence headValue)]
              <> [ AdmissionError "retention-base" "retention proof does not name the accepted scope revision"
                 | (_, proof) <- Map.toAscList (reviewRetentions document)
                 , Map.lookup (retentionOwner proof) (headAccepted headValue) /= Just (retentionRevision proof)
                 ]
              <> [ AdmissionError "retention-history" "retained resource already has a historical incarnation"
                 | resource <- Map.keys (reviewRetentions document)
                 , Map.member resource (headRetained headValue)
                 ]
              <> [ AdmissionError "migration-base" "migration source differs from the accepted scope revision"
                 | (resource, proof) <- Map.toAscList (reviewMigrations document)
                 , Map.lookup (migrationProofOwner proof) (headAccepted headValue)
                     /= Just (migrationProofRevision proof)
                     || Map.member resource (headRetained headValue)
                     || Map.member resource (headCollected headValue)
                 ]
              <> validateOperationInputs registry reviewed Map.empty
      case staticErrors of
        firstError : rest -> pure (Left (firstError :| rest))
        [] -> do
          deferred <- deferredScheduledPrune store headValue document
          case deferred of
            Left err -> pure (failure "deferred-operation" err)
            Right True ->
              pure
                ( failure
                    "deferred-operation"
                    "new scheduled pruning is deferred; recover an already-admitted partial prune by its original review"
                )
            Right False -> do
              coverage <- retentionCoverage store document
              continueAdmission store document transaction observed headValue coverage
  where
    continueAdmission store document transaction observed headValue coverage = case coverage of
      Left err -> pure (failure "retention-coverage" err)
      Right retainedRequests -> do
        migrationChecked <- migrationCoverage store document
        migrationSourceErrors <- case migrationChecked of
          Left _ -> pure []
          Right () -> migrationAdmissionChecks registry reviewed
        let sourceChecked = case migrationSourceErrors of
              [] -> Right ()
              firstError : _ -> Left (admissionErrorMessage firstError)
        checked <-
          if Map.null retainedRequests
            then pure (Right ())
            else do
              observed <- observeWithRegistry registry retainedRequests
              pure $ do
                facts <- observed
                forM_ (Map.toAscList (reviewRetentions document)) $ \(resource, proof) ->
                  unless
                    ( Map.lookup resource (observationMap facts)
                        == Just (ObservedPresent (retentionPhysical proof))
                    )
                    (Left "retained physical incarnation changed since review")
        case migrationChecked >> sourceChecked of
          Left err -> pure (failure "migration-coverage" err)
          Right () -> case checked of
            Left _ -> pure (failure "retention-observation" "retained physical incarnation could not be reverified")
            Right () -> do
              now <- timestamp
              let client = maybe (headClientIdentity headValue) id (storeClientIdentity store)
                  claim = ExecutorClaim (transactionIdText transaction) client 1 now
                  retained =
                    Map.map
                      ( \proof ->
                          RetainedIncarnation
                            (retentionOwner proof)
                            (retentionRevision proof)
                            (retentionPhysical proof)
                            now
                            Nothing
                      )
                      (reviewRetentions document)
                  migrated =
                    Map.map
                      ( \proof ->
                          RetainedIncarnation
                            (migrationProofOwner proof)
                            (migrationProofRevision proof)
                            (migrationProofPhysical proof)
                            now
                            (Just (reviewDocumentDigest document))
                      )
                      (reviewMigrations document)
                  activated =
                    headValue
                      { headGeneration = headGeneration headValue + 1
                      , headAccepted = reviewDesiredRevisions document
                      , headRetained = Map.unions [retained, migrated, headRetained headValue]
                      , headActiveTransaction = Just (transactionIdText transaction)
                      , headExecutorClaim = Just claim
                      }
              activation <- replaceObservedHead observed activated
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
deferredScheduledPrune ::
  InventoryStore ->
  HeadManifest ->
  ReviewDocument ->
  IO (Either Text Bool)
deferredScheduledPrune store headValue document = do
  checked <- forM changed $ \(_, revision) -> do
    member <- readObject store (scopeKey (revisionDigest revision))
    pure $ do
      bytes <-
        first showText member
          >>= maybe
            (Left "reviewed scope member is missing")
            Right
      scope <- first showText (decodeScope bytes)
      let fields = Resource.scopeOverrides scope
      pure
        ( Map.member "scheduled.prune.backup.scope" fields
            && Map.notMember "scheduled.prune.recovery.review" fields
        )
  pure (or <$> sequence checked)
  where
    changed =
      [ (scope, revision)
      | (scope, revision) <- Map.toAscList (reviewDesiredRevisions document)
      , Map.lookup scope (headAccepted headValue) /= Just revision
      ]

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
    desiredDeclarations <-
      first
        showText
        ( Resource.composedDeclarations
            (Map.fromList [(Resource.scopeId scope, scope) | scope <- scopes])
        )
    oldDeclarations <-
      first
        showText
        ( Resource.composedDeclarations
            (fmap snd (historyAccepted history))
        )
    let desiredIds = Set.fromList (map Resource.declarationId desiredDeclarations)
        removedChildren =
          [ resource
          | Resource.ObservedChild resource _ _ _ _ <- oldDeclarations
          , Set.notMember resource desiredIds
          ]
        removed =
          Map.fromList
            [ (resource ^. #identity, (resource ^. #owner, revision, resource ^. #executor))
            | Resource.Managed resource <- oldDeclarations
            , Just (revision, _) <- [Map.lookup (resource ^. #owner) (historyAccepted history)]
            , Set.notMember (resource ^. #identity) desiredIds
            ]
        proofs = reviewRetentions document
    unless
      (null removedChildren)
      (Left "observed controller children cannot disappear without retained child claims")
    let previouslyActive = Set.fromList (map Resource.declarationId oldDeclarations)
    unless
      ( Set.null
          ( Set.difference
              (Set.intersection desiredIds (Map.keysSet (headRetained (historyHead history))))
              previouslyActive
          )
      )
      (Left "retained logical identity cannot be reactivated without reviewed recovery")
    unless
      (Set.null (Set.intersection desiredIds (Map.keysSet (headCollected (historyHead history)))))
      (Left "collected logical identity cannot be reused after its deletion tombstone")
    unless
      (Map.keysSet removed == Map.keysSet proofs)
      (Left "removed managed resources require exactly one retained-incarnation proof")
    forM_ (Map.toAscList proofs) $ \(resource, proof) ->
      unless
        ( fmap (\(owner, revision, _) -> (owner, revision)) (Map.lookup resource removed)
            == Just (retentionOwner proof, retentionRevision proof)
        )
        (Left "retention proof differs from accepted resource ownership history")
    pure
      ( Map.fromListWith
          (<>)
          [(executor, [resource]) | (resource, (_, _, executor)) <- Map.toAscList removed]
      )
  where
    loadDesired revision = do
      let key = scopeKey (revisionDigest revision)
      loaded <- readObject store key
      pure $ do
        bytes <- first showText loaded >>= maybe (Left "desired scope member is missing") Right
        unless
          (contentDigest bytes == revisionDigest revision)
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
    sources =
      [ entry
      | entry <- reviewOperations (reviewedDocument reviewed)
      , plannedAction (reviewPlannedOperation entry) == MigrateResource BackUpSource
      ]

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
    desiredDeclarations <-
      first
        showText
        ( Resource.composedDeclarations
            (Map.fromList [(Resource.scopeId scope, scope) | scope <- scopes])
        )
    oldDeclarations <-
      first
        showText
        ( Resource.composedDeclarations
            (fmap snd (historyAccepted history))
        )
    let oldManaged =
          Map.fromList
            [(resource ^. #identity, resource) | Resource.Managed resource <- oldDeclarations]
        newManaged =
          Map.fromList
            [(resource ^. #identity, resource) | Resource.Managed resource <- desiredDeclarations]
    forM_ (Map.toAscList (reviewMigrations document)) $ \(resourceId, proof) -> do
      source <-
        maybe
          (Left "migration source declaration is missing")
          Right
          (Map.lookup resourceId oldManaged)
      destination <-
        maybe
          (Left "migration destination declaration is missing")
          Right
          (Map.lookup resourceId newManaged)
      let sourceClaims = Set.fromList (map snd (NE.toList (Resource.claimsOf (Resource.Managed source))))
          destinationClaims = Set.fromList (map snd (NE.toList (Resource.claimsOf (Resource.Managed destination))))
      unless
        ( source ^. #owner == migrationProofOwner proof
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
              _ -> False
        )
        (Left "migration proof differs from historical or destination declaration")
    pure ()
  where
    loadDesired revision = do
      let key = scopeKey (revisionDigest revision)
      loaded <- readObject store key
      pure $ do
        bytes <- first showText loaded >>= maybe (Left "migration destination scope is missing") Right
        unless
          (contentDigest bytes == revisionDigest revision)
          (Left "migration destination scope digest mismatch")
        first showText (decodeScope bytes)
