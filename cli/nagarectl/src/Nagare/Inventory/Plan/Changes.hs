-- | Changes responsibilities; internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.Changes
  ( candidateDesiredRevisions
  , planChanges
  )
where

import Data.Aeson (KeyValue ((.=)), ToJSON (toJSON), object)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.CloudCollection (cloudCollectionPolicyOnly)
import Nagare.Inventory.Adapter
  ( MigrationStage
      ( AdmitWrites
      , BackUpSource
      , FenceWriters
      , PrepareDestination
      , RetainSource
      , SwitchConsumers
      , TransferState
      , VerifyDestination
      )
  , ObservationSet
  , OperationAction
    ( AdoptResource
    , CreateResource
    , MigrateResource
    , OpenMaintenanceSession
    , RestoreLiveDatabase
    , RetireResource
    , RunDeclaredOperation
    , UpdateResource
    , VerifyResource
    )
  , PlannedOperation (..)
  , ResourceObservation
    ( ConfirmedAbsent
    , ObservationUnavailable
    , ObservedDrifted
    , ObservedForeign
    , ObservedPresent
    , ObservedReplacementRequired
    , ObservedUnowned
    )
  , observationMap
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId, operationIdText)
import Nagare.Inventory.Migration.Types
  ( ValidatedMigration
      ( validatedContract
      , validatedDestination
      , validatedDestinationAbsence
      , validatedSource
      , validatedSourcePhysical
      )
  )
import Nagare.Inventory.Plan.Lifecycle
  ( combineDecisions
  , validateLifecycleDecisions
  , validatePairedMigrations
  )
import Nagare.Inventory.Plan.Observation
  ( affectedManagedIds
  , observationRequirements
  )
import Nagare.Inventory.Plan.Types
  ( ChangeProposal (..)
  , InventoryHistory (..)
  , LifecycleDecisionKind (..)
  , LifecycleDecisions (..)
  , LifecycleProposal (..)
  , MigrationProof (..)
  , ObservationRequirements (..)
  , PlanError (..)
  , RetentionProof (..)
  , historyComposition
  , historyDeclarations
  , historyReservations
  , revisionEntries
  )
import Nagare.Inventory.Store
  ( HeadManifest
      ( headActiveTransaction
      , headBinding
      , headCollected
      , headDataFence
      , headRetained
      )
  , RetainedIncarnation
    ( retainedOwner
    , retainedPhysical
    , retainedRevision
    )
  , ScopeRevision (ScopeRevision, revisionGeneration)
  )
import Nagare.Resource.Inventory
  ( CompositionCandidate
  , Declaration (Managed, ObservedChild)
  , Executor
    ( ArtifactExecutor
    , BrokerExecutor
    , CdnExecutor
    , CloudFoundationExecutor
    , HelmExecutor
    , KubernetesExecutor
    , PulumiExecutor
    )
  , ManagedResource (dependencies, source)
  , OperationKind
    ( ActivateHost
    , StartVm
    , StopVm
    , PruneHostImage
    , PurgeCdnCache
    , PurgeCdnZone
    , CreateLogicalCache
    , MaintainData
    , PreDeployHook
    , PublishRelease
    , RestoreLiveData
    , SchemaMigration
    )
  , ScopeChange (CollectRetained, ReplaceScope, RetireScope)
  , candidateBase
  , candidateChanges
  , candidateGenerations
  , candidateInventory
  , candidateReservations
  , declarationDependencies
  , declarationId
  , inventoryBinding
  , inventoryDeclarations
  , inventoryScopes
  , scopeBundles
  , scopeId
  )
import Nagare.Resource.Policy
  ( DataPolicy (Durable, Stateless)
  , RecoveryClass (Idempotent, OperatorRecovery, VerifyBeforeRetry)
  , RetirementIntent (RetainResources)
  )
import Nagare.Resource.Reference
  ( Capability (NixCachePublicKey)
  , Dependency (Consumes, OrderedAfter, ReadyAfter)
  , SomeRef (SomeRef)
  , refProducer
  , refSignature
  )
import Nagare.Resource.Types
  ( ProviderAddress (Kubernetes)
  , ResourceId
  , ScopeId
  , SourceLocation (SourceLocation)
  , digestText
  , nameText
  )
import Nagare.Resource.Wire
  ( canonicalValue
  , encodeCanonicalScope
  )

