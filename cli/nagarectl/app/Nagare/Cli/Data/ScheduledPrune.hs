-- | Data / ScheduledPrune. Executable-private CLI boundary.
module Nagare.Cli.Data.ScheduledPrune
  ( runReviewedScheduledPrunePlan
  , runReviewedScheduledPruneRecoveryPlan
  )
where

import Control.Monad (forM, forM_)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Nagare.Cli.Data.ScheduleObservation
  ( scheduledProducerInFlight
  )
import Nagare.Cli.Inventory.Adapters (inventoryKubernetesAdapter)
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Cluster.GcsJob
  ( StoreBackend (GcsBackend, MinioBackend)
  )
import Nagare.Cluster.Kubeconfig (kubeconfigPath)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesState (KubernetesFailed, KubernetesPresent)
  , kubernetesObserve
  )
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  , mkKubernetesRuntimeOpsWithCacheKey
  )
import Nagare.Inventory.Backup
  ( ScheduledReceiptExpectation
      ( scheduledFormat
      , scheduledObjectPrefix
      , scheduledObjective
      , scheduledPolicyRevision
      )
  , scheduledReceiptExpectationFromCronJob
  )
import Nagare.Inventory.BackupRetention (retentionPolicyText, standardRetention)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.KubernetesReview
  ( kubernetesSpecsFromReview
  )
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.ScheduledPrune
  ( ScheduledPruneCandidate (..)
  , ScheduledPruneRequest (..)
  , compileScheduledPruneRecoveryScope
  , compileScheduledPruneScope
  , recoverScheduledPruneCandidate
  , selectScheduledPruneCandidates
  )
import Nagare.Inventory.ScheduledStore
  ( ListedObject (listedKey, listedModified)
  , ObjectReader
    ( listObjectEntries
    , listObjectVersions
    , readObjectToFile
    )
  , StoredObject (storedLength, storedVersion)
  , withLocalObjectStore
  )
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Target (Mode (Local), contextNameText)
import System.Directory (doesFileExist)
import System.Environment (setEnv)
import System.IO.Temp (withSystemTempDirectory)

