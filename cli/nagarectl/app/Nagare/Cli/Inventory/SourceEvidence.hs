-- | Inventory / SourceEvidence. Executable-private CLI boundary.
module Nagare.Cli.Inventory.SourceEvidence
  ( loadReviewedBackupSourceNative
  , loadReviewedLiveRestoreSourceNative
  , loadReviewedMaintenanceSourceNative
  , loadReviewedScheduledIngestSourceNative
  , loadReviewedVolumeSourceNative
  )
where

import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Backup
  ( BackupSourceProof
      ( sourcePvcId
      , sourceScopeDigest
      , sourceScopeGeneration
      , sourceScopeName
      , sourceStatefulId
      )
  , volumeSnapshotJobSourcePins
  )
import Nagare.Inventory.LiveRestore
  ( LiveBackupProof
      ( liveBackupJob
      , liveBackupScheduled
      , liveBackupScopeId
      , liveBackupScopeRevision
      )
  , LiveRestoreProof
    ( liveRestoreProofPvc
    , liveRestoreProofRecovery
    , liveRestoreProofSource
    , liveRestoreProofStateful
    , liveRestoreProofTargetRevision
    , liveRestoreProofTargetScope
    )
  , LiveScheduledProof (liveScheduledCron, liveScheduledSigning)
  )
import Nagare.Inventory.Maintenance
  ( MaintenanceSourceProof
      ( maintenanceSourceDigest
      , maintenanceSourceGeneration
      , maintenanceSourcePvc
      , maintenanceSourceRecovery
      , maintenanceSourceRecoveryDigest
      , maintenanceSourceRecoveryGeneration
      , maintenanceSourceRecoveryJob
      , maintenanceSourceScope
      , maintenanceSourceStateful
      )
  )
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Restore (volumeRestoreJobSourcePins)
import Nagare.Inventory.ScheduledIngest
  ( ScheduledIngestSourceProof
      ( scheduledSourceDigest
      , scheduledSourceGeneration
      , scheduledSourcePvcId
      , scheduledSourceScheduleId
      , scheduledSourceScopeName
      , scheduledSourceSigningId
      , scheduledSourceStatefulId
      )
  )
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Inventory.VolumePrune (volumePruneJobCredentialPin)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource

-- Reconstruct maintenance source bytes from the still-accepted revisions.
-- These are private replay inputs; the public review carries only digests.
loadReviewedMaintenanceSourceNative ::
  InventoryStore.InventoryStore ->
  InventoryPlan.ReviewDocument ->
  [MaintenanceSourceProof] ->
  IO
    ( Map.Map
        Resource.ResourceId
        (ResourceInventory.ManagedResource, ByteString)
    , Map.Map
        Resource.ResourceId
        (ResourceInventory.ManagedResource, ByteString)
    )
loadReviewedMaintenanceSourceNative _ _ [] = pure (Map.empty, Map.empty)
loadReviewedMaintenanceSourceNative store document proofs = do
  history <-
    InventoryPlan.loadInventoryHistory store
      >>= either (dieT . T.pack . show) pure
  let findScope label = case [ (owner, revision, scope)
                             | (owner, (revision, scope)) <-
                                 Map.toAscList (InventoryPlan.historyAccepted history)
                             , Resource.scopeIdText owner == label
                             ] of
        [single] -> pure single
        _ -> dieT "maintenance source or recovery scope is no longer uniquely accepted"
      hasMember scope resource group kind =
        length
          [ member
          | bundle <- ResourceInventory.scopeBundles scope
          , ResourceInventory.Managed member <-
              ResourceInventory.declarations bundle
          , member ^. #identity == resource
          , case member ^. #address of
              Resource.Kubernetes _ api actualKind _ _ ->
                api == group && Resource.nameText actualKind == kind
              _ -> False
          ]
          == 1
  forM_ proofs $ \proof -> do
    (targetOwner, targetRevision, targetScope) <-
      findScope (maintenanceSourceScope proof)
    (recoveryOwner, recoveryRevision, recoveryScope) <-
      findScope (maintenanceSourceRecovery proof)
    unless
      ( Resource.generationNumber
          (InventoryStore.revisionGeneration targetRevision)
          == maintenanceSourceGeneration proof
          && InventoryStore.revisionDigest targetRevision
            == maintenanceSourceDigest proof
          && Map.lookup
            targetOwner
            (InventoryPlan.reviewDesiredRevisions document)
            == Just targetRevision
          && hasMember
            targetScope
            (maintenanceSourceStateful proof)
            "apps"
            "statefulset"
          && hasMember
            targetScope
            (maintenanceSourcePvc proof)
            ""
            "persistentvolumeclaim"
      )
      (dieT "maintenance database source changed after review")
    unless
      ( Resource.generationNumber
          (InventoryStore.revisionGeneration recoveryRevision)
          == maintenanceSourceRecoveryGeneration proof
          && InventoryStore.revisionDigest recoveryRevision
            == maintenanceSourceRecoveryDigest proof
          && Map.lookup
            recoveryOwner
            (InventoryPlan.reviewDesiredRevisions document)
            == Just recoveryRevision
          && hasMember
            recoveryScope
            (maintenanceSourceRecoveryJob proof)
            "batch"
            "job"
      )
      (dieT "maintenance recovery Job changed after review")
  acceptedSnapshot <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.mkScopeSnapshot
          (InventoryPlan.reviewContextBinding document)
          ( Map.map
              ( \(revision, scope) ->
                  (InventoryStore.revisionGeneration revision, scope)
              )
              (InventoryPlan.historyAccepted history)
          )
          (InventoryPlan.historyReservations history)
      )
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot acceptedSnapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative
      store
      history
      acceptedInventory
      >>= either dieT pure
  let wanted =
        Set.fromList
          ( concat
              [ [ maintenanceSourceStateful proof
                , maintenanceSourcePvc proof
                , maintenanceSourceRecoveryJob proof
                ]
              | proof <- proofs
              ]
          )
      selected = Map.restrictKeys acceptedNative wanted
  unless
    (Map.keysSet selected == wanted)
    (dieT "maintenance source or recovery lacks accepted private native evidence")
  pure (selected, acceptedNative)

