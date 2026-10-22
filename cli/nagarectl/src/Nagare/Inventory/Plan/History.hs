-- | History responsibilities; internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.History
  ( loadInventoryHistory
  , loadInventoryHistoryAt
  , loadInventoryPlanningHistory
  , loadInventoryPlanningHistoryFrom
  , ReviewInventory (..)
  , reviewInventoryHistory
  , loadUnstartedApplicationCreates
  , seedInventoryHistory
  , seedInventoryHistoryAt
  )
where

import Control.Monad (forM, forM_)
import Data.Aeson (eitherDecodeStrict')
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Adapter
  ( OperationAction (CreateResource, UpdateResource, VerifyResource)
  , PlannedOperation
    ( plannedAction
    , plannedExecutor
    , plannedOperationId
    , plannedResources
    )
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal
  ( JournalEvent
      ( eventOperation
      , eventSequence
      , eventState
      , eventTransaction
      )
  , OperationId
  , OperationState (Ambiguous, Completed, IntentRecorded, OperatorResolved, Pending)
  , TransactionId
  , decodeJournalEvent
  , operationStates
  , transactionIdText
  , validateJournal
  )
import Nagare.Inventory.Plan.CloseRecord (CloseRecord (closedDesired, closedNeverStarted), closedRecordDigest, loadCloseRecord)
import Nagare.Inventory.Plan.Publication (loadPublishedReview)
import Nagare.Inventory.Plan.Types
  ( InventoryHistory (..)
  , MigrationProof (..)
  , ReviewBundle (..)
  , ReviewDocument (..)
  , ReviewOperation (..)
  , encodeReviewDocument
  , retainedReservations
  , reviewBundleDocument
  , reviewBundleScopes
  )
import Nagare.Inventory.PreviewOwnership (previewScopeMembers)
import Nagare.Inventory.ScopeMember (decodeScopeMember)
import Nagare.Inventory.Store
  ( DeletionTombstone
      ( tombstoneAt
      , tombstoneOwner
      , tombstonePhysical
      , tombstoneReview
      , tombstoneRevision
      )
  , HeadManifest
    ( headAccepted
    , headActiveTransaction
    , headBinding
    , headCollected
    , headConverged
    , headGeneration
    , headRetained
    , headSequence
    )
  , InventoryStore
  , RetainedIncarnation
    ( retainedMigrationReview
    , retainedOwner
    , retainedPhysical
    , retainedRevision
    )
  , ScopeRevision (ScopeRevision, revisionDigest)
  , StoreError (StoreConditionFailed, StoreInvalidObject)
  , countStore
  , publishIfAbsent
  , readHead
  , readJournalPrefix
  , readObject
  , replaceHeadIfGenerationMatches
  , reviewKey
  , scopeKey
  )
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Inventory.Store.Counters (Counter (HistoryLoad))
import Nagare.Resource.Inventory
  ( CompositionCandidate
  , Declaration (Managed)
  , Executor (KubernetesExecutor)
  , ResourceBundle (declarations)
  , ScopeChange (ReplaceScope, RetireScope)
  , candidateBase
  , candidateChanges
  , candidateGenerations
  , candidateInventory
  , claimsOf
  , composedDeclarations
  , declarationId
  , inventoryScopes
  , pairedDnsRouteClaim
  , scopeBundles
  , scopeId
  )
import Nagare.Resource.Policy (DataPolicy (Stateless))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
  ( ProviderAddress (Kubernetes)
  , ResourceId
  , ScopeId
  , ScopeKind (Application, Standalone)
  , mkContentDigest
  , nameText
  , resourceIdText
  , scopeIdText
  , scopeKind
  )
import Nagare.Resource.Wire (decodeScope, encodeCanonicalScope)

-- | What an execution registry builds adapters against: the command's store
-- and, when the command already loaded it, the history of the head it pinned.
-- Without one, a factory loads the history as it always did (EP-212).
data ReviewInventory = ReviewInventory
  { executionStore :: !InventoryStore
  , pinnedHistory :: !(Maybe InventoryHistory)
  }
  deriving stock (Generic)

reviewInventoryHistory :: ReviewInventory -> IO (Either StoreError InventoryHistory)
reviewInventoryHistory (ReviewInventory store pinned) = maybe (loadInventoryHistory store) (pure . Right) pinned

loadInventoryHistory :: InventoryStore -> IO (Either StoreError InventoryHistory)
loadInventoryHistory store = do
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue) -> loadInventoryHistoryAt store headValue

-- | The history of a head the caller already read. It never reads the head:
-- the result is a function of that head's bytes and the immutable members it
-- names, so equal heads give equal histories (EP-212).
loadInventoryHistoryAt :: InventoryStore -> HeadManifest -> IO (Either StoreError InventoryHistory)
loadInventoryHistoryAt store headValue = countStore store HistoryLoad $ do
  loaded <- traverse (loadScope store) (Map.toAscList (headAccepted headValue))
  retained <- traverse (loadRetained store) (Map.toAscList (headRetained headValue))
  collected <- traverse (loadCollected store) (Map.toAscList (headCollected headValue))
  migrations <-
    traverse
      (loadMigrationReview store)
      [ (resource, digest)
      | (resource, incarnation) <- Map.toAscList (headRetained headValue)
      , Just digest <- [retainedMigrationReview incarnation]
      ]
  pure $ do
    accepted <- Map.fromList <$> sequence loaded
    historical <- Map.fromList <$> sequence retained
    _ <- sequence collected
    migrationProofs <- Map.fromList <$> sequence migrations
    let reservations = retainedReservations historical
        claimHolders =
          Map.fromListWith
            (<>)
            [ (claim, [Managed resource])
            | (_, resource) <- Map.elems historical
            , (_, claim) <- NE.toList (claimsOf (Managed resource))
            ]
    unless
      (all (\(claim, holders) -> length holders == 1 || pairedDnsRouteClaim claim holders) (Map.toList claimHolders))
      (Left (StoreInvalidObject "head.json" "retained address claims overlap"))
    acceptedDeclarations <-
      first
        (StoreInvalidObject "head.json" . T.pack . show)
        (composedDeclarations (fmap snd accepted))
    let acceptedIds = Set.fromList (map declarationId acceptedDeclarations)
        activeManaged =
          Map.fromList
            [(resource ^. #identity, resource) | Managed resource <- acceptedDeclarations]
        activeRetained = Set.intersection acceptedIds (Map.keysSet historical)
    unless
      (Set.null (Set.intersection acceptedIds (Map.keysSet (headCollected headValue))))
      (Left (StoreInvalidObject "head.json" "collected resource is also active"))
    forM_ (Set.toAscList activeRetained) $ \resource ->
      case ( Map.lookup resource historical
           , Map.lookup resource activeManaged
           , Map.lookup resource migrationProofs
           ) of
        (Just (incarnation, source), Just destination, Just proof)
          | retainedOwner incarnation == migrationProofOwner proof
          , retainedRevision incarnation == migrationProofRevision proof
          , retainedPhysical incarnation == migrationProofPhysical proof
          , source ^. #address == migrationProofSourceAddress proof
          , destination ^. #address == migrationProofDestinationAddress proof
          , Set.null
              ( Set.intersection
                  (Set.fromList (map snd (NE.toList (claimsOf (Managed source)))))
                  (Set.fromList (map snd (NE.toList (claimsOf (Managed destination)))))
              ) ->
              pure ()
        _ -> Left (StoreInvalidObject "head.json" "active retained resource lacks a disjoint reviewed migration")
    pure (InventoryHistory headValue accepted (headConverged headValue) historical Set.empty)
  where
    loadScope inventoryStore (scope, revision) = do
      bytesResult <- readObject inventoryStore (scopeKey (revisionDigest revision))
      pure $ do
        declaration <- bytesResult >>= decodeScopeMember scope (revisionDigest revision)
        pure (scope, (revision, declaration))
    loadRetained inventoryStore (resourceId, retained) = do
      let revision = retainedRevision retained
          key = scopeKey (revisionDigest revision)
      bytesResult <- readObject inventoryStore key
      pure $ do
        bytes <- bytesResult >>= maybe (Left (StoreInvalidObject key "retained scope member is missing")) Right
        unless
          (contentDigest bytes == revisionDigest revision)
          (Left (StoreInvalidObject key "retained scope member digest mismatch"))
        declaration <- first (StoreInvalidObject key . T.pack . show) (decodeScope bytes)
        unless
          (scopeId declaration == retainedOwner retained)
          (Left (StoreInvalidObject key "retained scope owner mismatch"))
        -- A contribution target (for example the access backend map) exists only
        -- in composition. Consumers that contribute to it retire before its owner,
        -- so composing the owner scope alone reproduces the retained member (F40).
        let composedAlone =
              either
                (const [])
                id
                (composedDeclarations (Map.singleton (scopeId declaration) declaration))
        managed <-
          maybe
            (Left (StoreInvalidObject key "retained resource declaration is missing"))
            Right
            ( listToMaybe
                ( [ resource
                  | bundle <- scopeBundles declaration
                  , Managed resource <- bundle ^. #declarations
                  , resource ^. #identity == resourceId
                  ]
                    <> [ resource
                       | Managed resource <- composedAlone
                       , resource ^. #identity == resourceId
                       ]
                )
            )
        unless
          (managed ^. #owner == retainedOwner retained)
          (Left (StoreInvalidObject key "retained resource owner mismatch"))
        pure (resourceId, (retained, managed))
    loadCollected inventoryStore (resourceId, tombstone) = do
      let historical =
            InventoryStore.RetainedIncarnation
              (tombstoneOwner tombstone)
              (tombstoneRevision tombstone)
              (tombstonePhysical tombstone)
              (tombstoneAt tombstone)
              Nothing
              Nothing
          digest = tombstoneReview tombstone
          key = reviewKey digest
      declaration <- loadRetained inventoryStore (resourceId, historical)
      review <- readObject inventoryStore key
      pure $ do
        _ <- declaration
        bytes <- review >>= maybe (Left (StoreInvalidObject key "collection review is missing")) Right
        unless
          (contentDigest bytes == digest)
          (Left (StoreInvalidObject key "collection review digest mismatch"))
        pure ()
    loadMigrationReview inventoryStore (resourceId, digest) = do
      let key = reviewKey digest
      review <- readObject inventoryStore key
      pure $ do
        bytes <- review >>= maybe (Left (StoreInvalidObject key "migration review is missing")) Right
        unless
          (contentDigest bytes == digest)
          (Left (StoreInvalidObject key "migration review digest mismatch"))
        document <- first (StoreInvalidObject key . T.pack) (eitherDecodeStrict' bytes)
        unless
          (encodeReviewDocument document == bytes)
          (Left (StoreInvalidObject key "migration review is not canonical"))
        proof <-
          maybe
            (Left (StoreInvalidObject key "migration proof is missing"))
            Right
            (Map.lookup resourceId (reviewMigrations document))
        pure (resourceId, proof)

-- Only an idle, unconverged application needs this exceptional history proof.
-- Fetch one committed journal prefix, not a remote read per event. Neither an
-- absent provider object nor a nonconverged revision alone proves no data was
-- created. The original stopped review must still own this exact revision.
loadInventoryPlanningHistory ::
  InventoryStore ->
  CompositionCandidate ->
  IO (Either StoreError InventoryHistory)
loadInventoryPlanningHistory store candidate =
  loadInventoryHistory store >>= either (pure . Left) (\history -> loadInventoryPlanningHistoryFrom store history candidate)

-- | 'loadInventoryPlanningHistory' over a history already loaded (EP-212).
loadInventoryPlanningHistoryFrom ::
  InventoryStore ->
  InventoryHistory ->
  CompositionCandidate ->
  IO (Either StoreError InventoryHistory)
loadInventoryPlanningHistoryFrom store history candidate = do
  unstarted <- loadUnstartedApplicationCreates store selected (historyHead history)
  pure ((\proof -> history {historyUnstartedCreates = proof}) <$> unstarted)
  where
    -- A retirement may also leave never-started members behind (F58).
    selected =
      Set.fromList
        [ owner
        | change <- NE.toList (candidateChanges candidate)
        , owner <- case change of
            ReplaceScope declaration -> [scopeId declaration]
            RetireScope scope _ -> [scope]
            _ -> []
        ]

loadUnstartedApplicationCreates ::
  InventoryStore ->
  Set ScopeId ->
  HeadManifest ->
  IO (Either StoreError (Set ResourceId))
loadUnstartedApplicationCreates store selectedOwners headValue
  | not (isNothing (headActiveTransaction headValue)) || Set.null incomplete =
      pure (Right Set.empty)
  | otherwise = do
      loaded <- readJournalPrefix store (headSequence headValue)
      case loaded
        >>= traverse (first (StoreInvalidObject "journal") . decodeJournalEvent)
        >>= first (StoreInvalidObject "journal") . validateJournal of
        Left err -> pure (Left err)
        Right events -> do
          -- ADR 26: a close records the creates that never started and were
          -- absent at close; they hold while the scope's accepted revision is
          -- still the closed review's desired revision. A closed transaction
          -- is final, so any later event naming it voids the proof.
          let final event = not (any (\later -> eventTransaction later == eventTransaction event && eventSequence later > eventSequence event) events)
          closes <- traverse (loadCloseRecord store) [digest | event <- events, final event, Just digest <- [closedRecordDigest (eventTransaction event) [event]]]
          let closed =
                Set.unions
                  [ Set.filter (\resource -> any (\scope -> ownedBy scope resource && Map.lookup scope (headAccepted headValue) == Map.lookup scope (closedDesired record)) (Set.toList selectedOwners)) (closedNeverStarted record)
                  | Right record <- closes
                  ]
              ownedBy scope resource = (scopeIdText scope <> "/") `T.isPrefixOf` resourceIdText resource
          pure (Right closed)
  where
    incomplete =
      Map.keysSet
        ( Map.filterWithKey
            ( \owner revision ->
                Set.member owner selectedOwners
                  -- A closed scope of any kind (F59, ADR 26) leaves
                  -- never-started members, such as a database's signing key.
                  && Map.lookup owner (headConverged headValue) /= Just revision
            )
            (headAccepted headValue)
        )

-- | Seed only unchanged base scopes when opening a new store. A changed or
-- retired scope cannot be reconstructed safely from a candidate's desired view.
seedInventoryHistory :: InventoryStore -> CompositionCandidate -> IO (Either StoreError HeadManifest)
seedInventoryHistory store candidate = do
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue) -> seedInventoryHistoryAt store headValue candidate

-- | 'seedInventoryHistory' from a head the caller already read (EP-212). It
-- returns that head unchanged unless the store is new and was seeded.
seedInventoryHistoryAt :: InventoryStore -> HeadManifest -> CompositionCandidate -> IO (Either StoreError HeadManifest)
seedInventoryHistoryAt store headValue candidate
  | not (Map.null (headAccepted headValue)) = pure (Right headValue)
  | otherwise = do
      let desired = inventoryScopes (candidateInventory candidate)
          unchanged =
            [ (scope, generation, declaration)
            | (scope, generation) <- Map.toAscList (candidateBase candidate)
            , Map.lookup scope (candidateGenerations candidate) == Just generation
            , Just declaration <- [Map.lookup scope desired]
            ]
          reconstructable = Map.keysSet (candidateBase candidate) == Set.fromList [scope | (scope, _, _) <- unchanged]
      if not reconstructable
        then pure (Left (StoreConditionFailed "new inventory store cannot reconstruct a changed or retired base scope"))
        else do
          published <- forM unchanged $ \(_, _, declaration) -> do
            let bytes = encodeCanonicalScope declaration
            publishIfAbsent store (scopeKey (contentDigest bytes)) bytes
          case sequence published of
            Left err -> pure (Left err)
            Right _ -> do
              let revisions =
                    Map.fromList
                      [ (scope, ScopeRevision generation (contentDigest (encodeCanonicalScope declaration)))
                      | (scope, generation, declaration) <- unchanged
                      ]
                  replacement =
                    headValue
                      { headGeneration = headGeneration headValue + 1
                      , headAccepted = revisions
                      , headConverged = revisions
                      }
              replaced <- replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) replacement
              pure (replacement <$ replaced)
