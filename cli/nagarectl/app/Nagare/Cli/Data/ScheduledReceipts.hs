-- | Data / ScheduledReceipts. Executable-private CLI boundary.
module Nagare.Cli.Data.ScheduledReceipts
  ( runListScheduledReceipts
  , runReviewedScheduledReceiptPlan
  )
where

import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Nagare.Cli.Inventory.Adapters (inventoryKubernetesAdapter)
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Cluster.GcsJob
  ( storeObjectUrl
  )
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Backup
  ( ScheduledBackupReceipt (scheduledRecoveryPoint)
  , ScheduledReceiptExpectation
    ( scheduledFormat
    , scheduledKeep
    , scheduledObjectPrefix
    , scheduledPolicyRevision
    )
  , scheduledReceiptExpectationFromCronJob
  )
import Nagare.Inventory.BackupFreshness (BackupFreshness (Fresh), backupFreshness, renderBackupFreshness)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.ScheduledGcs (withScheduledObjectStore)
import Nagare.Inventory.ScheduledIngest
  ( ScheduledIngestRequest
      ( ScheduledIngestRequest
      , ingestBackend
      , ingestBackupId
      , ingestDatabase
      , ingestEvidence
      , ingestNamespace
      , ingestPvcUid
      , ingestScheduleUid
      , ingestSigningUid
      , ingestSource
      , ingestSourceRevision
      , ingestStatefulUid
      )
  , compileScheduledIngestScope
  , scheduledIngestEvidenceMatches
  )
import Nagare.Inventory.ScheduledReceipt
  ( ScheduledReceiptEvidence (scheduledReceipt)
  , classifyScheduledListingKeys
  , inspectScheduledReceipt
  , verifyAcceptedScheduledReceiptPoint
  )
import Nagare.Inventory.ScheduledStore
  ( ObjectReader (listObjectKeys)
  , readSecretField
  )
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (contextNameText)
import System.Exit (exitFailure)

