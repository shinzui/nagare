-- | Data / ScheduledReceipts. Executable-private CLI boundary.
module Nagare.Cli.Data.ScheduledReceipts
  ( ScheduledReceiptReport (..)
  , ReceiptReportError (..)
  , runListScheduledReceipts
  , IngestSelection (..)
  , runReviewedScheduledReceiptPlan
  , runReviewedVolumeReceiptPlan
  , runListVolumeReceipts
  , scheduledReceiptReport
  , scheduledRecoveryPointProbes
  , ScheduledSource (..)
  , resolveScheduledSource
  )
where

import Control.Exception (Exception, Handler (..), catches, throwIO, try)
import Control.Monad (forM, forM_)
import Data.Foldable (toList)
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
import Nagare.Database.Backup (volumeBackupScheduleName)
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
  , scheduledVolumeReceiptExpectationFromCronJob
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
      , ingestEvidence
      , ingestNamespace
      , ingestPvcUid
      , ingestScheduleUid
      , ingestSigningUid
      , ingestSource
      , ingestSourceKind
      , ingestSourceRevision
      )
  , ScheduledIngestSource (IngestDatabase, IngestVolume)
  , compileScheduledIngestBatch
  , pendingScheduledRuns
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
import Nagare.Resource.Reference (Dependency (OrderedAfter))
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
          schedules =
            Set.toAscList
              ( Set.fromList
                  [ (Resource.nameText namespace, Resource.nameText name, ResourceInventory.scopeId scope, member ^. #identity)
                  | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
                  , bundle <- ResourceInventory.scopeBundles scope
                  , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                  , Resource.Kubernetes _ "batch" kind (Just namespace) name <- [member ^. #address]
                  , Resource.nameText kind == "cronjob"
                  , any (`T.isPrefixOf` Resource.nameText name) ["nagare-dbbackup-", "nagare-volbackup-"]
                  ]
              )
      -- A database row is labelled by its name; a volume row (EP-183 M3) by
      -- its schedule. Retention is graded per schedule from accepted receipts
      -- alone; no provider read.
      fmap concat . forM schedules $ \(namespaceName, schedule, source, cron) -> do
        let retention command label = retentionProbe command label ((standardRetention,) . length <$> acceptedPastPolicy standardRetention now source cron current)
        case T.stripPrefix "nagare-dbbackup-" schedule of
          Just database -> do
            let label = namespaceName <> "/" <> database
            point <-
              recoveryPointProbe label
                <$> ( (Right . (^. #freshness) <$> scheduledReceiptScan NewestVerified mctx database namespaceName Nothing)
                        `catches` unobservable
                    )
            pure [point, retention "db prune-scheduled-backups" label]
          Nothing -> do
            let label = namespaceName <> "/" <> schedule
            point <-
              recoveryPointProbe label
                <$> ( (Right . (^. #freshness) <$> (resolveVolumeScheduledSource mctx schedule namespaceName Nothing >>= scheduledReceiptScanSource NewestVerified))
                        `catches` unobservable
                    )
            pure [point, retention "storage prune-scheduled-backups" label]
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
  , statefulUid :: !(Maybe Resource.PhysicalIdentity)
  -- ^ a database's StatefulSet; 'Nothing' for a volume (EP-183 M3)
  , pvcUid :: !Resource.PhysicalIdentity
  , signingUid :: !Resource.PhysicalIdentity
  , backend :: !StoreBackend
  , expectation :: !ScheduledReceiptExpectation
  , signingName :: !Text
  , namespaceName :: !Text
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
      , statefulUid = Just statefulUid
      , pvcUid = pvcUid
      , signingUid = signingUid
      , backend = backend
      , expectation = expectation
      , signingName = "nagare-dbbackup-" <> database <> "-signing"
      , namespaceName = namespaceName
      }

-- | The accepted source of one scheduled volume backup (EP-183 M3): the
-- CronJob, its signing Secret, and the claim it is ordered after, all in one
-- accepted scope and freshly observed as their recorded incarnations. The
-- expectation comes from the accepted CronJob bytes, exactly as for a database.
resolveVolumeScheduledSource :: Maybe String -> Text -> Text -> Maybe String -> IO ScheduledSource
resolveVolumeScheduledSource mctx schedule namespaceName bucketArg = do
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
  cronAddress <- findAddress "batch/v1" "CronJob" schedule
  signingAddress <- findAddress "v1" "Secret" (schedule <> "-signing")
  (sourceScope, cron) <-
    case [(scope, member) | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot), member <- members scope cronAddress] of
      [single] -> pure single
      _ -> reportFail "scheduled volume receipt listing requires one accepted backup CronJob"
  signing <- case members sourceScope signingAddress of
    [single] -> pure single
    _ -> reportFail "scheduled volume receipt listing requires one accepted backup signing Secret"
  pvc <-
    case [ member
         | bundle <- ResourceInventory.scopeBundles sourceScope
         , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
         , OrderedAfter (member ^. #identity) `elem` (cron ^. #dependencies)
         , Resource.Kubernetes _ "" kind _ _ <- [member ^. #address]
         , Resource.nameText kind == "persistentvolumeclaim"
         ] of
      [single] -> pure single
      _ -> reportFail "scheduled volume backup is not ordered after exactly one accepted claim"
  store <- Inventory.openTargetStoreReadOnly active >>= either (reportFail . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (reportFail . T.pack . show) pure
  acceptedInventory <-
    either
      (reportFail . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  let sourceIds = map (^. #identity) [pvc, cron, signing]
  (sourceNative, _) <-
    InventoryStatus.loadAcceptedNativeSelected (Set.fromList sourceIds) store history acceptedInventory
      >>= either reportFail pure
  unless
    (Map.size sourceNative == 3)
    (reportFail "scheduled volume receipt listing lacks accepted private native evidence")
  sourceAdapter <-
    inventoryKubernetesAdapter
      active
      (ResourceInventory.snapshotBinding snapshot)
      (\_ -> pure (Left "scheduled receipt listing does not use a cache key"))
      sourceNative
  observed <- InventoryAdapter.adapterObserve sourceAdapter sourceIds >>= either reportFail pure
  let physical resource = case Map.lookup resource (InventoryAdapter.observationMap observed) of
        Just (InventoryAdapter.ObservedPresent uid) -> pure uid
        _ -> reportFail "scheduled volume receipt listing claim, schedule, or signing key is absent or drifted"
  pvcUid <- physical (pvc ^. #identity)
  _ <- physical (cron ^. #identity)
  signingUid <- physical (signing ^. #identity)
  -- ADR 27: uploads count only from the recorded claim and signing key.
  let incarnations = InventoryStore.headIncarnations (InventoryPlan.historyHead history)
      acceptedSource what member uid = either (reportFail . ("scheduled receipt source is not the accepted volume incarnation: " <>)) pure (requireAccepted what (checkedPhysical incarnations (member ^. #identity) uid))
  _ <- acceptedSource "the PersistentVolumeClaim" pvc pvcUid
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
      (scheduledVolumeReceiptExpectationFromCronJob backend namespaceName schedule pvcUid cronBytes)
  pure
    ScheduledSource
      { active = active
      , snapshot = snapshot
      , sourceScope = sourceScope
      , statefulUid = Nothing
      , pvcUid = pvcUid
      , signingUid = signingUid
      , backend = backend
      , expectation = expectation
      , signingName = schedule <> "-signing"
      , namespaceName = namespaceName
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
scheduledReceiptScan scan mctx database namespaceName bucketArg =
  resolveScheduledSource mctx database namespaceName bucketArg >>= scheduledReceiptScanSource scan

-- | Verify one resolved source's scheduled objects and receipts (database or volume).
scheduledReceiptScanSource :: ReceiptScan -> ScheduledSource -> IO ScheduledReceiptReport
scheduledReceiptScanSource scan source = do
  let ScheduledSource active snapshot sourceScope _ _ _ backend expectation signingName namespaceName = source
  signingKey <-
    readSecretField
      (contextNameText (active ^. #contextName))
      namespaceName
      signingName
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

-- | Which scheduled runs one ingestion review names.
data IngestSelection
  = -- | One run, by its producer Job UID; it must verify.
    IngestRun !Text
  | -- | EP-183 M2 (ADR 22 amendment): every verified run that is listed with
    -- its receipt and not yet ingested. A run that does not verify is reported
    -- and left unresolved, never ingested.
    IngestAllVerified
  deriving stock (Eq, Show)

-- | Whose scheduled runs one ingestion review names: a database, or an
-- application volume's schedule (EP-183 M3). Both compile through the same
-- ingestion; a volume's only source is the claim its CronJob is ordered after.
data ReceiptSourceSelection
  = ReceiptDatabase !Text
  | -- | application, volume
    ReceiptVolume !Text !Text
  deriving stock (Eq, Show)

runReviewedScheduledReceiptPlan ::
  Maybe String -> Text -> Text -> Maybe String -> IngestSelection -> FilePath -> IO ()
runReviewedScheduledReceiptPlan mctx database = runReviewedScheduledSourceReceiptPlan mctx (ReceiptDatabase database)

-- | @storage backup-receipts APP VOLUME@: review the ingestion of a volume
-- schedule's verified runs (EP-183 M3).
runReviewedVolumeReceiptPlan ::
  Maybe String -> Text -> Text -> Text -> Maybe String -> IngestSelection -> FilePath -> IO ()
runReviewedVolumeReceiptPlan mctx app volume = runReviewedScheduledSourceReceiptPlan mctx (ReceiptVolume app volume)

-- | @storage backup-receipts APP VOLUME@ without a review: list and verify the
-- volume schedule's runs, exactly as @db backup-receipts@ lists a database's.
runListVolumeReceipts :: Maybe String -> Text -> Text -> Text -> Maybe String -> IO ()
runListVolumeReceipts mctx app volume namespaceName bucketArg = do
  report <-
    try (resolveVolumeScheduledSource mctx (volumeBackupScheduleName app volume) namespaceName bucketArg >>= scheduledReceiptScanSource FullListing)
      >>= either (\(ReceiptReportError reason) -> dieT reason) pure
  if null (report ^. #rows)
    then TIO.putStrLn "No scheduled volume backup objects or accepted receipts."
    else mapM_ TIO.putStrLn (report ^. #rows)
  TIO.putStrLn (renderBackupFreshness (report ^. #freshness))

runReviewedScheduledSourceReceiptPlan ::
  Maybe String -> ReceiptSourceSelection -> Text -> Maybe String -> IngestSelection -> FilePath -> IO ()
runReviewedScheduledSourceReceiptPlan mctx sourceSelection namespaceName bucketArg selection output = do
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
      everywhere address =
        [ (scope, member)
        | (_, scope) <-
            Map.elems
              (ResourceInventory.snapshotScopes snapshot)
        , member <- members scope address
        ]
      schedule = case sourceSelection of
        ReceiptDatabase database -> "nagare-dbbackup-" <> database
        ReceiptVolume app volume -> volumeBackupScheduleName app volume
  cronAddress <- findAddress "batch/v1" "CronJob" schedule
  signingAddress <- findAddress "v1" "Secret" (schedule <> "-signing")
  -- A database's sources are its StatefulSet and claim; a volume's only source
  -- is the one claim its accepted CronJob is ordered after (EP-183 M3).
  (sourceScope, stateful, pvc, cron) <- case sourceSelection of
    ReceiptDatabase database -> do
      statefulAddress <- findAddress "apps/v1" "StatefulSet" database
      (scope, member) <- case everywhere statefulAddress of
        [single] -> pure single
        _ -> dieT "scheduled receipt requires one accepted database StatefulSet"
      pvcAddress <- findAddress "v1" "PersistentVolumeClaim" (dbPvcName database)
      let unique label address = case members scope address of
            [single] -> pure single
            _ -> dieT ("scheduled receipt requires one accepted " <> label)
      claim <- unique "database PVC" pvcAddress
      schedule' <- unique "backup CronJob" cronAddress
      pure (scope, Just member, claim, schedule')
    ReceiptVolume _ _ -> do
      (scope, schedule') <- case everywhere cronAddress of
        [single] -> pure single
        _ -> dieT "scheduled volume receipt requires one accepted backup CronJob"
      claim <- case [ member
                    | bundle <- ResourceInventory.scopeBundles scope
                    , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                    , OrderedAfter (member ^. #identity) `elem` (schedule' ^. #dependencies)
                    , Resource.Kubernetes _ "" kind _ _ <- [member ^. #address]
                    , Resource.nameText kind == "persistentvolumeclaim"
                    ] of
        [single] -> pure single
        _ -> dieT "scheduled volume backup is not ordered after exactly one accepted claim"
      pure (scope, Nothing, claim, schedule')
  signing <- case members sourceScope signingAddress of
    [single] -> pure single
    _ -> dieT "scheduled receipt requires one accepted backup signing Secret"
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
  let sourceIds = map (^. #identity) (maybe [] pure stateful <> [pvc, cron, signing])
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNativeSelected (Set.fromList sourceIds) store history acceptedInventory
      >>= either dieT pure
  let sourceNative = acceptedNative
  unless
    (Map.size sourceNative == length sourceIds)
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
  statefulUid <- traverse (physical . (^. #identity)) stateful
  pvcUid <- physical (pvc ^. #identity)
  cronUid <- physical (cron ^. #identity)
  signingUid <- physical (signing ^. #identity)
  (_, cronBytes) <-
    maybe
      (dieT "accepted CronJob lacks native bytes")
      pure
      (Map.lookup (cron ^. #identity) sourceNative)
  backend <- resolveStoreBackend mctx bucketArg
  sourceKind <- case (sourceSelection, statefulUid) of
    (ReceiptDatabase database, Just uid) -> pure (IngestDatabase database uid)
    (ReceiptVolume _ _, Nothing) -> pure (IngestVolume schedule)
    _ -> dieT "scheduled receipt source shape is inconsistent"
  expectation <-
    either
      dieT
      pure
      ( case sourceKind of
          IngestDatabase database uid -> scheduledReceiptExpectationFromCronJob backend namespaceName database uid pvcUid cronBytes
          IngestVolume _ -> scheduledVolumeReceiptExpectationFromCronJob backend namespaceName schedule pvcUid cronBytes
      )
  let contextName = contextNameText (active ^. #contextName)
  signingResult <-
    readSecretField
      contextName
      namespaceName
      (schedule <> "-signing")
      "HMAC_KEY"
  signingKey <- either dieT pure signingResult
  let acceptedRuns =
        Map.fromList
          [ (selected, scope)
          | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
          , Map.lookup "scheduled.backup.source.scope" (ResourceInventory.scopeOverrides scope)
              == Just (Resource.scopeIdText (ResourceInventory.scopeId sourceScope))
          , Just selected <- [Map.lookup "scheduled.backup.id" (ResourceInventory.scopeOverrides scope)]
          ]
      bucketPrefix = storeObjectUrl backend ""
  inspected <- withScheduledObjectStore contextName backend $ \reader -> case selection of
    IngestRun backupId -> do
      evidence <- inspectScheduledReceipt reader expectation backupId signingKey
      pure (fmap (\checked -> ([(backupId, checked)], [])) evidence)
    IngestAllVerified -> case T.stripPrefix bucketPrefix (scheduledObjectPrefix expectation) of
      Nothing -> pure (Left "accepted schedule has another bucket")
      Just keyPrefix -> do
        entries <- listObjectEntries reader keyPrefix
        case entries of
          Left reason -> pure (Left reason)
          Right listed -> do
            let (recognized, _) =
                  classifyScheduledListingKeys bucketPrefix keyPrefix (scheduledFormat expectation) acceptedRuns (map listedKey listed)
            checked <- forM (pendingScheduledRuns acceptedRuns recognized) $ \run ->
              (run,) <$> inspectScheduledReceipt reader expectation run signingKey
            pure (Right ([(run, evidence) | (run, Right evidence) <- checked], [(run, reason) | (run, Left reason) <- checked]))
  (verified, unverified) <- either dieT pure inspected >>= either dieT pure
  forM_ unverified $ \(run, reason) ->
    TIO.putStrLn ("Not ingested (unresolved): " <> run <> ": " <> reason)
  selected <- maybe (dieT "no verified scheduled run awaits ingestion") pure (NE.nonEmpty verified)
  let request (backupId, evidence) =
        ScheduledIngestRequest
          { ingestSourceKind = sourceKind
          , ingestNamespace = namespaceName
          , ingestBackupId = backupId
          , ingestSourceRevision = revision
          , ingestPvcUid = pvcUid
          , ingestScheduleUid = cronUid
          , ingestSigningUid = signingUid
          , ingestEvidence = evidence
          , ingestBackend = backend
          , ingestSource =
              Resource.SourceLocation
                ( case sourceSelection of
                    ReceiptDatabase database -> "db backup-receipts/" <> database
                    ReceiptVolume app volume -> "storage backup-receipts/" <> app <> "/" <> volume
                )
                backupId
          , ingestAcceptedIncarnations = InventoryStore.headIncarnations (InventoryPlan.historyHead history)
          }
  compiled <-
    either
      (dieT . T.pack . show)
      pure
      (compileScheduledIngestBatch (fmap request selected) sourceScope acceptedNative)
  forM_ compiled $ \(receiptScope', _) -> do
    case Map.lookup
      (ResourceInventory.scopeId receiptScope')
      (ResourceInventory.snapshotScopes snapshot) of
      Just (_, prior) | prior /= receiptScope' -> do
        let keys =
              Set.toList
                ( Map.keysSet (ResourceInventory.scopeOverrides prior)
                    `Set.union` Map.keysSet (ResourceInventory.scopeOverrides receiptScope')
                )
            changed =
              [ key
              | key <- keys
              , Map.lookup key (ResourceInventory.scopeOverrides prior)
                  /= Map.lookup key (ResourceInventory.scopeOverrides receiptScope')
              ]
            beforeDeclarations =
              concatMap
                ResourceInventory.declarations
                (ResourceInventory.scopeBundles prior)
            afterDeclarations =
              concatMap
                ResourceInventory.declarations
                (ResourceInventory.scopeBundles receiptScope')
            beforeOperations =
              concatMap
                ResourceInventory.operations
                (ResourceInventory.scopeBundles prior)
            afterOperations =
              concatMap
                ResourceInventory.operations
                (ResourceInventory.scopeBundles receiptScope')
        dieT
          ( "scheduled receipt ID already has another accepted intent; changed fields: "
              <> T.intercalate "," changed
              <> "; native bundle changed: "
              <> T.pack
                ( show
                    (ResourceInventory.scopeBundles prior /= ResourceInventory.scopeBundles receiptScope')
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
                    (ResourceInventory.scopeConfigDigest prior /= ResourceInventory.scopeConfigDigest receiptScope')
                )
          )
      _ -> pure ()

  candidate <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composeInventory
          snapshot
          (fmap (ResourceInventory.ReplaceScope . fst) compiled)
      )
  Inventory.planInventoryCandidateWith
    ( inventoryPlanRegistryWithNative
        active
        workspace
        (Map.unions (sourceNative : map snd (toList compiled)))
    )
    active
    candidate
    output
  TIO.putStrLn ("Reviewing the ingestion of " <> T.pack (show (length compiled)) <> " verified scheduled run(s) in one transaction.")
  TIO.putStrLn
    ( "Saved exact scheduled receipt ingestion review. Apply it to verify both stored versions. "
        <> "Scheduled retention: "
        <> retentionPolicyText standardRetention
        <> "; runs past policy are removed only by a reviewed db prune-scheduled-backups."
    )
