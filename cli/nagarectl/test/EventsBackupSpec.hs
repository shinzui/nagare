{-# LANGUAGE OverloadedStrings #-}

-- | EP-233: verified scheduled database backups become
-- @database.backup.completed@ events through the real receipt verifier and
-- the real feed materializer, over a faultable versioned bucket and a
-- virtual clock.
module EventsBackupSpec (eventsBackupTests) where

import AppDatabaseSpec (alpha, pgServer, scopeAndNative, snapshotWith)
import Control.Concurrent.Async (concurrently)
import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Data.Vector qualified as V
import Data.Yaml qualified as Yaml
import InventoryObjectOpsSpec (fakeObjectOps)
import InventoryTransactionSpec (fixtureBinding, preparedFixtureFrom)
import Nagare.Database.AppDatabase.Backup (AppDatabaseBackup (..), appDatabaseBackupKeyPrefix, renderInventoryAppDatabaseBackupCronJob)
import Nagare.Database.Backup (renderInventoryDbBackupCronJob)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Nagare.Events.Backup
import Nagare.Events.BackupCollector
import Nagare.Events.BackupSources (resolveSchedules)
import Nagare.Events.Envelope (encodeEnvelope, eventIdFor, eventIdText)
import Nagare.Events.Materialize
import Nagare.Events.Read
import Nagare.Events.Source
import Nagare.Events.Store
import Nagare.Inventory.Actor (anonymousOperator)
import Nagare.Inventory.Adapter (AdapterExecution (AdapterEffectCompleted), RecoveryDecision (RecoverySafeToRetry))
import Nagare.Inventory.Backup (ScheduledReceiptExpectation, scheduledReceiptExpectationFromCronJob)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (HourlyRecoveryPoint))
import Nagare.Inventory.BackupReceipt (scheduledAppDatabaseReceiptExpectationFromCronJob)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (Converged), applyReviewed)
import Nagare.Inventory.Journal (mkTransactionId)
import Nagare.Inventory.ScheduledStatus (ScheduledStatusKind (..), scheduledStatusSources)
import Nagare.Inventory.ScheduledStore (StoredObject (..), VersionedObject (..), VersionedReader (..))
import Nagare.Inventory.Store (InventoryStore, ScopeRevision (..), initializeStore, newObjectStore)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Inventory.Store.S3 (parseVersionListing)
import Nagare.Resource.Inventory (Declaration (Managed), declarations, scopeBundles, snapshotScopes)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.DataFixtures (localMinioBackend)
import Test.Tasty
import Test.Tasty.HUnit

