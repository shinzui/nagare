-- | Types responsibilities; internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.Types
  ( historyReservations
  , retainedReservations
  , AbsenceProof (..)
  , ChangeProposal (..)
  , InventoryHistory (..)
  , LifecycleDecisionKind (..)
  , LifecycleDecisions (..)
  , LifecycleProposal (..)
  , MigrationProof (..)
  , ObservationRequirements (..)
  , PlanError (..)
  , RebindProof (..)
  , renderRebind
  , RebuildProof (..)
  , RetentionProof (..)
  , ReviewBundle (..)
  , ReviewDocument (..)
  , ReviewError (..)
  , ReviewOperation (..)
  , ReviewedPlan (..)
  , duplicateValues
  , encodeReviewDocument
  , fenceMembersValid
  , historyComposition
  , historyDeclarations
  , reviewBundleDocument
  , reviewBundleFenceRecord
  , reviewBundleNative
  , reviewBundleScopes
  , reviewDigest
  , reviewPrivateDigests
  , reviewedDocument
  , reviewedFenceRecord
  , reviewedNativeBundles
  , revisionEntries
  )
where

import Data.Aeson
  ( FromJSON (parseJSON)
  , KeyValue ((.=))
  , ToJSON (toJSON)
  , Value
  , defaultOptions
  , eitherDecodeStrict'
  , genericParseJSON
  , genericToJSON
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  )
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Adapter
  ( PlannedOperation
  , ResourceObservation
  , ReviewBarrier
  )
import Nagare.Inventory.DataFence (dataFenceIntentDigest)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Lineage (RebuildProof (..))
import Nagare.Inventory.Migration.Types
  ( MigrationContract
  , ValidatedMigration
  )
import Nagare.Inventory.Store
  ( DataFenceRecord
  , HeadManifest
  , RetainedIncarnation (retainedOwner, retainedPhysical)
  , ScopeRevision
  )
import Nagare.Resource.Inventory
  ( ClaimHolder (..)
  , CompositionCandidate
  , Declaration (Managed)
  , Executor
  , ManagedResource
  , ScopeDeclaration
  , claimsOf
  , composedDeclarations
  )
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types
  ( CanonicalClaim
  , ContentDigest
  , ContextBinding
  , InventoryError
  , PhysicalIdentity
  , ProviderAddress
  , ResourceId
  , ScopeId
  , physicalIdentityText
  , resourceIdText
  )
import Nagare.Resource.Wire (canonicalValue)

data InventoryHistory = InventoryHistory
  { historyHead :: !HeadManifest
  , historyAccepted :: !(Map ScopeId (ScopeRevision, ScopeDeclaration))
  , historyConverged :: !(Map ScopeId ScopeRevision)
  , historyRetained :: !(Map ResourceId (RetainedIncarnation, ManagedResource))
  , historyUnstartedCreates :: !(Set ResourceId)
  }
  deriving stock (Eq, Show)

data ObservationRequirements = ObservationRequirements
  { requiredResources :: !(Set ResourceId)
  , requirementsByExecutor :: !(Map Executor [ResourceId])
  , migrationIncarnations :: !(Map ResourceId (ManagedResource, ManagedResource))
  , migrationSourcesByExecutor :: !(Map Executor [ResourceId])
  }
  deriving stock (Eq, Show)

-- | EP-183 M4: 'ApproveRebuild' carries what the rebuild names, since its
-- evidence is a confirmed absence that says nothing about the predecessor.
data LifecycleDecisionKind = ApproveAdoption | ApproveTransfer | ApproveRetirement | ApproveMigration | ApproveCollection | ApproveRebind | ApproveRebuild !RebuildProof
  deriving stock (Eq, Ord, Show, Generic)

