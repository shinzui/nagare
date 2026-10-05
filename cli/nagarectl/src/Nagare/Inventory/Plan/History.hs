-- | History responsibilities; internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.History
  ( LandedUpdateProof (..)
  , incompleteApplicationOnlyReview
  , loadInventoryHistory
  , loadInventoryPlanningHistory
  , loadUnstartedApplicationCreates
  , seedInventoryHistory
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
  , publishIfAbsent
  , readHead
  , readJournalPrefix
  , readObject
  , replaceHeadIfGenerationMatches
  , reviewKey
  , scopeKey
  )
import Nagare.Inventory.Store qualified as InventoryStore
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
  , scopeKind
  )
import Nagare.Resource.Wire (decodeScope, encodeCanonicalScope)

loadInventoryHistory :: InventoryStore -> IO (Either StoreError InventoryHistory)
loadInventoryHistory store = do
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue) -> do
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
        bytes <- bytesResult >>= maybe (Left (StoreInvalidObject (scopeKey (revisionDigest revision)) "scope member is missing")) Right
        unless (contentDigest bytes == revisionDigest revision) (Left (StoreInvalidObject (scopeKey (revisionDigest revision)) "scope member digest mismatch"))
        declaration <- first (StoreInvalidObject (scopeKey (revisionDigest revision)) . T.pack . show) (decodeScope bytes)
        unless (scopeId declaration == scope) (Left (StoreInvalidObject (scopeKey (revisionDigest revision)) "scope member identity mismatch"))
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

-- | Whether adapter recovery settled the selected intended application
-- update's outcome: it landed exactly as reviewed and is not Ready (F54), or
-- its reviewed target was replaced outside review so it can no longer land
-- (F56). Without that proof only a never-started update may be stopped.
data LandedUpdateProof
  = LandedUpdateUnproved
  | LandedUpdateProved
  deriving stock (Eq, Show)

incompleteApplicationOnlyReview ::
  LandedUpdateProof ->
  ReviewBundle ->
  [JournalEvent] ->
  TransactionId ->
  OperationId ->
  PlannedOperation ->
  Bool
