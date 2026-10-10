-- | Data / ScheduledReceipts. Executable-private CLI boundary.
module Nagare.Cli.Data.ScheduledReceipts
  ( ScheduledReceiptReport (..)
  , ReceiptReportError (..)
  , runListScheduledReceipts
  , runReviewedScheduledReceiptPlan
  , scheduledReceiptReport
  , scheduledRecoveryPointProbes
  , ScheduledSource (..)
  , resolveScheduledSource
  )
where

import Control.Exception (Exception, Handler (..), catches, throwIO, try)
import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
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
  ( StoreBackend
  , storeObjectUrl
  )
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Backup
  ( ScheduledBackupReceipt (scheduledRecoveryPoint)
  , ScheduledReceiptExpectation
    ( ScheduledReceiptExpectation
    , scheduledFormat
    , scheduledKeep
    , scheduledObjectPrefix
    , scheduledObjective
    , scheduledPolicyRevision
    )
  , scheduledReceiptExpectationFromCronJob
  )
import Nagare.Inventory.BackupFreshness
  ( BackupFreshness (Fresh)
  , RecoveryPointGrade (RecoveryPointGrade)
  , backupFreshness
  , newestRecoveryPoint
  , renderBackupFreshness
  )
import Nagare.Inventory.BackupRetention (retentionPolicyText, standardRetention)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Identity (checkedPhysical, requireAccepted)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.ScheduledGcs (withScheduledObjectStore)
import Nagare.Inventory.ScheduledIngest
  ( ScheduledIngestRequest
      ( ScheduledIngestRequest
      , ingestAcceptedIncarnations
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
import Nagare.Inventory.ScheduledPrune (acceptedPastPolicy)
import Nagare.Inventory.ScheduledReceipt
  ( ScheduledReceiptEvidence (scheduledReceipt)
  , classifyScheduledListingKeys
  , inspectScheduledReceipt
  , verifyAcceptedScheduledReceiptPoint
  )
import Nagare.Inventory.ScheduledStore
  ( ListedObject (listedKey, listedModified)
  , ObjectReader (listObjectEntries, listObjectKeys)
  , readSecretField
  )
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Ops.Probe (Probe, recoveryPointProbe, retentionProbe)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, contextNameText)
import System.Exit (ExitCode, exitFailure)

-- | A failed observation inside 'scheduledReceiptReport'. The listing command
-- reports it and exits; status probes degrade it to an unknown result.
newtype ReceiptReportError = ReceiptReportError Text
  deriving stock (Show)
  deriving anyclass (Exception)

data ScheduledReceiptReport = ScheduledReceiptReport
  { keep :: !Int
  , rows :: ![Text]
  , freshness :: !RecoveryPointGrade
  }
  deriving stock (Generic)

reportFail :: Text -> IO a
reportFail = throwIO . ReceiptReportError

runListScheduledReceipts :: Maybe String -> Text -> Text -> Maybe String -> Bool -> IO ()
runListScheduledReceipts mctx database namespaceName bucketArg checkFreshness = do
  report <-
    try (scheduledReceiptReport mctx database namespaceName bucketArg)
      >>= either (\(ReceiptReportError reason) -> dieT reason) pure
  TIO.putStrLn
    ( "Scheduled retention: "
        <> retentionPolicyText standardRetention
        <> "; runs past policy are removed only by a reviewed db prune-scheduled-backups."
    )
  if null (report ^. #rows)
    then TIO.putStrLn "No scheduled backup objects or accepted receipts."
    else mapM_ TIO.putStrLn (report ^. #rows)
  TIO.putStrLn (renderBackupFreshness (report ^. #freshness))
  when checkFreshness $ case report ^. #freshness . #freshness of
    Fresh _ -> pure ()
    _ -> exitFailure

-- | One recovery-point probe per accepted scheduled backup in the selected
-- context, for @server status@ and @doctor@. Read-only; a source that cannot be
-- observed (including a context without inventory) is reported unknown.
scheduledRecoveryPointProbes :: Maybe String -> IO [Probe]
scheduledRecoveryPointProbes mctx =
  ( do
      snapshot <- activeTarget mctx >>= Inventory.loadTargetSnapshotReadOnly
      now <- getCurrentTime
      let current = map snd (Map.elems (ResourceInventory.snapshotScopes snapshot))
          sources =
            Set.toAscList
              ( Set.fromList
                  [ (Resource.nameText namespace, database, ResourceInventory.scopeId scope)
                  | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
                  , bundle <- ResourceInventory.scopeBundles scope
                  , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                  , Resource.Kubernetes _ "batch" kind (Just namespace) name <- [member ^. #address]
                  , Resource.nameText kind == "cronjob"
                  , Just database <- [T.stripPrefix "nagare-dbbackup-" (Resource.nameText name)]
                  ]
              )
      fmap concat . forM sources $ \(namespaceName, database, source) -> do
        let label = namespaceName <> "/" <> database
        point <-
          recoveryPointProbe label
            <$> ( (Right . (^. #freshness) <$> scheduledReceiptScan NewestVerified mctx database namespaceName Nothing)
                    `catches` unobservable
                )
        -- EP-183 M2: graded from accepted receipts alone; no provider read.
        let retention = retentionProbe label ((standardRetention,) . length <$> acceptedPastPolicy standardRetention now source current)
        pure [point, retention]
  )
    `catches` [ Handler (\(_ :: ExitCode) -> pure [recoveryPointProbe "(context)" (Left "accepted inventory is unavailable")])
              ]
  where
    unobservable =
      [ Handler (\(ReceiptReportError reason) -> pure (Left reason))
      , Handler (\(_ :: ExitCode) -> pure (Left "source or object store observation failed"))
      ]

-- | Verify every scheduled object and receipt of one accepted database source
-- and compute recovery-point freshness against the accepted schedule's
-- objective. Accepted receipts and verified uploads awaiting ingestion both
-- count (MasterPlan 23, D1): a pending upload counts only after its exact
-- stored bytes, HMAC, and current source identities have been checked here.
-- Acceptance remains the only route to restore authority.
-- | The accepted source of one scheduled database backup, freshly observed:
-- its StatefulSet, PVC and signing Secret incarnations, the store backend, and
-- the receipt expectation derived from the accepted CronJob bytes.
data ScheduledSource = ScheduledSource
  { active :: !ActiveTarget
  , snapshot :: !ResourceInventory.ScopeSnapshot
  , sourceScope :: !ResourceInventory.ScopeDeclaration
  , statefulUid :: !Resource.PhysicalIdentity
  , pvcUid :: !Resource.PhysicalIdentity
  , signingUid :: !Resource.PhysicalIdentity
  , backend :: !StoreBackend
  , expectation :: !ScheduledReceiptExpectation
  }
  deriving stock (Generic)

resolveScheduledSource :: Maybe String -> Text -> Text -> Maybe String -> IO ScheduledSource
resolveScheduledSource mctx database namespaceName bucketArg = do
  active <- activeTarget mctx
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either reportFail pure (acceptedFoundationNamespace snapshot namespaceName)
  let findAddress api kind name =
        either
          reportFail
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
    _ -> reportFail "scheduled receipt listing requires one accepted database source"
  pvcAddress <- findAddress "v1" "PersistentVolumeClaim" (dbPvcName database)
  cronAddress <- findAddress "batch/v1" "CronJob" ("nagare-dbbackup-" <> database)
  signingAddress <-
    findAddress
      "v1"
      "Secret"
      ("nagare-dbbackup-" <> database <> "-signing")
  let unique label address = case members sourceScope address of
        [single] -> pure single
        _ -> reportFail ("scheduled receipt listing requires one accepted " <> label)
  pvc <- unique "database PVC" pvcAddress
  cron <- unique "backup CronJob" cronAddress
  signing <- unique "backup signing Secret" signingAddress
  store <- Inventory.openTargetStoreReadOnly active >>= either (reportFail . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (reportFail . T.pack . show) pure
  acceptedInventory <-
    either
      (reportFail . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  let sourceIds = map (^. #identity) [stateful, pvc, cron, signing]
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNativeSelected (Set.fromList sourceIds) store history acceptedInventory
      >>= either reportFail pure
  let sourceNative = acceptedNative
  unless
    (Map.size sourceNative == 4)
    (reportFail "scheduled receipt listing lacks accepted private native evidence")
  sourceAdapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "scheduled receipt listing does not use a cache key"))
      sourceNative
  observed <- InventoryAdapter.adapterObserve sourceAdapter sourceIds >>= either reportFail pure
  let physical resource = case Map.lookup resource (InventoryAdapter.observationMap observed) of
        Just (InventoryAdapter.ObservedPresent uid) -> pure uid
        _ -> reportFail "scheduled receipt listing source, schedule, or signing key is absent or drifted"
  statefulUid <- physical (stateful ^. #identity)
  pvcUid <- physical (pvc ^. #identity)
  _ <- physical (cron ^. #identity)
  signingUid <- physical (signing ^. #identity)
  -- Pending uploads of an object that replaced the accepted incarnation
  -- outside Nagare must not count as recovery points (F49).
  -- ADR 27: an unrecorded source is refused too, never read as a match.
  let incarnations = InventoryStore.headIncarnations (InventoryPlan.historyHead history)
      acceptedSource what member uid = either (reportFail . ("scheduled receipt source is not the accepted database incarnation: " <>)) pure (requireAccepted what (checkedPhysical incarnations (member ^. #identity) uid))
  _ <- acceptedSource "the StatefulSet" stateful statefulUid
  _ <- acceptedSource "the PersistentVolumeClaim" pvc pvcUid
  -- N5: the HMAC key that authenticates the receipts is the accepted Secret's.
  _ <- acceptedSource "the signing Secret" signing signingUid
  (_, cronBytes) <-
    maybe
      (reportFail "accepted CronJob lacks native bytes")
      pure
      (Map.lookup (cron ^. #identity) sourceNative)
  backend <- resolveStoreBackend mctx bucketArg
  expectation <-
    either
      reportFail
      pure
      ( scheduledReceiptExpectationFromCronJob
          backend
          namespaceName
          database
          statefulUid
          pvcUid
          cronBytes
      )
  pure
    ScheduledSource
      { active = active
      , snapshot = snapshot
      , sourceScope = sourceScope
      , statefulUid = statefulUid
      , pvcUid = pvcUid
      , signingUid = signingUid
      , backend = backend
      , expectation = expectation
      }

-- | How much of a source's scheduled history a report verifies.
data ReceiptScan
  = -- | Every scheduled object and receipt (@db backup-receipts@).
    FullListing
  | -- | Only the newest verified recovery point, for freshness (F92: doctor
    -- downloaded every retained backup, linear in their number).
    NewestVerified
  deriving stock (Eq, Show)

scheduledReceiptReport :: Maybe String -> Text -> Text -> Maybe String -> IO ScheduledReceiptReport
scheduledReceiptReport = scheduledReceiptScan FullListing

scheduledReceiptScan :: ReceiptScan -> Maybe String -> Text -> Text -> Maybe String -> IO ScheduledReceiptReport
scheduledReceiptScan scan mctx database namespaceName bucketArg = do
  ScheduledSource active snapshot sourceScope _ _ _ backend expectation <-
    resolveScheduledSource mctx database namespaceName bucketArg
  signingKey <-
    readSecretField
      (contextNameText (active ^. #contextName))
      namespaceName
      ("nagare-dbbackup-" <> database <> "-signing")
      "HMAC_KEY"
      >>= either reportFail pure
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
      (reportFail "accepted schedule has another local bucket")
      pure
      (T.stripPrefix bucketPrefix prefix)
  listed <- withScheduledObjectStore (contextNameText (active ^. #contextName)) backend $
    \reader -> do
      entries <- listObjectEntries reader keyPrefix
      case entries of
        Left reason -> pure (Left reason)
        Right listedEntries -> do
          let allKeys = map listedKey listedEntries
              classifyKeys =
                classifyScheduledListingKeys
                  bucketPrefix
                  keyPrefix
                  (scheduledFormat expectation)
                  accepted
              (recognized, unknown) = classifyKeys allKeys
              objectTimes =
                Map.fromList
                  [ (selected, listedModified entry)
                  | entry <- listedEntries
                  , ([(selected, True)], _) <- [classifyKeys [listedKey entry]]
                  ]
              candidates =
                Set.toAscList
                  ( Set.fromList
                      (Map.keys accepted <> map fst recognized)
                  )
              hasPart selected isObject = (selected, isObject) `elem` recognized
          let row selected = do
                let objectPresent = hasPart selected True
                    receiptPresent = hasPart selected False
                    acceptedScope = Map.lookup selected accepted
                    acceptedPrune =
                      maybe
                        False
                        ((`Set.member` pruned) . Resource.scopeIdText . ResourceInventory.scopeId)
                        acceptedScope
                    unresolved message = pure (message, Nothing)
                    acceptedPoint stamp = fmap (\at -> (at, False)) stamp
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
                              pure (acceptedStatus, acceptedPoint (point evidence))
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
                              (\stamp -> (acceptedStatus, acceptedPoint stamp))
                              checked
                    Nothing -> do
                      inspected <- inspectScheduledReceipt reader expectation selected signingKey
                      pure $
                        either
                          (\reason -> ("unresolved: " <> reason, Nothing))
                          ( \evidence ->
                              ( "verified; ingestion pending"
                              , fmap (\at -> (at, True)) (point evidence)
                              )
                          )
                          inspected
                pure (selected <> "  " <> status, recoveryPoint)
          case scan of
            FullListing -> do
              rows <- forM candidates row
              pure (Right (rows <> [("unresolved provider key: " <> key, Nothing) | key <- unknown]))
            NewestVerified -> do
              newest <-
                newestRecoveryPoint
                  [(selected, Map.findWithDefault (posixSecondsToUTCTime 0) selected objectTimes) | selected <- candidates]
                  (\selected -> (\(label, point') -> (label,) <$> point') <$> row selected)
              pure (Right [(label, Just point') | Just (label, point') <- [newest]])
  verifiedRows <- either reportFail pure listed >>= either reportFail pure
  now <- getCurrentTime
  let points = catMaybes (map snd verifiedRows)
      newest = maximum (map fst points)
      latestPending =
        not (null points)
          && not (any (\(at, pending) -> at == newest && not pending) points)
  pure
    ScheduledReceiptReport
      { keep = scheduledKeep expectation
      , rows = map fst verifiedRows
      , freshness =
          RecoveryPointGrade
            (scheduledObjective expectation)
            (backupFreshness (scheduledObjective expectation) now (map fst points))
            latestPending
      }

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
          , ingestAcceptedIncarnations = InventoryStore.headIncarnations (InventoryPlan.historyHead history)
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
        <> "Scheduled retention: "
        <> retentionPolicyText standardRetention
        <> "; runs past policy are removed only by a reviewed db prune-scheduled-backups."
    )
