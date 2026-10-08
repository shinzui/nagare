-- | Lifecycle responsibilities; internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.Lifecycle
  ( approveMigrations
  , combineDecisions
  , lifecycleObservationDigest
  , noLifecycleDecisions
  , validateLifecycleDecisions
  , validatePairedMigrations
  )
where

import Data.Aeson (KeyValue ((.=)), object)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Adapter
  ( MigrationObservationSet
  , ObservationSet
  , ResourceObservation
    ( ConfirmedAbsent
    , ObservedPresent
    , ObservedUnowned
    )
  , migrationObservationMap
  , observationMap
  )
import Nagare.Inventory.CollectionPolicy
  ( supportsRetainedCollection
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Migration.Types
  ( MigrationContract (DurableMigration, StatelessMigration)
  , ValidatedMigration
    ( validatedContract
    , validatedDestination
    , validatedDestinationAbsence
    , validatedSource
    , validatedSourcePhysical
    )
  , migrationPoliciesCompatible
  )
import Nagare.Inventory.Plan.Types
  ( InventoryHistory (..)
  , LifecycleDecisionKind (..)
  , LifecycleDecisions (..)
  , LifecycleProposal (..)
  , PlanError (..)
  , duplicateValues
  , historyDeclarations
  )
import Nagare.Inventory.Store
  ( HeadManifest (headCollected, headIncarnations, headRetained)
  , RetainedIncarnation (retainedPhysical)
  )
import Nagare.Resource.Inventory
  ( CompositionCandidate
  , Declaration (Managed)
  , DesiredSpec (AccessGrantSpec)
  , Executor
    ( AccessExecutor
    , ArtifactExecutor
    , BrokerExecutor
    , CdnExecutor
    , HelmExecutor
    , HostExecutor
    , KubernetesExecutor
    , PulumiExecutor
    )
  , ManagedResource
  , ScopeChange (CollectRetained, ReplaceScope, RetireScope)
  , candidateChanges
  , candidateInventory
  , declarationDependencies
  , declarationId
  , inventoryBinding
  , inventoryDeclarations
  , scopeBundles
  , scopeId
  )
import Nagare.Resource.Policy
  ( DataPolicy (Durable, Stateless)
  , LifecyclePolicy (DeleteWhenUnreferenced)
  , RetirementIntent (RetainResources)
  )
import Nagare.Resource.Reference
  ( Dependency (Consumes, OrderedAfter, ReadyAfter)
  , refSignature
  )
import Nagare.Resource.Types
  ( ContentDigest
  , ContextBinding
  , ResourceId
  , ScopeKind (Platform)
  , nameText
  , scopeKind
  , scopeName
  )
import Nagare.Resource.Wire (canonicalValue)

noLifecycleDecisions :: LifecycleDecisions
noLifecycleDecisions = LifecycleDecisions Nothing Map.empty Map.empty

-- | A review can combine independently validated lifecycle requests only
-- when each names a different logical resource. planChanges revalidates the
-- combined set against its own candidate, history, and observations.
combineDecisions :: LifecycleDecisions -> LifecycleDecisions -> Either (NonEmpty PlanError) LifecycleDecisions
combineDecisions
  (LifecycleDecisions firstCandidate firstDecisions firstMigrations)
  (LifecycleDecisions secondCandidate secondDecisions secondMigrations) =
    case Map.keys (Map.intersection firstDecisions secondDecisions) of
      overlapping@(_ : _) ->
        Left
          ( PlanError
              "duplicate-lifecycle-decision"
              "resource has more than one lifecycle decision"
              overlapping
              :| []
          )
      [] -> case (firstCandidate, secondCandidate) of
        (Just firstReviewed, Just secondReviewed)
          | firstReviewed /= secondReviewed ->
              Left
                ( PlanError
                    "stale-lifecycle-context"
                    "lifecycle decisions were validated for different candidates or inventory histories"
                    []
                    :| []
                )
        _ ->
          Right
            ( LifecycleDecisions
                (firstCandidate <|> secondCandidate)
                (Map.union firstDecisions secondDecisions)
                (Map.union firstMigrations secondMigrations)
            )

-- | Bind an operator decision to one observed incarnation in one provider
-- target. A new observation or a different target requires a fresh decision.
lifecycleObservationDigest :: ContextBinding -> ResourceId -> ResourceObservation -> ContentDigest
lifecycleObservationDigest binding resource fact =
  contentDigest
    ( either
        (error . T.unpack)
        id
        ( canonicalValue
            (object ["binding" .= binding, "resource" .= resource, "observation" .= fact])
        )
    )

migrationObservationDigest ::
  ContextBinding ->
  ResourceId ->
  ValidatedMigration ->
  (ResourceObservation, ResourceObservation) ->
  ContentDigest
migrationObservationDigest binding resource migration (sourceFact, destinationFact) =
  contentDigest
    ( either
        (error . T.unpack)
        id
        ( canonicalValue
            ( object
                [ "binding" .= binding
                , "resource" .= resource
                , "sourceRevision" .= fst (validatedSource migration)
                , "source" .= sourceFact
                , "destination" .= destinationFact
                , "contract" .= validatedContract migration
                ]
            )
        )
    )

-- | Only a paired, freshly observed migration can build an opaque approval.
-- The planner rechecks this value against its own candidate and destination
-- observation; admission must reobserve the source under the writer lock.
approveMigrations ::
  CompositionCandidate ->
  InventoryHistory ->
  ObservationSet ->
  MigrationObservationSet ->
  Map ResourceId ValidatedMigration ->
  Either (NonEmpty PlanError) LifecycleDecisions
approveMigrations candidate history observations pairs migrations
  | not (null missing) =
      Left
        ( PlanError
            "migration-coverage"
            "validated migration lacks one paired source and destination observation"
            missing
            :| []
        )
  | otherwise = validatePairedMigrations candidate history observations paired
  where
    paired = Map.intersectionWith (,) migrations (migrationObservationMap pairs)
    missing = Set.toAscList (Map.keysSet migrations `Set.difference` Map.keysSet paired)

validatePairedMigrations ::
  CompositionCandidate ->
  InventoryHistory ->
  ObservationSet ->
  Map ResourceId (ValidatedMigration, (ResourceObservation, ResourceObservation)) ->
  Either (NonEmpty PlanError) LifecycleDecisions
validatePairedMigrations candidate history observations paired =
  if null errors
    then Right (LifecycleDecisions (Just (candidate, history)) proposals paired)
    else Left (NE.fromList errors)
  where
    binding = inventoryBinding (candidateInventory candidate)
    desired =
      Map.fromList
        [ (resource ^. #identity, resource)
        | Managed resource <- inventoryDeclarations (candidateInventory candidate)
        ]
    accepted =
      Map.fromList
        [ (resource ^. #identity, (revision, resource))
        | (scope, (revision, declaration)) <- Map.toAscList (historyAccepted history)
        , bundle <- scopeBundles declaration
        , Managed resource <- bundle ^. #declarations
        , resource ^. #owner == scope
        ]
    pairedResources =
      [ (snd (validatedSource migration), validatedDestination migration)
      | (migration, _) <- Map.elems paired
      ]
    proposals =
      Map.mapWithKey
        ( \resource (migration, facts) ->
            LifecycleProposal
              resource
              ApproveMigration
              (migrationObservationDigest binding resource migration facts)
        )
        paired
    errors =
      [ PlanError "invalid-migration" "migration differs from accepted source, composed destination, data policy, or exact observations" [resource]
      | (resource, (migration, (sourceFact, destinationFact))) <- Map.toAscList paired
      , let (revision, source) = validatedSource migration
            destination = validatedDestination migration
      , Map.lookup resource accepted /= Just (revision, source)
          || Map.lookup resource desired /= Just destination
          || source ^. #owner /= destination ^. #owner
          || ( source ^. #address == destination ^. #address
                 && source ^. #executor == destination ^. #executor
             )
          || not (migrationPoliciesCompatible pairedResources source destination)
          || not
            ( case (source ^. #dataPolicy, validatedContract migration) of
                (Stateless, StatelessMigration) -> True
                (Durable _, DurableMigration {}) -> True
                _ -> False
            )
          || sourceFact /= ObservedPresent (validatedSourcePhysical migration)
          || destinationFact /= ConfirmedAbsent (validatedDestinationAbsence migration)
          || Map.lookup resource (observationMap observations) /= Just destinationFact
          || Map.member resource (historyRetained history)
          || Map.member resource (headCollected (historyHead history))
      ]

validateLifecycleDecisions :: CompositionCandidate -> InventoryHistory -> ObservationSet -> [LifecycleProposal] -> Either (NonEmpty PlanError) LifecycleDecisions
validateLifecycleDecisions candidate history observations proposals =
  if null errors then Right (LifecycleDecisions (Just (candidate, history)) values Map.empty) else Left (NE.fromList errors)
  where
    values = Map.fromList [(lifecycleResource proposal, proposal) | proposal <- proposals]
    desired = Map.fromList [(declarationId declaration, declaration) | declaration <- inventoryDeclarations (candidateInventory candidate)]
    historical = Map.fromList [(declarationId declaration, declaration) | declaration <- historyDeclarations history]
    known =
      Map.keysSet desired
        `Set.union` Map.keysSet historical
        `Set.union` Map.keysSet (historyRetained history)
    observed = observationMap observations
    retirementSelected resource = case Map.lookup resource historical of
      Just (Managed old) ->
        any
          ( \case
              RetireScope scope RetainResources -> scope == old ^. #owner
              RetireScope _ _ -> False
              ReplaceScope scope ->
                scopeId scope == old ^. #owner
                  && Map.notMember resource desired
              CollectRetained _ -> False
          )
          (NE.toList (candidateChanges candidate))
      _ -> False
    decisionError proposal =
      let resource = lifecycleResource proposal
          issue code message = [PlanError code message [resource]]
          fact = Map.lookup resource observed
          evidence =
            maybe
              []
              ( \value ->
                  if lifecycleEvidence proposal
                    == lifecycleObservationDigest
                      (inventoryBinding (candidateInventory candidate))
                      resource
                      value
                    then []
                    else issue "stale-lifecycle-evidence" "decision evidence differs from the current observation"
              )
              fact
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
                , Set.fromList (next ^. #dependencies) == Set.fromList (old ^. #dependencies) ->
                    []
              _ -> issue "invalid-transfer" "transfer needs both selected scopes, a matching owned incarnation, and an unchanged Kubernetes or Helm resource contract"
            ApproveRetirement -> case (Map.lookup resource desired, Map.lookup resource historical) of
              (Nothing, Just (Managed old))
                | Just (ObservedPresent _) <- fact
                , retirementSelected resource
                , ( old ^. #executor `elem` [KubernetesExecutor, HelmExecutor, BrokerExecutor, CdnExecutor]
                      -- Host systems and artifacts (kubeconfig, images) are retained as
                      -- history only; no reviewed collection deletes them (F40).
                      || old ^. #executor `elem` [HostExecutor, ArtifactExecutor]
                      || ( old ^. #executor == PulumiExecutor
                             && scopeKind (old ^. #owner) == Platform
                             && nameText (scopeName (old ^. #owner)) == "cloud"
                         )
                      -- A revoked access grant is retained as history; it grants nothing.
                      || (old ^. #executor == AccessExecutor && not (grantLive old))
                  )
                , Map.notMember resource (headRetained (historyHead history)) ->
                    []
              (Nothing, Just (Managed old))
                | old ^. #executor == AccessExecutor
                , grantLive old ->
                    issue "access-grant-live" "revoke the access grant with a reviewed access revoke before retiring its scope; a retired grant could never be revoked"
              _ -> issue "invalid-retirement" "retention needs a selected scope replacement or retirement that removes an owned present Kubernetes, Helm, broker topic, CDN, host, artifact, or platform cloud declaration"
            ApproveCollection -> case (Map.lookup resource desired, Map.lookup resource (historyRetained history), fact) of
              (Nothing, Just (incarnation, old), Just (ObservedPresent physical))
                | CollectRetained resource `elem` NE.toList (candidateChanges candidate)
                , physical == retainedPhysical incarnation
                , old ^. #lifecycle == DeleteWhenUnreferenced
                , old ^. #dataPolicy == Stateless
                , supportsRetainedCollection old
                , null
                    [ consumer
                    | consumer <- historyDeclarations history <> map (Managed . snd) (Map.elems (historyRetained history))
                    , any ((== resource) . dependencyTarget) (declarationDependencies consumer)
                    ] ->
                    []
              _ -> issue "invalid-collection" "collection needs a selected retained incarnation of a supported kind, exact present provider identity, stateless deletion policy, and no known consumers"
            ApproveMigration -> issue "unsupported-migration" "migration needs a reviewed data and cutover contract"
            -- ADR 27 §3: record the live object of an accepted Kubernetes
            -- member that stays declared, when it is not the recorded one.
            ApproveRebind -> case (Map.lookup resource desired, Map.lookup resource historical, fact) of
              (Just (Managed next), Just (Managed old), Just (ObservedPresent live))
                | next ^. #executor == KubernetesExecutor
                , old ^. #executor == KubernetesExecutor
                , next ^. #owner == old ^. #owner
                , Map.lookup resource (headIncarnations (historyHead history)) /= Just live ->
                    []
              _ -> issue "invalid-rebind" "rebind needs an accepted Kubernetes member that stays declared and a live owned object that is not its recorded incarnation"
       in evidence <> shape
    selectedScopes =
      Set.fromList
        [ scope
        | change <- NE.toList (candidateChanges candidate)
        , Just scope <-
            [ case change of
                ReplaceScope declaration -> Just (scopeId declaration)
                RetireScope owner _ -> Just owner
                CollectRetained _ -> Nothing
            ]
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

-- | Whether an access grant's accepted declaration grants access.
grantLive :: ManagedResource -> Bool
grantLive resource = case resource ^. #spec of
  AccessGrantSpec _ granted -> granted
  _ -> False
