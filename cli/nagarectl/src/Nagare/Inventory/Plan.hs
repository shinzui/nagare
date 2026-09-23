-- | Pure inventory planning and digest-bound review bundles.
module Nagare.Inventory.Plan
  ( InventoryHistory
  , loadInventoryHistory
  , seedInventoryHistory
  , historyAccepted
  , historyConverged
  , ObservationRequirements
  , observationRequirements
  , requiredResources
  , requirementsByExecutor
  , LifecycleDecisionKind (..)
  , LifecycleProposal (..)
  , LifecycleDecisions
  , noLifecycleDecisions
  , validateLifecycleDecisions
  , PlanError (..)
  , ChangeProposal
  , proposalOperations
  , proposalDesired
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
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
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
      pure $ InventoryHistory headValue . Map.fromList <$> sequence loaded <*> pure (headConverged headValue)
  where
    loadScope inventoryStore (scope, revision) = do
      bytesResult <- readObject inventoryStore (scopeKey (revisionDigest revision))
      pure $ do
        bytes <- bytesResult >>= maybe (Left (StoreInvalidObject (scopeKey (revisionDigest revision)) "scope member is missing")) Right
        unless (contentDigest bytes == revisionDigest revision) (Left (StoreInvalidObject (scopeKey (revisionDigest revision)) "scope member digest mismatch"))
        declaration <- first (StoreInvalidObject (scopeKey (revisionDigest revision)) . T.pack . show) (decodeScope bytes)
        unless (scopeId declaration == scope) (Left (StoreInvalidObject (scopeKey (revisionDigest revision)) "scope member identity mismatch"))
        pure (scope, (revision, declaration))

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
  }
  deriving stock (Eq, Show)

