-- | The inventory head manifest and the records it names, with their
-- canonical JSON forms. Re-exported by "Nagare.Inventory.Store".
module Nagare.Inventory.Store.Manifest
  ( ScopeRevision (..)
  , ExecutorClaim (..)
  , MigrationTombstone (..)
  , RetainedIncarnation (..)
  , DeletionTombstone (..)
  , DataFencePhase (..)
  , DataFenceRecord (..)
  , HeadManifest (..)
  , TransitionMarker (..)
  , hasSubstantiveHistory
  , transitionReviewIdentity
  , parseTransitionReviewIdentity
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Digest
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

data ScopeRevision = ScopeRevision
  { revisionGeneration :: !ScopeGeneration
  , revisionDigest :: !ContentDigest
  }
  deriving stock (Eq, Ord, Show, Generic)

data ExecutorClaim = ExecutorClaim
  { claimTransaction :: !Text
  , claimClientIdentity :: !Text
  , claimEpoch :: !Integer
  , claimTimestamp :: !Text
  }
  deriving stock (Eq, Show, Generic)

data MigrationTombstone = MigrationTombstone
  { migrationDestination :: !Text
  , migrationHeadDigest :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

-- | Historical ownership kept after a scope or one of its members leaves the
-- accepted vector.
-- The scope member remains immutable in the store; this record binds the
-- exact live incarnation and keeps its provider claims reserved.
data RetainedIncarnation = RetainedIncarnation
  { retainedOwner :: !ScopeId
  , retainedRevision :: !ScopeRevision
  , retainedPhysical :: !PhysicalIdentity
  , retainedAt :: !Text
  , retainedMigrationReview :: !(Maybe ContentDigest)
  , retainedReplacedBy :: !(Maybe PhysicalIdentity)
  }
  deriving stock (Eq, Show, Generic)

data DeletionTombstone = DeletionTombstone
  { tombstoneOwner :: !ScopeId
  , tombstoneRevision :: !ScopeRevision
  , tombstonePhysical :: !PhysicalIdentity
  , tombstoneAt :: !Text
  , tombstoneReview :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

-- | A live data target stays reserved across process loss. The record is
-- private inventory history, never part of a public reviewed scope.
data DataFencePhase
  = FenceAcquiring
  | FenceExcluded
  | FenceChanging
  | FenceVerifying
  | FenceUnresolved
  | FenceReleasing
  deriving stock (Eq, Show, Generic)

data DataFenceRecord = DataFenceRecord
  { fenceContext :: !ContextBinding
  , fenceSession :: !Text
  , fenceTransaction :: !(Maybe Text)
  , fenceAccepted :: !(Map ScopeId ScopeRevision)
  , fencePhysical :: !(Map ResourceId PhysicalIdentity)
  , fenceTargets :: !(Set ResourceId)
  , fenceAffected :: !(Set ResourceId)
  , fenceRecoveryArtifact :: !Text
  , fenceRecoveryDigest :: !ContentDigest
  , fenceSavedWriters :: !(Map ResourceId Value)
  , fenceProviderIntent :: !(Maybe Value)
  , fencePhase :: !DataFencePhase
  , fenceAcquiredAt :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | An open release transition (EP-172): the pinned source release, the
-- target payload, and when its first review was admitted. While it is open,
-- only reviews carrying 'transitionReviewIdentity' are admitted, and only the
-- target payload's CLI applies, resumes, recovers or closes; the pin step clears it.
data TransitionMarker = TransitionMarker
  { transitionSource :: !Text
  , transitionTarget :: !Text
  , transitionStartedAt :: !Text
  , transitionFinalizing :: !(Maybe Text)
  -- ^ EP-228 M1: the release the context pin is being moved to. While set,
  -- no review is admitted and only the commit finishes. An older CLI refuses
  -- the field, so it cannot admit across the pin write either.
  }
  deriving stock (Eq, Show, Generic)

data HeadManifest = HeadManifest
  { headSchemaVersion :: !Int
  , headGeneration :: !Integer
  , headSequence :: !Integer
  , headBinding :: !ContextBinding
  , headClientIdentity :: !Text
  , headAccepted :: !(Map ScopeId ScopeRevision)
  , headConverged :: !(Map ScopeId ScopeRevision)
  , headRetained :: !(Map ResourceId RetainedIncarnation)
  , headCollected :: !(Map ResourceId DeletionTombstone)
  , headActiveTransaction :: !(Maybe Text)
  , headExecutorClaim :: !(Maybe ExecutorClaim)
  , headMigration :: !(Maybe MigrationTombstone)
  , headDataFence :: !(Maybe DataFenceRecord)
  , headIncarnations :: !(Map ResourceId PhysicalIdentity)
  -- ^ Physical identity of each accepted durable member, recorded when its
  -- transaction converges and never silently replaced (F49).
  , headTransition :: !(Maybe TransitionMarker)
  -- ^ The open release transition, if any (EP-172).
  }
  deriving stock (Eq, Show, Generic)

-- | Legacy platform mutations have no component receipts and may run only before
-- this store accepted or retained any resource work: an untouched head is safe
-- for the older path; an admitted transaction is not, even before a commit.
hasSubstantiveHistory :: HeadManifest -> Bool
hasSubstantiveHistory headValue =
  headGeneration headValue > 0
    || headSequence headValue > 0
    || not (Map.null (headAccepted headValue))
    || not (Map.null (headConverged headValue))
    || not (Map.null (headRetained headValue))
    || not (Map.null (headCollected headValue))
    || isJust (headActiveTransaction headValue)
    || isJust (headExecutorClaim headValue)
    || isJust (headMigration headValue)
    || isJust (headDataFence headValue)
    || isJust (headTransition headValue)

-- | The payload identity of a release transition's reviews (EP-172): the
-- pinned source release and the target payload.
transitionReviewIdentity :: Text -> Text -> Text
transitionReviewIdentity source target = "nagare-transition:" <> source <> "->" <> target

parseTransitionReviewIdentity :: Text -> Maybe (Text, Text)
parseTransitionReviewIdentity identity = do
  pair <- T.stripPrefix "nagare-transition:" identity
  let (source, rest) = T.breakOn "->" pair
  target <- T.stripPrefix "->" rest
  if T.null source || T.null target then Nothing else Just (source, target)

instance ToJSON ScopeRevision where
  toJSON revision = object ["generation" .= revisionGeneration revision, "digest" .= revisionDigest revision]

instance FromJSON ScopeRevision where
  parseJSON = withObject "ScopeRevision" $ \o -> ScopeRevision <$> o .: "generation" <*> o .: "digest"

instance ToJSON ExecutorClaim where
  toJSON claim =
    object
      [ "transaction" .= claimTransaction claim
      , "clientIdentity" .= claimClientIdentity claim
      , "epoch" .= claimEpoch claim
      , "timestamp" .= claimTimestamp claim
      ]

instance FromJSON ExecutorClaim where
  parseJSON = withObject "ExecutorClaim" $ \o ->
    ExecutorClaim <$> o .: "transaction" <*> o .: "clientIdentity" <*> o .: "epoch" <*> o .: "timestamp"

instance ToJSON MigrationTombstone where
  toJSON marker = object ["destination" .= migrationDestination marker, "headDigest" .= migrationHeadDigest marker]

instance FromJSON MigrationTombstone where
  parseJSON = withObject "MigrationTombstone" $ \o ->
    MigrationTombstone <$> o .: "destination" <*> o .: "headDigest"

instance ToJSON TransitionMarker where
  toJSON marker =
    object
      ( ["from" .= transitionSource marker, "to" .= transitionTarget marker, "startedAt" .= transitionStartedAt marker]
          <> maybe [] (\pin -> ["finalizing" .= pin]) (transitionFinalizing marker)
      )

instance FromJSON TransitionMarker where
  parseJSON = withObject "TransitionMarker" $ \o -> do
    unless (all (`elem` ["from", "to", "startedAt", "finalizing"]) (KM.keys o)) (fail "transition marker has an unknown field")
    TransitionMarker <$> o .: "from" <*> o .: "to" <*> o .: "startedAt" <*> o .:? "finalizing"

instance ToJSON RetainedIncarnation where
  toJSON retained =
    object
      ( [ "owner" .= retainedOwner retained
        , "revision" .= retainedRevision retained
        , "physical" .= retainedPhysical retained
        , "retainedAt" .= retainedAt retained
        ]
          <> ["migrationReview" .= digest | Just digest <- [retainedMigrationReview retained]]
          <> ["replacedBy" .= replacement | Just replacement <- [retainedReplacedBy retained]]
      )

instance FromJSON RetainedIncarnation where
  parseJSON = withObject "RetainedIncarnation" $ \o -> do
    unless
      (all (`elem` ["owner", "revision", "physical", "retainedAt", "migrationReview", "replacedBy"]) (KM.keys o))
      (fail "retained incarnation has an unknown field")
    RetainedIncarnation
      <$> o .: "owner"
      <*> o .: "revision"
      <*> o .: "physical"
      <*> o .: "retainedAt"
      <*> o .:? "migrationReview"
      <*> o .:? "replacedBy"

instance ToJSON DeletionTombstone where
  toJSON tombstone =
    object
      [ "owner" .= tombstoneOwner tombstone
      , "revision" .= tombstoneRevision tombstone
      , "physical" .= tombstonePhysical tombstone
      , "deletedAt" .= tombstoneAt tombstone
      , "review" .= tombstoneReview tombstone
      ]

instance FromJSON DeletionTombstone where
  parseJSON = withObject "DeletionTombstone" $ \o -> do
    unless
      (all (`elem` ["owner", "revision", "physical", "deletedAt", "review"]) (KM.keys o))
      (fail "deletion tombstone has an unknown field")
    DeletionTombstone
      <$> o .: "owner"
      <*> o .: "revision"
      <*> o .: "physical"
      <*> o .: "deletedAt"
      <*> o .: "review"

instance ToJSON DataFencePhase where
  toJSON phase = String $ case phase of
    FenceAcquiring -> "acquiring"
    FenceExcluded -> "excluded"
    FenceChanging -> "changing"
    FenceVerifying -> "verifying"
    FenceUnresolved -> "unresolved"
    FenceReleasing -> "releasing"

instance FromJSON DataFencePhase where
  parseJSON = withText "DataFencePhase" $ \case
    "acquiring" -> pure FenceAcquiring
    "excluded" -> pure FenceExcluded
    "changing" -> pure FenceChanging
    "verifying" -> pure FenceVerifying
    "unresolved" -> pure FenceUnresolved
    "releasing" -> pure FenceReleasing
    _ -> fail "unknown data fence phase"

instance ToJSON DataFenceRecord where
  toJSON fence =
    object $
      [ "context" .= fenceContext fence
      , "session" .= fenceSession fence
      , "transaction" .= fenceTransaction fence
      , "accepted"
          .= [ object ["scope" .= scope, "revision" .= revision]
             | (scope, revision) <- Map.toAscList (fenceAccepted fence)
             ]
      , "physical"
          .= [ object ["resource" .= resource, "identity" .= physical]
             | (resource, physical) <- Map.toAscList (fencePhysical fence)
             ]
      , "targets" .= Set.toAscList (fenceTargets fence)
      , "affected" .= Set.toAscList (fenceAffected fence)
      , "recoveryArtifact" .= fenceRecoveryArtifact fence
      , "recoveryDigest" .= fenceRecoveryDigest fence
      , "savedWriters"
          .= [ object ["resource" .= resource, "configuration" .= configuration]
             | (resource, configuration) <- Map.toAscList (fenceSavedWriters fence)
             ]
      , "phase" .= fencePhase fence
      , "acquiredAt" .= fenceAcquiredAt fence
      ]
        <> maybe
          []
          (\intent -> ["providerIntent" .= intent])
          (fenceProviderIntent fence)

instance FromJSON DataFenceRecord where
  parseJSON = withObject "DataFenceRecord" $ \o -> do
    unless
      ( all
          ( `elem`
              [ "context"
              , "session"
              , "transaction"
              , "accepted"
              , "physical"
              , "targets"
              , "affected"
              , "recoveryArtifact"
              , "recoveryDigest"
              , "savedWriters"
              , "providerIntent"
              , "phase"
              , "acquiredAt"
              ]
          )
          (KM.keys o)
      )
      (fail "data fence has an unknown field")
    accepted <-
      uniqueEntries "accepted scope"
        =<< traverse
          (withObject "fence scope" (\v -> (,) <$> v .: "scope" <*> v .: "revision"))
        =<< o .: "accepted"
    physical <-
      uniqueEntries "physical resource"
        =<< traverse
          (withObject "fence physical" (\v -> (,) <$> v .: "resource" <*> v .: "identity"))
        =<< o .: "physical"
    targetList <- o .: "targets"
    affectedList <- o .: "affected"
    unless
      ( not (null targetList)
          && length targetList == Set.size (Set.fromList targetList)
          && length affectedList == Set.size (Set.fromList affectedList)
          && Set.fromList (targetList <> affectedList) `Set.isSubsetOf` Map.keysSet physical
      )
      (fail "data fence target and affected identities must be complete and unique")
    saved <-
      uniqueEntries "saved writer"
        =<< traverse
          (withObject "fence writer" (\v -> (,) <$> v .: "resource" <*> v .: "configuration"))
        =<< o .: "savedWriters"
    unless
      (Map.keysSet saved == Set.fromList affectedList)
      (fail "data fence does not preserve every writer configuration")
    session <- o .: "session"
    recovery <- o .: "recoveryArtifact"
    unless
      (not (T.null session) && not (T.null recovery) && not (Map.null physical))
      (fail "data fence lacks its session, recovery artifact, or physical target")
    providerIntent <- o .:? "providerIntent"
    unless
      (maybe True isObject providerIntent)
      (fail "data fence provider intent must be an object")
    DataFenceRecord
      <$> o .: "context"
      <*> pure session
      <*> o .:? "transaction"
      <*> pure accepted
      <*> pure physical
      <*> pure (Set.fromList targetList)
      <*> pure (Set.fromList affectedList)
      <*> pure recovery
      <*> o .: "recoveryDigest"
      <*> pure saved
      <*> pure providerIntent
      <*> o .: "phase"
      <*> o .: "acquiredAt"
    where
      isObject (Object _) = True
      isObject _ = False
      uniqueEntries label entries = do
        let selected = Map.fromList entries
        unless (length entries == Map.size selected) (fail ("duplicate " <> label))
        pure selected

instance ToJSON HeadManifest where
  toJSON headValue =
    object
      ( [ "version" .= headSchemaVersion headValue
        , "generation" .= headGeneration headValue
        , "sequence" .= headSequence headValue
        , "binding" .= headBinding headValue
        , "clientIdentity" .= headClientIdentity headValue
        , "accepted" .= revisionsValue (headAccepted headValue)
        , "converged" .= revisionsValue (headConverged headValue)
        , "activeTransaction" .= headActiveTransaction headValue
        , "executorClaim" .= headExecutorClaim headValue
        ]
          <> ["retained" .= retainedValue (headRetained headValue) | not (Map.null (headRetained headValue))]
          <> ["collected" .= collectedValue (headCollected headValue) | not (Map.null (headCollected headValue))]
          <> maybe [] (\marker -> ["migration" .= marker]) (headMigration headValue)
          <> maybe [] (\fence -> ["dataFence" .= fence]) (headDataFence headValue)
          <> maybe [] (\marker -> ["transition" .= marker]) (headTransition headValue)
          <> ["incarnations" .= [object ["resource" .= r, "physical" .= p] | (r, p) <- Map.toAscList (headIncarnations headValue)] | not (Map.null (headIncarnations headValue))]
      )
    where
      revisionsValue revisions = [object ["scope" .= scope, "revision" .= revision] | (scope, revision) <- Map.toAscList revisions]
      retainedValue entries =
        [ object ["resource" .= resource, "incarnation" .= incarnation]
        | (resource, incarnation) <- Map.toAscList entries
        ]
      collectedValue entries =
        [ object ["resource" .= resource, "tombstone" .= tombstone]
        | (resource, tombstone) <- Map.toAscList entries
        ]

instance FromJSON HeadManifest where
  parseJSON = withObject "HeadManifest" $ \o -> do
    let allowed = ["version", "generation", "sequence", "binding", "clientIdentity", "accepted", "converged", "retained", "collected", "activeTransaction", "executorClaim", "migration", "dataFence", "incarnations", "transition"]
    unless (all (`elem` allowed) (KM.keys o)) (fail "head manifest has an unknown field")
    version <- o .: "version"
    unless (version == 1) (fail "unsupported inventory head schema version")
    generation <- o .: "generation"
    sequenceNumber <- o .: "sequence"
    unless (generation >= 0 && sequenceNumber >= 0) (fail "head counters must not be negative")
    accepted <- parseRevisions =<< o .: "accepted"
    converged <- parseRevisions =<< o .: "converged"
    retained <- parseRetained =<< o .:? "retained" .!= []
    collected <- parseCollected =<< o .:? "collected" .!= []
    incarnations <- traverse (withObject "incarnation" (\v -> (,) <$> v .: "resource" <*> v .: "physical")) =<< o .:? "incarnations" .!= []
    unless (length incarnations == Map.size (Map.fromList incarnations)) (fail "duplicate incarnation resource")
    unless
      (Map.null (Map.intersection retained collected))
      (fail "resource cannot be retained and collected in the same head")
    active <- o .: "activeTransaction"
    unless
      (isJust active || all (`Map.member` accepted) (Map.keys converged))
      (fail "converged scopes must also be accepted when no transaction is active")
    binding <- o .: "binding"
    fence <- o .:? "dataFence"
    transition <- o .:? "transition"
    unless
      ( maybe
          True
          ( \entry ->
              fenceContext entry == binding
                && fenceAccepted entry == accepted
                && maybe
                  (isNothing active)
                  (\transaction -> active == Just transaction)
                  (fenceTransaction entry)
          )
          fence
      )
      (fail "data fence differs from its context, accepted head, or linked transaction")
    HeadManifest version generation sequenceNumber
      <$> pure binding
      <*> o .: "clientIdentity"
      <*> pure accepted
      <*> pure converged
      <*> pure retained
      <*> pure collected
      <*> pure active
      <*> o .: "executorClaim"
      <*> o .:? "migration"
      <*> pure fence
      <*> pure (Map.fromList incarnations)
      <*> pure transition
    where
      parseRevisions values = do
        revisions <- traverse (withObject "scope revision" (\v -> (,) <$> v .: "scope" <*> v .: "revision")) values
        unless (length revisions == Map.size (Map.fromList revisions)) (fail "duplicate scope revision")
        pure (Map.fromList revisions)
      parseRetained values = do
        entries <- traverse (withObject "retained entry" (\v -> (,) <$> v .: "resource" <*> v .: "incarnation")) values
        unless (length entries == Map.size (Map.fromList entries)) (fail "duplicate retained resource")
        pure (Map.fromList entries)
      parseCollected values = do
        entries <- traverse (withObject "collected entry" (\v -> (,) <$> v .: "resource" <*> v .: "tombstone")) values
        unless (length entries == Map.size (Map.fromList entries)) (fail "duplicate collected resource")
        pure (Map.fromList entries)