-- | EP-183 M2: review the accepted scheduled runs of one database that the
-- retention policy (ADR 28) places past policy, one exact prune scope each.
-- Admission re-evaluates the policy against the accepted receipts before any
-- effect. Local (MinIO) contexts only, as receipt recovery is.
runReviewedScheduledPrunePlan :: Maybe String -> Text -> Text -> Maybe String -> FilePath -> IO ()
runReviewedScheduledPrunePlan mctx database namespaceName bucketArg output = do
  active <- activeTarget mctx
  when (active ^. #profile . #mode == Local) $ do
    selectedKubeconfig <- kubeconfigPath (active ^. #contextName)
    exists <- doesFileExist selectedKubeconfig
    unless exists (dieT "reviewed local scheduled prune kubeconfig is missing")
    setEnv "KUBECONFIG" selectedKubeconfig
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  let findAddress api kind name = either dieT pure (Resource.kubernetesAddress cluster api kind (Just namespaceName) name)
      members scope address =
        [ member
        | bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
        , member ^. #address == address
        ]
      scopes = map snd (Map.elems (ResourceInventory.snapshotScopes snapshot))
  statefulAddress <- findAddress "apps/v1" "StatefulSet" database
  (sourceScope, stateful) <- case [(scope, member) | scope <- scopes, member <- members scope statefulAddress] of
    [single] -> pure single
    _ -> dieT "scheduled prune requires one accepted database source"
  pvcAddress <- findAddress "v1" "PersistentVolumeClaim" (dbPvcName database)
  cronAddress <- findAddress "batch/v1" "CronJob" ("nagare-dbbackup-" <> database)
  signingAddress <- findAddress "v1" "Secret" ("nagare-dbbackup-" <> database <> "-signing")
  let unique label address = case members sourceScope address of
        [single] -> pure single
        _ -> dieT ("scheduled prune requires one accepted " <> label)
  pvc <- unique "database PVC" pvcAddress
  cron <- unique "backup CronJob" cronAddress
  signing <- unique "backup signing Secret" signingAddress
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  let acceptedRevision scope = case Map.lookup (ResourceInventory.scopeId scope) (InventoryPlan.historyAccepted history) of
        Just (revision, accepted) | accepted == scope -> pure revision
        _ -> dieT "scheduled prune source or receipt differs from accepted history"
  sourceRevision <- acceptedRevision sourceScope
  acceptedInventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <- InventoryStatus.loadAcceptedNative store history acceptedInventory >>= either dieT pure
  let sourceIds = map (^. #identity) [stateful, pvc, cron, signing]
      sourceNative = Map.restrictKeys acceptedNative (Set.fromList sourceIds)
  unless (Map.size sourceNative == 4) (dieT "scheduled prune source lacks accepted private native evidence")
  sourceAdapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "scheduled prune source observation does not use a cache key"))
      sourceNative
  observed <- InventoryAdapter.adapterObserve sourceAdapter sourceIds >>= either dieT pure
  let physical resource = case Map.lookup resource (InventoryAdapter.observationMap observed) of
        Just (InventoryAdapter.ObservedPresent uid) -> pure uid
        _ -> dieT "scheduled prune source, schedule, or signing key is absent or drifted"
  statefulUid <- physical (stateful ^. #identity)
  pvcUid <- physical (pvc ^. #identity)
  cronUid <- physical (cron ^. #identity)
  _ <- physical (signing ^. #identity)
  inFlight <- scheduledProducerInFlight (contextNameText (active ^. #contextName)) namespaceName cronUid
  when inFlight (dieT "scheduled backup producer has not completed successfully")
  (_, cronBytes) <- maybe (dieT "accepted CronJob lacks private native bytes") pure (Map.lookup (cron ^. #identity) sourceNative)
  backend <- resolveStoreBackend mctx bucketArg
  expectation <- either dieT pure (scheduledReceiptExpectationFromCronJob backend namespaceName database statefulUid pvcUid cronBytes)
  minio <- case backend of
    MinioBackend ref -> pure ref
    GcsBackend {} -> dieT "cloud scheduled prune requires exact-generation provider listing and receipt recovery"
  let bucketAddress = "s3://" <> minio ^. #bucket <> "/"
      prefix = scheduledObjectPrefix expectation
  keyPrefix <- maybe (dieT "accepted schedule has another local bucket") pure (T.stripPrefix bucketAddress prefix)
  listedResult <- withLocalObjectStore (contextNameText (active ^. #contextName)) minio (\reader -> listObjectEntries reader keyPrefix)
  listed <- either dieT pure listedResult >>= either dieT pure
  let receiptScopes =
        [ scope
        | scope <- scopes
        , Map.lookup "scheduled.backup.source.scope" (ResourceInventory.scopeOverrides scope)
            == Just (Resource.scopeIdText (ResourceInventory.scopeId sourceScope))
        ]
      dependsOn backup scope =
        let backupId = Resource.scopeIdText (ResourceInventory.scopeId backup)
            backupMembers =
              [ member ^. #identity
              | bundle <- ResourceInventory.scopeBundles backup
              , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
              ]
         in ResourceInventory.scopeId scope /= ResourceInventory.scopeId backup
              && Map.notMember "scheduled.prune.backup.scope" (ResourceInventory.scopeOverrides scope)
              && ( backupId `elem` Map.elems (ResourceInventory.scopeOverrides scope)
                     || or
                       [ ResourceReference.OrderedAfter identity `elem` (member ^. #dependencies)
                       | bundle <- ResourceInventory.scopeBundles scope
                       , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                       , identity <- backupMembers
                       ]
                 )
      -- An accepted restore that depends on a run keeps that run.
      protected =
        Set.fromList
          [ Resource.scopeIdText (ResourceInventory.scopeId backup)
          | backup <- receiptScopes
          , any (dependsOn backup) scopes
          ]
  forM_ receiptScopes $ \receiptScope -> do
    let fields = ResourceInventory.scopeOverrides receiptScope
        alreadyPruned =
          any
            ( \scope ->
                Map.lookup "scheduled.prune.backup.scope" (ResourceInventory.scopeOverrides scope)
                  == Just (Resource.scopeIdText (ResourceInventory.scopeId receiptScope))
            )
            scopes
    unless
      ( alreadyPruned
          || ( Map.lookup "scheduled.backup.source.revision" fields
                 == Just (Resource.digestText (InventoryStore.revisionDigest sourceRevision))
                 && Map.lookup "scheduled.backup.schedule.revision" fields
                   == Just (Resource.digestText (scheduledPolicyRevision expectation))
             )
      )
      (dieT "scheduled backup was admitted under an older source or schedule; ingest under the current schedule first")
  now <- getCurrentTime
  candidates <-
    either
      dieT
      pure
      ( selectScheduledPruneCandidates
          (ResourceInventory.scopeId sourceScope)
          bucketAddress
          prefix
          (scheduledFormat expectation)
          standardRetention
          (scheduledObjective expectation)
          now
          protected
          scopes
          listed
      )
  when (null candidates) (dieT ("no accepted scheduled backup is past the retention policy (" <> retentionPolicyText standardRetention <> ")"))
  let contextName = contextNameText (active ^. #contextName)
  context <- either dieT pure (Resource.mkContextId contextName)
  let config = KubernetesRuntimeConfig context contextName (fmap (fmap (const ())) (guardKubernetesContext active))
  compiled <- forM candidates $ \selected -> do
    backup <- case [scope | scope <- receiptScopes, ResourceInventory.scopeId scope == scheduledPruneScope selected] of
      [single] -> pure single
      _ -> dieT "selected scheduled receipt is no longer unique"
    backupRevision <- acceptedRevision backup
    ingestionJob <- case [ member
                         | bundle <- ResourceInventory.scopeBundles backup
                         , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                         , case member ^. #address of
                             Resource.Kubernetes _ "batch" kind (Just ns) _ ->
                               Resource.nameText kind == "job" && Resource.nameText ns == namespaceName
                             _ -> False
                         ] of
      [single] -> pure single
      _ -> dieT "selected scheduled receipt lacks one ingestion Job"
    backupNative <- case Map.lookup (ingestionJob ^. #identity) acceptedNative of
      Just pair | fst pair == ingestionJob -> pure (Map.singleton (ingestionJob ^. #identity) pair)
      _ -> dieT "selected scheduled receipt lacks private native evidence"
    let ops =
          mkKubernetesRuntimeOpsWithCacheKey
            config
            (\_ -> pure (Left "scheduled receipt Job observation does not use a cache key"))
            backupNative
    state <- kubernetesObserve ops (ingestionJob ^. #identity)
    backupUid <- case (state, Map.lookup (ingestionJob ^. #identity) backupNative) of
      (KubernetesPresent uid _ (Just owner) digest, Just (_, bytes))
        | owner == ingestionJob ^. #identity && digest == InventoryDigest.contentDigest bytes -> pure uid
      _ -> dieT "scheduled receipt ingestion Job is absent, incomplete, or drifted"
    let request =
          ScheduledPruneRequest
            { scheduledPruneDatabase = database
            , scheduledPruneNamespace = namespaceName
            , scheduledPruneCandidate = selected
            , scheduledPruneBackupRevision = backupRevision
            , scheduledPruneBackupJobUid = backupUid
            , scheduledPrunePolicyScope = ResourceInventory.scopeId sourceScope
            , scheduledPrunePolicyRevision = sourceRevision
            , scheduledPruneRetention = standardRetention
            , scheduledPruneBackend = backend
            , scheduledPruneSource = Resource.SourceLocation ("db prune-scheduled-backups/" <> database) (scheduledPruneId selected)
            }
    (pruneScope, pruneNative) <- either (dieT . T.pack . show) pure (compileScheduledPruneScope request backup backupNative)
    case Map.lookup (ResourceInventory.scopeId pruneScope) (ResourceInventory.snapshotScopes snapshot) of
      Just (_, prior) | prior /= pruneScope -> dieT "scheduled prune review for this run has another accepted intent"
      _ -> pure ()
    pure (pruneScope, Map.union pruneNative backupNative)
  replacements <-
    maybe
      (dieT "no scheduled prune candidate")
      pure
      (NE.nonEmpty [ResourceInventory.ReplaceScope scope | (scope, _) <- compiled])
  candidate <- either (dieT . T.pack . show) pure (ResourceInventory.composeInventory snapshot replacements)
  let native = Map.unions (sourceNative : map snd compiled)
  Inventory.planInventoryCandidateWith (inventoryPlanRegistryWithNative active workspace native) active candidate output
  TIO.putStrLn ("Saved exact scheduled pruning review for " <> T.pack (show (length candidates)) <> " run(s) past the retention policy.")

runReviewedScheduledPruneRecoveryPlan ::
  Maybe String ->
  Text ->
  Text ->
  Text ->
  Maybe String ->
  FilePath ->
  FilePath ->
  IO ()
runReviewedScheduledPruneRecoveryPlan
  mctx
  database
  namespaceName
  backupId
  bucketArg
  failedDirectory
  output = do
    active <- activeTarget mctx
    when (active ^. #profile . #mode == Local) $ do
      selectedKubeconfig <- kubeconfigPath (active ^. #contextName)
      exists <- doesFileExist selectedKubeconfig
      unless exists (dieT "reviewed local prune recovery kubeconfig is missing")
      setEnv "KUBECONFIG" selectedKubeconfig
    (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    snapshot <- Inventory.loadTargetSnapshot active
    store <-
      Inventory.openTargetStoreReadOnly active
        >>= either (dieT . T.pack . show) pure
    history <-
      InventoryPlan.loadInventoryHistory store
        >>= either (dieT . T.pack . show) pure
    unless
      ( isNothing
          ( InventoryStore.headActiveTransaction
              (InventoryPlan.historyHead history)
          )
      )
      (dieT "scheduled prune recovery requires the failed transaction to be abandoned")
    localReview <- InventoryPlan.loadReviewBundle failedDirectory >>= either dieT pure
    let reviewDigest = InventoryPlan.reviewDigest localReview
    published <-
      InventoryPlan.loadPublishedReview store reviewDigest
        >>= either (dieT . T.pack . show) pure
    unless
      ( InventoryPlan.reviewBundleDocument localReview
          == InventoryPlan.reviewBundleDocument published
          && InventoryPlan.reviewBundleScopes localReview
            == InventoryPlan.reviewBundleScopes published
      )
      (dieT "failed scheduled prune review differs from its published members")
    let document = InventoryPlan.reviewBundleDocument published
    unless
      ( InventoryPlan.reviewBaseRevisions document
          == InventoryStore.headAccepted (InventoryPlan.historyHead history)
      )
      (dieT "accepted inventory changed after the failed scheduled prune review")
    reviewedScopes <-
      traverse
        ( either (dieT . T.pack . show) pure
            . ResourceWire.decodeScope
        )
        (Map.elems (InventoryPlan.reviewBundleScopes published))
    failedOwner <-
      either
        dieT
        pure
        ( Resource.mkScopeId
            Resource.Standalone
            ( "database-scheduled-prune-"
                <> namespaceName
                <> "-"
                <> database
                <> "-"
                <> backupId
            )
        )
    backupOwner <-
      either
        dieT
        pure
        ( Resource.mkScopeId
            Resource.Standalone
            ( "database-scheduled-receipt-"
                <> namespaceName
                <> "-"
                <> database
                <> "-"
                <> backupId
            )
        )
    failedScope <- case [ scope
                        | scope <- reviewedScopes
                        , ResourceInventory.scopeId scope == failedOwner
                        ] of
      [single] -> pure single
      _ -> dieT "published failed review lacks the exact scheduled prune scope"
    unless
      ( Map.lookup
          "scheduled.prune.backup.scope"
          (ResourceInventory.scopeOverrides failedScope)
          == Just (Resource.scopeIdText backupOwner)
      )
      (dieT "failed prune review names another accepted backup")
    backupScope <- case Map.lookup
      backupOwner
      (InventoryPlan.historyAccepted history) of
      Just (_, accepted) -> pure accepted
      _ -> dieT "partial prune backup is no longer accepted"
    backupRevision <- case Map.lookup
      backupOwner
      (InventoryPlan.historyAccepted history) of
      Just (revision, _) -> pure revision
      _ -> dieT "partial prune backup revision is unavailable"
    let failedFields = ResourceInventory.scopeOverrides failedScope
        required key =
          maybe
            (dieT ("failed prune lacks " <> key))
            pure
            (Map.lookup key failedFields)
    policyName <- required "scheduled.prune.policy.scope"
    policy <- case [ (owner, revision, scope)
                   | (owner, (revision, scope)) <-
                       Map.toAscList
                         (InventoryPlan.historyAccepted history)
                   , Resource.scopeIdText owner == policyName
                   ] of
      [single] -> pure single
      _ -> dieT "failed prune policy source is no longer uniquely accepted"
    let (policyOwner, policyRevision, _) = policy
    policyPin <- required "scheduled.prune.policy.revision"
    unless
      ( policyPin
          == Resource.digestText
            (InventoryStore.revisionDigest policyRevision)
      )
      (dieT "failed prune retention policy revision changed")
    retentionText <- required "scheduled.prune.policy.retention"
    unless
      (retentionText == retentionPolicyText standardRetention)
      (dieT "failed prune was reviewed under another retention policy")
    failedJob <- case [ member
                      | bundle <- ResourceInventory.scopeBundles failedScope
                      , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                      , case member ^. #address of
                          Resource.Kubernetes _ "batch" kind (Just ns) _ ->
                            Resource.nameText kind == "job"
                              && Resource.nameText ns == namespaceName
                          _ -> False
                      ] of
      [single] -> pure single
      _ -> dieT "failed prune review lacks one exact Job"
    failedNative <- either dieT pure (kubernetesSpecsFromReview published)
    (failedBound, failedBytes) <- case Map.lookup
      (failedJob ^. #identity)
      failedNative of
      Just pair | fst pair == failedJob -> pure pair
      _ -> dieT "failed prune Job lacks exact published native evidence"
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
        failedOps =
          mkKubernetesRuntimeOpsWithCacheKey
            config
            (\_ -> pure (Left "failed prune observation does not use a cache key"))
            (Map.singleton (failedJob ^. #identity) (failedBound, failedBytes))
    failedState <- kubernetesObserve failedOps (failedJob ^. #identity)
    failedUid <- case failedState of
      KubernetesFailed uid _ (Just owner) digest
        | owner == failedJob ^. #identity
            && digest == InventoryDigest.contentDigest failedBytes ->
            pure uid
      _ -> dieT "original scheduled prune Job is not the exact owned terminal failure"
    acceptedInventory <-
      either
        (dieT . T.pack . show)
        pure
        (ResourceInventory.composeSnapshot snapshot)
    (acceptedNative, _) <-
      InventoryStatus.loadAcceptedNative store history acceptedInventory
        >>= either dieT pure
    ingestionJob <- case [ member
                         | bundle <- ResourceInventory.scopeBundles backupScope
                         , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                         , case member ^. #address of
                             Resource.Kubernetes _ "batch" kind (Just ns) _ ->
                               Resource.nameText kind == "job"
                                 && Resource.nameText ns == namespaceName
                             _ -> False
                         ] of
      [single] -> pure single
      _ -> dieT "accepted scheduled receipt lacks one ingestion Job"
    backupNative <- case Map.lookup (ingestionJob ^. #identity) acceptedNative of
      Just pair
        | fst pair == ingestionJob ->
            pure
              (Map.singleton (ingestionJob ^. #identity) pair)
      _ -> dieT "accepted scheduled ingestion Job lacks private native evidence"
    let backupOps =
          mkKubernetesRuntimeOpsWithCacheKey
            config
            (\_ -> pure (Left "scheduled ingestion observation does not use a cache key"))
            backupNative
    backupState <- kubernetesObserve backupOps (ingestionJob ^. #identity)
    backupUid <- case ( backupState
                      , Map.lookup
                          (ingestionJob ^. #identity)
                          backupNative
                      ) of
      (KubernetesPresent uid _ (Just owner) digest, Just (_, bytes))
        | owner == ingestionJob ^. #identity
            && digest == InventoryDigest.contentDigest bytes ->
            pure uid
      _ -> dieT "accepted scheduled ingestion Job is absent or drifted"
    backend <- resolveStoreBackend mctx bucketArg
    minio <- case backend of
      MinioBackend ref -> pure ref
      GcsBackend {} -> dieT "cloud partial prune recovery requires exact-generation proof"
    let bucketAddress = "s3://" <> minio ^. #bucket <> "/"
    objectAddress <- required "scheduled.prune.object"
    receiptAddress <- required "scheduled.prune.receipt"
    objectVersion <- required "scheduled.prune.object.version"
    receiptVersion <- required "scheduled.prune.receipt.version"
    objectKey <-
      maybe
        (dieT "failed object is outside the selected local bucket")
        pure
        (T.stripPrefix bucketAddress objectAddress)
    receiptKey <-
      maybe
        (dieT "failed receipt is outside the selected local bucket")
        pure
        (T.stripPrefix bucketAddress receiptAddress)
    provider <- withSystemTempDirectory "nagare-partial-prune-review" $ \scratch ->
      withLocalObjectStore (contextNameText (active ^. #contextName)) minio $ \reader -> do
        current <- listObjectEntries reader objectKey
        versions <- listObjectVersions reader objectKey
        receiptStored <-
          readObjectToFile
            reader
            receiptAddress
            (Just receiptVersion)
            (scratch <> "/receipt.json")
        bytes <- case receiptStored of
          Left reason -> pure (Left reason)
          Right stored -> do
            content <- BS.readFile (scratch <> "/receipt.json")
            pure (Right (stored, content))
        pure $ do
          listed <- current
          exactVersions <- versions
          (stored, content) <- bytes
          unless
            ( map listedKey listed == [receiptKey]
                && exactVersions == [(receiptKey, receiptVersion)]
                && storedVersion stored == receiptVersion
            )
            (Left "partial prune provider state differs from one remaining exact receipt")
          let expectedLength =
                Map.lookup
                  "scheduled.backup.receipt.length"
                  (ResourceInventory.scopeOverrides backupScope)
              expectedDigest =
                Map.lookup
                  "scheduled.backup.receipt.digest"
                  (ResourceInventory.scopeOverrides backupScope)
          unless
            ( expectedLength == Just (T.pack (show (storedLength stored)))
                && expectedDigest
                  == Just
                    ( Resource.digestText
                        (InventoryDigest.contentDigest content)
                    )
                && not ((objectKey, objectVersion) `elem` exactVersions)
            )
            (Left "remaining receipt bytes or reviewed object absence changed")
          case listed of
            [entry] -> Right (listedModified entry)
            _ -> Left "partial prune receipt has no unique current listing"
    receiptTime <- either dieT pure provider >>= either dieT pure
    selected <-
      either
        dieT
        pure
        (recoverScheduledPruneCandidate backupScope failedScope receiptTime)
    unless
      ( scheduledPruneId selected == backupId
          && scheduledPruneObject selected == objectAddress
          && scheduledPruneReceipt selected == receiptAddress
      )
      (dieT "failed prune recovery changes the selected backup")
    let request =
          ScheduledPruneRequest
            { scheduledPruneDatabase = database
            , scheduledPruneNamespace = namespaceName
            , scheduledPruneCandidate = selected
            , scheduledPruneBackupRevision = backupRevision
            , scheduledPruneBackupJobUid = backupUid
            , scheduledPrunePolicyScope = policyOwner
            , scheduledPrunePolicyRevision = policyRevision
            , scheduledPruneRetention = standardRetention
            , scheduledPruneBackend = backend
            , scheduledPruneSource =
                Resource.SourceLocation
                  ("db recover-scheduled-prune/" <> database)
                  backupId
            }
    (recoveryScope, recoveryNative) <-
      either
        (dieT . T.pack . show)
        pure
        ( compileScheduledPruneRecoveryScope
            request
            backupScope
            backupNative
            failedScope
            failedUid
            reviewDigest
        )
    case Map.lookup
      (ResourceInventory.scopeId recoveryScope)
      (ResourceInventory.snapshotScopes snapshot) of
      Just (_, prior)
        | prior /= recoveryScope ->
            dieT "remaining-receipt recovery ID already has another accepted intent"
      _ -> pure ()
    candidate <-
      either
        (dieT . T.pack . show)
        pure
        ( ResourceInventory.composeInventory
            snapshot
            (ResourceInventory.ReplaceScope recoveryScope NE.:| [])
        )
    Inventory.planInventoryCandidateWith
      ( inventoryPlanRegistryWithNative
          active
          workspace
          (Map.union recoveryNative backupNative)
      )
      active
      candidate
      output
    TIO.putStrLn "Saved exact remaining-receipt recovery review from the abandoned prune."
