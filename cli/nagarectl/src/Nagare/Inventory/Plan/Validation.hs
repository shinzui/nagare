-- | Validation responsibilities; internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.Validation
  ( verifyActiveReview
  , verifyReview
  )
where

import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
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
  , OperationAction (MigrateResource, RetireResource)
  , PlannedOperation
    ( plannedAction
    , plannedDependencies
    , plannedOperationId
    , plannedResources
    )
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Plan.Types
  ( MigrationProof (..)
  , RetentionProof (..)
  , ReviewBundle (..)
  , ReviewDocument (..)
  , ReviewError (..)
  , ReviewOperation (..)
  , ReviewedPlan (..)
  , encodeReviewDocument
  , fenceMembersValid
  , reviewDigest
  , reviewPrivateDigests
  )
import Nagare.Inventory.Store
  ( DeletionTombstone
      ( tombstoneOwner
      , tombstonePhysical
      , tombstoneReview
      , tombstoneRevision
      )
  , HeadManifest
    ( headAccepted
    , headActiveTransaction
    , headBinding
    , headCollected
    , headGeneration
    , headRetained
    , headSequence
    )
  , RetainedIncarnation
    ( retainedMigrationReview
    , retainedOwner
    , retainedPhysical
    , retainedRevision
    )
  , ScopeRevision (revisionDigest)
  , StoreSnapshot (storeSnapshotHead, storeSnapshotReviewDigests)
  )

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
        <> migrationReviewErrors headValue document
        <> [ReviewError "scope-member" "review scope member is missing or has a different digest" | not (membersMatch (bundleScopes bundle) (map revisionDigest (Map.elems (reviewDesiredRevisions document))))]
        <> [ReviewError "native-member" "review private member is missing or has a different digest" | not (membersMatch (bundleNative bundle) (reviewPrivateDigests document))]
        <> [ReviewError "data-fence-member" "review data fence private member is malformed or differs from its digest" | not (fenceMembersValid document (bundleNative bundle))]
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
        <> [ ReviewError "active-retention" "active review retained incarnation differs from the accepted historical catalogue"
           | (resource, proof) <- Map.toAscList (reviewRetentions document)
           , case Map.lookup resource (headRetained headValue) of
               Just retained ->
                 retainedOwner retained /= retentionOwner proof
                   || retainedRevision retained /= retentionRevision proof
                   || retainedPhysical retained /= retentionPhysical proof
               Nothing -> True
           ]
        <> [ ReviewError "active-migration" "active migration source differs from the reviewed retained incarnation"
           | (resource, proof) <- Map.toAscList (reviewMigrations document)
           , case Map.lookup resource (headRetained headValue) of
               Just retained ->
                 retainedOwner retained /= migrationProofOwner proof
                   || retainedRevision retained /= migrationProofRevision proof
                   || retainedPhysical retained /= migrationProofPhysical proof
                   || retainedMigrationReview retained /= Just digest
               Nothing -> True
           ]
        <> activeCollectionReviewErrors headValue document
        <> [ReviewError "scope-member" "active review scope member is missing or has a different digest" | not (membersMatch (bundleScopes bundle) (map revisionDigest (Map.elems (reviewDesiredRevisions document))))]
        <> [ReviewError "native-member" "active review private member is missing or has a different digest" | not (membersMatch (bundleNative bundle) (reviewPrivateDigests document))]
        <> [ReviewError "data-fence-member" "active review data fence private member is malformed or differs from its digest" | not (fenceMembersValid document (bundleNative bundle))]
    membersMatch members digests =
      Set.fromList digests == Map.keysSet members
        && all (\(memberDigest, bytes) -> contentDigest bytes == memberDigest) (Map.toList members)

retentionReviewErrors :: HeadManifest -> ReviewDocument -> [ReviewError]
retentionReviewErrors headValue document =
  [ ReviewError "retention-base" "retention proof does not name the accepted scope revision"
  | (_, proof) <- Map.toAscList (reviewRetentions document)
  , Map.lookup (retentionOwner proof) (headAccepted headValue) /= Just (retentionRevision proof)
  ]
    <> [ ReviewError "retention-history" "retained resource already exists in the historical catalogue"
       | resource <- Map.keys (reviewRetentions document)
       , Map.member resource (headRetained headValue)
       ]