-- Reconstruct only the target and two backup Jobs named in the private
-- live-restore proof from still-accepted history. Review bytes cannot supply
-- replacement native objects or backup revisions during apply/recovery.
loadReviewedLiveRestoreSourceNative ::
  InventoryStore.InventoryStore ->
  InventoryPlan.ReviewDocument ->
  [LiveRestoreProof] ->
  IO
    ( Map.Map
        Resource.ResourceId
        (ResourceInventory.ManagedResource, ByteString)
    , Map.Map
        Resource.ResourceId
        (ResourceInventory.ManagedResource, ByteString)
    )
loadReviewedLiveRestoreSourceNative _ _ [] = pure (Map.empty, Map.empty)
loadReviewedLiveRestoreSourceNative store document proofs = do
  history <-
    InventoryPlan.loadInventoryHistory store
      >>= either (dieT . T.pack . show) pure
  let accepted = InventoryPlan.historyAccepted history
      desired = InventoryPlan.reviewDesiredRevisions document
      checkedScope owner revision = case Map.lookup owner accepted of
        Just (current, scope)
          | current == revision && Map.lookup owner desired == Just revision ->
              pure scope
        _ -> dieT "live restore target or backup scope changed after review"
      hasMember scope resource group kind =
        length
          [ member
          | bundle <- ResourceInventory.scopeBundles scope
          , ResourceInventory.Managed member <-
              ResourceInventory.declarations bundle
          , member ^. #identity == resource
          , case member ^. #address of
              Resource.Kubernetes _ api actualKind _ _ ->
                api == group && Resource.nameText actualKind == kind
              _ -> False
          ]
          == 1
  forM_ proofs $ \proof -> do
    target <-
      checkedScope
        (liveRestoreProofTargetScope proof)
        (liveRestoreProofTargetRevision proof)
    source <-
      checkedScope
        (liveBackupScopeId (liveRestoreProofSource proof))
        (liveBackupScopeRevision (liveRestoreProofSource proof))
    recovery <-
      checkedScope
        (liveBackupScopeId (liveRestoreProofRecovery proof))
        (liveBackupScopeRevision (liveRestoreProofRecovery proof))
    unless
      ( hasMember target (liveRestoreProofStateful proof) "apps" "statefulset"
          && hasMember target (liveRestoreProofPvc proof) "" "persistentvolumeclaim"
          && hasMember
            source
            (liveBackupJob (liveRestoreProofSource proof))
            "batch"
            "job"
          && hasMember
            recovery
            (liveBackupJob (liveRestoreProofRecovery proof))
            "batch"
            "job"
          && case liveBackupScheduled (liveRestoreProofSource proof) of
            Nothing -> True
            Just scheduled ->
              hasMember target (liveScheduledCron scheduled) "batch" "cronjob"
                && hasMember target (liveScheduledSigning scheduled) "" "secret"
      )
      (dieT "live restore accepted source members changed after review")
  acceptedSnapshot <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.mkScopeSnapshot
          (InventoryPlan.reviewContextBinding document)
          ( Map.map
              ( \(revision, scope) ->
                  (InventoryStore.revisionGeneration revision, scope)
              )
              accepted
          )
          (InventoryPlan.historyReservations history)
      )
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot acceptedSnapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative
      store
      history
      acceptedInventory
      >>= either dieT pure
  let wanted =
        Set.fromList
          ( concat
              [ [ liveRestoreProofStateful proof
                , liveRestoreProofPvc proof
                , liveBackupJob (liveRestoreProofSource proof)
                , liveBackupJob (liveRestoreProofRecovery proof)
                ]
                  <> maybe
                    []
                    ( \scheduled ->
                        [liveScheduledCron scheduled, liveScheduledSigning scheduled]
                    )
                    (liveBackupScheduled (liveRestoreProofSource proof))
              | proof <- proofs
              ]
          )
      selected = Map.restrictKeys acceptedNative wanted
  unless
    (Map.keysSet selected == wanted)
    (dieT "live restore target or backups lack accepted private native evidence")
  pure (selected, acceptedNative)