incompleteApplicationOnlyReview landed published events transaction operationId operation =
  let document = reviewBundleDocument published
      reviewed = reviewOperations document
      changed =
        Map.keys
          ( Map.differenceWith
              (\desired base -> if desired == base then Nothing else Just desired)
              (reviewDesiredRevisions document)
              (reviewBaseRevisions document)
          )
      scopes =
        mapMaybe
          (either (const Nothing) Just . decodeScope)
          (Map.elems (reviewBundleScopes published))
      selected = NE.toList (plannedResources operation)
      previous = operationStates transaction events
      otherSettled entry =
        plannedOperationId (reviewPlannedOperation entry) == operationId
          || case Map.lookup (plannedOperationId (reviewPlannedOperation entry)) previous of
            Nothing -> True
            Just Pending -> True
            Just (Completed _) -> True
            _ -> False
      neverIntended = onlyStates (const False)
      -- A landed update was intended and its readiness wait ended ambiguous;
      -- a completed or failed update is not a landed unready one.
      landedUpdate = onlyStates (`elem` [IntentRecorded, Ambiguous])
      onlyStates allowed selectedOp =
        all
          ( \event ->
              eventTransaction event /= transaction
                || eventOperation event /= Just selectedOp
                || case eventState event of
                  Pending -> True
                  OperatorResolved marker -> selectedOp == operationId && "stopped-incomplete-application:" `T.isPrefixOf` marker
                  state -> allowed state
          )
          events
      pendingUpdate scope =
        plannedAction operation == UpdateResource
          -- F63: a standalone data service's StatefulSet update, as F54's.
          && (scopeKind (scopeId scope) == Application || selectedStatefulSet scope)
          && (neverIntended operationId || (landed == LandedUpdateProved && landedUpdate operationId))
          && all
            ( \entry ->
                let op = reviewPlannedOperation entry
                 in plannedExecutor op == KubernetesExecutor
                      && isNothing (reviewFenceDigest entry)
                      && all (owns scope) (NE.toList (plannedResources op))
                      && ( if plannedOperationId op == operationId
                             then True
                             else case Map.findWithDefault Pending (plannedOperationId op) previous of
                               Completed _ -> True
                               Pending -> neverStartedCompanion scope op
                               _ -> False
                         )
            )
            reviewed
      -- F55: a companion that never started had no effect. A verify of any
      -- member is admitted (a corrected review verifies unchanged members,
      -- durable ones included); a create or an update only of a stateless
      -- ConfigMap ordered after the stopped operation (an application update
      -- rewrites its release history).
      neverStartedCompanion scope op =
        neverIntended (plannedOperationId op)
          && case [ member
                  | bundle <- scopeBundles scope
                  , Managed member <- declarations bundle
                  , NE.toList (plannedResources op) == [member ^. #identity]
                  ] of
            [member] ->
              plannedAction op == VerifyResource
                || ( plannedAction op `elem` [CreateResource, UpdateResource]
                       && member ^. #dataPolicy == Stateless
                       && (case member ^. #address of Kubernetes _ "" kind (Just _) _ -> nameText kind == "configmap"; _ -> False)
                       && any (\resource -> OrderedAfter resource `elem` (member ^. #dependencies)) selected
                   )
            _ -> False
      selectedStatefulSet scope =
        scopeKind (scopeId scope) == Standalone
          && any
            ( \bundle ->
                any
                  ( \case
                      Managed member ->
                        [member ^. #identity] == selected
                          && case member ^. #address of
                            Kubernetes _ "apps" kind (Just _) _ -> nameText kind == "statefulset"
                            _ -> False
                      _ -> False
                  )
                  (declarations bundle)
            )
            (scopeBundles scope)
      owns scope resource =
        any
          ( \bundle ->
              any
                ((== resource) . declarationId)
                (declarations bundle)
          )
          (scopeBundles scope)
   in case changed of
        [owner] | scopeKind owner `elem` [Application, Standalone] -> case [scope | scope <- scopes, scopeId scope == owner] of
          [scope] ->
            ( pendingUpdate scope
                || ( all
                       ( \entry ->
                           let planned = reviewPlannedOperation entry
                            in ( plannedAction planned == CreateResource
                                   -- F65: a review that recreates a Service deleted outside
                                   -- review also rewrites its release history; a never-started
                                   -- companion had no effect.
                                   || ( plannedOperationId planned /= operationId
                                          && Map.findWithDefault Pending (plannedOperationId planned) previous == Pending
                                          && neverStartedCompanion scope planned
                                      )
                               )
                                 && plannedExecutor planned == KubernetesExecutor
                                 && isNothing (reviewFenceDigest entry)
                                 && all (owns scope) (NE.toList (plannedResources planned))
                       )
                       reviewed
                       -- F59: a database's later creates (its schedule, signing key and
                       -- companions) never started when its StatefulSet stalls; like an
                       -- application's, they had no effect.
                       && ( if scopeKind owner == Application || selectedStatefulSet scope
                              then all otherSettled reviewed
                              else
                                all
                                  ( \entry ->
                                      let op = plannedOperationId (reviewPlannedOperation entry)
                                       in op == operationId || case Map.lookup op previous of
                                            Just (Completed _) -> True
                                            _ -> False
                                  )
                                  reviewed
                          )
                   )
            )
              && case [ member
                      | bundle <- scopeBundles scope
                      , Managed member <- declarations bundle
                      , [member ^. #identity] == selected
                      ] of
                [member] | member ^. #dataPolicy == Stateless -> case member ^. #address of
                  Kubernetes _ "serving.knative.dev" kind (Just _) _
                    | scopeKind owner == Application -> nameText kind == "service"
                    | nameText kind == "domainmapping" -> case previewScopeMembers scope of
                        Right (_, route) -> route == member
                        Left _ -> False
                  -- F59: a standalone data service's StatefulSet created but never
                  -- Ready. It is stateless; its data lives on the separately created PVC.
                  Kubernetes _ "apps" kind (Just _) _
                    | scopeKind owner == Standalone -> nameText kind == "statefulset"
                  _ -> False
                _ -> False
          _ -> False
        _ -> False

-- Only an idle, unconverged application needs this exceptional history proof.
-- Fetch one committed journal prefix, not a remote read per event. Neither an
-- absent provider object nor a nonconverged revision alone proves no data was
-- created. The original stopped review must still own this exact revision.
loadInventoryPlanningHistory ::
  InventoryStore ->
  CompositionCandidate ->
  IO (Either StoreError InventoryHistory)
loadInventoryPlanningHistory store candidate = do
  loaded <- loadInventoryHistory store
  case loaded of
    Left err -> pure (Left err)
    Right history -> do
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
          proofs <- traverse (loadProof events) [event | event <- events, stopped event]
          pure (Set.unions <$> sequence proofs)
  where
    incomplete =
      Map.keysSet
        ( Map.filterWithKey
            ( \owner revision ->
                Set.member owner selectedOwners
                  -- A stopped standalone data service (F59) leaves never-started
                  -- members too, such as its backup signing key.
                  && scopeKind owner `elem` [Application, Standalone]
                  && Map.lookup owner (headConverged headValue) /= Just revision
            )
            (headAccepted headValue)
        )
    stopped event = case eventState event of
      OperatorResolved marker -> case T.stripPrefix "stopped-incomplete-application:" marker of
        Just token -> either (const False) (const True) (mkContentDigest token)
        Nothing -> False
      _ -> False
    loadProof events stop = case ( eventOperation stop
                                 , T.stripPrefix "tx-" (transactionIdText (eventTransaction stop)) >>= either (const Nothing) Just . mkContentDigest
                                 ) of
      (Just selected, Just digest) -> do
        published <- loadPublishedReview store digest
        pure $ do
          bundle <- published
          let document = reviewBundleDocument bundle
              prefix = takeWhile ((<= eventSequence stop) . eventSequence) events
              transaction = eventTransaction stop
              changed =
                Map.keysSet
                  ( Map.differenceWith
                      (\desired base -> if desired == base then Nothing else Just desired)
                      (reviewDesiredRevisions document)
                      (reviewBaseRevisions document)
                  )
              currentRevision =
                all
                  ( \owner ->
                      Map.lookup owner (reviewDesiredRevisions document) == Map.lookup owner (headAccepted headValue)
                  )
                  (Set.toList changed)
              selectedOperations =
                [ reviewPlannedOperation entry
                | entry <- reviewOperations document
                , plannedOperationId (reviewPlannedOperation entry) == selected
                ]
              validStop = case selectedOperations of
                -- This proof only releases never-started durable members of an
                -- unready create's review. A landed update stop (F54) adds
                -- nothing here.
                [operation] -> incompleteApplicationOnlyReview LandedUpdateUnproved bundle prefix transaction selected operation
                _ -> False
              neverStarted operation =
                all
                  ( \event ->
                      eventTransaction event /= transaction
                        || eventOperation event /= Just (plannedOperationId operation)
                        || eventState event == Pending
                  )
                  events
          pure $
            if reviewContextBinding document == headBinding headValue
              && changed `Set.isSubsetOf` incomplete
              && not (Set.null changed)
              && currentRevision
              && validStop
              && null (reviewBarriers document)
              then
                Set.fromList
                  [ resource
                  | entry <- reviewOperations document
                  , let operation = reviewPlannedOperation entry
                  , -- Only a never-started create may be replanned as a create. A
                  -- never-started verify or update of a durable member that is
                  -- later found absent was deleted out of band (F55).
                  plannedAction operation == CreateResource
                  , neverStarted operation
                  , resource <- NE.toList (plannedResources operation)
                  ]
              else Set.empty
      _ -> pure (Left (StoreInvalidObject "journal" "application stop has no canonical review transaction or operation"))

-- | Seed only unchanged base scopes when opening a new store. A changed or
-- retired scope cannot be reconstructed safely from a candidate's desired view.
seedInventoryHistory :: InventoryStore -> CompositionCandidate -> IO (Either StoreError HeadManifest)
seedInventoryHistory store candidate = do
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue)
      | not (Map.null (headAccepted headValue)) -> pure (Right headValue)
      | otherwise -> do
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