-- | The review's desired vector is determined by the candidate alone. A
-- provider that captures private fence evidence before planning must use the
-- same canonical revisions that the resulting proposal will publish.
candidateDesiredRevisions :: CompositionCandidate -> Map ScopeId ScopeRevision
candidateDesiredRevisions candidate =
  Map.mapWithKey
    ( \scope declaration ->
        ScopeRevision
          (candidateGenerations candidate Map.! scope)
          (contentDigest (encodeCanonicalScope declaration))
    )
    (inventoryScopes (candidateInventory candidate))

planChanges :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) ChangeProposal
planChanges candidate decisions history observations = do
  unless (null structuralErrors) (Left (NE.fromList structuralErrors))
  case decisions of
    LifecycleDecisions (Just (reviewed, reviewedHistory)) _ _
      | reviewed /= candidate ->
          Left
            ( PlanError
                "stale-lifecycle-candidate"
                "lifecycle decisions were validated for a different composition candidate"
                []
                :| []
            )
      | reviewedHistory /= history ->
          Left
            ( PlanError
                "stale-lifecycle-history"
                "lifecycle decisions were validated for a different inventory history"
                []
                :| []
            )
    _ -> pure ()
  let (submitted, migrations) = case decisions of
        LifecycleDecisions _ values migrationValues -> (values, migrationValues)
  ordinary <-
    validateLifecycleDecisions
      candidate
      history
      observations
      [proposal | proposal <- Map.elems submitted, lifecycleDecision proposal /= ApproveMigration]
  migrationDecisions <- validatePairedMigrations candidate history observations migrations
  checkedDecisions@(LifecycleDecisions _ checked _) <- combineDecisions ordinary migrationDecisions
  unless
    (submitted == checked)
    ( Left
        ( PlanError
            "stale-lifecycle-evidence"
            "lifecycle decision evidence differs from current candidate and observations"
            []
            :| []
        )
    )
  operations <- buildOperations candidate checkedDecisions history observations
  retentions <- buildRetentionProofs candidate checkedDecisions history observations
  collections <- buildCollectionProofs candidate checkedDecisions history observations
  let migrationProofs = buildMigrationProofs checkedDecisions
  let desiredScopes = inventoryScopes (candidateInventory candidate)
      scopeMembers = Map.fromList [(contentDigest bytes, bytes) | declaration <- Map.elems desiredScopes, let bytes = encodeCanonicalScope declaration]
      desiredRevisions = candidateDesiredRevisions candidate
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
      , proposalMigrations = migrationProofs
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
        <> [ PlanError "active-data-fence" "recover and verify the live data fence before planning another review" []
           | Just _ <- [headDataFence (historyHead history)]
           ]
        <> [PlanError "base-revision" "candidate base scope generations do not match the accepted store head" [] | candidateBase candidate /= historyGenerations]
        <> [PlanError "reservation-history" "candidate retained address reservations differ from the authoritative store" [] | candidateReservations candidate /= historyReservations history]
        <> [ PlanError "retained-reactivation" "a retained logical resource requires a reviewed restore or migration before becoming desired again" retainedReactivations
           | not (null retainedReactivations)
           ]
        <> [ PlanError "collected-reactivation" "a collected logical resource has a deletion tombstone and cannot be silently reused" collectedReactivations
           | not (null collectedReactivations)
           ]
        <> [PlanError "accepted-contributions" "accepted scopes cannot be composed into their effective resources" [] | either (const True) (const False) (historyComposition history)]
        <> [PlanError "observation-coverage" "required resource was not observed" missing | not (null missing)]
        <> [PlanError "observation-unavailable" "required resource observation is unavailable" unavailable | not (null unavailable)]
    retainedReactivations =
      Set.toAscList
        ( Set.filter
            ( \resource ->
                Map.notMember
                  resource
                  ( Map.fromList
                      [(declarationId declaration, ()) | declaration <- historyDeclarations history]
                  )
            )
            ( Set.intersection
                (Map.keysSet (headRetained (historyHead history)))
                (Set.fromList (map declarationId (inventoryDeclarations (candidateInventory candidate))))
            )
        )
    collectedReactivations =
      Set.toAscList
        ( Set.intersection
            (Map.keysSet (headCollected (historyHead history)))
            (Set.fromList (map declarationId (inventoryDeclarations (candidateInventory candidate))))
        )

