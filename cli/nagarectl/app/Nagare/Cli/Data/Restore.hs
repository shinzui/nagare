-- | Data / Restore. Executable-private CLI boundary.
module Nagare.Cli.Data.Restore
  ( runReviewedDbRestorePlan
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonMap
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Maybe (maybeToList)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
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
import Nagare.Dsl.Database (Engine (Postgres), dbSecretName)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesAdapterOps (kubernetesObserve)
  , KubernetesState (KubernetesPresent)
  )
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  , mkKubernetesRuntimeOpsWithCacheKey
  , readBackupReceiptFromCompletedPod
  , readCompletedJobContainerMessage
  )
import Nagare.Inventory.Backup (parseManualBackupReceipt)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataFence.DatabaseShutdown qualified as DatabaseShutdown
import Nagare.Inventory.DataFence.KubernetesIntent
  ( parseObservedDatabaseServer
  )
import Nagare.Inventory.DataFence.StatefulWriter qualified as StatefulWriter
import Nagare.Inventory.DataFence.VolumeState
  ( kubectlVolumeTransport
  )
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.LiveRestore
  ( LiveBackupInput (LiveBackupInput)
  , LiveRestoreRequest
    ( LiveRestoreRequest
    , liveRestoreBackend
    , liveRestoreDatabase
    , liveRestoreId
    , liveRestoreNamespace
    , liveRestorePodUid
    , liveRestorePvcUid
    , liveRestoreRecoveryBackup
    , liveRestoreSource
    , liveRestoreSourceBackup
    , liveRestoreStatefulUid
    , liveRestoreTargetRevision
    )
  , compileLiveRestoreScope
  )
import Nagare.Inventory.LiveRestoreSource
  ( captureLiveBackupVersions
  )
import Nagare.Inventory.ManualReceipt
  ( ManualReceiptEvidence (..)
  , manualReceiptRecord
  )
import Nagare.Inventory.ManualReceiptSource
  ( inspectManualReceipt
  , withGcsManualObjectReader
  )
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Restore
  ( ManualRestoreRequest
      ( ManualRestoreRequest
      , restoreBackupRevision
      , restoreBackupScope
      , restoreDatabaseName
      , restoreId
      , restoreNamespaceName
      , restoreReceiptBytes
      , restoreSource
      , restoreStorageBackend
      , restoreTargetPvcUid
      , restoreTargetRevision
      , restoreTargetStatefulUid
      )
  , compileManualRestoreScope
  )
import Nagare.Inventory.ScheduledGcs (withScheduledObjectStore)
import Nagare.Inventory.ScheduledReceipt (verifyAcceptedScheduledReceipt)
import Nagare.Inventory.ScheduledStore
  ( ObjectReader (readObjectToFile)
  , withLocalObjectStore
  )
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (contextNameText)

runReviewedDbRestorePlan ::
  Maybe String ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe Text ->
  Maybe String ->
  FilePath ->
  IO ()