data LifecycleProposal = LifecycleProposal
  { lifecycleResource :: !ResourceId
  , lifecycleDecision :: !LifecycleDecisionKind
  , lifecycleEvidence :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

data LifecycleDecisions
  = LifecycleDecisions
      !(Maybe (CompositionCandidate, InventoryHistory))
      !(Map ResourceId LifecycleProposal)
      !(Map ResourceId (ValidatedMigration, (ResourceObservation, ResourceObservation)))
  deriving stock (Eq, Show)

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
  , proposalMigrations :: !(Map ResourceId MigrationProof)
  , proposalAbsences :: !(Map ResourceId AbsenceProof)
  , proposalRebinds :: !(Map ResourceId RebindProof)
  , proposalRebuilds :: !(Map ResourceId RebuildProof)
  }
  deriving stock (Eq, Show)

-- | F58: an accepted member a retirement removes without retaining it,
-- because it is confirmed absent and holds no data (a stateless member, or a
-- durable member whose create never started).
data AbsenceProof = AbsenceProof
  { absenceOwner :: !ScopeId
  , absenceRevision :: !ScopeRevision
  , absenceEvidence :: !ContentDigest
  }
  deriving stock (Eq, Show)

data RetentionProof = RetentionProof
  { retentionOwner :: !ScopeId
  , retentionRevision :: !ScopeRevision
  , retentionPhysical :: !PhysicalIdentity
  , retentionReplacedBy :: !(Maybe PhysicalIdentity)
  -- ^ ADR 27 (N1): the live object that replaced the recorded incarnation
  -- outside review. Retirement retains the record and names the replacement.
  }
  deriving stock (Eq, Show)