observationRequirements :: CompositionCandidate -> InventoryHistory -> ObservationRequirements
observationRequirements candidate history =
  ObservationRequirements ids grouped
  where
    declarations = inventoryDeclarations (candidateInventory candidate) <> historyDeclarations history
    managed = [(resource ^. #identity, resource ^. #executor) | Managed resource <- declarations]
    ids = Set.fromList (map fst managed)
    grouped = Map.map (Set.toAscList . Set.fromList) (Map.fromListWith (<>) [(executor, [resource]) | (resource, executor) <- managed])

data LifecycleDecisionKind = ApproveAdoption | ApproveRetirement | ApproveMigration | ApproveCollection
  deriving stock (Eq, Ord, Show, Generic)

data LifecycleProposal = LifecycleProposal
  { lifecycleResource :: !ResourceId
  , lifecycleDecision :: !LifecycleDecisionKind
  , lifecycleEvidence :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

newtype LifecycleDecisions = LifecycleDecisions (Map ResourceId LifecycleProposal)
  deriving stock (Eq, Show)

noLifecycleDecisions :: LifecycleDecisions
noLifecycleDecisions = LifecycleDecisions Map.empty

validateLifecycleDecisions :: CompositionCandidate -> InventoryHistory -> ObservationSet -> [LifecycleProposal] -> Either (NonEmpty PlanError) LifecycleDecisions
validateLifecycleDecisions candidate history observations proposals =
  if null errors then Right (LifecycleDecisions values) else Left (NE.fromList errors)
  where
    values = Map.fromList [(lifecycleResource proposal, proposal) | proposal <- proposals]
    known = Set.fromList (map declarationId (inventoryDeclarations (candidateInventory candidate) <> historyDeclarations history))
    observed = Map.keysSet (observationMap observations)
    errors =
      [PlanError "duplicate-lifecycle-decision" "resource has more than one lifecycle decision" [resource] | resource <- duplicateValues (map lifecycleResource proposals)]
        <> [PlanError "unknown-lifecycle-resource" "lifecycle decision names an unknown resource" [resource] | resource <- Map.keys values, Set.notMember resource known]
        <> [PlanError "unobserved-lifecycle-resource" "lifecycle decision lacks an observation" [resource] | resource <- Map.keys values, Set.notMember resource observed]

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
  }
  deriving stock (Eq, Show)

planChanges :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) ChangeProposal
planChanges candidate decisions history observations = do
  unless (null structuralErrors) (Left (NE.fromList structuralErrors))
  operations <- buildOperations candidate decisions history observations
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
        <> [PlanError "active-transaction" "resume or resolve the active inventory transaction before planning another review" []
           | Just _ <- [headActiveTransaction (historyHead history)]]
        <> [PlanError "base-revision" "candidate base scope generations do not match the accepted store head" [] | candidateBase candidate /= historyGenerations]
        <> [PlanError "accepted-contributions" "accepted scopes cannot be composed into their effective resources" [] | either (const True) (const False) (historyComposition history)]
        <> [PlanError "observation-coverage" "required resource was not observed" missing | not (null missing)]
        <> [PlanError "observation-unavailable" "required resource observation is unavailable" unavailable | not (null unavailable)]

buildOperations :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) [PlannedOperation]
buildOperations candidate (LifecycleDecisions decisions) history observations =
  if null errors then Right (map addDependencies preliminary <> map snd declaredOperations) else Left (NE.fromList errors)
  where
    desiredDeclarations = Map.fromList [(declarationId declaration, declaration) | declaration <- inventoryDeclarations (candidateInventory candidate)]
    bootstrapReview = any isBootstrapMarker (Map.elems desiredDeclarations)
    isBootstrapMarker (Managed resource) = resource ^. #source . #file == "generated:bootstrap"
    isBootstrapMarker _ = False
    oldDeclarations = Map.fromList [(declarationId declaration, declaration) | declaration <- historyDeclarations history]
    -- Converged scope revisions retain proof of unchanged forward-only
    -- migrations after Kubernetes TTL removes their Job objects.
    provenMigrations = Map.fromList
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
    provenMigrationJobs = Set.fromList
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
    classified = map classifyDesired desiredManaged
    errors = concatMap fst classified <> concatMap retireError retired
    preliminary = mapMaybe snd classified <> mapMaybe retireOperation retired
    operationByResource = Map.fromList [(resource, plannedOperationId operation) | operation <- preliminary, resource <- NE.toList (plannedResources operation)]
    operationByDeclaration = Map.fromList
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
    cacheOutputOperations = Map.fromList
      [ (resource, plannedOperationId planned)
      | (declaredOperation, planned) <- declaredSeeds
      , declaredOperation ^. #operationKind == CreateLogicalCache
      , resource <- NE.toList (declaredOperation ^. #affects)
      ]
    operationForDependency dependency = case dependency of
      Consumes ref | refCapability ref == NixCachePublicKey ->
        Map.lookup (dependencyResource dependency) cacheOutputOperations
      _ -> Map.lookup (dependencyResource dependency) operationByDependency
    refCapability (SomeRef ref) = let (_, _, capability, _, _) = refSignature (SomeRef ref) in capability
    scopeDeclared declaration = mapMaybe declared
      [ operation | bundle <- scopeBundles declaration, operation <- bundle ^. #operations,
        not (migrationIsProven operation)]
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
        let canonicalDependencies value = value
              {dependencies = Set.toAscList (Set.fromList (value ^. #dependencies))}
         in canonicalBytes (toJSON (Managed (canonicalDependencies previous)))
              == canonicalBytes (toJSON (Managed (canonicalDependencies resource)))
      _ -> False
    classifyDesired (resourceId, resource, previous, observation) = case (previous, observation) of
      (Nothing, Just (ConfirmedAbsent _)) -> ([], Just (resourceOperation CreateResource resource))
      (Nothing, Just (ObservedPresent _)) ->
        if decisionIs ApproveAdoption resourceId
          then ([], Just (resourceOperation AdoptResource resource))
          else ([PlanError "adoption-required" "resource exists but is not owned by accepted history" [resourceId]], Nothing)
      (Nothing, Just (ObservedDrifted _ _)) ->
        if decisionIs ApproveAdoption resourceId
          then ([], Just (resourceOperation AdoptResource resource))
          else ([PlanError "adoption-required" "resource exists but is not owned by accepted history" [resourceId]], Nothing)
      (_, Just (ObservedForeign _)) -> ([PlanError "foreign-resource" "resource address is occupied by an object without accepted ownership" [resourceId]], Nothing)
      (Nothing, Just (ObservationUnavailable _)) -> ([PlanError "observation-unavailable" "resource observation is unavailable" [resourceId]], Nothing)
      (Just old, Just (ConfirmedAbsent _)) -> case resource ^. #dataPolicy of
        Stateless | Set.member resourceId provenMigrationJobs
          , sameManaged old resource
          , isMigrationJob (resource ^. #address) -> ([], Nothing)
        Stateless -> ([], Just (resourceOperation CreateResource resource))
        Durable _ -> ([PlanError "durable-resource-missing"
          "accepted durable resource is absent; recover its data before replanning" [resourceId]], Nothing)
      (Just _, Just (ObservedDrifted _ _)) -> ([], Just (resourceOperation UpdateResource resource))
      (Just old, _)
        | sameManaged old resource ->
            ([], if bootstrapReview && resource ^. #executor `elem` [KubernetesExecutor, HelmExecutor]
              then Just (resourceOperation VerifyResource resource) else Nothing)
      (Just _, Just (ObservationUnavailable _)) -> ([PlanError "observation-unavailable" "resource observation is unavailable" [resourceId]], Nothing)
      (Just _, _) -> ([], Just (resourceOperation UpdateResource resource))
      (_, Nothing) -> ([PlanError "observation-coverage" "resource was not observed" [resourceId]], Nothing)
    retireError (resource, _)
      | decisionIs ApproveRetirement resource || decisionIs ApproveCollection resource = []
      | otherwise = [PlanError "retirement-required" "accepted resource is absent from desired inventory without a lifecycle decision" [resource]]
    retireOperation (resource, Managed old)
      | decisionIs ApproveRetirement resource || decisionIs ApproveCollection resource = Just (resourceOperation RetireResource old)
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

instance ToJSON ReviewDocument where
  toJSON document =
    object
      [ "version" .= reviewSchemaVersion document
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
      ]

instance FromJSON ReviewDocument where
  parseJSON = withObject "ReviewDocument" $ \o -> do
    let allowed = ["version", "context", "headGeneration", "headSequence", "baseRevisions", "desiredRevisions", "candidateDigest", "payloadIdentity", "policyVersion", "operations", "barriers"]
    unless (all (`elem` allowed) (KM.keys o)) (fail "review document has an unknown field")
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail "unsupported review schema version")
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
        <> [ReviewError "scope-member" "active review scope member is missing or has a different digest" | not (membersMatch (bundleScopes bundle) (map revisionDigest (Map.elems (reviewDesiredRevisions document))))]
        <> [ReviewError "native-member" "active review native member is missing or has a different digest" | not (membersMatch (bundleNative bundle) [member | operation <- reviewOperations document, Just member <- [reviewNativeDigest operation]])]
    membersMatch members digests =
      Set.fromList digests == Map.keysSet members
        && all (\(memberDigest, bytes) -> contentDigest bytes == memberDigest) (Map.toList members)

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