loadReviewedBackupSourceNative ::
  InventoryStore.InventoryStore ->
  InventoryPlan.ReviewDocument ->
  [BackupSourceProof] ->
  IO (Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString))
loadReviewedBackupSourceNative _ _ [] = pure Map.empty
loadReviewedBackupSourceNative store document proofs = do
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  forM_ proofs $ \proof -> do
    let sources =
          [ (owner, revision, sourceScope)
          | (owner, (revision, sourceScope)) <-
              Map.toAscList (InventoryPlan.historyAccepted history)
          , Resource.scopeIdText owner == sourceScopeName proof
          ]
    (owner, revision, sourceScope) <- case sources of
      [single] -> pure single
      _ -> dieT "manual backup source scope is no longer uniquely accepted"
    unless
      ( Resource.generationNumber (InventoryStore.revisionGeneration revision)
          == sourceScopeGeneration proof
          && InventoryStore.revisionDigest revision == sourceScopeDigest proof
          && Map.lookup owner (InventoryPlan.reviewDesiredRevisions document) == Just revision
      )
      (dieT "manual backup source scope revision changed after review")
    let members =
          [ member
          | bundle <- ResourceInventory.scopeBundles sourceScope
          , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
          ]
        sourceKind resourceId group kind =
          [ member
          | member <- members
          , member ^. #identity == resourceId
          , case member ^. #address of
              Resource.Kubernetes _ api resourceKind _ _ ->
                api == group && Resource.nameText resourceKind == kind
              _ -> False
          ]
    unless
      ( length (sourceKind (sourceStatefulId proof) "apps" "statefulset") == 1
          && length (sourceKind (sourcePvcId proof) "" "persistentvolumeclaim") == 1
      )
      (dieT "manual backup source resources changed after review")
  acceptedSnapshot <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.mkScopeSnapshot
          (InventoryPlan.reviewContextBinding document)
          ( Map.map
              ( \(revision, sourceScope) ->
                  (InventoryStore.revisionGeneration revision, sourceScope)
              )
              (InventoryPlan.historyAccepted history)
          )
          (InventoryPlan.historyReservations history)
      )
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot acceptedSnapshot)
  let wanted =
        Set.fromList
          ( concat
              [[sourceStatefulId proof, sourcePvcId proof] | proof <- proofs]
          )
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNativeSelected wanted store history acceptedInventory
      >>= either dieT pure
  let selected = Map.restrictKeys acceptedNative wanted
  unless
    (Map.keysSet selected == wanted)
    (dieT "manual backup source lacks accepted private native evidence")
  pure selected

-- The volume Job's private native annotations pin the accepted PVC, backup
-- Job, and store credential. Reopen only those exact reviewed dependencies at
-- apply/resume so the Kubernetes adapter can verify their physical UIDs.
loadReviewedVolumeSourceNative ::
  InventoryStore.InventoryStore ->
  InventoryPlan.ReviewDocument ->
  Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) ->
  IO (Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString))