runListScheduledReceipts :: Maybe String -> Text -> Text -> Maybe String -> Bool -> IO ()
runListScheduledReceipts mctx database namespaceName bucketArg checkFreshness = do
  active <- activeTarget mctx
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  let findAddress api kind name =
        either
          dieT
          pure
          (Resource.kubernetesAddress cluster api kind (Just namespaceName) name)
      members scope address =
        [ member
        | bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
        , member ^. #address == address
        ]
  statefulAddress <- findAddress "apps/v1" "StatefulSet" database
  let sources =
        [ (scope, member)
        | (_, scope) <-
            Map.elems
              (ResourceInventory.snapshotScopes snapshot)
        , member <- members scope statefulAddress
        ]
  (sourceScope, stateful) <- case sources of
    [single] -> pure single
    _ -> dieT "scheduled receipt listing requires one accepted database source"
  pvcAddress <- findAddress "v1" "PersistentVolumeClaim" (dbPvcName database)
  cronAddress <- findAddress "batch/v1" "CronJob" ("nagare-dbbackup-" <> database)
  signingAddress <-
    findAddress
      "v1"
      "Secret"
      ("nagare-dbbackup-" <> database <> "-signing")
  let unique label address = case members sourceScope address of
        [single] -> pure single
        _ -> dieT ("scheduled receipt listing requires one accepted " <> label)
  pvc <- unique "database PVC" pvcAddress
  cron <- unique "backup CronJob" cronAddress
  signing <- unique "backup signing Secret" signingAddress
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  let sourceIds = map (^. #identity) [stateful, pvc, cron, signing]
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNativeSelected (Set.fromList sourceIds) store history acceptedInventory
      >>= either dieT pure
  let sourceNative = acceptedNative
  unless
    (Map.size sourceNative == 4)
    (dieT "scheduled receipt listing lacks accepted private native evidence")
  sourceAdapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "scheduled receipt listing does not use a cache key"))
      sourceNative
  observed <- InventoryAdapter.adapterObserve sourceAdapter sourceIds >>= either dieT pure
  let physical resource = case Map.lookup resource (InventoryAdapter.observationMap observed) of
        Just (InventoryAdapter.ObservedPresent uid) -> pure uid
        _ -> dieT "scheduled receipt listing source, schedule, or signing key is absent or drifted"
  statefulUid <- physical (stateful ^. #identity)
  pvcUid <- physical (pvc ^. #identity)
  _ <- physical (cron ^. #identity)
  _ <- physical (signing ^. #identity)
  (_, cronBytes) <-
    maybe
      (dieT "accepted CronJob lacks native bytes")
      pure
      (Map.lookup (cron ^. #identity) sourceNative)
  backend <- resolveStoreBackend mctx bucketArg
  expectation <-
    either
      dieT
      pure
      ( scheduledReceiptExpectationFromCronJob
          backend
          namespaceName
          database
          statefulUid
          pvcUid
          cronBytes
      )
  signingKey <-
    readSecretField
      (contextNameText (active ^. #contextName))
      namespaceName
      ("nagare-dbbackup-" <> database <> "-signing")
      "HMAC_KEY"
      >>= either dieT pure
  let accepted =
        Map.fromList
          [ (selected, scope)
          | (_, scope) <-
              Map.elems
                (ResourceInventory.snapshotScopes snapshot)
          , Map.lookup "scheduled.backup.source.scope" (ResourceInventory.scopeOverrides scope)
              == Just (Resource.scopeIdText (ResourceInventory.scopeId sourceScope))
          , Just selected <- [Map.lookup "scheduled.backup.id" (ResourceInventory.scopeOverrides scope)]
          ]
      pruned =
        Set.fromList
          [ backupScope
          | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
          , Just backupScope <-
              [ Map.lookup
                  "scheduled.prune.backup.scope"
                  (ResourceInventory.scopeOverrides scope)
              ]
          ]
      prefix = scheduledObjectPrefix expectation
      bucketPrefix = storeObjectUrl backend ""
  keyPrefix <-
    maybe
      (dieT "accepted schedule has another local bucket")
      pure
      (T.stripPrefix bucketPrefix prefix)
  listed <- withScheduledObjectStore (contextNameText (active ^. #contextName)) backend $
    \reader -> do
      keys <- listObjectKeys reader keyPrefix
      case keys of
        Left reason -> pure (Left reason)
        Right allKeys -> do
          let (recognized, unknown) =
                classifyScheduledListingKeys
                  bucketPrefix
                  keyPrefix
                  (scheduledFormat expectation)
                  accepted
                  allKeys
              candidates =
                Set.toAscList
                  ( Set.fromList
                      (Map.keys accepted <> map fst recognized)
                  )
              hasPart selected isObject = (selected, isObject) `elem` recognized
          rows <- forM candidates $ \selected -> do
            let objectPresent = hasPart selected True
                receiptPresent = hasPart selected False
                acceptedScope = Map.lookup selected accepted
                acceptedPrune =
                  maybe
                    False
                    ((`Set.member` pruned) . Resource.scopeIdText . ResourceInventory.scopeId)
                    acceptedScope
                unresolved message = pure (message, Nothing)
                point = scheduledRecoveryPoint . scheduledReceipt
            (status, recoveryPoint) <- case (objectPresent, receiptPresent, acceptedPrune) of
              (False, False, True) -> unresolved "pruned"
              (True, _, True) -> unresolved "unresolved: pruned backup object reappeared"
              (_, True, True) -> unresolved "unresolved: pruned receipt reappeared"
              (False, False, False) -> unresolved "unresolved: accepted provider objects are missing"
              (True, False, False) -> unresolved "unresolved: backup object has no receipt"
              (False, True, False) -> unresolved "unresolved: receipt has no backup object"
              (True, True, False) -> case acceptedScope of
                Just scope -> do
                  let sameSchedule =
                        Map.lookup
                          "scheduled.backup.schedule.revision"
                          (ResourceInventory.scopeOverrides scope)
                          == Just (Resource.digestText (scheduledPolicyRevision expectation))
                      acceptedStatus = "accepted " <> Resource.scopeIdText (ResourceInventory.scopeId scope)
                  inspected <-
                    if sameSchedule
                      then inspectScheduledReceipt reader expectation selected signingKey
                      else pure (Left "accepted historical schedule revision")
                  case inspected of
                    Right evidence
                      | scheduledIngestEvidenceMatches scope evidence ->
                          pure (acceptedStatus, point evidence)
                    _ -> do
                      let acceptedAddress = Map.lookup "scheduled.backup.object" (ResourceInventory.scopeOverrides scope)
                          expectedPrefix = scheduledObjectPrefix expectation <> selected <> "."
                      checked <- case acceptedAddress of
                        Just address
                          | expectedPrefix `T.isPrefixOf` address ->
                              verifyAcceptedScheduledReceiptPoint reader address scope
                        _ -> pure (Left "accepted scheduled receipt has another object address")
                      pure $
                        either
                          (\reason -> ("unresolved: " <> reason, Nothing))
                          (\stamp -> (acceptedStatus, stamp))
                          checked
                Nothing -> do
                  inspected <- inspectScheduledReceipt reader expectation selected signingKey
                  pure $
                    either
                      (\reason -> ("unresolved: " <> reason, Nothing))
                      (const ("verified; ingestion pending", Nothing))
                      inspected
            pure (selected <> "  " <> status, recoveryPoint)
          pure (Right (rows <> [("unresolved provider key: " <> key, Nothing) | key <- unknown]))
  verifiedRows <- either dieT pure listed >>= either dieT pure
  now <- getCurrentTime
  let rows = map fst verifiedRows
      freshness = backupFreshness now (catMaybes (map snd verifiedRows))
  TIO.putStrLn
    ( "Scheduled retention: keep="
        <> T.pack (show (scheduledKeep expectation))
        <> " and expiry are unenforced; backups are retained by default."
    )
  if null rows
    then TIO.putStrLn "No scheduled backup objects or accepted receipts."
    else mapM_ TIO.putStrLn rows
  TIO.putStrLn (renderBackupFreshness freshness)
  when checkFreshness $ case freshness of
    Fresh _ -> pure ()
    _ -> exitFailure

runReviewedScheduledReceiptPlan ::
  Maybe String -> Text -> Text -> Maybe String -> Text -> FilePath -> IO ()
runReviewedScheduledReceiptPlan mctx database namespaceName bucketArg backupId output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  let findAddress api kind name =
        either
          dieT
          pure
          (Resource.kubernetesAddress cluster api kind (Just namespaceName) name)
      members scope address =
        [ member
        | bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
        , member ^. #address == address
        ]
  statefulAddress <- findAddress "apps/v1" "StatefulSet" database
  let sources =
        [ (scope, member)
        | (_, scope) <-
            Map.elems
              (ResourceInventory.snapshotScopes snapshot)
        , member <- members scope statefulAddress
        ]
  (sourceScope, stateful) <- case sources of
    [single] -> pure single
    _ -> dieT "scheduled receipt requires one accepted database StatefulSet"
  pvcAddress <- findAddress "v1" "PersistentVolumeClaim" (dbPvcName database)
  cronAddress <- findAddress "batch/v1" "CronJob" ("nagare-dbbackup-" <> database)
  signingAddress <-
    findAddress
      "v1"
      "Secret"
      ("nagare-dbbackup-" <> database <> "-signing")
  let unique label address = case members sourceScope address of
        [single] -> pure single
        _ -> dieT ("scheduled receipt requires one accepted " <> label)
  pvc <- unique "database PVC" pvcAddress
  cron <- unique "backup CronJob" cronAddress
  signing <- unique "backup signing Secret" signingAddress
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  revision <- case Map.lookup
    (ResourceInventory.scopeId sourceScope)
    (InventoryPlan.historyAccepted history) of
    Just (acceptedRevision, acceptedScope) | acceptedScope == sourceScope -> pure acceptedRevision
    _ -> dieT "scheduled receipt source scope differs from accepted history"
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  let sourceIds = map (^. #identity) [stateful, pvc, cron, signing]
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNativeSelected (Set.fromList sourceIds) store history acceptedInventory
      >>= either dieT pure
  let sourceNative = acceptedNative
  unless
    (Map.size sourceNative == 4)
    (dieT "scheduled receipt source lacks accepted private native evidence")
  sourceAdapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "scheduled receipt source observation does not use a cache key"))
      sourceNative
  observed <- InventoryAdapter.adapterObserve sourceAdapter sourceIds >>= either dieT pure
  let physical resource = case Map.lookup resource (InventoryAdapter.observationMap observed) of
        Just (InventoryAdapter.ObservedPresent uid) -> pure uid
        _ -> dieT "scheduled receipt source, schedule, or signing key is absent, drifted, or not ready"
  statefulUid <- physical (stateful ^. #identity)
  pvcUid <- physical (pvc ^. #identity)
  cronUid <- physical (cron ^. #identity)
  signingUid <- physical (signing ^. #identity)
  (_, cronBytes) <-
    maybe
      (dieT "accepted CronJob lacks native bytes")
      pure
      (Map.lookup (cron ^. #identity) sourceNative)
  backend <- resolveStoreBackend mctx bucketArg
  expectation <-
    either
      dieT
      pure
      ( scheduledReceiptExpectationFromCronJob
          backend
          namespaceName
          database
          statefulUid
          pvcUid
          cronBytes
      )
  let contextName = contextNameText (active ^. #contextName)
  signingResult <-
    readSecretField
      contextName
      namespaceName
      ("nagare-dbbackup-" <> database <> "-signing")
      "HMAC_KEY"
  signingKey <- either dieT pure signingResult
  candidateResult <- withScheduledObjectStore contextName backend $ \reader ->
    inspectScheduledReceipt reader expectation backupId signingKey
  evidence <- either dieT pure candidateResult >>= either dieT pure
  let request =
        ScheduledIngestRequest
          { ingestDatabase = database
          , ingestNamespace = namespaceName
          , ingestBackupId = backupId
          , ingestSourceRevision = revision
          , ingestStatefulUid = statefulUid
          , ingestPvcUid = pvcUid
          , ingestScheduleUid = cronUid
          , ingestSigningUid = signingUid
          , ingestEvidence = evidence
          , ingestBackend = backend
          , ingestSource =
              Resource.SourceLocation
                ("db backup-receipts/" <> database)
                backupId
          }
  (receiptScope, receiptNative) <-
    either
      (dieT . T.pack . show)
      pure
      (compileScheduledIngestScope request sourceScope acceptedNative)
  case Map.lookup
    (ResourceInventory.scopeId receiptScope)
    (ResourceInventory.snapshotScopes snapshot) of
    Just (_, prior) | prior /= receiptScope -> do
      let keys =
            Set.toList
              ( Map.keysSet (ResourceInventory.scopeOverrides prior)
                  `Set.union` Map.keysSet (ResourceInventory.scopeOverrides receiptScope)
              )
          changed =
            [ key
            | key <- keys
            , Map.lookup key (ResourceInventory.scopeOverrides prior)
                /= Map.lookup key (ResourceInventory.scopeOverrides receiptScope)
            ]
          beforeDeclarations =
            concatMap
              ResourceInventory.declarations
              (ResourceInventory.scopeBundles prior)
          afterDeclarations =
            concatMap
              ResourceInventory.declarations
              (ResourceInventory.scopeBundles receiptScope)
          beforeOperations =
            concatMap
              ResourceInventory.operations
              (ResourceInventory.scopeBundles prior)
          afterOperations =
            concatMap
              ResourceInventory.operations
              (ResourceInventory.scopeBundles receiptScope)
      dieT
        ( "scheduled receipt ID already has another accepted intent; changed fields: "
            <> T.intercalate "," changed
            <> "; native bundle changed: "
            <> T.pack
              ( show
                  (ResourceInventory.scopeBundles prior /= ResourceInventory.scopeBundles receiptScope)
              )
            <> "; declaration changed: "
            <> T.pack
              ( show
                  (beforeDeclarations /= afterDeclarations)
              )
            <> "; operation changed: "
            <> T.pack
              ( show
                  (beforeOperations /= afterOperations)
              )
            <> "; config digest changed: "
            <> T.pack
              ( show
                  (ResourceInventory.scopeConfigDigest prior /= ResourceInventory.scopeConfigDigest receiptScope)
              )
        )
    _ -> pure ()
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composeInventory
          snapshot
          (ResourceInventory.ReplaceScope receiptScope NE.:| [])
      )
  Inventory.planInventoryCandidateWith
    ( inventoryPlanRegistryWithNative
        active
        workspace
        (Map.union receiptNative sourceNative)
    )
    active
    candidate
    output
  TIO.putStrLn
    ( "Saved exact scheduled receipt ingestion review. Apply it to verify both stored versions. "
        <> "Scheduled keep="
        <> T.pack (show (scheduledKeep expectation))
        <> " and expiry are unenforced; backups are retained by default."
    )