eventsBackupTests :: TestTree
eventsBackupTests =
  testGroup
    "Events.Backup"
    [ testCase "one verified scheduled PostgreSQL run is one completion event, after a restart too" $ do
        world <- newWorld
        activate world
        uploadRun world run1 (minutes 1) validRun
        outcome <- collect world
        (outcome ^. #verified, outcome ^. #published) @?= (1, 1)
        events <- publishedEvents world
        length events @?= 1
        case events of
          [BackupCompletedPayload completion] -> do
            completion ^. #origin @?= ScheduledBackup
            completion ^. #run @?= run1
            completion ^. #archive . #version @?= "v1"
            completion ^. #recoveryPoint @?= Just "2026-11-17T00:00:00Z"
            completion ^. #completedAt @?= Just "2026-11-17T00:01:01Z"
            completion ^. #backup @?= backupIdFor ScheduledBackup ownerScope run1 (StoredVersion (archiveAddress run1) "v1") (StoredVersion (receiptAddress run1) "v2")
          other -> assertFailure ("expected one completion, got " <> show other)
        again <- collect world
        (again ^. #published, again ^. #known, again ^. #wrote) @?= (0, 1, False)
        restarted <- restart world
        afterRestart <- collect restarted
        (afterRestart ^. #published, afterRestart ^. #known) @?= (0, 1)
        stillOne <- publishedEvents restarted
        length stillOne @?= 1
    , testCase "runs present at activation are the baseline; later receipts, even for an earlier archive, are announced" $ do
        world <- newWorld
        uploadRun world run4 (minutes 0) validRun
        uploadRun world run1 (minutes 1) validRun
        uploadArchiveOnly world run2 (minutes 2)
        activate world
        uploadReceiptFor world run2 (minutes 3)
        uploadRun world run3 (minutes 4) validRun
        outcome <- collect world
        outcome ^. #published @?= 2
        runs <- map completionRun <$> publishedEvents world
        runs @?= [Just run2, Just run3]
    , testCase "a run that fails verification stays pending with its reason and never starves a later valid run" $ do
        world <- newWorld
        activate world
        uploadRun world run1 (minutes 1) validRun {signingHex = T.replicate 64 "b"}
        uploadRun world run2 (minutes 2) validRun {pvc = otherUid}
        uploadRun world run3 (minutes 3) validRun {archiveBytes = "changed", signedArchive = "original"}
        uploadRun world run4 (minutes 4) validRun {archiveBytes = "trunc", signedArchive = "truncated archive"}
        uploadRun world run5 (minutes 5) validRun {metadataEdit = KeyMap.insert "keep" (Aeson.Number 3)}
        uploadReceiptOnly world run6 (minutes 6)
        uploadRun world run7 (minutes 7) validRun
        outcome <- collect world
        outcome ^. #published @?= 1
        map fst (outcome ^. #failures) @?= [run1, run2, run3, run4, run5, run6]
        outcome ^. #pendingRuns @?= 6
        outcome ^. #oldestPending @?= Just (minutes 10)
        assertBool "each reason is named" (all (not . T.null . snd) (outcome ^. #failures))
        runs <- map completionRun <$> publishedEvents world
        runs @?= [Just run7]
        -- Backoff: the next cycle five minutes later does not retry yet.
        advance world 60
        retry <- collect world
        (retry ^. #failures, retry ^. #pendingRuns) @?= ([], 6)
    , testCase "a pending run deleted by its owner leaves the pending set" $ do
        world <- newWorld
        activate world
        uploadReceiptOnly world run1 (minutes 1)
        first' <- collect world
        first' ^. #pendingRuns @?= 1
        deleteObject world (receiptKey run1)
        advance world 600
        second' <- collect world
        second' ^. #pendingRuns @?= 0
    , testCase "a signing Secret that is not the recorded incarnation verifies nothing" $ do
        world <- newWorld
        activate world
        uploadRun world run1 (minutes 1) validRun
        writeIORef (world ^. #secretUid) otherUid
        outcome <- collect world
        outcome ^. #published @?= 0
        map snd (outcome ^. #failures) @?= ["the signing Secret is not the recorded incarnation"]
    , testCase "a receipt of an earlier accepted schedule revision verifies under that revision" $ do
        world <- newWorldWith [currentExpectation, olderExpectation]
        activate world
        uploadRun world run1 (minutes 1) validRun {metadataEdit = const olderMetadata}
        outcome <- collect world
        outcome ^. #published @?= 1
    , testCase "Redis, ClickHouse and app-database runs verify under their own formats and key spaces" $
        for_ [redisVariant, clickhouseVariant, appDatabaseVariant] $ \v -> do
          world <- newWorldFor v
          activate world
          uploadRun world run1 (minutes 1) validRun
          -- A run under another schedule's key space is not this schedule's.
          putObjectAt world ("databases/other/" <> run2 <> ".sql.gz.receipt.json") (receiptBytes run2 validRun) (minutes 2)
          outcome <- collect world
          (v ^. #label, outcome ^. #published, outcome ^. #failures) @?= (v ^. #label, 1, [])
          archives <- map (fmap (^. #name) . completionArchive) <$> publishedEvents world
          archives @?= [Just ("s3://nagare-backups/" <> variantArchiveKey v run1)]
    , testCase "a collector that dies between its observation and its head write is adopted; the event appears once" $ do
        world <- newWorld
        activate world
        uploadRun world run1 (minutes 1) validRun
        armFault world "receipts/head.json" NotLanded 3
        failed <- collect' world
        assertBool "the cycle reports its failure" (isLeft failed)
        advance world 60
        recovered <- collect world
        recovered ^. #wrote @?= True
        events <- publishedEvents world
        map completionRun events @?= [Just run1]
    , testCase "a lost acknowledgement of the collector head is settled as written" $ do
        world <- newWorld
        activate world
        uploadRun world run1 (minutes 1) validRun
        armFault world "receipts/head.json" LandedLost 1
        _ <- collect world
        again <- collect world
        (again ^. #published, again ^. #wrote) @?= (0, False)
        events <- publishedEvents world
        length events @?= 1
    , testCase "overlapping collectors publish each backup once" $ do
        world <- newWorld
        activate world
        uploadRun world run1 (minutes 1) validRun
        uploadRun world run2 (minutes 2) validRun
        (left, right) <- concurrently (collect' world) (collect' world)
        assertBool "both cycles finish or contend" (isRight left || isRight right)
        _ <- collect world
        runs <- map completionRun <$> publishedEvents world
        runs @?= [Just run1, Just run2]
    , testCase "a cycle lists each key-space root once and downloads only unverified versions" $ do
        world <- newWorld
        for_ [1 .. 1000 :: Int] $ \n -> uploadRun world (runNumbered n) (addUTCTime (fromIntegral n) baseTime) validRun
        activate world
        resetCounters world
        uploadRun world run1 (minutes 1000) validRun
        outcome <- collect world
        outcome ^. #published @?= 1
        (lists, downloaded) <- counters world
        -- 2002 objects under one root: three pages of 1000.
        lists @?= 3
        downloaded @?= runBytes run1
        resetCounters world
        idle <- collect world
        idle ^. #published @?= 0
        (idleLists, idleBytes) <- counters world
        (idleLists, idleBytes) @?= (3, 0)
    , testCase "verification past the budget is deferred, not skipped" $ do
        world <- newWorld
        activate world
        for_ [run1, run2, run3] $ \run' -> uploadRun world run' (minutes 1) validRun
        first' <- collectWith world (defaultCollectBudget & #verifications .~ 2)
        (first' ^. #published, first' ^. #deferred) @?= (2, 1)
        second' <- collectWith world (defaultCollectBudget & #verifications .~ 2)
        (second' ^. #published, second' ^. #deferred) @?= (1, 0)
    , testCase "a listing failure changes nothing" $ do
        world <- newWorld
        activate world
        uploadRun world run1 (minutes 1) validRun
        writeIORef (world ^. #listFault) True
        failed <- collect' world
        case failed of
          Left (CollectListing _ _) -> pure ()
          other -> assertFailure ("expected a listing failure, got " <> show other)
        writeIORef (world ^. #listFault) False
        outcome <- collect world
        outcome ^. #published @?= 1
    , testCase "collection needs activation" $ do
        world <- newWorld
        outcome <- collect' world
        outcome @?= Left CollectNotActive
    , testCase "a published backup event carries no signing key, receipt body or credential" $ do
        world <- newWorld
        activate world
        uploadRun world run1 (minutes 1) validRun
        _ <- collect world
        _ <- publishedEvents world
        page <- readPage (world ^. #feed) fixtureBinding readRequest >>= either (assertFailure . show) pure
        let bodies = map (encodeEnvelope . (^. #envelope)) (page ^. #entries)
        length bodies @?= 1
        for_ bodies $ \body -> for_ [TE.encodeUtf8 signingKeyHex, "hmac", "HMAC", "jobUid", "signing"] $ \needle ->
          assertBool ("the event holds " <> show needle) (not (needle `BS.isInfixOf` body))
    , testCase "the collector resolves database and app-database schedules from recorded incarnations alone" $ do
        let (pgScope, _) = scopeAndNative pgServer (alpha Postgres)
            accepted = snapshotWith [pgServer] [pgScope]
            members = [m ^. #identity | (_, scope') <- Map.elems (snapshotScopes accepted), bundle <- scopeBundles scope', Managed m <- declarations bundle]
            recorded = Map.fromList [(resource, ok (mkPhysicalIdentity ("uid-" <> T.pack (show n)))) | (n, resource) <- zip [1 :: Int ..] members]
            expected = [status ^. #label | status <- scheduledStatusSources accepted, case status ^. #kind of VolumeStatus _ -> False; _ -> True]
            resolved = resolveSchedules accepted recorded
        map fst resolved @?= expected
        length expected @?= 2
        [(label', reason') | (label', Left reason') <- resolved] @?= []
        assertBool "an unrecorded source resolves nothing" (all (isLeft . snd) (resolveSchedules accepted Map.empty))
    , testCase "a backup's identity holds no route, and manual and scheduled runs never collide" $ do
        let archive = StoredVersion "s3://b/a" "1"
            receipt = StoredVersion "s3://b/a.receipt.json" "2"
        backupIdFor ScheduledBackup ownerScope "r" archive receipt @?= backupIdFor ScheduledBackup ownerScope "r" archive receipt
        assertBool "origins are separate key spaces" (backupIdFor ScheduledBackup ownerScope "r" archive receipt /= backupIdFor ManualBackup ownerScope "r" archive receipt)
        assertBool "versions are identity" (backupIdFor ScheduledBackup ownerScope "r" archive receipt {version = "3"} /= backupIdFor ScheduledBackup ownerScope "r" archive receipt)
    , testCase "a reviewed scheduled ingestion is one acceptance, and completes the backup under the collector's key, in either order" $ do
        -- Collector first: its completion is published, the ingestion's is the same event.
        world <- newWorld
        activate world
        uploadRun world run1 (minutes 1) validRun
        _ <- collect world
        _ <- publishedEvents world
        ingested <- ingestedInventory
        afterIngestion <- materializeWith world ingested
        kindsOf afterIngestion @?= [DatabaseBackupCompleted, ChangeApplied, DatabaseBackupAccepted]
        assertCrossReferenced afterIngestion
        -- Ingestion first: the collector's later completion is the same event.
        world' <- newWorld
        activate world'
        uploadRun world' run1 (minutes 1) validRun
        ingested' <- ingestedInventory
        _ <- materializeWith world' ingested'
        _ <- collect world'
        both <- materializeWith world' ingested'
        -- Facts are key-ordered: here the acceptance is published first, after
        -- the ingestion's change.applied.
        kindsOf both @?= [ChangeApplied, DatabaseBackupAccepted, DatabaseBackupCompleted]
        assertCrossReferenced both
    , testCase "a later revision keeping the pins, a volume run and a recorded manual receipt announce nothing; a new manual record announces completion and acceptance" $ do
        let input scopes' = SourceInput (fixtureBinding ^. #identity) (ok (mkTransactionId "tx-1")) (contentDigest "review") "operator-cli" Map.empty Map.empty Map.empty Map.empty [] anonymousOperator Nothing Map.empty Map.empty [] Map.empty (Map.fromList scopes')
            revision = ScopeRevision (ok (mkScopeGeneration 2)) (contentDigest "scope")
            produced = (backupProducer ^. #produce) . input
            receiptScope = ok (mkScopeId Platform "receipt-1")
        produced [(receiptScope, ScopeView revision ingestionPins Nothing)] `lengthIs` 2
        -- A bulk ingestion: one acceptance per newly accepted backup.
        let secondRun = Map.insert "scheduled.backup.id" run2 (Map.insert "scheduled.backup.object.version" "v9" ingestionPins)
        produced [(receiptScope, ScopeView revision ingestionPins Nothing), (ok (mkScopeId Platform "receipt-2"), ScopeView revision secondRun Nothing)] `lengthIs` 4
        produced [(receiptScope, ScopeView revision ingestionPins (Just ingestionPins))] `lengthIs` 0
        produced [(receiptScope, ScopeView revision (Map.insert "scheduled.backup.source.kind" "volume" ingestionPins) Nothing)] `lengthIs` 0
        produced [(receiptScope, ScopeView revision manualRecord (Just (Map.delete "backup.record" manualRecord)))] `lengthIs` 2
        produced [(receiptScope, ScopeView revision manualRecord (Just manualRecord))] `lengthIs` 0
        case [candidate ^. #payload | PublicCandidate candidate <- produced [(receiptScope, ScopeView revision manualRecord Nothing)]] of
          [BackupCompletedPayload completion, BackupAcceptedPayload acceptance] -> do
            completion ^. #origin @?= ManualBackup
            acceptance ^. #backup @?= completion ^. #backup
            acceptance ^. #receiptScope @?= receiptScope
          other -> assertFailure ("expected a manual completion and acceptance, got " <> show other)
    , testCase "an S3 version listing keeps only live versions and names its next page" $ do
        let page =
              "<ListVersionsResult><IsTruncated>true</IsTruncated><NextKeyMarker>databases/x/b</NextKeyMarker><NextVersionIdMarker>v9</NextVersionIdMarker>"
                <> "<Version><Key>databases/x/a</Key><VersionId>v2</VersionId><IsLatest>true</IsLatest><LastModified>2026-11-17T00:00:01.000Z</LastModified><Size>3</Size></Version>"
                <> "<Version><Key>databases/x/a</Key><VersionId>v1</VersionId><IsLatest>false</IsLatest><LastModified>2026-11-17T00:00:00.000Z</LastModified><Size>2</Size></Version>"
                <> "<DeleteMarker><Key>databases/x/b</Key><VersionId>v9</VersionId><IsLatest>true</IsLatest><LastModified>2026-11-17T00:00:02.000Z</LastModified></DeleteMarker>"
                <> "<Version><Key>databases/x/b</Key><VersionId>v8</VersionId><IsLatest>false</IsLatest><LastModified>2026-11-17T00:00:00.000Z</LastModified><Size>4</Size></Version>"
                <> "</ListVersionsResult>"
        case parseVersionListing "databases/" page of
          Right (live, next) -> do
            map (\o -> (versionedKey o, versionedVersion o, versionedSize o)) live @?= [("databases/x/a", "v2", 3)]
            next @?= Just ("databases/x/b", "v9")
          Left reason -> assertFailure (T.unpack reason)
        assertBool "a page escaping its prefix refuses" (isLeft (parseVersionListing "other/" page))
        assertBool "a truncated page without markers refuses" (isLeft (parseVersionListing "databases/" "<ListVersionsResult><IsTruncated>true</IsTruncated></ListVersionsResult>"))
    ]

-- * Acceptance fixtures

-- | An inventory whose one converged transaction is a reviewed ingestion of
-- run1 at the versions the world uploads (the fixture's changed scope
-- carries the ingestion pins).
ingestedInventory :: IO InventoryStore
ingestedInventory = do
  ops' <- fakeObjectOps
  store <- newObjectStore ops' fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
  (reviewed, registry) <- preparedFixtureFrom "test/fixtures/inventory/valid-backup-ingestion.json" "operator-cli" id store (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure RecoverySafeToRetry) (\_ r -> r)
  applied <- applyReviewed store registry reviewed >>= either (assertFailure . show) pure
  case applied of
    Converged _ -> pure store
    other -> assertFailure ("the ingestion did not converge: " <> show other)

materializeWith :: World -> InventoryStore -> IO [EventPayload]
materializeWith world store = do
  _ <- materializeOnce store (world ^. #feed) fixtureBinding defaultBudget (pure "2026-11-17T01:00:00Z") >>= either (assertFailure . show) pure
  page <- readPage (world ^. #feed) fixtureBinding readRequest >>= either (assertFailure . show) pure
  pure [entry ^. #envelope . #payload | entry <- page ^. #entries]

kindsOf :: [EventPayload] -> [EventKind]
kindsOf = map payloadKind

assertCrossReferenced :: [EventPayload] -> Assertion
assertCrossReferenced payloads = case ([c | BackupCompletedPayload c <- payloads], [a | BackupAcceptedPayload a <- payloads]) of
  ([completion], [acceptance]) -> do
    completion ^. #backup @?= backupIdFor ScheduledBackup ownerScope run1 (StoredVersion (archiveAddress run1) "v1") (StoredVersion (receiptAddress run1) "v2")
    acceptance ^. #backup @?= completion ^. #backup
    acceptance ^. #completion @?= eventIdText (eventIdFor (fixtureBinding ^. #identity) (completionKey (completion ^. #backup)))
  _ -> assertFailure ("expected one completion and one acceptance, got " <> show payloads)

lengthIs :: [a] -> Int -> Assertion
lengthIs items n = length items @?= n

ingestionPins, manualRecord :: Map Text Text
ingestionPins =
  Map.fromList
    [ ("scheduled.backup.id", run1)
    , ("scheduled.backup.object", archiveAddress run1)
    , ("scheduled.backup.object.version", "v1")
    , ("scheduled.backup.object.length", "13")
    , ("scheduled.backup.object.sha256", T.replicate 64 "a")
    , ("scheduled.backup.receipt", receiptAddress run1)
    , ("scheduled.backup.receipt.version", "v2")
    , ("scheduled.backup.receipt.digest", T.replicate 64 "b")
    , ("scheduled.backup.source.scope", "platform:database-mydb")
    ]
manualRecord =
  Map.fromList
    [ ("backup.record", "verified-v1")
    , ("backup.id", "manual-1")
    , ("backup.source.scope", "platform:database-mydb")
    , ("backup.object", "s3://nagare-backups/manual-databases/personal/mydb/manual-1.sql.gz")
    , ("backup.object.version", "m1")
    , ("backup.object.length", "10")
    , ("backup.object.sha256", T.replicate 64 "c")
    , ("backup.receipt", "s3://nagare-backups/manual-databases/personal/mydb/manual-1.sql.gz.receipt.json")
    , ("backup.receipt.version", "m2")
    , ("backup.receipt.digest", T.replicate 64 "d")
    ]

-- * The world

data Landing = NotLanded | LandedLost

data World = World
  { bucket :: !(IORef (Map Text [(Text, ByteString, UTCTime)]))
  , versions :: !(IORef Int)
  , lists :: !(IORef Int)
  , downloaded :: !(IORef Int)
  , listFault :: !(IORef Bool)
  , secretUid :: !(IORef PhysicalIdentity)
  , now :: !(IORef UTCTime)
  , feedOps :: !ObjectOps
  , fault :: !(IORef (Maybe (Text, Landing, Int)))
  , feed :: !FeedStore
  , inventory :: !InventoryStore
  , schedules :: ![BackupSchedule]
  , variant :: !Variant
  }
  deriving stock (Generic)

newWorld :: IO World
newWorld = newWorldFor postgresVariant

newWorldWith :: [ScheduledReceiptExpectation] -> IO World
newWorldWith expectations = newWorldFor (postgresVariant & #expectations .~ expectations)

newWorldFor :: Variant -> IO World
newWorldFor variant' = do
  bucket' <- newIORef Map.empty
  versions' <- newIORef 0
  lists' <- newIORef 0
  downloaded' <- newIORef 0
  listFault' <- newIORef False
  secret' <- newIORef secretIncarnation
  now' <- newIORef (minutes 10)
  fault' <- newIORef Nothing
  base <- fakeObjectOps
  let ops = faulted fault' base
  feed' <- newFeedStore ops
  inventoryOps <- fakeObjectOps
  inventory' <- newObjectStore inventoryOps fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
  _ <- initializeStore inventory' fixtureBinding "client-a" >>= either (assertFailure . show) pure
  _ <- enableFeed feed' fixtureBinding "epoch-1" initialCheckpoint >>= either (assertFailure . show) pure
  pure (World bucket' versions' lists' downloaded' listFault' secret' now' ops fault' feed' inventory' [scheduleFor variant'] variant')

-- | The same stores, read by a new process: no in-memory state survives.
restart :: World -> IO World
restart world = do
  feed' <- newFeedStore (world ^. #feedOps)
  pure (world & #feed .~ feed')

-- | The next @count@ puts of one name fail.
faulted :: IORef (Maybe (Text, Landing, Int)) -> ObjectOps -> ObjectOps
faulted armed base =
  base
    { putObject = \condition name@(ObjectName key) bytes -> do
        fire <- readIORef armed
        case fire of
          Just (target, landing, count) | target == key -> do
            writeIORef armed (if count > 1 then Just (target, landing, count - 1) else Nothing)
            case landing of
              NotLanded -> pure (PutUnknown "injected failure")
              LandedLost -> putObject base condition name bytes >> pure (PutUnknown "injected lost acknowledgement")
          _ -> putObject base condition name bytes
    }

armFault :: World -> Text -> Landing -> Int -> IO ()
armFault world key landing count = writeIORef (world ^. #fault) (Just (key, landing, count))

ops :: World -> CollectorOps
ops world =
  CollectorOps
    { objects = VersionedReader (listLive world) (readAt world)
    , bucketAddress = "s3://nagare-backups/"
    , signingKey = \_ -> Right . (,) signingKeyHex <$> readIORef (world ^. #secretUid)
    , clock = readIORef (world ^. #now)
    }

listLive :: World -> Text -> IO (Either Text [VersionedObject])
listLive world prefix = do
  fire <- readIORef (world ^. #listFault)
  if fire
    then pure (Left "injected listing failure")
    else do
      objects' <- readIORef (world ^. #bucket)
      let live = [VersionedObject key version (toInteger (BS.length bytes)) modified | (key, entries) <- Map.toAscList objects', prefix `T.isPrefixOf` key, (version, bytes, modified) : _ <- [reverse entries]]
      -- One request per page of 1000, as the providers page.
      modifyIORef' (world ^. #lists) (+ max 1 ((length live + 999) `div` 1000))
      pure (Right live)

readAt :: World -> Text -> Text -> FilePath -> IO (Either Text StoredObject)
readAt world key version path = do
  objects' <- readIORef (world ^. #bucket)
  case [bytes | (v, bytes, _) <- Map.findWithDefault [] key objects', v == version] of
    [bytes] -> do
      BS.writeFile path bytes
      modifyIORef' (world ^. #downloaded) (+ BS.length bytes)
      pure (Right (StoredObject version (toInteger (BS.length bytes))))
    _ -> pure (Left "no such object version")

putObjectAt :: World -> Text -> ByteString -> UTCTime -> IO ()
putObjectAt world key bytes modified = do
  n <- atomicModifyIORef' (world ^. #versions) (\v -> (v + 1, v + 1))
  modifyIORef' (world ^. #bucket) (Map.insertWith (flip (<>)) key [("v" <> T.pack (show n), bytes, modified)])

deleteObject :: World -> Text -> IO ()
deleteObject world key = modifyIORef' (world ^. #bucket) (Map.delete key)

advance :: World -> Integer -> IO ()
advance world seconds = modifyIORef' (world ^. #now) (addUTCTime (fromIntegral seconds))

resetCounters :: World -> IO ()
resetCounters world = writeIORef (world ^. #lists) 0 >> writeIORef (world ^. #downloaded) 0

counters :: World -> IO (Int, Int)
counters world = (,) <$> readIORef (world ^. #lists) <*> readIORef (world ^. #downloaded)

activate :: World -> IO ()
activate world = void (activateCollection (world ^. #feed) fixtureBinding (ops world) (world ^. #schedules) >>= either (assertFailure . show) pure)

collect' :: World -> IO (Either CollectError CollectOutcome)
collect' world = collectOnce (world ^. #feed) fixtureBinding (ops world) defaultCollectBudget (world ^. #schedules)

collect :: World -> IO CollectOutcome
collect world = collectWith world defaultCollectBudget

collectWith :: World -> CollectBudget -> IO CollectOutcome
collectWith world budget = collectOnce (world ^. #feed) fixtureBinding (ops world) budget (world ^. #schedules) >>= either (assertFailure . show) pure

-- | Materialize, then every event in the feed.
publishedEvents :: World -> IO [EventPayload]
publishedEvents world = do
  _ <- materializeOnce (world ^. #inventory) (world ^. #feed) fixtureBinding defaultBudget (pure "2026-11-17T01:00:00Z") >>= either (assertFailure . show) pure
  page <- readPage (world ^. #feed) fixtureBinding readRequest >>= either (assertFailure . show) pure
  pure [entry ^. #envelope . #payload | entry <- page ^. #entries]

completionArchive :: EventPayload -> Maybe StoredVersion
completionArchive = \case
  BackupCompletedPayload completion -> Just (completion ^. #archive)
  _ -> Nothing

completionRun :: EventPayload -> Maybe Text
completionRun payload' = case payload' of
  BackupCompletedPayload completion -> Just (completion ^. #run)
  _ -> Nothing

-- * Runs

data RunSpec = RunSpec
  { signingHex :: !Text
  , pvc :: !PhysicalIdentity
  , archiveBytes :: !ByteString
  , signedArchive :: !ByteString
  , metadataEdit :: !(KeyMap.KeyMap Aeson.Value -> KeyMap.KeyMap Aeson.Value)
  }
  deriving stock (Generic)

validRun :: RunSpec
validRun = RunSpec signingKeyHex claimIncarnation "archive bytes" "archive bytes" id

uploadRun :: World -> Text -> UTCTime -> RunSpec -> IO ()
uploadRun world run' at spec = do
  let v = world ^. #variant
  putObjectAt world (variantArchiveKey v run') (spec ^. #archiveBytes) at
  putObjectAt world (variantArchiveKey v run' <> ".receipt.json") (receiptBytesFor v run' spec) (addUTCTime 1 at)

uploadArchiveOnly :: World -> Text -> UTCTime -> IO ()
uploadArchiveOnly world run' = putObjectAt world (variantArchiveKey (world ^. #variant) run') (validRun ^. #archiveBytes)

uploadReceiptFor :: World -> Text -> UTCTime -> IO ()
uploadReceiptFor world run' = putObjectAt world (variantArchiveKey (world ^. #variant) run' <> ".receipt.json") (receiptBytesFor (world ^. #variant) run' validRun)

uploadReceiptOnly :: World -> Text -> UTCTime -> IO ()
uploadReceiptOnly = uploadReceiptFor

runBytes :: Text -> Int
runBytes run' = BS.length (receiptBytes run' validRun) + BS.length (validRun ^. #archiveBytes)

receiptBytes :: Text -> RunSpec -> ByteString
receiptBytes = receiptBytesFor postgresVariant

receiptBytesFor :: Variant -> Text -> RunSpec -> ByteString
receiptBytesFor v run' spec =
  LBS.toStrict (Aeson.encode (Aeson.object ["version" Aeson..= (5 :: Int), "payload" Aeson..= payload, "hmacSha256" Aeson..= signature]))
  where
    payload =
      Aeson.object
        [ "sha256" Aeson..= digestText (contentDigest (spec ^. #signedArchive))
        , "jobUid" Aeson..= run'
        , "object" Aeson..= ("s3://nagare-backups/" <> variantArchiveKey v run')
        , "source" Aeson..= Aeson.object ["statefulSetUid" Aeson..= physicalIdentityText statefulIncarnation, "pvcUid" Aeson..= physicalIdentityText (spec ^. #pvc)]
        , "backup" Aeson..= Aeson.Object ((spec ^. #metadataEdit) (v ^. #metadata))
        , "recoveryPoint" Aeson..= ("2026-11-17T00:00:00Z" :: Text)
        ]
    key = BS.pack (hexBytes (T.unpack (spec ^. #signingHex)))
    signature = T.pack (show (hmacGetDigest (hmac key (canonical payload) :: HMAC SHA256)))
    hexBytes (high : low : rest) = fromIntegral (hexDigit high * 16 + hexDigit low) : hexBytes rest
    hexBytes _ = []
    hexDigit c = if c >= 'a' then fromEnum c - fromEnum 'a' + 10 else fromEnum c - fromEnum '0'

canonical :: Aeson.Value -> ByteString
canonical = either (error . T.unpack) id . canonicalValue

archiveKey, receiptKey, archiveAddress, receiptAddress :: Text -> Text
archiveKey = variantArchiveKey postgresVariant
receiptKey run' = archiveKey run' <> ".receipt.json"
archiveAddress run' = "s3://nagare-backups/" <> archiveKey run'
receiptAddress run' = "s3://nagare-backups/" <> receiptKey run'

run1, run2, run3, run4, run5, run6, run7 :: Text
run1 = runNumbered 10001
run2 = runNumbered 10002
run3 = runNumbered 10003
run4 = runNumbered 10004
run5 = runNumbered 10005
run6 = runNumbered 10006
run7 = runNumbered 10007

-- | A Kubernetes UID shape, distinct per number.
runNumbered :: Int -> Text
runNumbered n = "11111111-1111-1111-1111-" <> T.justifyRight 12 '0' (T.pack (show n))

baseTime :: UTCTime
baseTime = UTCTime (fromGregorian 2026 11 17) 0

minutes :: Integer -> UTCTime
minutes n = addUTCTime (fromIntegral (n * 60)) baseTime

-- * The accepted schedule

ok :: Either Text a -> a
ok = either (error . T.unpack) id

ownerScope :: ScopeId
ownerScope = ok (mkScopeId Platform "database-mydb")

statefulIncarnation, claimIncarnation, secretIncarnation, otherUid :: PhysicalIdentity
statefulIncarnation = ok (mkPhysicalIdentity "22222222-2222-2222-2222-222222222222")
claimIncarnation = ok (mkPhysicalIdentity "33333333-3333-3333-3333-333333333333")
secretIncarnation = ok (mkPhysicalIdentity "44444444-4444-4444-4444-444444444444")
otherUid = ok (mkPhysicalIdentity "55555555-5555-5555-5555-555555555555")

signingKeyHex :: Text
signingKeyHex = T.replicate 64 "a"

cronNative :: Int -> ByteString
cronNative keep = canonical (either (error . show) id (Yaml.decodeEither' (renderInventoryDbBackupCronJob HourlyRecoveryPoint "personal" "mydb" Postgres "18" localMinioBackend keep) :: Either Yaml.ParseException Aeson.Value))

expectationFor :: Int -> ScheduledReceiptExpectation
expectationFor keep = ok (scheduledReceiptExpectationFromCronJob localMinioBackend "personal" "mydb" statefulIncarnation claimIncarnation (cronNative keep))

currentExpectation, olderExpectation :: ScheduledReceiptExpectation
currentExpectation = expectationFor 7
olderExpectation = expectationFor 5

-- | The receipt metadata an accepted CronJob signs into its runs.
metadataOf :: ByteString -> KeyMap.KeyMap Aeson.Value
metadataOf native = case Aeson.decodeStrict native of
  Just value
    | Just (Aeson.Array containers) <- path ["spec", "jobTemplate", "spec", "template", "spec", "containers"] value
    , [text] <-
        [ text
        | container <- V.toList containers
        , path ["name"] container == Just (Aeson.String "upload")
        , Just (Aeson.Array env) <- [path ["env"] container]
        , entry <- V.toList env
        , path ["name"] entry == Just (Aeson.String "BACKUP_RECEIPT_METADATA")
        , Just (Aeson.String text) <- [path ["value"] entry]
        ]
    , Just (Aeson.Object fields) <- Aeson.decodeStrict (TE.encodeUtf8 text) ->
        fields
  _ -> error "the rendered CronJob has no receipt metadata"
  where
    path [] current = Just current
    path (k : rest) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= path rest
    path _ _ = Nothing

cronMetadata, olderMetadata :: KeyMap.KeyMap Aeson.Value
cronMetadata = metadataOf (cronNative 7)
olderMetadata = metadataOf (cronNative 5)

-- | One accepted schedule's shape: its key space, archive format, the
-- metadata its accepted CronJob signs into runs, and its expectations.
data Variant = Variant
  { kind :: !ScheduleKind
  , label :: !Text
  , keyPrefix :: !Text
  , format :: !Text
  , metadata :: !(KeyMap.KeyMap Aeson.Value)
  , expectations :: ![ScheduledReceiptExpectation]
  }
  deriving stock (Generic)

variantArchiveKey :: Variant -> Text -> Text
variantArchiveKey v run' = v ^. #keyPrefix <> run' <> "." <> v ^. #format

postgresVariant, redisVariant, clickhouseVariant, appDatabaseVariant :: Variant
postgresVariant = Variant DatabaseSchedule "personal/mydb" "databases/mydb/" "sql.gz" cronMetadata [currentExpectation]
redisVariant = engineVariant "cache" Redis "8" "rdb.gz"
clickhouseVariant = engineVariant "events" ClickHouse "25" "zip.gz"
appDatabaseVariant =
  Variant AppDatabaseSchedule "personal/notes" (appDatabaseBackupKeyPrefix "personal" "notes") "dump.gz" (metadataOf native) [ok (scheduledAppDatabaseReceiptExpectationFromCronJob localMinioBackend "personal" "notes" statefulIncarnation claimIncarnation native)]
  where
    native = canonical (either (error . show) id (Yaml.decodeEither' (renderInventoryAppDatabaseBackupCronJob HourlyRecoveryPoint backup localMinioBackend 7) :: Either Yaml.ParseException Aeson.Value))
    backup = AppDatabaseBackup "personal" "notes" "pg" Postgres "postgres:18" ["notes"] (T.replicate 64 "e") Nothing

engineVariant :: Text -> Engine -> Text -> Text -> Variant
engineVariant database engine version format' =
  Variant DatabaseSchedule ("personal/" <> database) ("databases/" <> database <> "/") format' (metadataOf native) [ok (scheduledReceiptExpectationFromCronJob localMinioBackend "personal" database statefulIncarnation claimIncarnation native)]
  where
    native = canonical (either (error . show) id (Yaml.decodeEither' (renderInventoryDbBackupCronJob HourlyRecoveryPoint "personal" database engine version localMinioBackend 7) :: Either Yaml.ParseException Aeson.Value))

scheduleFor :: Variant -> BackupSchedule
scheduleFor v =
  BackupSchedule
    { kind = v ^. #kind
    , label = v ^. #label
    , owner = ownerScope
    , schedule = ok (mkResourceId "platform:database-mydb/mydb/cronjob")
    , keyPrefix = v ^. #keyPrefix
    , objectPrefix = "s3://nagare-backups/" <> v ^. #keyPrefix
    , expectations = v ^. #expectations
    , signing = SigningRef "personal" "nagare-dbbackup-mydb-signing" (ok (mkResourceId "platform:database-mydb/mydb/signing")) secretIncarnation
    , source = ResourceRef ownerScope Nothing (Just "personal") (Just statefulIncarnation)
    }