loadReviewedVolumeSourceNative store document reviewed = do
  pins <- fmap concat $ forM (Map.elems reviewed) $ \(_, native) ->
    either dieT pure $ do
      snapshotPins <- volumeSnapshotJobSourcePins native
      restorePins <- volumeRestoreJobSourcePins native
      prunePin <- volumePruneJobCredentialPin native
      pure
        ( maybe [] (\selected -> selected) snapshotPins
            <> maybe [] (\selected -> selected) restorePins
            <> maybe [] (: []) prunePin
        )
  if null pins
    then pure Map.empty
    else do
      let expected =
            Map.fromListWith
              Set.union
              [(resource, Set.singleton uid) | (resource, uid) <- pins]
      unless
        (all ((== 1) . Set.size) (Map.elems expected))
        (dieT "reviewed volume Jobs disagree on a source physical identity")
      history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
      let accepted = InventoryPlan.historyAccepted history
          owners =
            Map.fromList
              [ (member ^. #identity, owner)
              | (owner, (_, scope)) <- Map.toAscList accepted
              , bundle <- ResourceInventory.scopeBundles scope
              , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
              ]
      forM_ (Map.keys expected) $ \resource -> do
        owner <-
          maybe
            (dieT "volume source is not an accepted resource")
            pure
            (Map.lookup resource owners)
        revision <-
          maybe
            (dieT "volume source scope is no longer accepted")
            (pure . fst)
            (Map.lookup owner accepted)
        unless
          ( Map.lookup owner (InventoryPlan.reviewDesiredRevisions document)
              == Just revision
          )
          (dieT "volume source scope revision changed after review")
      acceptedSnapshot <-
        either
          (dieT . T.pack . show)
          pure
          ( ResourceInventory.mkScopeSnapshot
              (InventoryPlan.reviewContextBinding document)
              ( Map.map
                  ( \(revision, scope) ->
                      (InventoryStore.revisionGeneration revision, scope)
                  )
                  accepted
              )
              (InventoryPlan.historyReservations history)
          )
      acceptedInventory <-
        either
          (dieT . T.pack . show)
          pure
          (ResourceInventory.composeSnapshot acceptedSnapshot)
      (native, _) <-
        InventoryStatus.loadAcceptedNativeSelected (Map.keysSet expected) store history acceptedInventory
          >>= either dieT pure
      let selected = Map.restrictKeys native (Map.keysSet expected)
      unless
        (Map.keysSet selected == Map.keysSet expected)
        (dieT "volume source lacks accepted private native evidence")
      pure selected

-- The saved scheduled-ingestion review pins the accepted database scope and
-- all four dependencies. Their native bytes are reloaded only from that exact
-- accepted revision; the Job annotations pin their observed UIDs at submit.
loadReviewedScheduledIngestSourceNative ::
  InventoryStore.InventoryStore ->
  InventoryPlan.ReviewDocument ->
  [ScheduledIngestSourceProof] ->
  IO (Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString))
loadReviewedScheduledIngestSourceNative _ _ [] = pure Map.empty
loadReviewedScheduledIngestSourceNative store document proofs = do
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  forM_ proofs $ \proof -> do
    let sources =
          [ (owner, revision, sourceScope)
          | (owner, (revision, sourceScope)) <-
              Map.toAscList (InventoryPlan.historyAccepted history)
          , Resource.scopeIdText owner == scheduledSourceScopeName proof
          ]
    (owner, revision, sourceScope) <- case sources of
      [single] -> pure single
      _ -> dieT "scheduled ingestion source scope is no longer uniquely accepted"
    unless
      ( Resource.generationNumber (InventoryStore.revisionGeneration revision)
          == scheduledSourceGeneration proof
          && InventoryStore.revisionDigest revision == scheduledSourceDigest proof
          && Map.lookup owner (InventoryPlan.reviewDesiredRevisions document) == Just revision
      )
      (dieT "scheduled ingestion source scope revision changed after review")
    let members =
          [ member
          | bundle <- ResourceInventory.scopeBundles sourceScope
          , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
          ]
        one resourceId group kind =
          length
            [ member
            | member <- members
            , member ^. #identity == resourceId
            , case member ^. #address of
                Resource.Kubernetes _ api resourceKind _ _ ->
                  api == group && Resource.nameText resourceKind == kind
                _ -> False
            ]
            == 1
    unless
      ( one (scheduledSourceStatefulId proof) "apps" "statefulset"
          && one (scheduledSourcePvcId proof) "" "persistentvolumeclaim"
          && one (scheduledSourceScheduleId proof) "batch" "cronjob"
          && one (scheduledSourceSigningId proof) "" "secret"
      )
      (dieT "scheduled ingestion source resources changed after review")
  acceptedSnapshot <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.mkScopeSnapshot
          (InventoryPlan.reviewContextBinding document)
          ( Map.map
              ( \(revision, sourceScope) ->
                  (InventoryStore.revisionGeneration revision, sourceScope)
              )
              (InventoryPlan.historyAccepted history)
          )
          (InventoryPlan.historyReservations history)
      )
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot acceptedSnapshot)
  let wanted =
        Set.fromList
          ( concat
              [ [ scheduledSourceStatefulId proof
                , scheduledSourcePvcId proof
                , scheduledSourceScheduleId proof
                , scheduledSourceSigningId proof
                ]
              | proof <- proofs
              ]
          )
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNativeSelected wanted store history acceptedInventory
      >>= either dieT pure
  let selected = Map.restrictKeys acceptedNative wanted
  unless
    (Map.keysSet selected == wanted)
    (dieT "scheduled ingestion source lacks accepted private native evidence")
  pure selected
