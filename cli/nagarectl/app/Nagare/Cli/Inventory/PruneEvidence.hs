-- | Inventory / PruneEvidence. Executable-private CLI boundary.
module Nagare.Cli.Inventory.PruneEvidence
  ( loadReviewedPruneSourceNative
  , verifyReviewedScheduledPruneProvider
  , verifyReviewedScheduledPruneRecovery
  )
where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cli.Data.ScheduleObservation
  ( scheduledProducerInFlight
  )
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Cluster.GcsJob
  ( StoreBackend (GcsBackend, MinioBackend)
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesState (KubernetesFailed, KubernetesPresent)
  , kubernetesObserve
  )
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  , mkKubernetesRuntimeOpsWithCacheKey
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.Identity (IdentityCheck (..), checkedPhysical)
import Nagare.Inventory.KubernetesReview
  ( kubernetesSpecsFromReview
  )
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Prune
  ( PruneSourceProof
      ( pruneSourceCredential
      , pruneSourceJob
      , pruneSourcePolicy
      , pruneSourceRevision
      , pruneSourceScope
      , pruneSourceUid
      )
  )
import Nagare.Inventory.ScheduledStore
  ( ListedObject (listedKey)
  , ObjectReader (listObjectEntries, listObjectVersions)
  , withLocalObjectStore
  )
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Target (contextNameText)

-- A saved scheduled prune can run only while the accepted receipt set still
-- matches a complete provider listing. A selected key may have no hidden
-- older version or delete marker, and the schedule may have no active Job.
verifyReviewedScheduledPruneProvider ::
  Maybe String ->
  [ResourceInventory.ScopeDeclaration] ->
  Set.Set Resource.ResourceId ->
  IO ()