data ReviewOperation = ReviewOperation
  { reviewPlannedOperation :: !PlannedOperation
  , reviewAdapterIdentity :: !Text
  , reviewAdapterVersion :: !Text
  , reviewNativeDigest :: !(Maybe ContentDigest)
  , reviewPublicSummary :: !Text
  , reviewFenceCapability :: !(Maybe Text)
  , reviewFenceDigest :: !(Maybe ContentDigest)
  , reviewFenceSummary :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data MigrationProof = MigrationProof
  { migrationProofOwner :: !ScopeId
  , migrationProofRevision :: !ScopeRevision
  , migrationProofPhysical :: !PhysicalIdentity
  , migrationProofSourceAddress :: !ProviderAddress
  , migrationProofDestinationAddress :: !ProviderAddress
  , migrationProofDestinationAbsence :: !ContentDigest
  , migrationProofContract :: !MigrationContract
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
  , reviewMigrations :: !(Map ResourceId MigrationProof)
  , reviewAbsences :: !(Map ResourceId AbsenceProof)
  , reviewRebinds :: !(Map ResourceId RebindProof)
  , reviewRebuilds :: !(Map ResourceId RebuildProof)
  -- ^ EP-183 M4: the recovery lineage of each member this review recreates.
  }
  deriving stock (Eq, Show, Generic)

-- | ADR 27 §3: a reviewed rebind records a member's live object as its
-- accepted incarnation. The recorded identity it supersedes is absent for a
-- member that was never recorded.
data RebindProof = RebindProof
  { rebindRecorded :: !(Maybe PhysicalIdentity)
  , rebindLive :: !PhysicalIdentity
  }
  deriving stock (Eq, Show)

-- | What an operator approves with a rebind: the identities and the data
-- consequence.
renderRebind :: ResourceId -> RebindProof -> Text
renderRebind resource proof =
  "rebind "
    <> resourceIdText resource
    <> ": records "
    <> physicalIdentityText (rebindLive proof)
    <> maybe
      " (no incarnation was recorded)"
      (\recorded -> " in place of " <> physicalIdentityText recorded <> "; the recovery points of " <> physicalIdentityText recorded <> " no longer describe this object")
      (rebindRecorded proof)

instance ToJSON RebindProof where
  toJSON proof = object (("live" .= rebindLive proof) : ["recorded" .= recorded | Just recorded <- [rebindRecorded proof]])

instance FromJSON RebindProof where
  parseJSON = withObject "RebindProof" $ \o -> do
    unless (all (`elem` ["live", "recorded"]) (KM.keys o)) (fail "rebind proof has an unknown field")
    RebindProof <$> o .:? "recorded" <*> o .: "live"

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

-- | Private prepared native evidence and reviewed fence records. A public
-- review directory loads with an empty map; command factories receive the
-- store-backed bundle after matching its public document and scope members.
reviewBundleNative :: ReviewBundle -> Map ContentDigest ByteString
reviewBundleNative = bundleNative

-- | Reconstruct only a member named by this review's operation. A saved
-- record is never taken from current provider state or the public directory.
reviewBundleFenceRecord ::
  ReviewBundle ->
  ReviewOperation ->
  Either Text (Maybe DataFenceRecord)
reviewBundleFenceRecord bundle =
  fenceRecordFromMembers
    (bundleDocument bundle)
    (bundleNative bundle)

reviewedFenceRecord ::
  ReviewedPlan ->
  ReviewOperation ->
  Either Text (Maybe DataFenceRecord)
reviewedFenceRecord (ReviewedPlan document members) =
  fenceRecordFromMembers document members

fenceRecordFromMembers ::
  ReviewDocument ->
  Map ContentDigest ByteString ->
  ReviewOperation ->
  Either Text (Maybe DataFenceRecord)
fenceRecordFromMembers document members operation = do
  unless
    (operation `elem` reviewOperations document)
    (Left "data fence operation is absent from this review")
  case ( reviewFenceCapability operation
       , reviewFenceDigest operation
       , reviewFenceSummary operation
       ) of
    (Nothing, Nothing, Nothing) -> Right Nothing
    (Just capability, Just digest, Just summary)
      | not (T.null capability) && not (T.null summary) -> do
          bytes <-
            maybe
              (Left "reviewed data fence private member is absent")
              Right
              (Map.lookup digest members)
          unless
            (contentDigest bytes == digest)
            (Left "reviewed data fence private member digest changed")
          record <- first T.pack (eitherDecodeStrict' bytes)
          canonical <- canonicalValue (toJSON (record :: DataFenceRecord))
          unless
            (canonical == bytes && dataFenceIntentDigest record == digest)
            (Left "reviewed data fence private member is not canonical")
          Right (Just record)
    _ -> Left "reviewed data fence capability, digest, or summary is incomplete"

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
    object $
      [ "operation" .= reviewPlannedOperation operation
      , "adapterIdentity" .= reviewAdapterIdentity operation
      , "adapterVersion" .= reviewAdapterVersion operation
      , "nativeDigest" .= reviewNativeDigest operation
      , "summary" .= reviewPublicSummary operation
      ]
        <> maybe
          []
          (\capability -> ["fenceCapability" .= capability])
          (reviewFenceCapability operation)
        <> maybe
          []
          (\digest -> ["fenceDigest" .= digest])
          (reviewFenceDigest operation)
        <> maybe
          []
          (\summary -> ["fenceSummary" .= summary])
          (reviewFenceSummary operation)

instance FromJSON ReviewOperation where
  parseJSON = withObject "ReviewOperation" $ \o ->
    ReviewOperation
      <$> o .: "operation"
      <*> o .: "adapterIdentity"
      <*> o .: "adapterVersion"
      <*> o .: "nativeDigest"
      <*> o .: "summary"
      <*> o .:? "fenceCapability"
      <*> o .:? "fenceDigest"
      <*> o .:? "fenceSummary"

instance ToJSON RetentionProof where
  toJSON proof =
    object
      ( [ "owner" .= retentionOwner proof
        , "revision" .= retentionRevision proof
        , "physical" .= retentionPhysical proof
        ]
          <> ["replacedBy" .= replacement | Just replacement <- [retentionReplacedBy proof]]
      )

instance FromJSON RetentionProof where
  parseJSON = withObject "RetentionProof" $ \o -> do
    unless
      (all (`elem` ["owner", "revision", "physical", "replacedBy"]) (KM.keys o))
      (fail "retention proof has an unknown field")
    RetentionProof <$> o .: "owner" <*> o .: "revision" <*> o .: "physical" <*> o .:? "replacedBy"

instance ToJSON AbsenceProof where
  toJSON proof =
    object
      [ "owner" .= absenceOwner proof
      , "revision" .= absenceRevision proof
      , "evidence" .= absenceEvidence proof
      ]

instance FromJSON AbsenceProof where
  parseJSON = withObject "AbsenceProof" $ \o -> do
    unless
      (all (`elem` ["owner", "revision", "evidence"]) (KM.keys o))
      (fail "absence proof has an unknown field")
    AbsenceProof <$> o .: "owner" <*> o .: "revision" <*> o .: "evidence"

instance ToJSON MigrationProof where
  toJSON proof =
    object
      [ "owner" .= migrationProofOwner proof
      , "revision" .= migrationProofRevision proof
      , "physical" .= migrationProofPhysical proof
      , "sourceAddress" .= migrationProofSourceAddress proof
      , "destinationAddress" .= migrationProofDestinationAddress proof
      , "destinationAbsence" .= migrationProofDestinationAbsence proof
      , "contract" .= migrationProofContract proof
      ]

instance FromJSON MigrationProof where
  parseJSON = withObject "MigrationProof" $ \o -> do
    unless
      (all (`elem` ["owner", "revision", "physical", "sourceAddress", "destinationAddress", "destinationAbsence", "contract"]) (KM.keys o))
      (fail "migration proof has an unknown field")
    MigrationProof
      <$> o .: "owner"
      <*> o .: "revision"
      <*> o .: "physical"
      <*> o .: "sourceAddress"
      <*> o .: "destinationAddress"
      <*> o .: "destinationAbsence"
      <*> o .: "contract"

instance ToJSON ReviewDocument where
  toJSON document =
    object
      ( [ "version" .= reviewSchemaVersion document
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
          <> [ "retentions" .= retentionEntries (reviewRetentions document)
             | not (Map.null (reviewRetentions document))
             ]
          <> [ "collections" .= retentionEntries (reviewCollections document)
             | not (Map.null (reviewCollections document))
             ]
          <> [ "migrations" .= migrationEntries (reviewMigrations document)
             | not (Map.null (reviewMigrations document))
             ]
          <> [ "absences" .= [object ["resource" .= resource, "proof" .= proof] | (resource, proof) <- Map.toAscList (reviewAbsences document)]
             | not (Map.null (reviewAbsences document))
             ]
          <> [ "rebinds" .= [object ["resource" .= resource, "proof" .= proof] | (resource, proof) <- Map.toAscList (reviewRebinds document)]
             | not (Map.null (reviewRebinds document))
             ]
          <> [ "rebuilds" .= [object ["resource" .= resource, "proof" .= proof] | (resource, proof) <- Map.toAscList (reviewRebuilds document)]
             | not (Map.null (reviewRebuilds document))
             ]
      )
    where
      retentionEntries entries =
        [ object ["resource" .= resource, "proof" .= proof]
        | (resource, proof) <- Map.toAscList entries
        ]
      migrationEntries entries =
        [ object ["resource" .= resource, "proof" .= proof]
        | (resource, proof) <- Map.toAscList entries
        ]

instance FromJSON ReviewDocument where
  parseJSON = withObject "ReviewDocument" $ \o -> do
    let allowed = ["version", "context", "headGeneration", "headSequence", "baseRevisions", "desiredRevisions", "candidateDigest", "payloadIdentity", "policyVersion", "operations", "barriers", "retentions", "collections", "migrations", "absences", "rebinds", "rebuilds"]
    unless (all (`elem` allowed) (KM.keys o)) (fail "review document has an unknown field")
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail "unsupported review schema version")
    retentions <- parseRetentions =<< o .:? "retentions" .!= []
    collections <- parseRetentions =<< o .:? "collections" .!= []
    migrations <- parseMigrations =<< o .:? "migrations" .!= []
    absences <- parseAbsences =<< o .:? "absences" .!= []
    rebinds <- parseRebinds =<< o .:? "rebinds" .!= []
    rebuilds <- parseRebinds =<< o .:? "rebuilds" .!= []
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
      <*> pure migrations
      <*> pure absences
      <*> pure rebinds
      <*> pure rebuilds
    where
      parseRetentions values = do
        entries <- traverse (withObject "retention entry" (\v -> (,) <$> v .: "resource" <*> v .: "proof")) values
        unless (length entries == Map.size (Map.fromList entries)) (fail "duplicate retention proof")
        pure (Map.fromList entries)
      parseRebinds :: (FromJSON proof) => [Value] -> Parser (Map ResourceId proof)
      parseRebinds values = do
        entries <- traverse (withObject "identity entry" (\v -> (,) <$> v .: "resource" <*> v .: "proof")) values
        unless (length entries == Map.size (Map.fromList entries)) (fail "duplicate rebind or rebuild proof")
        pure (Map.fromList entries)
      parseAbsences values = do
        entries <- traverse (withObject "absence entry" (\v -> (,) <$> v .: "resource" <*> v .: "proof")) values
        unless (length entries == Map.size (Map.fromList entries)) (fail "duplicate absence proof")
        pure (Map.fromList entries)
      parseMigrations values = do
        entries <- traverse (withObject "migration entry" (\v -> (,) <$> v .: "resource" <*> v .: "proof")) values
        unless (length entries == Map.size (Map.fromList entries)) (fail "duplicate migration proof")
        pure (Map.fromList entries)

encodeReviewDocument :: ReviewDocument -> ByteString
encodeReviewDocument = either (error . T.unpack) id . canonicalValue . toJSON

reviewDigest :: ReviewBundle -> ContentDigest
reviewDigest = contentDigest . encodeReviewDocument . bundleDocument

-- The public document names both the prepared adapter object and the private
-- fence record. Keep both in the content-addressed store, never in the public
-- review directory, so a new process reconstructs the exact reviewed intent.
reviewPrivateDigests :: ReviewDocument -> [ContentDigest]
reviewPrivateDigests document =
  [ digest
  | operation <- reviewOperations document
  , Just digest <- [reviewNativeDigest operation]
  ]
    <> [ digest
       | operation <- reviewOperations document
       , Just digest <- [reviewFenceDigest operation]
       ]

fenceMembersValid :: ReviewDocument -> Map ContentDigest ByteString -> Bool
fenceMembersValid document members = all valid (reviewOperations document)
  where
    bundle = ReviewBundle document Map.empty members
    valid operation = case reviewBundleFenceRecord bundle operation of
      Left _ -> False
      Right _ -> True

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

duplicateValues :: (Ord a) => [a] -> [a]
duplicateValues values = Map.keys (Map.filter (> (1 :: Int)) (Map.fromListWith (+) [(value, 1) | value <- values]))

historyReservations :: InventoryHistory -> Map CanonicalClaim ClaimHolder
historyReservations = retainedReservations . historyRetained

retainedReservations :: Map ResourceId (RetainedIncarnation, ManagedResource) -> Map CanonicalClaim ClaimHolder
retainedReservations entries =
  Map.fromList
    [ (claim, ClaimHolder (retainedOwner retained) resourceId (retainedPhysical retained) ResourceInventory.RetainedIncarnation)
    | (resourceId, (retained, managed)) <- Map.toAscList entries
    , (_, claim) <- NE.toList (claimsOf (Managed managed))
    ]