runReviewedDbRestorePlan
  mctx
  database
  namespaceName
  backupId
  restoreKey
  recoveryBackupId
  bucketArg
  output = do
    active <- activeTarget mctx
    (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    snapshot <- Inventory.loadTargetSnapshot active
    (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
    statefulAddress <-
      either
        dieT
        pure
        ( Resource.kubernetesAddress
            cluster
            "apps/v1"
            "StatefulSet"
            (Just namespaceName)
            database
        )
    let sources =
          [ (scope, member)
          | (_, scope) <-
              Map.elems
                (ResourceInventory.snapshotScopes snapshot)
          , bundle <- ResourceInventory.scopeBundles scope
          , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
          , member ^. #address == statefulAddress
          ]
    (targetScope, stateful) <- case sources of
      [single] -> pure single
      _ -> dieT "reviewed restore requires one accepted database StatefulSet at the selected address"
    pvcAddress <-
      either
        dieT
        pure
        ( Resource.kubernetesAddress
            cluster
            "v1"
            "PersistentVolumeClaim"
            (Just namespaceName)
            (dbPvcName database)
        )
    pvc <- case [ member
                | bundle <- ResourceInventory.scopeBundles targetScope
                , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                , member ^. #address == pvcAddress
                ] of
      [single] -> pure single
      _ -> dieT "reviewed restore requires one accepted database PVC"
    credentialAddress <-
      either
        dieT
        pure
        ( Resource.kubernetesAddress
            cluster
            "v1"
            "Secret"
            (Just namespaceName)
            (dbSecretName database)
        )
    credential <- case [ member
                       | bundle <- ResourceInventory.scopeBundles targetScope
                       , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                       , member ^. #address == credentialAddress
                       ] of
      [single] -> pure single
      _ -> dieT "reviewed restore requires one accepted database credential"
    let backups =
          [ scope
          | (_, scope) <-
              Map.elems
                (ResourceInventory.snapshotScopes snapshot)
          , let fields = ResourceInventory.scopeOverrides scope
          , ( Map.lookup "backup.id" fields == Just backupId
                && Map.lookup "backup.source.scope" fields
                  == Just (Resource.scopeIdText (ResourceInventory.scopeId targetScope))
            )
              || ( Map.lookup "scheduled.backup.id" fields == Just backupId
                     && Map.lookup "scheduled.backup.source.scope" fields
                       == Just (Resource.scopeIdText (ResourceInventory.scopeId targetScope))
                 )
          , ( manualReceiptRecord scope
                || any
                  ( \bundle ->
                      any
                        ( \case
                            ResourceInventory.Managed member -> case member ^. #address of
                              Resource.Kubernetes _ "batch" kind _ _ -> Resource.nameText kind == "job"
                              _ -> False
                            _ -> False
                        )
                        (ResourceInventory.declarations bundle)
                  )
                  (ResourceInventory.scopeBundles scope)
            )
          ]
    backupScope <- case backups of
      [single] -> pure single
      _ -> dieT "reviewed restore requires one accepted backup with the selected ID"
    let scheduled = Map.member "scheduled.backup.id" (ResourceInventory.scopeOverrides backupScope)
    let pruned =
          [ scope
          | (_, scope) <-
              Map.elems
                (ResourceInventory.snapshotScopes snapshot)
          , Map.lookup "prune.backup.scope" (ResourceInventory.scopeOverrides scope)
              == Just (Resource.scopeIdText (ResourceInventory.scopeId backupScope))
              || Map.lookup "scheduled.prune.backup.scope" (ResourceInventory.scopeOverrides scope)
                == Just (Resource.scopeIdText (ResourceInventory.scopeId backupScope))
          ]
    unless
      (null pruned)
      (dieT "selected backup has an accepted prune operation")
    let backupJobs =
          [ member
          | bundle <- ResourceInventory.scopeBundles backupScope
          , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
          , case member ^. #address of
              Resource.Kubernetes _ "batch" kind _ _ -> Resource.nameText kind == "job"
              _ -> False
          ]
    backupJob <- case (manualReceiptRecord backupScope, backupJobs) of
      (False, [single]) -> pure (Just single)
      (True, []) -> pure Nothing
      _ -> dieT "reviewed restore backup has no unique accepted Job"
    unless scheduled $ case Map.lookup "backup.expiry" (ResourceInventory.scopeOverrides backupScope) of
      Just "retain" -> pure ()
      Just expiryText -> case parseTimeM
                                True
                                defaultTimeLocale
                                "%Y-%m-%dT%H:%M:%SZ"
                                (T.unpack expiryText) ::
                                Maybe UTCTime of
        Nothing -> dieT "accepted backup expiry is invalid"
        Just expiry -> do
          now <- getCurrentTime
          unless (expiry > now) (dieT "selected backup has expired")
      Nothing -> dieT "accepted backup has no expiry policy"
    store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
    history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
    when (manualReceiptRecord backupScope) $ do
      let fields = ResourceInventory.scopeOverrides backupScope
          required key =
            maybe
              (dieT ("manual receipt lacks " <> key))
              pure
              (Map.lookup key fields)
      recordedJob <-
        required "backup.job"
          >>= either dieT pure . Resource.mkResourceId
      recordedUid <-
        required "backup.job.uid"
          >>= either dieT pure . Resource.mkPhysicalIdentity
      generationText <- required "backup.producer.generation"
      generation <- case reads (T.unpack generationText) of
        [(selected, "")] | selected > (0 :: Integer) -> pure selected
        _ -> dieT "manual receipt producer generation is invalid"
      digestText <- required "backup.producer.revision"
      digest <- either dieT pure (Resource.mkContentDigest digestText)
      scopeGeneration <- either dieT pure (Resource.mkScopeGeneration generation)
      let producerRevision = InventoryStore.ScopeRevision scopeGeneration digest
          retained = case Map.lookup recordedJob (InventoryPlan.historyRetained history) of
            Just (incarnation, member) ->
              InventoryStore.retainedOwner incarnation == ResourceInventory.scopeId backupScope
                && InventoryStore.retainedRevision incarnation == producerRevision
                && InventoryStore.retainedPhysical incarnation == recordedUid
                && member ^. #owner == ResourceInventory.scopeId backupScope
            Nothing -> False
          collected = case Map.lookup
            recordedJob
            (InventoryStore.headCollected (InventoryPlan.historyHead history)) of
            Just tombstone ->
              InventoryStore.tombstoneOwner tombstone == ResourceInventory.scopeId backupScope
                && InventoryStore.tombstoneRevision tombstone == producerRevision
                && InventoryStore.tombstonePhysical tombstone == recordedUid
            Nothing -> False
      unless
        (retained || collected)
        (dieT "manual receipt has no matching retained or collected accepted backup Job")
    let acceptedRevision scope = case Map.lookup
          (ResourceInventory.scopeId scope)
          (InventoryPlan.historyAccepted history) of
          Just (revision, accepted) | accepted == scope -> pure revision
          _ -> dieT "restore source or backup scope differs from accepted history"
    targetRevision <- acceptedRevision targetScope
    backupRevision <- acceptedRevision backupScope
    acceptedInventory <-
      either
        (dieT . T.pack . show)
        pure
        (ResourceInventory.composeSnapshot snapshot)
    let sourceIds = [stateful ^. #identity, pvc ^. #identity]
        nativeIds =
          Set.fromList
            (map (^. #identity) (maybeToList backupJob) <> (credential ^. #identity : sourceIds))
    (acceptedNative, _) <-
      ( case recoveryBackupId of
          Nothing -> InventoryStatus.loadAcceptedNativeSelected nativeIds store history acceptedInventory
          Just _ -> InventoryStatus.loadAcceptedNative store history acceptedInventory
      )
        >>= either dieT pure
    let selectedNative = Map.restrictKeys acceptedNative nativeIds
    unless
      (Map.size selectedNative == 3 + length (maybeToList backupJob))
      (dieT "restore target or selected backup lacks accepted private native evidence")
    sourceAdapter <-
      inventoryKubernetesAdapter
        active
        (ResourceInventory.snapshotBinding snapshot)
        (\_ -> pure (Left "restore target observation does not use a cache key"))
        (Map.restrictKeys selectedNative (Set.fromList sourceIds))
    observed <- InventoryAdapter.adapterObserve sourceAdapter sourceIds >>= either dieT pure
    let physical resource = case Map.lookup resource (InventoryAdapter.observationMap observed) of
          Just (InventoryAdapter.ObservedPresent uid) -> pure uid
          _ -> dieT "restore target StatefulSet or PVC is absent, drifted, or not ready"
    statefulUid <- physical (stateful ^. #identity)
    pvcUid <- physical (pvc ^. #identity)
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
        backupNative =
          Map.restrictKeys
            selectedNative
            (Set.fromList (map (^. #identity) (maybeToList backupJob)))
        backupOps =
          mkKubernetesRuntimeOpsWithCacheKey
            config
            (\_ -> pure (Left "backup Job observation does not use a cache key"))
            backupNative
    backupUid <- case backupJob of
      Nothing -> pure Nothing
      Just selectedJob -> do
        backupState <- kubernetesObserve backupOps (selectedJob ^. #identity)
        case (backupState, Map.lookup (selectedJob ^. #identity) backupNative) of
          (KubernetesPresent uid _ (Just owner) digest, Just (_, bytes))
            | owner == selectedJob ^. #identity
            , digest == InventoryDigest.contentDigest bytes ->
                pure (Just uid)
          _ -> dieT "accepted backup Job is absent, incomplete, foreign, or drifted"
    backend <- resolveStoreBackend mctx bucketArg
    receiptBytes <-
      if manualReceiptRecord backupScope
        then do
          let required key =
                maybe
                  (dieT ("accepted manual receipt lacks " <> key))
                  pure
                  (Map.lookup key (ResourceInventory.scopeOverrides backupScope))
          recordedJobUid <-
            required "backup.job.uid"
              >>= either dieT pure . Resource.mkPhysicalIdentity
          guarded <- guardKubernetesContext active
          _ <- either dieT pure guarded
          inspected <- case backend of
            MinioBackend ref -> withLocalObjectStore
              (contextNameText (active ^. #contextName))
              ref
              $ \reader ->
                inspectManualReceipt
                  (\address path -> readObjectToFile reader address Nothing path)
                  backupScope
                  recordedJobUid
            GcsBackend {} -> withGcsManualObjectReader backend $ \readOne ->
              inspectManualReceipt readOne backupScope recordedJobUid
          evidence <- either dieT pure inspected >>= either dieT pure
          expectedObjectVersion <- required "backup.object.version"
          expectedObjectLength <- required "backup.object.length"
          expectedObjectSha <- required "backup.object.sha256"
          expectedReceiptVersion <- required "backup.receipt.version"
          expectedReceiptLength <- required "backup.receipt.length"
          expectedReceiptDigest <- required "backup.receipt.digest"
          unless
            ( manualObjectVersion evidence == expectedObjectVersion
                && T.pack (show (manualObjectLength evidence)) == expectedObjectLength
                && manualObjectSha256 evidence == expectedObjectSha
                && manualReceiptVersion evidence == expectedReceiptVersion
                && T.pack (show (manualReceiptLength evidence)) == expectedReceiptLength
                && Resource.digestText
                  (InventoryDigest.contentDigest (manualReceiptBytes evidence))
                  == expectedReceiptDigest
            )
            (dieT "manual restore stored bytes or provider versions differ from accepted receipt")
          pure (manualReceiptBytes evidence)
        else
          if scheduled
            then do
              selectedJob <-
                maybe
                  (dieT "scheduled receipt has no accepted ingestion Job")
                  pure
                  backupJob
              selectedUid <-
                maybe
                  (dieT "scheduled receipt ingestion Job is not ready")
                  pure
                  backupUid
              let required key =
                    maybe
                      (dieT ("accepted scheduled backup lacks " <> key))
                      pure
                      (Map.lookup key (ResourceInventory.scopeOverrides backupScope))
              expectedStateful <-
                required "scheduled.backup.source.statefulset.uid"
                  >>= either dieT pure . Resource.mkPhysicalIdentity
              expectedPvc <-
                required "scheduled.backup.source.pvc.uid"
                  >>= either dieT pure . Resource.mkPhysicalIdentity
              unless
                (expectedStateful == statefulUid && expectedPvc == pvcUid)
                (dieT "scheduled restore target source incarnation changed after ingestion")
              objectAddress <- required "scheduled.backup.object"
              checked <- withScheduledObjectStore (contextNameText (active ^. #contextName)) backend $ \reader ->
                verifyAcceptedScheduledReceipt reader objectAddress backupScope
              either dieT pure checked >>= either dieT pure
              objectVersion <- required "scheduled.backup.object.version"
              receiptVersion <- required "scheduled.backup.receipt.version"
              objectSha <- required "scheduled.backup.object.sha256"
              message <-
                readCompletedJobContainerMessage
                  config
                  backupNative
                  (selectedJob ^. #identity)
                  selectedUid
                  "verify"
                  >>= either dieT pure
              readback <-
                either
                  (dieT . T.pack)
                  pure
                  (Aeson.eitherDecodeStrict' message)
              unless
                ( case readback of
                    Aeson.Object fields ->
                      AesonMap.size fields == 3
                        && AesonMap.lookup "objectVersion" fields == Just (Aeson.String objectVersion)
                        && AesonMap.lookup "receiptVersion" fields == Just (Aeson.String receiptVersion)
                        && AesonMap.lookup "sha256" fields == Just (Aeson.String objectSha)
                    _ -> False
                )
                (dieT "scheduled ingestion Job readback differs from accepted receipt")
              pure message
            else do
              selectedJob <-
                maybe
                  (dieT "manual backup has no accepted Job")
                  pure
                  backupJob
              selectedUid <-
                maybe
                  (dieT "manual backup Job is not ready")
                  pure
                  backupUid
              readBackupReceiptFromCompletedPod
                config
                backupNative
                (selectedJob ^. #identity)
                selectedUid
                >>= either dieT pure
    case recoveryBackupId of
      Nothing -> do
        let request =
              ManualRestoreRequest
                { restoreDatabaseName = database
                , restoreNamespaceName = namespaceName
                , restoreId = restoreKey
                , restoreBackupScope = backupScope
                , restoreBackupRevision = backupRevision
                , restoreReceiptBytes = receiptBytes
                , restoreTargetRevision = targetRevision
                , restoreTargetStatefulUid = statefulUid
                , restoreTargetPvcUid = pvcUid
                , restoreStorageBackend = backend
                , restoreSource = Resource.SourceLocation ("db restore/" <> database) restoreKey
                }
        (restoreScope, restoreNative) <-
          either
            (dieT . T.pack . show)
            pure
            (compileManualRestoreScope request targetScope acceptedNative)
        case Map.lookup
          (ResourceInventory.scopeId restoreScope)
          (ResourceInventory.snapshotScopes snapshot) of
          Just (_, prior)
            | prior /= restoreScope ->
                dieT "restore ID already has different accepted intent; choose a new ID"
          _ -> pure ()
        candidate <-
          either
            (dieT . T.pack . show)
            pure
            ( ResourceInventory.composeInventory
                snapshot
                (ResourceInventory.ReplaceScope restoreScope NE.:| [])
            )
        Inventory.planInventoryCandidateWith
          ( inventoryPlanRegistryWithNative
              active
              workspace
              (Map.union restoreNative selectedNative)
          )
          active
          candidate
          output
        TIO.putStrLn "Saved reviewed scratch restore. Apply it to verify the backup again and create the fixed scratch target."
      Just recoveryId -> do
        when
          (recoveryId == backupId)
          (dieT "reviewed live restore requires a distinct recovery backup")
        recoveryScope <- case [ scope
                              | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
                              , let fields = ResourceInventory.scopeOverrides scope
                              , Map.lookup "backup.id" fields == Just recoveryId
                              , Map.lookup "backup.source.scope" fields
                                  == Just (Resource.scopeIdText (ResourceInventory.scopeId targetScope))
                              ] of
          [single] -> pure single
          _ -> dieT "reviewed live restore requires one accepted manual recovery backup"
        case Map.lookup
          "backup.expiry"
          (ResourceInventory.scopeOverrides recoveryScope) of
          Just "retain" -> pure ()
          Just expiryText -> case parseTimeM
                                    True
                                    defaultTimeLocale
                                    "%Y-%m-%dT%H:%M:%SZ"
                                    (T.unpack expiryText) ::
                                    Maybe UTCTime of
            Nothing -> dieT "live restore recovery backup expiry is invalid"
            Just expiry -> do
              now <- getCurrentTime
              unless
                (expiry > now)
                (dieT "live restore recovery backup has expired")
          Nothing -> dieT "live restore recovery backup has no expiry policy"
        let recoveryPruned =
              [ scope
              | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
              , Map.lookup
                  "prune.backup.scope"
                  (ResourceInventory.scopeOverrides scope)
                  == Just (Resource.scopeIdText (ResourceInventory.scopeId recoveryScope))
              ]
        unless
          (null recoveryPruned)
          (dieT "live restore recovery backup has an accepted prune operation")
        recoveryJob <- case [ member
                            | bundle <- ResourceInventory.scopeBundles recoveryScope
                            , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                            , case member ^. #address of
                                Resource.Kubernetes _ "batch" kind _ _ ->
                                  Resource.nameText kind == "job"
                                _ -> False
                            ] of
          [single] -> pure single
          _ -> dieT "live restore recovery backup has no unique accepted Job"
        recoveryRevision <- acceptedRevision recoveryScope
        let recoveryNative =
              Map.restrictKeys
                acceptedNative
                (Set.singleton (recoveryJob ^. #identity))
            recoveryOps =
              mkKubernetesRuntimeOpsWithCacheKey
                config
                (\_ -> pure (Left "recovery Job observation does not use a cache key"))
                recoveryNative
        recoveryState <- kubernetesObserve recoveryOps (recoveryJob ^. #identity)
        recoveryUid <- case ( recoveryState
                            , Map.lookup (recoveryJob ^. #identity) recoveryNative
                            ) of
          (KubernetesPresent uid _ (Just owner) digest, Just (_, bytes))
            | owner == recoveryJob ^. #identity
            , digest == InventoryDigest.contentDigest bytes ->
                pure uid
          _ -> dieT "accepted recovery Job is absent, incomplete, foreign, or drifted"
        recoveryReceipt <-
          readBackupReceiptFromCompletedPod
            config
            recoveryNative
            (recoveryJob ^. #identity)
            recoveryUid
            >>= either dieT pure
        let pinVersions selectedScope receipt = do
              let fields = ResourceInventory.scopeOverrides selectedScope
                  required key =
                    maybe
                      (dieT ("live restore backup lacks " <> key))
                      pure
                      (Map.lookup key fields)
              objectAddress <- required "backup.object"
              receiptAddress <- required "backup.receipt"
              checksum <-
                either
                  dieT
                  pure
                  ( parseManualBackupReceipt
                      selectedScope
                      receiptAddress
                      receipt
                  )
              captureLiveBackupVersions
                config
                backend
                objectAddress
                receiptAddress
                receipt
                checksum
                >>= either dieT pure
        sourceVersions <-
          if scheduled
            then do
              let fields = ResourceInventory.scopeOverrides backupScope
                  required key =
                    maybe
                      (dieT ("scheduled live restore lacks " <> key))
                      pure
                      (Map.lookup key fields)
              objectVersion <- required "scheduled.backup.object.version"
              receiptVersion <- required "scheduled.backup.receipt.version"
              pure (objectVersion, receiptVersion)
            else pinVersions backupScope receiptBytes
        recoveryVersions <- pinVersions recoveryScope recoveryReceipt
        (_, statefulBytes) <-
          maybe
            (dieT "live restore target StatefulSet lacks native bytes")
            pure
            (Map.lookup (stateful ^. #identity) acceptedNative)
        statefulValue <-
          either
            (dieT . T.pack)
            pure
            (Aeson.eitherDecodeStrict' statefulBytes)
        (engine, image) <- case parseObservedDatabaseServer statefulValue of
          Right (Just (selectedEngine, selectedImage)) ->
            pure (selectedEngine, selectedImage)
          _ -> dieT "live restore requires an accepted database server"
        unless
          (engine == Postgres)
          (dieT "reviewed live restore currently supports PostgreSQL only")
        liveWriter <-
          StatefulWriter.readStatefulWriter
            (StatefulWriter.kubectlStatefulWriterTransport config)
            namespaceName
            database
            >>= either dieT pure
        writerDigest <-
          either
            dieT
            pure
            (StatefulWriter.digestStatefulWriterSpec liveWriter)
        writerPin <-
          either
            dieT
            pure
            ( StatefulWriter.mkStatefulWriterPin
                namespaceName
                database
                (Resource.physicalIdentityText statefulUid)
                1
                writerDigest
            )
        (podName, podUidText) <-
          DatabaseShutdown.observeDatabasePod
            (kubectlVolumeTransport config)
            writerPin
            engine
            image
            >>= either dieT pure
        unless
          (podName == database <> "-0")
          (dieT "reviewed live restore target is not the accepted database Pod")
        podUid <- either dieT pure (Resource.mkPhysicalIdentity podUidText)
        selectedBackupUid <-
          maybe
            (dieT "live restore requires an accepted backup Job")
            pure
            backupUid
        let sourceInput =
              LiveBackupInput
                backupScope
                backupRevision
                selectedBackupUid
                receiptBytes
                (fst sourceVersions)
                (snd sourceVersions)
            recoveryInput =
              LiveBackupInput
                recoveryScope
                recoveryRevision
                recoveryUid
                recoveryReceipt
                (fst recoveryVersions)
                (snd recoveryVersions)
            request =
              LiveRestoreRequest
                { liveRestoreDatabase = database
                , liveRestoreNamespace = namespaceName
                , liveRestoreId = restoreKey
                , liveRestoreTargetRevision = targetRevision
                , liveRestoreStatefulUid = statefulUid
                , liveRestorePvcUid = pvcUid
                , liveRestorePodUid = podUid
                , liveRestoreSourceBackup = sourceInput
                , liveRestoreRecoveryBackup = recoveryInput
                , liveRestoreBackend = backend
                , liveRestoreSource =
                    Resource.SourceLocation
                      ("db restore/live/" <> database)
                      restoreKey
                }
        liveScope <-
          either
            (dieT . T.pack . show)
            pure
            (compileLiveRestoreScope request targetScope acceptedNative)
        case Map.lookup
          (ResourceInventory.scopeId liveScope)
          (ResourceInventory.snapshotScopes snapshot) of
          Just (_, prior)
            | prior /= liveScope ->
                dieT "live restore ID already has different accepted intent"
          _ -> pure ()
        candidate <-
          either
            (dieT . T.pack . show)
            pure
            ( ResourceInventory.composeInventory
                snapshot
                (ResourceInventory.ReplaceScope liveScope NE.:| [])
            )
        Inventory.planInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace acceptedNative)
          active
          candidate
          output
        TIO.putStrLn "Saved reviewed live PostgreSQL restore. Inspect the target, source, recovery backup, and fence before apply."
