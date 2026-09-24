-- | Pure inventory planning and digest-bound review bundles.
module Nagare.Inventory.Plan
  ( InventoryHistory
  , loadInventoryHistory
  , historyHead
  , seedInventoryHistory
  , historyAccepted
  , historyConverged
  , historyRetained
  , historyReservations
  , ObservationRequirements
  , observationRequirements
  , requiredResources
  , requirementsByExecutor
  , migrationIncarnations
  , LifecycleDecisionKind (..)
  , LifecycleProposal (..)
  , LifecycleDecisions
  , noLifecycleDecisions
  , lifecycleObservationDigest
  , validateLifecycleDecisions
  , combineDecisions
  , PlanError (..)
  , ChangeProposal
  , proposalOperations
  , proposalDesired
  , RetentionProof (..)
  , planChanges
  , ReviewOperation (..)
  , ReviewDocument (..)
  , ReviewBundle
  , reviewBundleDocument
  , reviewBundleScopes
  , reviewBundleNative
  , ReviewError (..)
  , ReviewedPlan
  , reviewedDocument
  , reviewedNativeBundles
  , prepareReview
  , reviewDigest
  , encodeReviewDocument
  , publishReview
  , loadPublishedReview
  , writeReviewBundle
  , loadReviewBundle
  , verifyReview
  , verifyActiveReview
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Either (partitionEithers)
import Data.Generics.Labels ()
import Data.List (sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Adapter
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Inventory.Store
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Inventory
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types
import Nagare.Resource.Wire
import System.Directory
import System.FilePath
import System.IO.Temp (withTempDirectory)
import System.Posix.Files (setFileMode)

data InventoryHistory = InventoryHistory
  { historyHead :: !HeadManifest
  , historyAccepted :: !(Map ScopeId (ScopeRevision, ScopeDeclaration))
  , historyConverged :: !(Map ScopeId ScopeRevision)
  , historyRetained :: !(Map ResourceId (RetainedIncarnation, ManagedResource))
  }
  deriving stock (Eq, Show)

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
      pure $ do
        accepted <- Map.fromList <$> sequence loaded
        historical <- Map.fromList <$> sequence retained
        _ <- sequence collected
        let reservations = retainedReservations historical
            count = sum [length (NE.toList (claimsOf (Managed resource))) | (_, resource) <- Map.elems historical]
        unless (Map.size reservations == count)
          (Left (StoreInvalidObject "head.json" "retained address claims overlap"))
        acceptedDeclarations <- first (StoreInvalidObject "head.json" . T.pack . show)
          (composedDeclarations (fmap snd accepted))
        let acceptedIds = Set.fromList (map declarationId acceptedDeclarations)
        unless (Set.null (Set.intersection acceptedIds (Map.keysSet historical `Set.union` Map.keysSet (headCollected headValue))))
          (Left (StoreInvalidObject "head.json" "historical resource is also active"))
        pure (InventoryHistory headValue accepted (headConverged headValue) historical)
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
        unless (contentDigest bytes == revisionDigest revision)
          (Left (StoreInvalidObject key "retained scope member digest mismatch"))
        declaration <- first (StoreInvalidObject key . T.pack . show) (decodeScope bytes)
        unless (scopeId declaration == retainedOwner retained)
          (Left (StoreInvalidObject key "retained scope owner mismatch"))
        managed <- maybe (Left (StoreInvalidObject key "retained resource declaration is missing")) Right
          (listToMaybe [resource | bundle <- scopeBundles declaration,
            Managed resource <- bundle ^. #declarations, resource ^. #identity == resourceId])
        unless (managed ^. #owner == retainedOwner retained)
          (Left (StoreInvalidObject key "retained resource owner mismatch"))
        pure (resourceId, (retained, managed))
    loadCollected inventoryStore (resourceId, tombstone) = do
      let historical = InventoryStore.RetainedIncarnation (tombstoneOwner tombstone)
            (tombstoneRevision tombstone) (tombstonePhysical tombstone) (tombstoneAt tombstone)
          digest = tombstoneReview tombstone
          key = reviewKey digest
      declaration <- loadRetained inventoryStore (resourceId, historical)
      review <- readObject inventoryStore key
      pure $ do
        _ <- declaration
        bytes <- review >>= maybe (Left (StoreInvalidObject key "collection review is missing")) Right
        unless (contentDigest bytes == digest)
          (Left (StoreInvalidObject key "collection review digest mismatch"))
        pure ()

historyReservations :: InventoryHistory -> Map CanonicalClaim ClaimHolder
historyReservations = retainedReservations . historyRetained

retainedReservations :: Map ResourceId (RetainedIncarnation, ManagedResource) -> Map CanonicalClaim ClaimHolder
retainedReservations entries = Map.fromList
  [ (claim, ClaimHolder (retainedOwner retained) resourceId (retainedPhysical retained) ResourceInventory.RetainedIncarnation)
  | (resourceId, (retained, managed)) <- Map.toAscList entries
  , (_, claim) <- NE.toList (claimsOf (Managed managed))
  ]

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

data ObservationRequirements = ObservationRequirements
  { requiredResources :: !(Set ResourceId)
  , requirementsByExecutor :: !(Map Executor [ResourceId])
  , migrationIncarnations :: !(Map ResourceId (ManagedResource, ManagedResource))
  }
  deriving stock (Eq, Show)

observationRequirements :: CompositionCandidate -> InventoryHistory -> ObservationRequirements
observationRequirements candidate history =
  ObservationRequirements ids grouped migrations
  where
    desiredManaged = Map.fromList
      [(resource ^. #identity, resource) | Managed resource <- inventoryDeclarations (candidateInventory candidate)]
    historicalManaged = Map.fromList
      [(resource ^. #identity, resource) | Managed resource <- historyDeclarations history]
    migrations = Map.mapMaybe migration
      (Map.intersectionWith (,) historicalManaged desiredManaged)
    migration (source, destination)
      | source ^. #executor /= destination ^. #executor
        || source ^. #address /= destination ^. #address = Just (source, destination)
      | otherwise = Nothing
    -- The ordinary observation map has one entry per logical resource. For a
    -- changed executor it must ask only the destination adapter; otherwise
    -- observeWithRegistry receives duplicate IDs and refuses before the
    -- planner can report the required migration review. The source remains
    -- available separately in migrationIncarnations for a future dual read.
    managed = [(resourceId, resource ^. #executor)
      | (resourceId, resource) <- Map.toAscList (Map.union desiredManaged historicalManaged)]
      <> [(resourceId, resource ^. #executor)
         | CollectRetained resourceId <- NE.toList (candidateChanges candidate)
         , Just (_, resource) <- [Map.lookup resourceId (historyRetained history)]]
    ids = Set.fromList (map fst managed)
    grouped = Map.map (Set.toAscList . Set.fromList) (Map.fromListWith (<>) [(executor, [resource]) | (resource, executor) <- managed])

data LifecycleDecisionKind = ApproveAdoption | ApproveTransfer | ApproveRetirement | ApproveMigration | ApproveCollection
  deriving stock (Eq, Ord, Show, Generic)

data LifecycleProposal = LifecycleProposal
  { lifecycleResource :: !ResourceId
  , lifecycleDecision :: !LifecycleDecisionKind
  , lifecycleEvidence :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

data LifecycleDecisions = LifecycleDecisions !(Maybe (CompositionCandidate, InventoryHistory)) !(Map ResourceId LifecycleProposal)
  deriving stock (Eq, Show)

noLifecycleDecisions :: LifecycleDecisions
noLifecycleDecisions = LifecycleDecisions Nothing Map.empty

-- | A review can combine independently validated lifecycle requests only
-- when each names a different logical resource. planChanges revalidates the
-- combined set against its own candidate, history, and observations.
combineDecisions :: LifecycleDecisions -> LifecycleDecisions -> Either (NonEmpty PlanError) LifecycleDecisions
combineDecisions (LifecycleDecisions firstCandidate firstDecisions) (LifecycleDecisions secondCandidate secondDecisions) =
  case Map.keys (Map.intersection firstDecisions secondDecisions) of
    overlapping@(_:_) -> Left (PlanError "duplicate-lifecycle-decision"
      "resource has more than one lifecycle decision" overlapping :| [])
    [] -> case (firstCandidate, secondCandidate) of
      (Just firstReviewed, Just secondReviewed) | firstReviewed /= secondReviewed -> Left (PlanError "stale-lifecycle-context"
        "lifecycle decisions were validated for different candidates or inventory histories" [] :| [])
      _ -> Right (LifecycleDecisions (firstCandidate <|> secondCandidate)
        (Map.union firstDecisions secondDecisions))

-- | Bind an operator decision to one observed incarnation in one provider
-- target. A new observation or a different target requires a fresh decision.
lifecycleObservationDigest :: ContextBinding -> ResourceId -> ResourceObservation -> ContentDigest
lifecycleObservationDigest binding resource fact =
  contentDigest (either (error . T.unpack) id (canonicalValue
    (object ["binding" .= binding, "resource" .= resource, "observation" .= fact])))

validateLifecycleDecisions :: CompositionCandidate -> InventoryHistory -> ObservationSet -> [LifecycleProposal] -> Either (NonEmpty PlanError) LifecycleDecisions
validateLifecycleDecisions candidate history observations proposals =
  if null errors then Right (LifecycleDecisions (Just (candidate, history)) values) else Left (NE.fromList errors)
  where
    values = Map.fromList [(lifecycleResource proposal, proposal) | proposal <- proposals]
    desired = Map.fromList [(declarationId declaration, declaration) | declaration <- inventoryDeclarations (candidateInventory candidate)]
    historical = Map.fromList [(declarationId declaration, declaration) | declaration <- historyDeclarations history]
    known = Map.keysSet desired `Set.union` Map.keysSet historical
      `Set.union` Map.keysSet (historyRetained history)
    observed = observationMap observations
    retirementIntent resource = listToMaybe
      [intent | RetireScope scope intent <- NE.toList (candidateChanges candidate)
      , Just (Managed old) <- [Map.lookup resource historical], old ^. #owner == scope]
    decisionError proposal =
      let resource = lifecycleResource proposal
          issue code message = [PlanError code message [resource]]
          fact = Map.lookup resource observed
          evidence = maybe [] (\value ->
            if lifecycleEvidence proposal == lifecycleObservationDigest
              (inventoryBinding (candidateInventory candidate)) resource value
            then [] else issue "stale-lifecycle-evidence" "decision evidence differs from the current observation") fact
          kind = lifecycleDecision proposal
          shape = case kind of
            ApproveAdoption -> case (Map.lookup resource desired, Map.lookup resource historical, fact) of
              (Just (Managed _), Nothing, Just (ObservedUnowned _)) -> []
              _ -> issue "invalid-adoption" "adoption needs a new managed declaration and an unowned incarnation; an existing ownership stamp needs authoritative history"
            ApproveTransfer -> case (Map.lookup resource desired, Map.lookup resource historical, fact) of
              (Just (Managed next), Just (Managed old), Just (ObservedPresent _))
                | next ^. #owner /= old ^. #owner
                , Set.fromList [next ^. #owner, old ^. #owner]
                    `Set.isSubsetOf` selectedScopes
                , next ^. #executor == old ^. #executor
                , next ^. #executor `elem` [KubernetesExecutor, HelmExecutor]
                , next ^. #address == old ^. #address
                , next ^. #spec == old ^. #spec
                , next ^. #aliases == old ^. #aliases
                , next ^. #lifecycle == old ^. #lifecycle
                , next ^. #dataPolicy == old ^. #dataPolicy
                , next ^. #sensitivity == old ^. #sensitivity
                , next ^. #delegations == old ^. #delegations
                , Set.fromList (next ^. #dependencies) == Set.fromList (old ^. #dependencies) -> []
              _ -> issue "invalid-transfer" "transfer needs both selected scopes, a matching owned incarnation, and an unchanged Kubernetes or Helm resource contract"
            ApproveRetirement -> case (Map.lookup resource desired, Map.lookup resource historical, retirementIntent resource) of
              (Nothing, Just (Managed old), Just RetainResources)
                | Just (ObservedPresent _) <- fact
                , old ^. #executor `elem` [KubernetesExecutor, HelmExecutor]
                , Map.notMember resource (headRetained (historyHead history)) -> []
              _ -> issue "invalid-retirement" "retention needs a retired Kubernetes or Helm declaration, present owned incarnation, and RetainResources intent"
            ApproveCollection -> case (Map.lookup resource desired, Map.lookup resource (historyRetained history), fact) of
              (Nothing, Just (incarnation, old), Just (ObservedPresent physical))
                | CollectRetained resource `elem` NE.toList (candidateChanges candidate)
                , physical == retainedPhysical incarnation
                , old ^. #executor == KubernetesExecutor
                , old ^. #lifecycle == DeleteWhenUnreferenced
                , old ^. #dataPolicy == Stateless
                , supportsRetainedCollection old
                , null [consumer | consumer <- historyDeclarations history <> map (Managed . snd) (Map.elems (historyRetained history)),
                    any ((== resource) . dependencyTarget) (declarationDependencies consumer)] -> []
              _ -> issue "invalid-collection" "collection needs a selected retained Kubernetes ConfigMap incarnation, exact present UID, stateless deletion policy, and no known consumers"
            ApproveMigration -> issue "unsupported-migration" "migration needs a reviewed data and cutover contract"
       in evidence <> shape
    selectedScopes = Set.fromList
      [scope | change <- NE.toList (candidateChanges candidate)
      , Just scope <- [case change of
          ReplaceScope declaration -> Just (scopeId declaration)
          RetireScope owner _ -> Just owner
          CollectRetained _ -> Nothing]
      ]
    dependencyTarget dependency = case dependency of
      Consumes reference -> let (resource, _, _, _, _) = refSignature reference in resource
      ReadyAfter reference -> let (resource, _, _, _, _) = refSignature reference in resource
      OrderedAfter resource -> resource
    errors =
      [PlanError "duplicate-lifecycle-decision" "resource has more than one lifecycle decision" [resource] | resource <- duplicateValues (map lifecycleResource proposals)]
        <> [PlanError "unknown-lifecycle-resource" "lifecycle decision names an unknown resource" [resource] | resource <- Map.keys values, Set.notMember resource known]
        <> [PlanError "unobserved-lifecycle-resource" "lifecycle decision lacks an observation" [resource] | resource <- Map.keys values, Map.notMember resource observed]
        <> concatMap decisionError proposals

data PlanError = PlanError
  { planErrorCode :: !Text
  , planErrorMessage :: !Text
  , planErrorResources :: ![ResourceId]
  }
  deriving stock (Eq, Show, Generic)

data ChangeProposal = ChangeProposal
  { proposalBinding :: !ContextBinding
  , proposalBase :: !(Map ScopeId ScopeRevision)
  , proposalDesired :: !(Map ScopeId ScopeRevision)
  , proposalScopes :: !(Map ContentDigest ByteString)
  , proposalCandidateDigest :: !ContentDigest
  , proposalOperations :: ![PlannedOperation]
  , proposalRetentions :: !(Map ResourceId RetentionProof)
  , proposalCollections :: !(Map ResourceId RetentionProof)
  }
  deriving stock (Eq, Show)

data RetentionProof = RetentionProof
  { retentionOwner :: !ScopeId
  , retentionRevision :: !ScopeRevision
  , retentionPhysical :: !PhysicalIdentity
  }
  deriving stock (Eq, Show)

planChanges :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) ChangeProposal
planChanges candidate decisions history observations = do
  unless (null structuralErrors) (Left (NE.fromList structuralErrors))
  case decisions of
    LifecycleDecisions (Just (reviewed, reviewedHistory)) _
      | reviewed /= candidate -> Left (PlanError "stale-lifecycle-candidate"
          "lifecycle decisions were validated for a different composition candidate" [] :| [])
      | reviewedHistory /= history -> Left (PlanError "stale-lifecycle-history"
          "lifecycle decisions were validated for a different inventory history" [] :| [])
    _ -> pure ()
  checkedDecisions <- validateLifecycleDecisions candidate history observations
    (case decisions of LifecycleDecisions _ values -> Map.elems values)
  operations <- buildOperations candidate checkedDecisions history observations
  retentions <- buildRetentionProofs candidate checkedDecisions history observations
  collections <- buildCollectionProofs candidate checkedDecisions history observations
  let desiredScopes = inventoryScopes (candidateInventory candidate)
      scopeMembers = Map.fromList [(contentDigest bytes, bytes) | declaration <- Map.elems desiredScopes, let bytes = encodeCanonicalScope declaration]
      desiredRevisions =
        Map.mapWithKey
          (\scope declaration -> ScopeRevision (candidateGenerations candidate Map.! scope) (contentDigest (encodeCanonicalScope declaration)))
          desiredScopes
      candidateBytes =
        either (error . T.unpack) id $
          canonicalValue $
            object
              [ "binding" .= inventoryBinding (candidateInventory candidate)
              , "base" .= revisionEntries baseRevisions
              , "desired" .= revisionEntries desiredRevisions
              , "changes" .= map (T.pack . show) (NE.toList (candidateChanges candidate))
              ]
  pure
    ChangeProposal
      { proposalBinding = inventoryBinding (candidateInventory candidate)
      , proposalBase = baseRevisions
      , proposalDesired = desiredRevisions
      , proposalScopes = scopeMembers
      , proposalCandidateDigest = contentDigest candidateBytes
      , proposalOperations = sortOn (operationIdText . plannedOperationId) operations
      , proposalRetentions = retentions
      , proposalCollections = collections
      }
  where
    baseRevisions = fmap fst (historyAccepted history)
    observed = observationMap observations
    requirements = observationRequirements candidate history
    missing = Set.toAscList (requiredResources requirements `Set.difference` Map.keysSet observed)
    unavailable = [resource | (resource, ObservationUnavailable _) <- Map.toAscList observed, Set.member resource (requiredResources requirements)]
    historyGenerations = fmap (revisionGeneration . fst) (historyAccepted history)
    structuralErrors =
      [PlanError "context-binding" "candidate belongs to a different context or provider target" [] | inventoryBinding (candidateInventory candidate) /= headBinding (historyHead history)]
        <> [ PlanError "active-transaction" "resume or resolve the active inventory transaction before planning another review" []
           | Just _ <- [headActiveTransaction (historyHead history)]
           ]
        <> [PlanError "base-revision" "candidate base scope generations do not match the accepted store head" [] | candidateBase candidate /= historyGenerations]
        <> [PlanError "reservation-history" "candidate retained address reservations differ from the authoritative store" [] | candidateReservations candidate /= historyReservations history]
        <> [PlanError "retained-reactivation" "a retained logical resource requires a reviewed restore or migration before becoming desired again" retainedReactivations
           | not (null retainedReactivations)]
        <> [PlanError "collected-reactivation" "a collected logical resource has a deletion tombstone and cannot be silently reused" collectedReactivations
           | not (null collectedReactivations)]
        <> [PlanError "accepted-contributions" "accepted scopes cannot be composed into their effective resources" [] | either (const True) (const False) (historyComposition history)]
        <> [PlanError "observation-coverage" "required resource was not observed" missing | not (null missing)]
        <> [PlanError "observation-unavailable" "required resource observation is unavailable" unavailable | not (null unavailable)]
    retainedReactivations = Set.toAscList
      (Set.intersection (Map.keysSet (headRetained (historyHead history)))
        (Set.fromList (map declarationId (inventoryDeclarations (candidateInventory candidate)))))
    collectedReactivations = Set.toAscList
      (Set.intersection (Map.keysSet (headCollected (historyHead history)))
        (Set.fromList (map declarationId (inventoryDeclarations (candidateInventory candidate)))))

buildRetentionProofs :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) (Map ResourceId RetentionProof)
buildRetentionProofs candidate (LifecycleDecisions _ decisions) history observations = do
  unless (null disappearingChildren)
    (Left (PlanError "retained-child-history" "retirement of observed controller children requires retained child claims" disappearingChildren :| []))
  Map.fromList <$> traverse one selected
  where
    desired = Set.fromList (map declarationId (inventoryDeclarations (candidateInventory candidate)))
    disappearingChildren =
      [resource | ObservedChild resource _ _ _ _ <- historyDeclarations history,
        Set.notMember resource desired]
    retiredScopes = Set.fromList
      [scope | RetireScope scope RetainResources <- NE.toList (candidateChanges candidate)]
    selected =
      [(resource ^. #identity, resource) | (_, (_, scope)) <- Map.toAscList (historyAccepted history)
      , bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations
      , Set.notMember (resource ^. #identity) desired
      , Set.member (resource ^. #owner) retiredScopes]
    one (resourceId, resource) = case
      (Map.lookup resourceId decisions, Map.lookup resourceId (observationMap observations),
       Map.lookup (resource ^. #owner) (historyAccepted history)) of
      (Just decision, Just (ObservedPresent physical), Just (revision, _))
        | lifecycleDecision decision == ApproveRetirement ->
            Right (resourceId, RetentionProof (resource ^. #owner) revision physical)
      _ -> Left (PlanError "retention-proof" "retired resource lacks a reviewed present incarnation" [resourceId] :| [])

buildCollectionProofs :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) (Map ResourceId RetentionProof)
buildCollectionProofs candidate (LifecycleDecisions _ decisions) history observations =
  Map.fromList <$> traverse one selected
  where
    selected = [resource | CollectRetained resource <- NE.toList (candidateChanges candidate)]
    one resource = case (Map.lookup resource decisions, Map.lookup resource (historyRetained history),
      Map.lookup resource (observationMap observations)) of
      (Just decision, Just (incarnation, _), Just (ObservedPresent physical))
        | lifecycleDecision decision == ApproveCollection
        , physical == retainedPhysical incarnation ->
            Right (resource, RetentionProof (retainedOwner incarnation)
              (retainedRevision incarnation) physical)
      _ -> Left (PlanError "collection-proof" "collection lacks an exact retained incarnation proof" [resource] :| [])

buildOperations :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) [PlannedOperation]
buildOperations candidate (LifecycleDecisions _ decisions) history observations =
  if null errors then Right (map addDependencies preliminary <> map snd declaredOperations) else Left (NE.fromList errors)
  where
    desiredDeclarations = Map.fromList [(declarationId declaration, declaration) | declaration <- inventoryDeclarations (candidateInventory candidate)]
    bootstrapReview = any isBootstrapMarker (Map.elems desiredDeclarations)
    isBootstrapMarker (Managed resource) = resource ^. #source . #file == "generated:bootstrap"
    isBootstrapMarker _ = False
    oldDeclarations = Map.fromList [(declarationId declaration, declaration) | declaration <- historyDeclarations history]
    -- Converged scope revisions retain proof of unchanged forward-only
    -- migrations after Kubernetes TTL removes their Job objects.
    provenMigrations =
      Map.fromList
        [ (operation ^. #identity, operation)
        | (scope, (revision, declaration)) <- Map.toAscList (historyAccepted history)
        , Map.lookup scope (historyConverged history) == Just revision
        , bundle <- scopeBundles declaration
        , operation <- bundle ^. #operations
        , operation ^. #operationKind == SchemaMigration
        ]
    migrationIsProven operation =
      operation ^. #operationKind == SchemaMigration
        && Map.lookup (operation ^. #identity) provenMigrations == Just operation
    provenMigrationJobs =
      Set.fromList
        [ resource
        | scope <- Map.elems (inventoryScopes (candidateInventory candidate))
        , bundle <- scopeBundles scope
        , operation <- bundle ^. #operations
        , migrationIsProven operation
        , resource <- NE.toList (operation ^. #affects)
        ]
    observed = observationMap observations
    desiredManaged = [(resource ^. #identity, resource, Map.lookup (resource ^. #identity) oldDeclarations, Map.lookup (resource ^. #identity) observed) | Managed resource <- Map.elems desiredDeclarations]
    retired = [(resource, declaration) | (resource, declaration@(Managed _)) <- Map.toAscList oldDeclarations, Map.notMember resource desiredDeclarations]
    selectedCollections =
      [(resourceId, resource)
      | CollectRetained resourceId <- NE.toList (candidateChanges candidate)
      , Just (_, resource) <- [Map.lookup resourceId (historyRetained history)]]
    classified = map classifyDesired desiredManaged
    errors = concatMap fst classified <> concatMap retireError retired
      <> [PlanError "collection-decision" "retained collection lacks a validated lifecycle decision" [resourceId]
         | (resourceId, _) <- selectedCollections, not (decisionIs ApproveCollection resourceId)]
    preliminary = mapMaybe snd classified <> mapMaybe retireOperation retired
      <> [resourceOperation RetireResource resource | (_, resource) <- selectedCollections]
    operationByResource = Map.fromList [(resource, plannedOperationId operation) | operation <- preliminary, resource <- NE.toList (plannedResources operation)]
    operationByDeclaration =
      Map.fromList
        [ (declaredOperation ^. #identity, plannedOperationId operation)
        | (declaredOperation, operation) <- declaredSeeds
        ]
    operationByDependency = Map.union operationByResource operationByDeclaration
    addDependencies operation =
      operation
        { plannedDependencies =
            sort
              [ dependencyOperation
              | resource <- NE.toList (plannedResources operation)
              , Just declaration <- [Map.lookup resource desiredDeclarations]
              , dependency <- declarationDependencies declaration
              , Just dependencyOperation <- [operationForDependency dependency]
              , dependencyOperation /= plannedOperationId operation
              ]
        }
    declaredSeeds = concatMap scopeDeclared (Map.elems (inventoryScopes (candidateInventory candidate)))
    cacheOutputOperations =
      Map.fromList
        [ (resource, plannedOperationId planned)
        | (declaredOperation, planned) <- declaredSeeds
        , declaredOperation ^. #operationKind == CreateLogicalCache
        , resource <- NE.toList (declaredOperation ^. #affects)
        ]
    operationForDependency dependency = case dependency of
      Consumes ref
        | refCapability ref == NixCachePublicKey ->
            Map.lookup (dependencyResource dependency) cacheOutputOperations
      _ -> Map.lookup (dependencyResource dependency) operationByDependency
    refCapability (SomeRef ref) = let (_, _, capability, _, _) = refSignature (SomeRef ref) in capability
    scopeDeclared declaration =
      mapMaybe
        declared
        [ operation
        | bundle <- scopeBundles declaration
        , operation <- bundle ^. #operations
        , not (migrationIsProven operation)
        ]
    declared operation = do
      executor <- listToMaybe [resource ^. #executor | resourceId <- NE.toList (operation ^. #affects), Just (Managed resource) <- [Map.lookup resourceId desiredDeclarations]]
      let digest = contentDigest (canonicalBytes (toJSON operation))
      pure (operation, mkPlanned RunDeclaredOperation executor (operation ^. #affects) digest (operation ^. #recovery))
    declaredOperations = map addDeclaredDependencies declaredSeeds
    addDeclaredDependencies (operation, planned) =
      let affected = NE.toList (operation ^. #affects)
          prerequisites =
            [ prerequisite
            | resourceId <- affected
            , Just resource <- [Map.lookup resourceId desiredDeclarations]
            , dependency <- declarationDependencies resource
            , Just prerequisite <- [Map.lookup (dependencyResource dependency) operationByDependency]
            ]
          affectedChanges = mapMaybe (`Map.lookup` operationByResource) affected
       in (operation, planned {plannedDependencies = Set.toAscList (Set.fromList (affectedChanges <> prerequisites))})
    sameManaged old resource = case old of
      Managed previous ->
        let canonicalDependencies value =
              value
                { dependencies = Set.toAscList (Set.fromList (value ^. #dependencies))
                , source = SourceLocation "" ""
                }
         in canonicalBytes (toJSON (Managed (canonicalDependencies previous)))
              == canonicalBytes (toJSON (Managed (canonicalDependencies resource)))
      _ -> False
    classifyDesired (resourceId, resource, Just (Managed old), _)
      | old ^. #address /= resource ^. #address
        || old ^. #executor /= resource ^. #executor =
          ([PlanError "migration-review-required" "changing a known resource address or executor needs a reviewed source and destination migration" [resourceId]], Nothing)
      | old ^. #owner /= resource ^. #owner
      , decisionIs ApproveTransfer resourceId =
          ([], Just (resourceOperation VerifyResource resource))
      | old ^. #owner /= resource ^. #owner =
          ([PlanError "owner-transfer-required" "moving a known resource between scopes needs a reviewed two-scope transfer" [resourceId]], Nothing)
    classifyDesired (resourceId, resource, previous, observation) = case (previous, observation) of
      (Nothing, Just (ConfirmedAbsent _)) -> ([], Just (resourceOperation CreateResource resource))
      (Nothing, Just (ObservedPresent _)) ->
        ([PlanError "unverified-owner" "resource has an ownership stamp but no accepted history" [resourceId]], Nothing)
      (Nothing, Just (ObservedDrifted _ _)) ->
        ([PlanError "unverified-owner" "resource has an ownership stamp but no accepted history" [resourceId]], Nothing)
      (Nothing, Just (ObservedReplacementRequired _ _)) ->
        ([PlanError "unverified-owner" "resource has an ownership stamp but no accepted history" [resourceId]], Nothing)
      (Nothing, Just (ObservedUnowned _)) ->
        if decisionIs ApproveAdoption resourceId
          then ([], Just (resourceOperation AdoptResource resource))
          else ([PlanError "adoption-required" "resource exists without inventory ownership" [resourceId]], Nothing)
      (_, Just (ObservedUnowned _)) -> ([PlanError "foreign-resource" "accepted object lost its inventory owner stamp" [resourceId]], Nothing)
      (_, Just (ObservedForeign _)) -> ([PlanError "foreign-resource" "resource address is occupied by an object without accepted ownership" [resourceId]], Nothing)
      (Nothing, Just (ObservationUnavailable _)) -> ([PlanError "observation-unavailable" "resource observation is unavailable" [resourceId]], Nothing)
      (Just old, Just (ConfirmedAbsent _)) -> case resource ^. #dataPolicy of
        Stateless
          | Set.member resourceId provenMigrationJobs
          , sameManaged old resource
          , isMigrationJob (resource ^. #address) ->
              ([], Nothing)
        Stateless -> ([], Just (resourceOperation CreateResource resource))
        Durable _ ->
          (
            [ PlanError
                "durable-resource-missing"
                "accepted durable resource is absent; recover its data before replanning"
                [resourceId]
            ]
          , Nothing
          )
      (Just _, Just (ObservedDrifted _ _)) -> ([], Just (resourceOperation UpdateResource resource))
      (Just _, Just (ObservedReplacementRequired _ _)) ->
        ([PlanError "replacement-review-required" "provider requires an explicit reviewed replacement or migration" [resourceId]], Nothing)
      (Just old, _)
        | sameManaged old resource ->
            ( []
            , if bootstrapReview && resource ^. #executor `elem` [KubernetesExecutor, HelmExecutor]
                then Just (resourceOperation VerifyResource resource)
                else Nothing
            )
      (Just _, Just (ObservationUnavailable _)) -> ([PlanError "observation-unavailable" "resource observation is unavailable" [resourceId]], Nothing)
      (Just _, _) -> ([], Just (resourceOperation UpdateResource resource))
      (_, Nothing) -> ([PlanError "observation-coverage" "resource was not observed" [resourceId]], Nothing)
    retireError (resource, _)
      | decisionIs ApproveRetirement resource || decisionIs ApproveCollection resource = []
      | otherwise = [PlanError "retirement-required" "accepted resource is absent from desired inventory without a lifecycle decision" [resource]]
    retireOperation (resource, Managed old)
      | decisionIs ApproveCollection resource = Just (resourceOperation RetireResource old)
      | otherwise = Nothing
    retireOperation _ = Nothing
    decisionIs kind resource = maybe False ((== kind) . lifecycleDecision) (Map.lookup resource decisions)
    resourceOperation action resource =
      let digest = contentDigest (canonicalBytes (toJSON (Managed resource)))
          recovery = case resource ^. #dataPolicy of Stateless -> Idempotent; Durable _ -> VerifyBeforeRetry
       in mkPlanned action (resource ^. #executor) (resource ^. #identity :| []) digest recovery
    isMigrationJob (Kubernetes _ "batch" kind _ _) = nameText kind == "job"
    isMigrationJob _ = False
    mkPlanned action executor resources digest recovery =
      let descriptor = object ["action" .= action, "executor" .= executor, "resources" .= resources, "inputDigest" .= digest]
          token = "op-" <> T.take 24 (digestText (contentDigest (canonicalBytes descriptor)))
          operationId = either (error . T.unpack) id (mkOperationId token)
       in PlannedOperation operationId action executor resources digest [] recovery
    canonicalBytes = either (error . T.unpack) id . canonicalValue
    dependencyResource (Consumes ref) = case ref of SomeRef value -> refProducer value
    dependencyResource (ReadyAfter ref) = case ref of SomeRef value -> refProducer value
    dependencyResource (OrderedAfter resource) = resource

data ReviewOperation = ReviewOperation
  { reviewPlannedOperation :: !PlannedOperation
  , reviewAdapterIdentity :: !Text
  , reviewAdapterVersion :: !Text
  , reviewNativeDigest :: !(Maybe ContentDigest)
  , reviewPublicSummary :: !Text
  }
  deriving stock (Eq, Show, Generic)

data ReviewDocument = ReviewDocument
  { reviewSchemaVersion :: !Int
  , reviewContextBinding :: !ContextBinding
  , reviewHeadGeneration :: !Integer
  , reviewHeadSequence :: !Integer
  , reviewBaseRevisions :: !(Map ScopeId ScopeRevision)
  , reviewDesiredRevisions :: !(Map ScopeId ScopeRevision)
  , reviewCandidateDigest :: !ContentDigest
  , reviewPayloadIdentity :: !Text
  , reviewPolicyVersion :: !Text
  , reviewOperations :: ![ReviewOperation]
  , reviewBarriers :: ![ReviewBarrier]
  , reviewRetentions :: !(Map ResourceId RetentionProof)
  , reviewCollections :: !(Map ResourceId RetentionProof)
  }
  deriving stock (Eq, Show, Generic)

data ReviewBundle = ReviewBundle
  { bundleDocument :: !ReviewDocument
  , bundleScopes :: !(Map ContentDigest ByteString)
  , bundleNative :: !(Map ContentDigest ByteString)
  }
  deriving stock (Eq, Show)

reviewBundleDocument :: ReviewBundle -> ReviewDocument
reviewBundleDocument = bundleDocument

reviewBundleScopes :: ReviewBundle -> Map ContentDigest ByteString
reviewBundleScopes = bundleScopes

-- | Private retained native evidence. A public review directory loads with an
-- empty map; command factories receive the store-backed bundle after matching
-- its public document and scope members byte-for-byte.
reviewBundleNative :: ReviewBundle -> Map ContentDigest ByteString
reviewBundleNative = bundleNative

data ReviewError = ReviewError
  { reviewErrorCode :: !Text
  , reviewErrorMessage :: !Text
  }
  deriving stock (Eq, Show, Generic)

data ReviewedPlan = ReviewedPlan !ReviewDocument !(Map ContentDigest ByteString)

reviewedDocument :: ReviewedPlan -> ReviewDocument
reviewedDocument (ReviewedPlan document _) = document

reviewedNativeBundles :: ReviewedPlan -> Map ContentDigest ByteString
reviewedNativeBundles (ReviewedPlan _ bundles) = bundles

instance ToJSON LifecycleDecisionKind where toJSON = genericToJSON defaultOptions

instance FromJSON LifecycleDecisionKind where parseJSON = genericParseJSON defaultOptions

instance ToJSON LifecycleProposal where toJSON = genericToJSON defaultOptions

instance FromJSON LifecycleProposal where parseJSON = genericParseJSON defaultOptions

instance ToJSON ReviewOperation where
  toJSON operation =
    object
      [ "operation" .= reviewPlannedOperation operation
      , "adapterIdentity" .= reviewAdapterIdentity operation
      , "adapterVersion" .= reviewAdapterVersion operation
      , "nativeDigest" .= reviewNativeDigest operation
      , "summary" .= reviewPublicSummary operation
      ]

instance FromJSON ReviewOperation where
  parseJSON = withObject "ReviewOperation" $ \o ->
    ReviewOperation <$> o .: "operation" <*> o .: "adapterIdentity" <*> o .: "adapterVersion" <*> o .: "nativeDigest" <*> o .: "summary"

instance ToJSON RetentionProof where
  toJSON proof = object
    [ "owner" .= retentionOwner proof
    , "revision" .= retentionRevision proof
    , "physical" .= retentionPhysical proof
    ]

instance FromJSON RetentionProof where
  parseJSON = withObject "RetentionProof" $ \o -> do
    unless (all (`elem` ["owner", "revision", "physical"]) (KM.keys o))
      (fail "retention proof has an unknown field")
    RetentionProof <$> o .: "owner" <*> o .: "revision" <*> o .: "physical"

instance ToJSON ReviewDocument where
  toJSON document =
    object
      ([ "version" .= reviewSchemaVersion document
      , "context" .= reviewContextBinding document
      , "headGeneration" .= reviewHeadGeneration document
      , "headSequence" .= reviewHeadSequence document
      , "baseRevisions" .= revisionEntries (reviewBaseRevisions document)
      , "desiredRevisions" .= revisionEntries (reviewDesiredRevisions document)
      , "candidateDigest" .= reviewCandidateDigest document
      , "payloadIdentity" .= reviewPayloadIdentity document
      , "policyVersion" .= reviewPolicyVersion document
      , "operations" .= reviewOperations document
      , "barriers" .= reviewBarriers document
      ] <> ["retentions" .= retentionEntries (reviewRetentions document)
           | not (Map.null (reviewRetentions document))]
        <> ["collections" .= retentionEntries (reviewCollections document)
           | not (Map.null (reviewCollections document))])
    where
      retentionEntries entries =
        [object ["resource" .= resource, "proof" .= proof]
        | (resource, proof) <- Map.toAscList entries]

instance FromJSON ReviewDocument where
  parseJSON = withObject "ReviewDocument" $ \o -> do
    let allowed = ["version", "context", "headGeneration", "headSequence", "baseRevisions", "desiredRevisions", "candidateDigest", "payloadIdentity", "policyVersion", "operations", "barriers", "retentions", "collections"]
    unless (all (`elem` allowed) (KM.keys o)) (fail "review document has an unknown field")
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail "unsupported review schema version")
    retentions <- parseRetentions =<< o .:? "retentions" .!= []
    collections <- parseRetentions =<< o .:? "collections" .!= []
    ReviewDocument version
      <$> o .: "context"
      <*> o .: "headGeneration"
      <*> o .: "headSequence"
      <*> (parseRevisionEntries =<< o .: "baseRevisions")
      <*> (parseRevisionEntries =<< o .: "desiredRevisions")
      <*> o .: "candidateDigest"
      <*> o .: "payloadIdentity"
      <*> o .: "policyVersion"
      <*> o .: "operations"
      <*> o .: "barriers"
      <*> pure retentions
      <*> pure collections
    where
      parseRetentions values = do
        entries <- traverse (withObject "retention entry" (\v -> (,) <$> v .: "resource" <*> v .: "proof")) values
        unless (length entries == Map.size (Map.fromList entries)) (fail "duplicate retention proof")
        pure (Map.fromList entries)

prepareReview :: AdapterRegistry -> StoreSnapshot -> ChangeProposal -> IO (Either (NonEmpty PrepareError) ReviewBundle)
prepareReview registry snapshot proposal = do
  prepared <- traverse prepareOne (proposalOperations proposal)
  let (errors, successes) = partitionEithers prepared
  case errors of
    firstError : rest -> pure (Left (firstError :| rest))
    [] -> do
      let operations = [operation | (operation, _, _) <- successes]
          native = Map.fromList [(digest, bytes) | (_, Just (digest, bytes), _) <- successes]
          barriers = [barrier | (_, _, Just barrier) <- successes]
          headValue = storeSnapshotHead snapshot
          document =
            ReviewDocument
              { reviewSchemaVersion = 1
              , reviewContextBinding = proposalBinding proposal
              , reviewHeadGeneration = headGeneration headValue
              , reviewHeadSequence = headSequence headValue
              , reviewBaseRevisions = proposalBase proposal
              , reviewDesiredRevisions = proposalDesired proposal
              , reviewCandidateDigest = proposalCandidateDigest proposal
              , reviewPayloadIdentity = "operator-cli"
              , reviewPolicyVersion = "inventory-policy-v1"
              , reviewOperations = operations
              , reviewBarriers = barriers
              , reviewRetentions = proposalRetentions proposal
              , reviewCollections = proposalCollections proposal
              }
      pure (Right (ReviewBundle document (proposalScopes proposal) native))
  where
    prepareOne operation = case lookupAdapter registry (plannedExecutor operation) of
      Left err -> pure (Left (PrepareRefused (plannedOperationId operation) err))
      Right adapter -> do
        result <- adapterPrepare adapter operation
        pure $ case result of
          Left (PreparationBlocked barrier) ->
            Right
              ( ReviewOperation operation (adapterIdentity adapter) (adapterVersion adapter) Nothing "review barrier"
              , Nothing
              , Just barrier
              )
          Left err -> Left err
          Right prepared ->
            let bytes = preparedNativeBytes prepared
                digest = contentDigest bytes
             in Right
                  ( ReviewOperation operation (adapterIdentity adapter) (adapterVersion adapter) (Just digest) (preparedPublicSummary prepared)
                  , Just (digest, bytes)
                  , Nothing
                  )

encodeReviewDocument :: ReviewDocument -> ByteString
encodeReviewDocument = either (error . T.unpack) id . canonicalValue . toJSON

reviewDigest :: ReviewBundle -> ContentDigest
reviewDigest = contentDigest . encodeReviewDocument . bundleDocument

publishReview :: InventoryStore -> ReviewBundle -> IO (Either StoreError ContentDigest)
publishReview store bundle = do
  scopeResults <- traverse (\(digest, bytes) -> publishIfAbsent store (scopeKey digest) bytes) (Map.toAscList (bundleScopes bundle))
  case sequence scopeResults of
    Left err -> pure (Left err)
    Right _ -> do
      nativeResults <- traverse (\(digest, bytes) -> publishIfAbsent store (nativeKey digest) bytes) (Map.toAscList (bundleNative bundle))
      case sequence nativeResults of
        Left err -> pure (Left err)
        Right _ -> publishIfAbsent store (reviewKey digest) (encodeReviewDocument (bundleDocument bundle))
          where
            digest = reviewDigest bundle

loadPublishedReview :: InventoryStore -> ContentDigest -> IO (Either StoreError ReviewBundle)
loadPublishedReview store digest = do
  documentResult <- readObject store (reviewKey digest)
  case documentResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreInvalidObject (reviewKey digest) "published review is missing"))
    Right (Just bytes) -> case eitherDecodeStrict' bytes of
      Left err -> pure (Left (StoreInvalidObject (reviewKey digest) (T.pack err)))
      Right document
        | encodeReviewDocument document /= bytes -> pure (Left (StoreInvalidObject (reviewKey digest) "published review is not canonical"))
        | contentDigest bytes /= digest -> pure (Left (StoreInvalidObject (reviewKey digest) "published review digest mismatch"))
        | otherwise -> do
            scopeResults <- traverse (readRequired store . scopeKey) [revisionDigest revision | revision <- Map.elems (reviewDesiredRevisions document)]
            nativeResults <- traverse (readRequired store . nativeKey) [member | operation <- reviewOperations document, Just member <- [reviewNativeDigest operation]]
            pure $ do
              scopes <- sequence scopeResults
              native <- sequence nativeResults
              let scopeMap = Map.fromList [(contentDigest member, member) | member <- scopes]
                  nativeMap = Map.fromList [(contentDigest member, member) | member <- native]
              pure (ReviewBundle document scopeMap nativeMap)
  where
    readRequired inventoryStore key = do
      loaded <- readObject inventoryStore key
      pure (loaded >>= maybe (Left (StoreInvalidObject key "published review member is missing")) Right)

writeReviewBundle :: FilePath -> ReviewBundle -> IO (Either Text ContentDigest)
writeReviewBundle output bundle = do
  attempted <- try $ do
    exists <- doesPathExist output
    when exists (ioError (userError "review output already exists"))
    let parent = takeDirectory output
    createDirectoryIfMissing True parent
    withTempDirectory parent ".inventory-review-" $ \staging -> do
      setFileMode staging 0o700
      createPrivateDirectory (staging </> "scopes")
      let documentBytes = encodeReviewDocument (bundleDocument bundle)
          digest = reviewDigest bundle
      writePrivate (staging </> "review.json") documentBytes
      writePrivate (staging </> "review.sha256") (BC.pack (T.unpack (digestText digest)) <> "\n")
      forM_ (Map.toAscList (bundleScopes bundle)) $ \(memberDigest, bytes) -> writePrivate (staging </> scopeMemberPath memberDigest) bytes
      renameDirectory staging output
  pure $ case attempted of
    Left (err :: IOException) -> Left (T.pack (show err))
    Right () -> Right (reviewDigest bundle)
  where
    createPrivateDirectory path = createDirectory path >> setFileMode path 0o700
    writePrivate path bytes = BS.writeFile path bytes >> setFileMode path 0o600

loadReviewBundle :: FilePath -> IO (Either Text ReviewBundle)
loadReviewBundle directory = do
  attempted <- try $ do
    rejectLink directory
    documentBytes <- readRegular (directory </> "review.json")
    checksum <- readRegular (directory </> "review.sha256")
    document <- either (ioError . userError) pure (eitherDecodeStrict' documentBytes)
    let canonical = encodeReviewDocument document
        digest = contentDigest canonical
    unless (canonical == documentBytes) (ioError (userError "review document is not canonical"))
    unless (checksum == BC.pack (T.unpack (digestText digest)) <> "\n") (ioError (userError "review checksum mismatch"))
    scopes <- loadMembers directory scopeMemberPath [revisionDigest revision | revision <- Map.elems (reviewDesiredRevisions document)]
    let expectedRoot = sort ["review.json", "review.sha256", "scopes"]
    rootEntries <- sort <$> listDirectory directory
    unless (rootEntries == expectedRoot) (ioError (userError "review directory has unexpected members"))
    pure (ReviewBundle document scopes Map.empty)
  pure $ first (T.pack . show) (attempted :: Either IOException ReviewBundle)
  where
    loadMembers root memberPath digests = do
      let uniqueDigests = Set.toAscList (Set.fromList digests)
          subdirectory = takeDirectory (memberPath (headOrZero uniqueDigests))
          expected = sort [takeFileName (memberPath digest) | digest <- uniqueDigests]
      rejectLink (root </> subdirectory)
      actual <- sort <$> listDirectory (root </> subdirectory)
      unless (actual == expected) (ioError (userError (subdirectory <> " members differ from review")))
      fmap Map.fromList $ forM uniqueDigests $ \digest -> do
        bytes <- readRegular (root </> memberPath digest)
        unless (contentDigest bytes == digest) (ioError (userError "review member digest mismatch"))
        pure (digest, bytes)
    headOrZero [] = either (error . T.unpack) id (mkContentDigest (T.replicate 64 "0"))
    headOrZero (value : _) = value
    rejectLink path = pathIsSymbolicLink path >>= (`when` ioError (userError (path <> " is a symlink")))
    readRegular path = rejectLink path >> BS.readFile path

verifyReview :: StoreSnapshot -> ReviewBundle -> Either (NonEmpty ReviewError) ReviewedPlan
verifyReview snapshot bundle =
  if null errors then Right (ReviewedPlan document (bundleNative bundle)) else Left (NE.fromList errors)
  where
    document = bundleDocument bundle
    headValue = storeSnapshotHead snapshot
    digest = reviewDigest bundle
    operationIds = Set.fromList (map (plannedOperationId . reviewPlannedOperation) (reviewOperations document))
    missingDependencies =
      [ dependency
      | operation <- reviewOperations document
      , dependency <- plannedDependencies (reviewPlannedOperation operation)
      , Set.notMember dependency operationIds
      ]
    errors =
      [ReviewError "unpublished-review" "review bundle was not published by this store" | Set.notMember digest (storeSnapshotReviewDigests snapshot)]
        <> [ReviewError "context-binding" "review belongs to a different context or target" | reviewContextBinding document /= headBinding headValue]
        <> [ReviewError "stale-head" "review was issued against a different head generation or journal sequence" | reviewHeadGeneration document /= headGeneration headValue || reviewHeadSequence document /= headSequence headValue]
        <> [ReviewError "stale-base" "review base revisions differ from accepted desired state" | reviewBaseRevisions document /= headAccepted headValue]
        <> retentionReviewErrors headValue document
        <> collectionReviewErrors headValue document
        <> [ReviewError "scope-member" "review scope member is missing or has a different digest" | not (membersMatch (bundleScopes bundle) (map revisionDigest (Map.elems (reviewDesiredRevisions document))))]
        <> [ReviewError "native-member" "review native member is missing or has a different digest" | not (membersMatch (bundleNative bundle) [member | operation <- reviewOperations document, Just member <- [reviewNativeDigest operation]])]
        <> [ReviewError "operation-dependency" "review operation depends on an operation absent from the same review" | not (null missingDependencies)]
    membersMatch members digests =
      Set.fromList digests == Map.keysSet members
        && all (\(memberDigest, bytes) -> contentDigest bytes == memberDigest) (Map.toList members)

verifyActiveReview :: StoreSnapshot -> Text -> ReviewBundle -> Either (NonEmpty ReviewError) ReviewedPlan
verifyActiveReview snapshot transaction bundle =
  if null errors then Right (ReviewedPlan document (bundleNative bundle)) else Left (NE.fromList errors)
  where
    document = bundleDocument bundle
    headValue = storeSnapshotHead snapshot
    digest = reviewDigest bundle
    errors =
      [ReviewError "unpublished-review" "active review bundle was not published by this store" | Set.notMember digest (storeSnapshotReviewDigests snapshot)]
        <> [ReviewError "context-binding" "active review belongs to a different context or target" | reviewContextBinding document /= headBinding headValue]
        <> [ReviewError "inactive-transaction" "head does not reserve the requested transaction" | headActiveTransaction headValue /= Just transaction]
        <> [ReviewError "active-desired" "active review desired revisions differ from accepted desired state" | reviewDesiredRevisions document /= headAccepted headValue]
        <> [ReviewError "active-retention" "active review retained incarnation differs from the accepted historical catalogue"
           | (resource, proof) <- Map.toAscList (reviewRetentions document)
           , case Map.lookup resource (headRetained headValue) of
               Just retained -> retainedOwner retained /= retentionOwner proof
                 || retainedRevision retained /= retentionRevision proof
                 || retainedPhysical retained /= retentionPhysical proof
               Nothing -> True]
        <> activeCollectionReviewErrors headValue document
        <> [ReviewError "scope-member" "active review scope member is missing or has a different digest" | not (membersMatch (bundleScopes bundle) (map revisionDigest (Map.elems (reviewDesiredRevisions document))))]
        <> [ReviewError "native-member" "active review native member is missing or has a different digest" | not (membersMatch (bundleNative bundle) [member | operation <- reviewOperations document, Just member <- [reviewNativeDigest operation]])]
    membersMatch members digests =
      Set.fromList digests == Map.keysSet members
        && all (\(memberDigest, bytes) -> contentDigest bytes == memberDigest) (Map.toList members)

retentionReviewErrors :: HeadManifest -> ReviewDocument -> [ReviewError]
retentionReviewErrors headValue document =
  [ ReviewError "retention-base" "retention proof does not name a removed accepted scope revision"
  | (_, proof) <- Map.toAscList (reviewRetentions document)
  , Map.lookup (retentionOwner proof) (headAccepted headValue) /= Just (retentionRevision proof)
      || Map.member (retentionOwner proof) (reviewDesiredRevisions document)
  ] <> [ ReviewError "retention-history" "retained resource already exists in the historical catalogue"
       | resource <- Map.keys (reviewRetentions document), Map.member resource (headRetained headValue)]

collectionReviewErrors :: HeadManifest -> ReviewDocument -> [ReviewError]
collectionReviewErrors headValue document =
  [ ReviewError "collection-history" "collection proof differs from retained historical incarnation"
  | (resource, proof) <- Map.toAscList (reviewCollections document)
  , case Map.lookup resource (headRetained headValue) of
      Just retained -> retainedOwner retained /= retentionOwner proof
        || retainedRevision retained /= retentionRevision proof
        || retainedPhysical retained /= retentionPhysical proof
      Nothing -> True]
  <> [ReviewError "collection-operations" "collection proofs must match exactly the reviewed retire operations"
     | Map.keysSet (reviewCollections document) /= Set.fromList
         [resource | operation <- reviewOperations document
         , plannedAction (reviewPlannedOperation operation) == RetireResource
         , resource <- NE.toList (plannedResources (reviewPlannedOperation operation))]]

activeCollectionReviewErrors :: HeadManifest -> ReviewDocument -> [ReviewError]
activeCollectionReviewErrors headValue document =
  [ReviewError "active-collection" "active collection differs from retained history or finalized tombstone"
  | (resource, proof) <- Map.toAscList (reviewCollections document)
  , not (matchesRetained resource proof || matchesTombstone resource proof)]
  where
    matchesRetained resource proof = case Map.lookup resource (headRetained headValue) of
      Just retained -> retainedOwner retained == retentionOwner proof
        && retainedRevision retained == retentionRevision proof
        && retainedPhysical retained == retentionPhysical proof
      Nothing -> False
    matchesTombstone resource proof = case Map.lookup resource (headCollected headValue) of
      Just tombstone -> tombstoneOwner tombstone == retentionOwner proof
        && tombstoneRevision tombstone == retentionRevision proof
        && tombstonePhysical tombstone == retentionPhysical proof
        && tombstoneReview tombstone == contentDigest (encodeReviewDocument document)
      Nothing -> False

historyDeclarations :: InventoryHistory -> [Declaration]
historyDeclarations = either (const []) id . historyComposition

historyComposition :: InventoryHistory -> Either (NonEmpty InventoryError) [Declaration]
historyComposition = composedDeclarations . fmap snd . historyAccepted

revisionEntries :: Map ScopeId ScopeRevision -> [Value]
revisionEntries revisions = [object ["scope" .= scope, "revision" .= revision] | (scope, revision) <- Map.toAscList revisions]

parseRevisionEntries :: [Value] -> Parser (Map ScopeId ScopeRevision)
parseRevisionEntries values = do
  entries <- traverse (withObject "scope revision" (\o -> (,) <$> o .: "scope" <*> o .: "revision")) values
  unless (length entries == Map.size (Map.fromList entries)) (fail "duplicate scope revision")
  pure (Map.fromList entries)

nativeKey :: ContentDigest -> FilePath
nativeKey = objectKeyFor "native"

scopeMemberPath :: ContentDigest -> FilePath
scopeMemberPath digest = "scopes" </> T.unpack (digestText digest) <.> "json"

duplicateValues :: (Ord a) => [a] -> [a]
duplicateValues values = Map.keys (Map.filter (> (1 :: Int)) (Map.fromListWith (+) [(value, 1) | value <- values]))