collectionReviewErrors :: HeadManifest -> ReviewDocument -> [ReviewError]
collectionReviewErrors headValue document =
  [ ReviewError "collection-history" "collection proof differs from retained historical incarnation"
  | (resource, proof) <- Map.toAscList (reviewCollections document)
  , case Map.lookup resource (headRetained headValue) of
      Just retained ->
        retainedOwner retained /= retentionOwner proof
          || retainedRevision retained /= retentionRevision proof
          || retainedPhysical retained /= retentionPhysical proof
      Nothing -> True
  ]
    <> [ ReviewError "collection-operations" "collection proofs must match exactly the reviewed retire operations"
       | Map.keysSet (reviewCollections document)
           /= Set.fromList
             [ resource
             | operation <- reviewOperations document
             , plannedAction (reviewPlannedOperation operation) == RetireResource
             , resource <- NE.toList (plannedResources (reviewPlannedOperation operation))
             ]
       ]

migrationReviewErrors :: HeadManifest -> ReviewDocument -> [ReviewError]
migrationReviewErrors headValue document =
  [ ReviewError "migration-operations" "migration actions and proofs name different resources"
  | Map.keysSet (reviewMigrations document)
      /= Set.fromList
        [ resource
        | operation <- reviewOperations document
        , MigrateResource _ <- [plannedAction (reviewPlannedOperation operation)]
        , resource <- NE.toList (plannedResources (reviewPlannedOperation operation))
        ]
  ]
    <> [ ReviewError "migration-base" "migration source proof differs from accepted ownership history"
       | (resource, proof) <- Map.toAscList (reviewMigrations document)
       , Map.lookup (migrationProofOwner proof) (headAccepted headValue)
           /= Just (migrationProofRevision proof)
           || Map.notMember (migrationProofOwner proof) (reviewDesiredRevisions document)
           || Map.member resource (headRetained headValue)
           || Map.member resource (headCollected headValue)
           || migrationProofSourceAddress proof == migrationProofDestinationAddress proof
       ]
    <> [ ReviewError "migration-operations" "migration proof needs exactly one ordered operation for every stage"
       | (resource, _) <- Map.toAscList (reviewMigrations document)
       , not (stagesValid resource)
       ]
  where
    stagesValid resource =
      let stageOperations =
            [ (stage, reviewPlannedOperation operation)
            | operation <- reviewOperations document
            , resource `elem` NE.toList (plannedResources (reviewPlannedOperation operation))
            , MigrateResource stage <- [plannedAction (reviewPlannedOperation operation)]
            ]
          ordered =
            [ PrepareDestination
            , BackUpSource
            , FenceWriters
            , TransferState
            , VerifyDestination
            , SwitchConsumers
            , AdmitWrites
            , RetainSource
            ]
          stageMap = Map.fromList stageOperations
          linked = all link (zip ordered (drop 1 ordered))
          link (previous, next) = case (Map.lookup previous stageMap, Map.lookup next stageMap) of
            (Just predecessor, Just successor) ->
              plannedOperationId predecessor
                `elem` plannedDependencies successor
            _ -> False
       in sort (map fst stageOperations) == ordered && linked

activeCollectionReviewErrors :: HeadManifest -> ReviewDocument -> [ReviewError]
activeCollectionReviewErrors headValue document =
  [ ReviewError "active-collection" "active collection differs from retained history or finalized tombstone"
  | (resource, proof) <- Map.toAscList (reviewCollections document)
  , not (matchesRetained resource proof || matchesTombstone resource proof)
  ]
  where
    matchesRetained resource proof = case Map.lookup resource (headRetained headValue) of
      Just retained ->
        retainedOwner retained == retentionOwner proof
          && retainedRevision retained == retentionRevision proof
          && retainedPhysical retained == retentionPhysical proof
      Nothing -> False
    matchesTombstone resource proof = case Map.lookup resource (headCollected headValue) of
      Just tombstone ->
        tombstoneOwner tombstone == retentionOwner proof
          && tombstoneRevision tombstone == retentionRevision proof
          && tombstonePhysical tombstone == retentionPhysical proof
          && tombstoneReview tombstone == contentDigest (encodeReviewDocument document)
      Nothing -> False