verifyReviewedScheduledPruneProvider mctx scopes selectedJobs = do
  let selected =
        [ scope
        | scope <- scopes
        , let fields = ResourceInventory.scopeOverrides scope
        , Map.member "scheduled.prune.backup.scope" fields
        , Map.notMember "scheduled.prune.recovery.review" fields
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
        , Set.member (member ^. #identity) selectedJobs
        ]
  unless (null selected) $ do
    active <- activeTarget mctx
    store <-
      Inventory.openTargetStoreReadOnly active
        >>= either (dieT . T.pack . show) pure
    history <-
      InventoryPlan.loadInventoryHistory store
        >>= either (dieT . T.pack . show) pure
    snapshot <- Inventory.loadTargetSnapshot active
    acceptedInventory <-
      either
        (dieT . T.pack . show)
        pure
        (ResourceInventory.composeSnapshot snapshot)
    (acceptedNative, _) <-
      InventoryStatus.loadAcceptedNative
        store
        history
        acceptedInventory
        >>= either dieT pure
    backend <- resolveStoreBackend mctx Nothing
    minio <- case backend of
      MinioBackend ref -> pure ref
      GcsBackend {} -> dieT "cloud scheduled prune requires exact-generation provider preflight"
    context <-
      either
        dieT
        pure
        ( Resource.mkContextId
            (contextNameText (active ^. #contextName))
        )
    let contextName = contextNameText (active ^. #contextName)
        config =
          KubernetesRuntimeConfig
            context
            contextName
            (fmap (fmap (const ())) (guardKubernetesContext active))
        acceptedScopes = map snd (Map.elems (InventoryPlan.historyAccepted history))
        selectedOwners = Set.fromList (map ResourceInventory.scopeId selected)
        pruned =
          Set.fromList
            [ backupScope
            | scope <- acceptedScopes
            , Set.notMember (ResourceInventory.scopeId scope) selectedOwners
            , Just backupScope <-
                [ Map.lookup
                    "scheduled.prune.backup.scope"
                    (ResourceInventory.scopeOverrides scope)
                ]
            ]
        bucketAddress = "s3://" <> minio ^. #bucket <> "/"
    forM_ selected $ \pruneScope -> do
      let fields = ResourceInventory.scopeOverrides pruneScope
          required key =
            maybe
              (dieT ("scheduled prune lacks " <> key))
              pure
              (Map.lookup key fields)
      policyName <- required "scheduled.prune.policy.scope"
      policyScope <- case [ scope
                          | scope <- acceptedScopes
                          , Resource.scopeIdText (ResourceInventory.scopeId scope) == policyName
                          ] of
        [single] -> pure single
        _ -> dieT "scheduled prune policy is no longer uniquely accepted"
      cron <- case [ member
                   | bundle <- ResourceInventory.scopeBundles policyScope
                   , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                   , case member ^. #address of
                       Resource.Kubernetes _ "batch" kind (Just _) _ ->
                         Resource.nameText kind == "cronjob"
                       _ -> False
                   ] of
        [single] -> pure single
        _ -> dieT "scheduled prune policy lacks one accepted CronJob"
      namespaceName <- case cron ^. #address of
        Resource.Kubernetes _ _ _ (Just ns) _ -> pure (Resource.nameText ns)
        _ -> dieT "scheduled prune CronJob lacks a namespace"
      cronNative <- case Map.lookup (cron ^. #identity) acceptedNative of
        Just pair
          | fst pair == cron ->
              pure
                (Map.singleton (cron ^. #identity) pair)
        _ -> dieT "scheduled prune CronJob lacks accepted native evidence"
      let cronOps =
            mkKubernetesRuntimeOpsWithCacheKey
              config
              (\_ -> pure (Left "scheduled prune CronJob observation does not use a cache key"))
              cronNative
      cronState <- kubernetesObserve cronOps (cron ^. #identity)
      cronUid <- case (cronState, Map.lookup (cron ^. #identity) cronNative) of
        (KubernetesPresent uid _ (Just owner) digest, Just (_, bytes))
          | owner == cron ^. #identity
              && digest == InventoryDigest.contentDigest bytes ->
              pure uid
        _ -> dieT "scheduled prune CronJob is absent or drifted"
      -- ADR 27 (N22): the in-flight check finds Jobs by their CronJob's UID,
      -- so a replaced CronJob would hide the accepted one's running Jobs.
      case checkedPhysical (InventoryStore.headIncarnations (InventoryPlan.historyHead history)) (cron ^. #identity) cronUid of
        IdentityReplaced _ _ -> dieT "scheduled prune CronJob was replaced outside Nagare; the accepted producer's Jobs cannot be checked"
        _ -> pure ()
      inFlight <- scheduledProducerInFlight contextName namespaceName cronUid
      when inFlight (dieT "scheduled prune producer Job is still in flight")
      objectAddress <- required "scheduled.prune.object"
      receiptAddress <- required "scheduled.prune.receipt"
      objectVersion <- required "scheduled.prune.object.version"
      receiptVersion <- required "scheduled.prune.receipt.version"
      backupScopeName <- required "scheduled.prune.backup.scope"
      objectKey <-
        maybe
          (dieT "scheduled prune object is outside the local bucket")
          pure
          (T.stripPrefix bucketAddress objectAddress)
      receiptKey <-
        maybe
          (dieT "scheduled prune receipt is outside the local bucket")
          pure
          (T.stripPrefix bucketAddress receiptAddress)
      unless
        (receiptAddress == objectAddress <> ".receipt.json")
        (dieT "scheduled prune receipt no longer names its object")
      let (keyPrefix, _) = T.breakOnEnd "/" objectKey
          backups =
            [ scope
            | scope <- acceptedScopes
            , Map.lookup
                "scheduled.backup.source.scope"
                (ResourceInventory.scopeOverrides scope)
                == Just policyName
            , Set.notMember
                ( Resource.scopeIdText
                    (ResourceInventory.scopeId scope)
                )
                pruned
            ]
          expected =
            concatMap
              ( \scope ->
                  let backupFields = ResourceInventory.scopeOverrides scope
                   in mapMaybe
                        (>>= T.stripPrefix bucketAddress)
                        [ Map.lookup "scheduled.backup.object" backupFields
                        , Map.lookup "scheduled.backup.receipt" backupFields
                        ]
              )
              backups
      unless
        ( not (T.null keyPrefix)
            && backupScopeName
              `elem` map
                ( Resource.scopeIdText
                    . ResourceInventory.scopeId
                )
                backups
            && length expected == 2 * length backups
            && all (T.isPrefixOf keyPrefix) expected
        )
        (dieT "scheduled prune accepted receipts changed their provider key space")
      provider <- withLocalObjectStore contextName minio $ \reader -> do
        current <- listObjectEntries reader keyPrefix
        versions <- listObjectVersions reader objectKey
        pure ((,) <$> current <*> versions)
      (listed, versions) <- either dieT pure provider >>= either dieT pure
      unless
        ( Set.fromList (map listedKey listed) == Set.fromList expected
            && length listed == length expected
            && Set.fromList versions
              == Set.fromList
                [(objectKey, objectVersion), (receiptKey, receiptVersion)]
            && length versions == 2
        )
        (dieT "scheduled prune provider listing or exact versions changed after review")

-- A saved receipt-only recovery must still refer to the exact failed Job and
-- published prune review. Its Job rechecks complete provider version listings
-- and receipt bytes immediately before deleting the remaining receipt.
verifyReviewedScheduledPruneRecovery ::
  Maybe String ->
  [ResourceInventory.ScopeDeclaration] ->
  Set.Set Resource.ResourceId ->
  IO ()
verifyReviewedScheduledPruneRecovery mctx scopes selectedJobs = do
  let selected =
        [ (scope, member)
        | scope <- scopes
        , Map.member
            "scheduled.prune.recovery.review"
            (ResourceInventory.scopeOverrides scope)
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
        , Set.member (member ^. #identity) selectedJobs
        ]
  unless (null selected) $ do
    active <- activeTarget mctx
    store <-
      Inventory.openTargetStoreReadOnly active
        >>= either (dieT . T.pack . show) pure
    context <-
      either
        dieT
        pure
        ( Resource.mkContextId
            (contextNameText (active ^. #contextName))
        )
    let config =
          KubernetesRuntimeConfig
            context
            (contextNameText (active ^. #contextName))
            (fmap (fmap (const ())) (guardKubernetesContext active))
    forM_ selected $ \(recoveryScope, _) -> do
      let recoveryFields = ResourceInventory.scopeOverrides recoveryScope
          required key =
            maybe
              (dieT ("scheduled recovery lacks " <> key))
              pure
              (Map.lookup key recoveryFields)
      failedDigestText <- required "scheduled.prune.recovery.review"
      failedDigest <- either dieT pure (Resource.mkContentDigest failedDigestText)
      failedBundle <-
        InventoryPlan.loadPublishedReview store failedDigest
          >>= either (dieT . T.pack . show) pure
      failedScopeName <- required "scheduled.prune.recovery.failed.scope"
      failedUidText <- required "scheduled.prune.recovery.failed.job.uid"
      failedUid <- either dieT pure (Resource.mkPhysicalIdentity failedUidText)
      failedScopes <-
        traverse
          ( either (dieT . T.pack . show) pure
              . ResourceWire.decodeScope
          )
          (Map.elems (InventoryPlan.reviewBundleScopes failedBundle))
      failedScope <- case [ scope
                          | scope <- failedScopes
                          , Resource.scopeIdText (ResourceInventory.scopeId scope)
                              == failedScopeName
                          ] of
        [single] -> pure single
        _ -> dieT "scheduled recovery lacks its exact published failed scope"
      let failedFields = ResourceInventory.scopeOverrides failedScope
          exactKeys =
            [ "scheduled.prune.backup.scope"
            , "scheduled.prune.object"
            , "scheduled.prune.object.version"
            , "scheduled.prune.receipt"
            , "scheduled.prune.receipt.version"
            , "scheduled.prune.policy.scope"
            , "scheduled.prune.policy.revision"
            , "scheduled.prune.policy.keep"
            ]
      unless
        ( all
            ( \key ->
                Map.lookup key recoveryFields
                  == Map.lookup key failedFields
                  && Map.member key failedFields
            )
            exactKeys
        )
        (dieT "scheduled recovery differs from the published failed prune")
      failedJob <- case [ member
                        | bundle <- ResourceInventory.scopeBundles failedScope
                        , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                        , case member ^. #address of
                            Resource.Kubernetes _ "batch" kind (Just _) _ ->
                              Resource.nameText kind == "job"
                            _ -> False
                        ] of
        [single] -> pure single
        _ -> dieT "scheduled recovery failed prune lacks one exact Job"
      failedNative <- either dieT pure (kubernetesSpecsFromReview failedBundle)
      (bound, bytes) <- case Map.lookup (failedJob ^. #identity) failedNative of
        Just pair | fst pair == failedJob -> pure pair
        _ -> dieT "scheduled recovery failed Job lacks published native evidence"
      let failedOps =
            mkKubernetesRuntimeOpsWithCacheKey
              config
              (\_ -> pure (Left "failed prune observation does not use a cache key"))
              (Map.singleton (failedJob ^. #identity) (bound, bytes))
      observed <- kubernetesObserve failedOps (failedJob ^. #identity)
      case observed of
        KubernetesFailed uid _ (Just owner) digest
          | uid == failedUid
              && owner == failedJob ^. #identity
              && digest == InventoryDigest.contentDigest bytes ->
              pure ()
        _ -> dieT "scheduled recovery's original prune Job is no longer the exact terminal failure"

-- Admission requires the same accepted backup scope and Job. Once admitted,
-- resume/recover binds the source to the retained incarnation from the exact
-- review base. The Kubernetes adapter checks the observed UID and native
-- bytes again before submitting or verifying the prune Job.
loadReviewedPruneSourceNative ::
  InventoryStore.InventoryStore ->
  InventoryPlan.ReviewDocument ->
  [PruneSourceProof] ->
  IO (Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString))
loadReviewedPruneSourceNative _ _ [] = pure Map.empty
loadReviewedPruneSourceNative store document proofs = do
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  forM_ proofs $ \proof -> do
    let matches =
          [ (owner, revision, scope)
          | (owner, (revision, scope)) <-
              Map.toAscList (InventoryPlan.historyAccepted history)
          , Resource.scopeIdText owner == pruneSourceScope proof
          ]
    backupMembers <- case matches of
      [(owner, revision, scope)] -> do
        unless
          ( InventoryStore.revisionDigest revision == pruneSourceRevision proof
              && Map.lookup owner (InventoryPlan.reviewDesiredRevisions document) == Just revision
          )
          (dieT "manual prune backup scope changed after review")
        pure
          [ member ^. #identity
          | bundle <- ResourceInventory.scopeBundles scope
          , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
          ]
      [] -> case Map.lookup
        (pruneSourceJob proof)
        (InventoryPlan.historyRetained history) of
        Just (incarnation, member)
          | Resource.scopeIdText
              (InventoryStore.retainedOwner incarnation)
              == pruneSourceScope proof
          , InventoryStore.revisionDigest
              (InventoryStore.retainedRevision incarnation)
              == pruneSourceRevision proof
          , Map.lookup
              (InventoryStore.retainedOwner incarnation)
              (InventoryPlan.reviewBaseRevisions document)
              == Just (InventoryStore.retainedRevision incarnation)
          , InventoryStore.retainedPhysical incarnation == pruneSourceUid proof
          , member ^. #identity == pruneSourceJob proof ->
              pure [member ^. #identity]
        _ -> dieT "reviewed prune backup is not the exact retained incarnation"
      _ -> dieT "manual prune backup scope is no longer uniquely accepted"
    unless
      (pruneSourceJob proof `elem` backupMembers)
      (dieT "manual prune backup Job changed after review")
    when (isJust (pruneSourcePolicy proof)) $ do
      let dependent (_, other) =
            Resource.scopeIdText (ResourceInventory.scopeId other)
              /= pruneSourceScope proof
              && Map.notMember
                "scheduled.prune.backup.scope"
                (ResourceInventory.scopeOverrides other)
              && ( pruneSourceScope proof
                     `elem` Map.elems (ResourceInventory.scopeOverrides other)
                     || any
                       ( \bundle ->
                           any
                             ( \case
                                 ResourceInventory.Managed member ->
                                   any
                                     ( \identity ->
                                         ResourceReference.OrderedAfter identity
                                           `elem` (member ^. #dependencies)
                                     )
                                     backupMembers
                                 _ -> False
                             )
                             (ResourceInventory.declarations bundle)
                       )
                       (ResourceInventory.scopeBundles other)
                 )
      when
        (any dependent (Map.elems (InventoryPlan.historyAccepted history)))
        (dieT "scheduled prune backup gained an accepted dependency after review")
  forM_ (catMaybes (map pruneSourcePolicy proofs)) $ \(policyScope, policyRevision) -> do
    let matches =
          [ (owner, revision)
          | (owner, (revision, _)) <-
              Map.toAscList (InventoryPlan.historyAccepted history)
          , Resource.scopeIdText owner == policyScope
          ]
    case matches of
      [(owner, revision)]
        | InventoryStore.revisionDigest revision == policyRevision
            && Map.lookup owner (InventoryPlan.reviewDesiredRevisions document) == Just revision ->
            pure ()
      _ -> dieT "scheduled prune retention policy changed after review"
  let credentials = catMaybes (map pruneSourceCredential proofs)
  forM_ credentials $ \(resourceId, _) -> do
    let matches =
          [ (owner, revision, member)
          | (owner, (revision, scope)) <- Map.toAscList (InventoryPlan.historyAccepted history)
          , bundle <- ResourceInventory.scopeBundles scope
          , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
          , member ^. #identity == resourceId
          ]
    case matches of
      [(owner, revision, member)]
        | Map.lookup owner (InventoryPlan.reviewDesiredRevisions document) == Just revision
        , member ^. #executor == ResourceInventory.KubernetesExecutor
        , ( case member ^. #address of
              Resource.Kubernetes _ "" kind (Just _) _ -> Resource.nameText kind == "secret"
              _ -> False
          ) ->
            pure ()
      _ -> dieT "volume prune credential changed or lost accepted ownership after review"
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
  let wanted = Set.fromList (map pruneSourceJob proofs <> map fst credentials)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNativeSelected wanted store history acceptedInventory
      >>= either dieT pure
  let selected = Map.restrictKeys acceptedNative wanted
  unless
    (Map.keysSet selected == wanted)
    (dieT "manual prune backup Job lacks accepted private native evidence")
  pure selected
