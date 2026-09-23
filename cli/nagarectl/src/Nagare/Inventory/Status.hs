-- | Read-only findings over an accepted, validated inventory and provider facts.
module Nagare.Inventory.Status
  ( DriftCategory (..)
  , HealthCategory (..)
  , DriftFinding (..)
  , ActiveTransactionStatus (..)
  , OperationStatus (..)
  , DependencyTrace (..)
  , RetainedFinding (..)
  , CollectionAssessment (..)
  , classifyDrift
  , traceDependencies
  , traceRetainedDependencies
  , consumersOf
  , retainedFindings
  , assessCollections
  , loadAcceptedNative
  , loadActiveTransactionStatus
  , summarizeActiveTransaction
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.HelmReview (helmSpecsFromReview)
import Nagare.Inventory.Journal
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.Store qualified as Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

data DependencyTrace = DependencyTrace
  { traceFrom :: !ResourceId
  , traceResource :: !ResourceId
  , traceOwner :: !(Maybe ScopeId)
  , traceSource :: !(Maybe SourceLocation)
  , traceDepth :: !Int
  }
  deriving stock (Eq, Show)

-- | Follow the composed declaration graph. The visited set bounds the walk
-- even if a malformed inventory somehow reaches this read-only path.
traceDependencies :: ValidatedInventory -> ResourceId -> [DependencyTrace]
traceDependencies inventory = traceKnownDependencies inventory Map.empty

traceRetainedDependencies :: InventoryHistory -> ValidatedInventory -> ResourceId -> [DependencyTrace]
traceRetainedDependencies history inventory =
  traceKnownDependencies inventory (historyRetained history)

traceKnownDependencies
  :: ValidatedInventory -> Map ResourceId (Store.RetainedIncarnation, ManagedResource)
  -> ResourceId -> [DependencyTrace]
traceKnownDependencies inventory retainedEntries start = go Set.empty [(start, 1)]
  where
    declarations = Map.fromList
      ([(declarationId declaration, declaration) | declaration <- inventoryDeclarations inventory]
        <> [(resourceId, Managed resource) | (resourceId, (_, resource)) <- Map.toAscList retainedEntries])
    declaredScopes = Map.fromList
      ([ (declarationId declaration, scope)
      | (scope, scopeDeclaration) <- Map.toAscList (inventoryScopes inventory)
      , bundle <- scopeBundles scopeDeclaration
      , declaration <- declarationsIn bundle
      ] <> [(resourceId, retainedOwner incarnation)
           | (resourceId, (incarnation, _)) <- Map.toAscList retainedEntries])
    declarationsIn bundle = bundle ^. #declarations
    target dependency = case dependency of
      Consumes reference -> Just (let (producer, _, _, _, _) = refSignature reference in producer)
      ReadyAfter reference -> Just (let (producer, _, _, _, _) = refSignature reference in producer)
      OrderedAfter producer -> Just producer
    go _ [] = []
    go visited ((consumer, depth) : pending)
      | Set.member consumer visited = go visited pending
      | otherwise =
          let targets = case Map.lookup consumer declarations of
                Nothing -> []
                Just declaration -> Set.toAscList (Set.fromList
                  [resource | dependency <- declarationDependencies declaration,
                    Just resource <- [target dependency]])
              row resource = DependencyTrace consumer resource
                (case Map.lookup resource declarations of
                  Just (Managed managed) -> Just (managed ^. #owner)
                  _ -> Map.lookup resource declaredScopes)
                (declarationSource <$> Map.lookup resource declarations) depth
           in map row targets <> go (Set.insert consumer visited)
                (pending <> [(resource, depth + 1) | resource <- targets])

-- | Include retained declarations: a retired resource can still depend on
-- another retained or active incarnation after its original scope disappears.
consumersOf :: InventoryHistory -> ValidatedInventory -> ResourceId -> [ResourceId]
consumersOf history inventory target =
  [resource ^. #identity
  | resource <- active <> retained
  , any ((== Just target) . dependencyTarget) (resource ^. #dependencies)]
  where
    active = [resource | Managed resource <- inventoryDeclarations inventory]
    retained = [resource | (_, resource) <- Map.elems (historyRetained history)]
    dependencyTarget dependency = case dependency of
      Consumes reference -> Just (let (producer, _, _, _, _) = refSignature reference in producer)
      ReadyAfter reference -> Just (let (producer, _, _, _, _) = refSignature reference in producer)
      OrderedAfter resource -> Just resource

instance ToJSON DependencyTrace where
  toJSON entry = object
    [ "from" .= traceFrom entry
    , "resource" .= traceResource entry
    , "owner" .= traceOwner entry
    , "source" .= traceSource entry
    , "depth" .= traceDepth entry
    ]

data RetainedFinding = RetainedFinding
  { retainedResource :: !ResourceId
  , retainedScope :: !ScopeId
  , retainedExecutor :: !Executor
  , retainedAddress :: !ProviderAddress
  , retainedIdentity :: !PhysicalIdentity
  , retainedSince :: !Text
  , retainedLifecycle :: !LifecyclePolicy
  , retainedDataPolicy :: !DataPolicy
  , retainedObservation :: !Text
  , retainedObservedIdentity :: !(Maybe PhysicalIdentity)
  }
  deriving stock (Eq, Show)

retainedFindings :: InventoryHistory -> ObservationSet -> [RetainedFinding]
retainedFindings history observations =
  [ RetainedFinding resourceId (retainedOwner incarnation)
      (managed ^. #executor) (managed ^. #address)
      (retainedPhysical incarnation) (retainedAt incarnation)
      (managed ^. #lifecycle) (managed ^. #dataPolicy)
      (observationCategory incarnation (Map.lookup resourceId (observationMap observations)))
      (observedIdentity =<< Map.lookup resourceId (observationMap observations))
  | (resourceId, (incarnation, managed)) <- Map.toAscList (historyRetained history)]
  where
    observationCategory incarnation fact = case fact of
      Just (ObservedPresent physical) | physical == retainedPhysical incarnation -> "present"
      Just (ObservedPresent _) -> "replaced-incarnation"
      Just (ObservedDrifted physical _) | physical == retainedPhysical incarnation -> "drifted"
      Just (ObservedDrifted _ _) -> "replaced-incarnation"
      Just (ObservedUnowned _) -> "unowned"
      Just (ObservedForeign _) -> "foreign-owner"
      Just (ConfirmedAbsent _) -> "confirmed-absent"
      Just (ObservationUnavailable _) -> "unavailable"
      Nothing -> "unknown"
    observedIdentity fact = case fact of
      ObservedPresent physical -> Just physical
      ObservedDrifted physical _ -> Just physical
      ObservedUnowned physical -> Just physical
      ObservedForeign physical -> Just physical
      _ -> Nothing

instance ToJSON RetainedFinding where
  toJSON finding = object
    [ "resource" .= retainedResource finding
    , "owner" .= retainedScope finding
    , "executor" .= retainedExecutor finding
    , "address" .= retainedAddress finding
    , "physical" .= retainedIdentity finding
    , "retainedAt" .= retainedSince finding
    , "lifecycle" .= retainedLifecycle finding
    , "dataPolicy" .= retainedDataPolicy finding
    , "category" .= ("retained-orphan" :: Text)
    , "observation" .= retainedObservation finding
    , "observedPhysical" .= retainedObservedIdentity finding
    ]

-- | Read-only screening for a later collection review. A candidate has no
-- deletion authority; the collection executor and tombstone protocol remain
-- separate from this report.
data CollectionAssessment = CollectionAssessment
  { collectionResource :: !ResourceId
  , collectionCandidate :: !Bool
  , collectionReasons :: ![Text]
  , collectionConsumers :: ![ResourceId]
  , collectionObservation :: !Text
  }
  deriving stock (Eq, Show)

assessCollections :: InventoryHistory -> ValidatedInventory -> ObservationSet -> [CollectionAssessment]
assessCollections history inventory observations =
  [ assessment finding | finding <- retainedFindings history observations ]
  where
    assessment finding =
      let resource = retainedResource finding
          consumers = consumersOf history inventory resource
          reasons =
            ["retention-policy" | retainedLifecycle finding /= DeleteWhenUnreferenced]
              <> ["durable-recovery-evidence" | retainedDataPolicy finding /= Stateless]
              <> ["unsupported-collection-transport"
                 | Just (_, managed) <- [Map.lookup resource (historyRetained history)]
                 , not (supportsRetainedCollection managed)]
              <> ["dependent-consumers" | not (null consumers)]
              <> ["exact-incarnation-not-present" | retainedObservation finding /= "present"]
              <> ["active-transaction" | isJust (headActiveTransaction (historyHead history))]
       in CollectionAssessment resource (null reasons) reasons consumers
            (retainedObservation finding)

instance ToJSON CollectionAssessment where
  toJSON assessment = object
    [ "resource" .= collectionResource assessment
    , "candidate" .= collectionCandidate assessment
    , "reasons" .= collectionReasons assessment
    , "consumers" .= collectionConsumers assessment
    , "observation" .= collectionObservation assessment
    , "deletionAuthorized" .= False
    ]

-- | Read the committed journal without taking the writer lock. The caller
-- must compare the head again after its other observations, as status does.
loadActiveTransactionStatus :: InventoryStore -> HeadManifest -> IO (Either Text (Maybe ActiveTransactionStatus))
loadActiveTransactionStatus store headValue = case headActiveTransaction headValue of
  Nothing -> pure (Right Nothing)
  Just _ -> do
    members <- traverse (readObject store . journalKey) [0 .. headSequence headValue - 1]
    pure $ do
      raw <- first (T.pack . show) (sequence members)
      bytes <- traverse (maybe (Left "committed journal event is missing") Right) raw
      events <- traverse decodeJournalEvent bytes
      checked <- validateJournal events
      summarizeActiveTransaction headValue checked

data OperationStatus = OperationStatus
  { operationStatusId :: !OperationId
  , operationStatusState :: !Text
  }
  deriving stock (Eq, Show)

data ActiveTransactionStatus = ActiveTransactionStatus
  { activeStatusId :: !Text
  , activeStatusRecoveryRequired :: !Bool
  , activeStatusReason :: !Text
  , activeStatusOperations :: ![OperationStatus]
  }
  deriving stock (Eq, Show)

-- | Project only state names. Journal details and provider failure messages
-- may contain secrets or command output, so they never enter the report.
summarizeActiveTransaction :: HeadManifest -> [JournalEvent] -> Either Text (Maybe ActiveTransactionStatus)
summarizeActiveTransaction headValue events = case headActiveTransaction headValue of
  Nothing -> Right Nothing
  Just token -> do
    transaction <- mkTransactionId token
    let relevant = filter ((== transaction) . eventTransaction) events
    unless (any (\event -> eventOperation event == Nothing) relevant)
      (Left "active transaction has no admission event")
    let latest = Map.fromList
          [(operation, eventState event) | event <- relevant, Just operation <- [eventOperation event]]
        uncertain = any requiresRecovery (Map.elems latest)
        reason = if uncertain then "operation-recovery-required" else "resume-required"
    pure (Just (ActiveTransactionStatus token uncertain reason
      [OperationStatus operation (stateName state) | (operation, state) <- Map.toAscList latest]))
  where
    requiresRecovery state = case state of
      IntentRecorded -> True
      Ambiguous -> True
      Failed (PartialOrUnknown _) -> True
      _ -> False
    stateName state = case state of
      Pending -> "pending"
      IntentRecorded -> "intent-recorded"
      Completed _ -> "completed"
      Failed (KnownNoEffect _) -> "failed-no-effect"
      Failed (PartialOrUnknown _) -> "failed-uncertain"
      Ambiguous -> "ambiguous"
      OperatorResolved _ -> "operator-resolved"

instance ToJSON OperationStatus where
  toJSON status = object
    [ "operation" .= operationStatusId status
    , "state" .= operationStatusState status
    ]

instance ToJSON ActiveTransactionStatus where
  toJSON status = object
    [ "transaction" .= activeStatusId status
    , "recoveryRequired" .= activeStatusRecoveryRequired status
    , "reason" .= activeStatusReason status
    , "operations" .= activeStatusOperations status
    ]

-- | Recover exact accepted native members from immutable private reviews.
-- Reviews for newer, unaccepted revisions never become status evidence.
loadAcceptedNative
  :: InventoryStore -> InventoryHistory -> ValidatedInventory
  -> IO (Either Text (Map ResourceId (ManagedResource, ByteString),
                      Map ResourceId (ManagedResource, ByteString)))
loadAcceptedNative store history inventory = do
  snapshot <- readStoreSnapshot store
  case snapshot of
    Left failure -> pure (Left (T.pack (show failure)))
    Right state -> do
      loaded <- traverse (loadPublishedReview store) (Set.toAscList (storeSnapshotReviewDigests state))
      pure $ do
        retained <- first (T.pack . show) (sequence loaded)
        entries <- traverse collect retained
        kubernetes <- agree (concatMap fst entries)
        helm <- agree (concatMap snd entries)
        pure (kubernetes, helm)
  where
    accepted = fmap fst (historyAccepted history)
    desired = Map.fromList
      [ (resource ^. #identity, resource)
      | Managed resource <- inventoryDeclarations inventory
      ]
    collect bundle = do
      let revisions = reviewDesiredRevisions (reviewBundleDocument bundle)
          current member =
            activeCurrent member || retainedCurrent member
          activeCurrent member =
            Map.lookup (member ^. #owner) revisions == Map.lookup (member ^. #owner) accepted
              && case Map.lookup (member ^. #identity) desired of
                   Just resource -> resource ^. #address == member ^. #address
                     && resource ^. #spec == member ^. #spec
                   Nothing -> False
          retainedCurrent member = case Map.lookup (member ^. #identity) (historyRetained history) of
            Just (incarnation, old) ->
              Map.lookup (retainedOwner incarnation) revisions == Just (retainedRevision incarnation)
                && member ^. #owner == retainedOwner incarnation
                && member ^. #address == old ^. #address
                && member ^. #spec == old ^. #spec
            Nothing -> False
      kubernetes <- kubernetesSpecsFromReview bundle
      helm <- helmSpecsFromReview bundle
      pure
        ([(resource, native) | (resource, native@(member, _)) <- Map.toList kubernetes, current member]
        ,[(resource, native) | (resource, native@(member, _)) <- Map.toList helm, current member])
    agree entries = traverse one (Map.fromListWith (<>)
      [(resource, [native]) | (resource, native) <- entries])
    one [] = Left "accepted resource has an empty native evidence group"
    one values@(firstValue : _)
      | all (== firstValue) values = Right firstValue
      | otherwise = Left "accepted reviews disagree on a resource's native bytes"

data DriftCategory
  = Converged
  | ConfigurationDrift
  | MissingResource
  | UnownedResource
  | ForeignOwner
  | UnknownObservation
  deriving stock (Eq, Ord, Show)

-- | Configuration observation alone does not establish readiness. Providers
-- can later supply a separate condition observation without changing drift.
data HealthCategory = HealthReady | HealthNotReady | HealthUnknown | HealthUnavailable
  deriving stock (Eq, Ord, Show)

data DriftFinding = DriftFinding
  { findingResource :: !ResourceId
  , findingOwner :: !ScopeId
  , findingExecutor :: !Executor
  , findingAddress :: !ProviderAddress
  , findingCategory :: !DriftCategory
  , findingHealth :: !HealthCategory
  , findingPhysical :: !(Maybe PhysicalIdentity)
  , findingObservedDigest :: !(Maybe ContentDigest)
  , findingReason :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

classifyDrift :: ValidatedInventory -> ObservationSet -> [DriftFinding]
classifyDrift inventory observations =
  [ classify resource (Map.lookup (resource ^. #identity) observed)
  | Managed resource <- inventoryDeclarations inventory
  ]
  where
    observed = observationMap observations
    classify resource fact =
      let (category, health, physical, digest, reason) = case fact of
            Just (ObservedPresent uid) -> (Converged, HealthUnknown, Just uid, Nothing, Nothing)
            Just (ObservedDrifted uid changed) ->
              (ConfigurationDrift, HealthUnknown, Just uid, Just changed, Nothing)
            Just (ObservedForeign uid) ->
              (ForeignOwner, HealthUnknown, Just uid, Nothing, Just "observed object has a different owner")
            Just (ObservedUnowned uid) ->
              (UnownedResource, HealthUnknown, Just uid, Nothing, Just "observed object has no inventory owner")
            Just (ConfirmedAbsent _) ->
              (MissingResource, HealthUnavailable, Nothing, Nothing, Just "provider confirmed absence")
            Just (ObservationUnavailable _) ->
              (UnknownObservation, HealthUnknown, Nothing, Nothing, Just "provider observation is unavailable")
            Nothing ->
              (UnknownObservation, HealthUnknown, Nothing, Nothing, Just "provider did not report this resource")
       in DriftFinding
            (resource ^. #identity)
            (resource ^. #owner)
            (resource ^. #executor)
            (resource ^. #address)
            category health physical digest reason

instance ToJSON DriftCategory where
  toJSON category = toJSON $ case category of
    Converged -> ("converged" :: Text)
    ConfigurationDrift -> "configuration-drift"
    MissingResource -> "missing"
    UnownedResource -> "unowned"
    ForeignOwner -> "foreign-owner"
    UnknownObservation -> "unknown"

instance ToJSON HealthCategory where
  toJSON health = toJSON $ case health of
    HealthReady -> ("ready" :: Text)
    HealthNotReady -> "not-ready"
    HealthUnknown -> ("unknown" :: Text)
    HealthUnavailable -> "unavailable"

instance ToJSON DriftFinding where
  toJSON finding = object
    [ "resource" .= findingResource finding
    , "owner" .= findingOwner finding
    , "executor" .= findingExecutor finding
    , "address" .= findingAddress finding
    , "category" .= findingCategory finding
    , "health" .= findingHealth finding
    , "physical" .= findingPhysical finding
    , "observedDigest" .= findingObservedDigest finding
    , "reason" .= findingReason finding
    ]