buildMigrationProofs :: LifecycleDecisions -> Map ResourceId MigrationProof
buildMigrationProofs (LifecycleDecisions _ _ migrations) = Map.map one migrations
  where
    one (migration, _) =
      let (revision, source) = validatedSource migration
          destination = validatedDestination migration
       in MigrationProof
            (source ^. #owner)
            revision
            (validatedSourcePhysical migration)
            (source ^. #address)
            (destination ^. #address)
            (validatedDestinationAbsence migration)
            (validatedContract migration)

buildRetentionProofs :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) (Map ResourceId RetentionProof)
buildRetentionProofs candidate (LifecycleDecisions _ decisions _) history observations = do
  unless
    (null disappearingChildren)
    (Left (PlanError "retained-child-history" "retirement of observed controller children requires retained child claims" disappearingChildren :| []))
  Map.fromList <$> traverse one selected
  where
    desired = Set.fromList (map declarationId (inventoryDeclarations (candidateInventory candidate)))
    disappearingChildren =
      [ resource
      | ObservedChild resource _ _ _ _ <- historyDeclarations history
      , Set.notMember resource desired
      ]
    selectedScopes =
      Set.fromList
        [ scope
        | change <- NE.toList (candidateChanges candidate)
        , Just scope <-
            [ case change of
                RetireScope owner RetainResources -> Just owner
                ReplaceScope replacement -> Just (scopeId replacement)
                _ -> Nothing
            ]
        ]
    selected =
      [ (resource ^. #identity, resource)
      | (_, (_, scope)) <- Map.toAscList (historyAccepted history)
      , bundle <- scopeBundles scope
      , Managed resource <- bundle ^. #declarations
      , Set.notMember (resource ^. #identity) desired
      , Set.member (resource ^. #owner) selectedScopes
      ]
    one (resourceId, resource) = case ( Map.lookup resourceId decisions
                                      , Map.lookup resourceId (observationMap observations)
                                      , Map.lookup (resource ^. #owner) (historyAccepted history)
                                      ) of
      (Just decision, Just (ObservedPresent physical), Just (revision, _))
        | lifecycleDecision decision == ApproveRetirement ->
            Right (resourceId, RetentionProof (resource ^. #owner) revision physical)
      _ -> Left (PlanError "retention-proof" "retired resource lacks a reviewed present incarnation" [resourceId] :| [])

buildCollectionProofs :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) (Map ResourceId RetentionProof)
buildCollectionProofs candidate (LifecycleDecisions _ decisions _) history observations =
  Map.fromList <$> traverse one selected
  where
    selected = [resource | CollectRetained resource <- NE.toList (candidateChanges candidate)]
    one resource = case ( Map.lookup resource decisions
                        , Map.lookup resource (historyRetained history)
                        , Map.lookup resource (observationMap observations)
                        ) of
      (Just decision, Just (incarnation, _), Just (ObservedPresent physical))
        | lifecycleDecision decision == ApproveCollection
        , physical == retainedPhysical incarnation ->
            Right
              ( resource
              , RetentionProof
                  (retainedOwner incarnation)
                  (retainedRevision incarnation)
                  physical
              )
      _ -> Left (PlanError "collection-proof" "collection lacks an exact retained incarnation proof" [resource] :| [])

buildOperations :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) [PlannedOperation]
buildOperations candidate (LifecycleDecisions _ decisions migrations) history observations =
  if null errors then Right (map addDependencies preliminary <> map snd declaredOperations) else Left (NE.fromList errors)
  where
    desiredDeclarations = Map.fromList [(declarationId declaration, declaration) | declaration <- inventoryDeclarations (candidateInventory candidate)]
    -- Accepted markers remain in the composed inventory during ordinary
    -- application/access reviews. Only selecting a marker requests the
    -- bootstrap-wide verification needed before publishing that marker.
    bootstrapReview =
      any
        isBootstrapMarker
        [ declaration
        | ReplaceScope scope <- NE.toList (candidateChanges candidate)
        , bundle <- scopeBundles scope
        , declaration <- bundle ^. #declarations
        ]
    isBootstrapMarker (Managed resource) = resource ^. #source . #file == "generated:bootstrap"
    isBootstrapMarker _ = False
    oldDeclarations = Map.fromList [(declarationId declaration, declaration) | declaration <- historyDeclarations history]
    oldOperations =
      Map.fromList
        [ (operation ^. #identity, operation)
        | (_, scope) <- Map.elems (historyAccepted history)
        , bundle <- scopeBundles scope
        , operation <- bundle ^. #operations
        ]
    -- Converged scope revisions retain proof of unchanged forward-only
    -- operations. Kubernetes TTL can remove migration Jobs, while host
    -- activation and artifact publication retain their verified receipts in
    -- the journal. A missing artifact still gets a focused create operation.
    provenOperations =
      Map.fromList
        [ (operation ^. #identity, operation)
        | (scope, (revision, declaration)) <- Map.toAscList (historyAccepted history)
        , Map.lookup scope (historyConverged history) == Just revision
        , bundle <- scopeBundles declaration
        , operation <- bundle ^. #operations
        , forwardOnly operation
        ]
    operationIsProven operation =
      forwardOnly operation
        && Map.lookup (operation ^. #identity) provenOperations == Just operation
    forwardOnly operation =
      operation ^. #operationKind
        `elem` [SchemaMigration, PreDeployHook, ActivateHost, MaintainData, RestoreLiveData, PurgeCdnCache, PurgeCdnZone, StartVm, StopVm, PruneHostImage]
        || ( operation ^. #operationKind == PublishRelease
               && all isArtifact (NE.toList (operation ^. #affects))
           )
    isArtifact resourceId = case Map.lookup resourceId oldDeclarations of
      Just (Managed resource) -> resource ^. #executor == ArtifactExecutor
      _ -> False
    provenMigrationJobs =
      Set.fromList
        [ resource
        | scope <- Map.elems (inventoryScopes (candidateInventory candidate))
        , bundle <- scopeBundles scope
        , operation <- bundle ^. #operations
        , operationIsProven operation
        , resource <- NE.toList (operation ^. #affects)
        , Just (Managed affected) <- [Map.lookup resource desiredDeclarations]
        , isMigrationJob (affected ^. #address)
        ]
    observed = observationMap observations
    selectedIds = affectedManagedIds candidate history
    desiredManaged =
      [ (resource ^. #identity, resource, Map.lookup (resource ^. #identity) oldDeclarations, Map.lookup (resource ^. #identity) observed)
      | Managed resource <- Map.elems desiredDeclarations
      , Set.member (resource ^. #identity) selectedIds
      ]
    selectedScopeIds =
      Set.fromList
        [scopeId scope | ReplaceScope scope <- NE.toList (candidateChanges candidate)]
    unconvergedSelectedScopeIds =
      Set.filter
        ( \owner ->
            case Map.lookup owner (historyAccepted history) of
              Just (revision, _) -> Map.lookup owner (historyConverged history) /= Just revision
              Nothing -> False
        )
        selectedScopeIds
    requiredTopics =
      Set.fromList
        [ target
        | Managed consumer <- Map.elems desiredDeclarations
        , Set.member (consumer ^. #owner) selectedScopeIds
        , dependency <- consumer ^. #dependencies
        , let target = dependencyResource dependency
        , Just (Managed producer) <- [Map.lookup target desiredDeclarations]
        , producer ^. #executor == BrokerExecutor
        ]
    retired = [(resource, declaration) | (resource, declaration@(Managed _)) <- Map.toAscList oldDeclarations, Map.notMember resource desiredDeclarations]
    selectedCollections =
      [ (resourceId, resource)
      | CollectRetained resourceId <- NE.toList (candidateChanges candidate)
      , Just (_, resource) <- [Map.lookup resourceId (historyRetained history)]
      ]
    classified = map classifyDesired desiredManaged
    errors =
      concatMap fst classified
        <> concatMap retireError retired
        <> [ PlanError
               "operation-revision-required"
               "a declared operation changed under the same identity; use a new release or operation key"
               [operation ^. #identity]
           | (operation, _) <- declaredSeeds
           , operation ^. #operationKind == PreDeployHook
           , Just previous <- [Map.lookup (operation ^. #identity) oldOperations]
           , previous /= operation
           ]
        <> [ PlanError "collection-decision" "retained collection lacks a validated lifecycle decision" [resourceId]
           | (resourceId, _) <- selectedCollections
           , not (decisionIs ApproveCollection resourceId)
           ]
    preliminary = groupPulumiCreates preliminaryRaw
    preliminaryRaw =
      mapMaybe snd classified
        <> mapMaybe retireOperation retired
        <> concatMap migrationOperations (Map.toAscList migrations)
        <> [resourceOperation RetireResource resource | (_, resource) <- selectedCollections]
    -- Pulumi saved plans describe one stack snapshot. Independent plans for
    -- resources in that stack become stale as soon as the first one applies.
    groupPulumiCreates operations =
      [operation | operation <- operations, isNothing (pulumiCreateOwner operation)]
        <> [ groupOwner ownerOperations
           | (_, ownerOperations) <-
               Map.toAscList
                 ( Map.fromListWith
                     (<>)
                     [ (owner, [operation])
                     | operation <- operations
                     , Just owner <- [pulumiCreateOwner operation]
                     ]
                 )
           ]
    pulumiCreateOwner operation = case (plannedAction operation, plannedExecutor operation, NE.toList (plannedResources operation)) of
      (CreateResource, PulumiExecutor, [resourceId]) -> case Map.lookup resourceId desiredDeclarations of
        Just (Managed resource) -> Just (resource ^. #owner)
        _ -> Nothing
      _ -> Nothing
    groupOwner [operation] = operation
    groupOwner operations =
      let ordered = sortOn (NE.head . plannedResources) operations
          resources = NE.fromList (map (NE.head . plannedResources) ordered)
          digest =
            contentDigest
              ( canonicalBytes
                  ( toJSON
                      [(plannedResources operation, plannedInputDigest operation) | operation <- ordered]
                  )
              )
          recovery =
            if all ((== Idempotent) . plannedRecovery) ordered
              then Idempotent
              else VerifyBeforeRetry
       in mkPlanned CreateResource PulumiExecutor resources digest recovery
    -- A dependent update may start after the destination is verified, but
    -- the consumer-switch stage must wait for that update to complete. The
    -- final RetainSource stage is too late to be the dependency target.
    migrationVerification =
      Map.fromList
        [ (resource, plannedOperationId operation)
        | operation <- preliminary
        , plannedAction operation == MigrateResource VerifyDestination
        , resource <- NE.toList (plannedResources operation)
        ]
    operationByResource =
      Map.union
        migrationVerification
        ( Map.fromList
            [ (resource, plannedOperationId operation)
            | operation <- preliminary
            , case plannedAction operation of MigrateResource _ -> False; _ -> True
            , resource <- NE.toList (plannedResources operation)
            ]
        )
    operationByDeclaration =
      Map.fromList
        [ (declaredOperation ^. #identity, plannedOperationId operation)
        | (declaredOperation, operation) <- declaredSeeds
        ]
    operationByDependency = Map.union operationByResource operationByDeclaration
    addDependencies operation =
      operation
        { plannedDependencies =
            Set.toAscList
              ( Set.fromList
                  ( plannedDependencies operation
                      <> [ dependencyOperation
                         | resource <- NE.toList (plannedResources operation)
                         , Just declaration <- [Map.lookup resource desiredDeclarations]
                         , dependency <- declarationDependencies declaration
                         , Just dependencyOperation <- [operationForDependency dependency]
                         , dependencyOperation /= plannedOperationId operation
                         ]
                      <> switchPrerequisites operation
                  )
              )
        }
    switchPrerequisites operation = case plannedAction operation of
      MigrateResource SwitchConsumers ->
        [ plannedOperationId consumerOperation
        | migrated <- NE.toList (plannedResources operation)
        , consumerOperation <- preliminary
        , case plannedAction consumerOperation of MigrateResource _ -> False; _ -> True
        , consumer <- NE.toList (plannedResources consumerOperation)
        , Just declaration <- [Map.lookup consumer desiredDeclarations]
        , migrated `elem` map dependencyResource (declarationDependencies declaration)
        ]
      _ -> []
    declaredSeeds = concatMap scopeDeclared (Map.elems (inventoryScopes (candidateInventory candidate)))
    hookJobIds =
      Set.fromList
        [ resource
        | (operation, _) <- declaredSeeds
        , operation ^. #operationKind == PreDeployHook
        , resource <- NE.toList (operation ^. #affects)
        , Just (Managed affected) <- [Map.lookup resource desiredDeclarations]
        , isMigrationJob (affected ^. #address)
        ]
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
        , any (`Set.member` selectedIds) (NE.toList (operation ^. #affects))
        , not (operationIsProven operation)
        ]
    declared operation = do
      executor <- listToMaybe [resource ^. #executor | resourceId <- NE.toList (operation ^. #affects), Just (Managed resource) <- [Map.lookup resourceId desiredDeclarations]]
      let digest = contentDigest (canonicalBytes (toJSON operation))
      let action = case operation ^. #operationKind of
            MaintainData -> OpenMaintenanceSession
            RestoreLiveData -> RestoreLiveDatabase
            _ -> RunDeclaredOperation
      pure (operation, mkPlanned action executor (operation ^. #affects) digest (operation ^. #recovery))
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
    classifyDesired (resourceId, resource, Just (Managed old), observation)
      | Set.member resourceId hookJobIds
      , old ^. #spec /= resource ^. #spec =
          (
            [ PlanError
                "job-revision-required"
                "a reviewed Job changed under the same identity; use a new release or run ID"
                [resourceId]
            ]
          , Nothing
          )
      | old ^. #address /= resource ^. #address
          || old ^. #executor /= resource ^. #executor
      , decisionIs ApproveMigration resourceId =
          ([], Nothing)
      | old ^. #address /= resource ^. #address
          || old ^. #executor /= resource ^. #executor =
          ([PlanError "migration-review-required" "changing a known resource address or executor needs a reviewed source and destination migration" [resourceId]], Nothing)
      | old ^. #owner /= resource ^. #owner
      , decisionIs ApproveTransfer resourceId =
          ([], Just (resourceOperation VerifyResource resource))
      | old ^. #owner /= resource ^. #owner =
          ([PlanError "owner-transfer-required" "moving a known resource between scopes needs a reviewed two-scope transfer" [resourceId]], Nothing)
      | cloudCollectionPolicyOnly old resource
      , Just (ObservedPresent _) <- observation =
          ([], Just (resourceOperation VerifyResource resource))
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
          if Set.member resourceId (historyUnstartedCreates history)
            && sameManaged old resource
            then ([], Just (resourceOperation CreateResource resource))
            else
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
            , if (bootstrapReview && resource ^. #executor `elem` [KubernetesExecutor, HelmExecutor])
                || Set.member (resource ^. #owner) unconvergedSelectedScopeIds
                || Set.member resourceId requiredTopics
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
          recovery = case (resource ^. #executor, resource ^. #dataPolicy) of
            (CdnExecutor, _) -> VerifyBeforeRetry
            (CloudFoundationExecutor, _) -> VerifyBeforeRetry
            (_, Stateless) -> Idempotent
            (_, Durable _) -> VerifyBeforeRetry
       in mkPlanned action (resource ^. #executor) (resource ^. #identity :| []) digest recovery
    migrationOperations (resourceId, (migration, _)) =
      zipWith addPrevious stages (Nothing : map (Just . plannedOperationId) stages)
      where
        (sourceRevision, sourceResource) = validatedSource migration
        destinationResource = validatedDestination migration
        digest =
          contentDigest
            ( canonicalBytes
                ( object
                    [ "resource" .= resourceId
                    , "sourceRevision" .= sourceRevision
                    , "source" .= Managed sourceResource
                    , "sourcePhysical" .= validatedSourcePhysical migration
                    , "destination" .= Managed destinationResource
                    , "destinationAbsence" .= validatedDestinationAbsence migration
                    , "contract" .= validatedContract migration
                    ]
                )
            )
        stages =
          [ stage PrepareDestination (destinationResource ^. #executor) Idempotent
          , stage BackUpSource (sourceResource ^. #executor) VerifyBeforeRetry
          , stage FenceWriters (sourceResource ^. #executor) OperatorRecovery
          , stage TransferState (destinationResource ^. #executor) VerifyBeforeRetry
          , stage VerifyDestination (destinationResource ^. #executor) Idempotent
          , stage SwitchConsumers (destinationResource ^. #executor) OperatorRecovery
          , stage AdmitWrites (destinationResource ^. #executor) OperatorRecovery
          , stage RetainSource (sourceResource ^. #executor) Idempotent
          ]
        stage name executor recovery =
          mkPlanned
            (MigrateResource name)
            executor
            (resourceId :| [])
            digest
            recovery
        addPrevious operation Nothing = operation
        addPrevious operation (Just predecessor) =
          operation
            { plannedDependencies = [predecessor]
            }
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
