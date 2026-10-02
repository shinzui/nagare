-- | Data / ScheduledPrune. Executable-private CLI boundary.
module Nagare.Cli.Data.ScheduledPrune
  ( runReviewedScheduledPruneRecoveryPlan
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
  ( KubernetesAdapterOps (kubernetesObserve)
  , KubernetesState (KubernetesFailed, KubernetesPresent)
  )
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  , mkKubernetesRuntimeOpsWithCacheKey
  )
import Nagare.Inventory.Backup
  ( ScheduledReceiptExpectation
      ( scheduledFormat
      , scheduledKeep
      , scheduledObjectPrefix
      , scheduledPolicyRevision
      )
  , scheduledReceiptExpectationFromCronJob
  )
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
    keepText <- required "scheduled.prune.policy.keep"
    keep <- case reads (T.unpack keepText) of
      [(number, "")] | number > (0 :: Int) -> pure number
      _ -> dieT "failed prune has an invalid retention count"
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
            , scheduledPruneKeep = keep
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
