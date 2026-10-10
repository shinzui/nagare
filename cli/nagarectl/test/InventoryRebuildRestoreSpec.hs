-- | EP-183 M4: a rebuilt member's data comes back from the one recovery point
-- its rebuild named: ClickHouse and Redis from scheduled backups (PostgreSQL is
-- in 'InventoryRebuildSpec'), application volumes from manual snapshots
-- verified from the object store alone.
module InventoryRebuildRestoreSpec (inventoryRebuildRestoreTests) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend), storeObjectUrl)
import Nagare.Dsl.Database (Database (Database), Engine (..), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Backup (ScheduledBackupReceipt (..))
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (HourlyRecoveryPoint))
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Lineage
import Nagare.Inventory.LineageHistory (RebuildLineage (..))
import Nagare.Inventory.RebuildRestore (RebuildRestoreRequest (..), compileRebuildRestoreScope)
import Nagare.Inventory.Restore (manualRestoreJobTargetPins)
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Inventory.ScheduledStore (ObjectReader (..), StoredObject (..))
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Inventory.VolumeRebuildRestore (VolumeRebuildRestoreRequest (..), VolumeRecoverySource (..), compileVolumeRebuildRestoreScope)
import Nagare.Inventory.VolumeRestore (volumeRestoreJobSourcePins)
import Nagare.Inventory.VolumeRestoreSource (verifyIngestedVolumeRun, verifyRecordedVolumeSnapshot)
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Model.Fixtures qualified as Fixtures
import Test.Tasty
import Test.Tasty.HUnit

inventoryRebuildRestoreTests :: TestTree
inventoryRebuildRestoreTests =
  testGroup
    "rebuild restores of ClickHouse, Redis and volumes"
    [ testCase "a ClickHouse rebuild restore stages the archive and moves every table into the empty default database" $ do
        let (scope, native) = engineDatabase ClickHouse
        (restoreScope, restoreNative) <- either (assertFailure . show) pure (compileRebuildRestoreScope (engineRequest ClickHouse) scope native)
        job <- singleJob restoreNative
        traverse_
          (\marker -> assertBool ("the ClickHouse Job lacks " <> T.unpack marker) (marker `T.isInfixOf` job))
          [ "RESTORE DATABASE default AS"
          , "nagare_rebuild_rebuild_1"
          , "RENAME TABLE $moves"
          , "refusing to restore over data"
          , "DROP DATABASE"
          , "/source-data"
          , "podAffinity"
          ]
        Map.lookup "restore.target.pvc.uid" (scopeOverrides restoreScope) @?= Just "uid-rebuilt-pvc"
        [pins | (_, bytes) <- Map.elems restoreNative, Right (Just pins) <- [manualRestoreJobTargetPins bytes]]
          @?= [[(member scope "statefulset", uid "uid-live-sts"), (member scope "persistentvolumeclaim", uid "uid-rebuilt-pvc")]]
    , testCase "a Redis rebuild restore loads the RDB at a restart and must report the RDB's key count" $ do
        let (scope, native) = engineDatabase Redis
        (_, restoreNative) <- either (assertFailure . show) pure (compileRebuildRestoreScope (engineRequest Redis) scope native)
        job <- singleJob restoreNative
        traverse_
          (\marker -> assertBool ("the Redis Job lacks " <> T.unpack marker) (marker `T.isInfixOf` job))
          ["redis-check-rdb", "DBSIZE", "CONFIG SET save", "mv -- \\\"$STAGED\\\" /source-data/dump.rdb", "SHUTDOWN NOSAVE", "refusing to restore over data", "podAffinity"]
    , testCase "a rebuild restore takes only a backup of the database's own engine" $ do
        let (scope, native) = engineDatabase ClickHouse
            postgresArchive = (engineRequest ClickHouse) {evidence = evidenceFor "sql.gz", lineage = lineageFor "sql.gz"}
        assertBool "a PostgreSQL dump restored into ClickHouse" (refused "not a scheduled backup of this database's engine" (compileRebuildRestoreScope postgresArchive scope native))
    , testCase "a volume rebuild restore restores only the named snapshot into the claim the rebuild created" $ do
        (restoreScope, restoreNative) <- either (assertFailure . show) pure (volumeCompile volumeRequest)
        job <- singleJob restoreNative
        traverse_
          (\marker -> assertBool ("the volume Job lacks " <> T.unpack marker) (marker `T.isInfixOf` job))
          ["refusing to restore over data", "mkdir /restore/.nagare-rebuild-rebuild_1", "NAGARE_VOLUME_PLACE", "NAGARE_VOLUME_RESTORE_MANIFEST"]
        Map.lookup "volume-restore.rebuild.predecessor" (scopeOverrides restoreScope) @?= Just "uid-old-pvc"
        [pins | (_, bytes) <- Map.elems restoreNative, Right (Just pins) <- [volumeRestoreJobSourcePins bytes]]
          @?= [[(volumeClaim, uid "uid-rebuilt-pvc")]]
        let refusal request = either (\errors -> T.intercalate "; " [err ^. #message | err <- NE.toList errors]) (const "") (volumeCompile request)
        assertBool "a volume restore targeted the predecessor" ("not the incarnation a reviewed rebuild created" `T.isInfixOf` refusal volumeRequest {targetPvcUid = uid "uid-old-pvc"})
        assertBool "a volume restore took another archive" ("not the recovery point the rebuild named" `T.isInfixOf` refusal volumeRequest {recovery = volumeRecovery {receiptDigest = contentDigest "another"}})
        assertBool "a volume restore took another incarnation's snapshot" ("another incarnation than the rebuild's predecessor" `T.isInfixOf` refusal volumeRequest {recovery = volumeRecovery {sourcePvcUid = uid "uid-other-pvc"}})
        assertBool "a volume restore took a database backup" ("another kind of recovery point" `T.isInfixOf` refusal volumeRequest {lineage = volumeLineage & #proof . #source .~ FromRecoveryPoint (volumePoint & #kind .~ ScheduledRecoveryPoint)})
        assertBool "a volume restore ran without exact versions" ("lacks exact stored versions" `T.isInfixOf` refusal volumeRequest {recovery = volumeRecovery {objectVersion = ""}})
    , testCase "an accepted snapshot verifies from the object store alone against the inventory's record of it" $ do
        good <- fakeReader [(snapshotReceipt, [("7", receiptBytes "uid-old-pvc" archiveSha)]), (snapshotObject, [("8", archiveBytes)])]
        verifyRecordedVolumeSnapshot good snapshotScope
          >>= (@?= Right volumeRecovery {objectVersion = "8", receiptVersion = "7", receiptDigest = contentDigest (receiptBytes "uid-old-pvc" archiveSha)})
        otherClaim <- fakeReader [(snapshotReceipt, [("7", receiptBytes "uid-other-pvc" archiveSha)]), (snapshotObject, [("8", archiveBytes)])]
        verifyRecordedVolumeSnapshot otherClaim snapshotScope >>= assertBool "a receipt of another claim incarnation verified" . refusedWith "names another snapshot"
        altered <- fakeReader [(snapshotReceipt, [("7", receiptBytes "uid-old-pvc" archiveSha)]), (snapshotObject, [("8", "tampered")])]
        verifyRecordedVolumeSnapshot altered snapshotScope >>= assertBool "an altered archive verified" . refusedWith "differs from its receipt checksum"
        moving <- movingReader [(snapshotReceipt, [("7", receiptBytes "uid-old-pvc" archiveSha)]), (snapshotObject, [("8", archiveBytes)])]
        verifyRecordedVolumeSnapshot moving snapshotScope >>= assertBool "an object that changed between reads verified" . refusedWith "changed while reading"
    , testCase "an accepted scheduled volume run verifies from the object store against its ingestion record" $ do
        good <- fakeReader [(runReceipt, [("5", runReceiptBytes)]), (runObject, [("6", archiveBytes)])]
        verifyIngestedVolumeRun good runScope >>= (@?= Right runRecovery)
        altered <- fakeReader [(runReceipt, [("5", runReceiptBytes)]), (runObject, [("6", "tampered")])]
        verifyIngestedVolumeRun altered runScope >>= assertBool "an altered run archive verified" . refusedWith "differs from its accepted checksum"
        swapped <- fakeReader [(runReceipt, [("5", "another receipt")]), (runObject, [("6", archiveBytes)])]
        verifyIngestedVolumeRun swapped runScope >>= assertBool "another receipt verified" . refusedWith "differs from the accepted receipt"
        verifyIngestedVolumeRun good (withScopeOverrides (Map.delete "scheduled.backup.source.kind" (scopeOverrides runScope)) runScope)
          >>= assertBool "a database run verified as a volume run" . refusedWith "not a scheduled volume run"
    , testCase "a volume rebuild restore also loads the scheduled run its rebuild named" $ do
        let point = RecoveryPoint ScheduledVolumeRecoveryPoint runReceipt (contentDigest runReceiptBytes)
            request = volumeRequest {lineage = volumeLineage & #proof . #source .~ FromRecoveryPoint point, recovery = runRecovery}
            refusal = either (\errors -> T.intercalate "; " [err ^. #message | err <- NE.toList errors]) (const "")
        (restoreScope, _) <- either (assertFailure . show) pure (volumeCompile request)
        Map.lookup "volume-restore.rebuild.predecessor" (scopeOverrides restoreScope) @?= Just "uid-old-pvc"
        assertBool
          "a run restored in place of the snapshot the rebuild named"
          ("not the recovery point the rebuild named" `T.isInfixOf` refusal (volumeCompile volumeRequest {recovery = runRecovery}))
    ]
  where
    refused text = either (any ((text `T.isInfixOf`) . (^. #message)) . NE.toList) (const False)
    refusedWith text = either (text `T.isInfixOf`) (const False)
    singleJob native = case Map.elems native of
      [(_, bytes)] -> pure (TE.decodeUtf8 bytes)
      other -> assertFailure ("expected one Job, got " <> show (length other)) >> pure ""

-- * Databases

engineDatabase :: Engine -> (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
engineDatabase engine =
  Fixtures.ok
    ( compileStandaloneDatabase
        (DatabaseDirectInput database owner Fixtures.appCluster Nothing recovery (SourceLocation "test" "db"))
        (DatabaseBackupTarget testBackend HourlyRecoveryPoint)
    )
  where
    owner = Fixtures.ok (mkScopeId Standalone "database-db")
    database =
      Database
        (Fixtures.ok (mkDatabaseName "db"))
        Nothing
        engine
        (defaultEngineVersion engine)
        (Fixtures.ok (Dsl.mkNamespace "personal"))
        (Fixtures.ok (Dsl.mkQuantity "1Gi"))
        Nothing
        Dsl.Retain
    recovery = RecoveryIntent (Fixtures.ok (mkName "backup")) (mkSecretRef (Fixtures.ok (mkName "nagare-db-db")) (Fixtures.ok (mkName "v1")) :| [])

member :: ScopeDeclaration -> Text -> ResourceId
member scope kind =
  case [ declared ^. #identity
       | bundle <- scopeBundles scope
       , Managed declared <- declarations bundle
       , Kubernetes _ _ nativeKind _ nativeName <- [declared ^. #address]
       , nameText nativeKind == kind
       , kind /= "persistentvolumeclaim" || nameText nativeName == "nagare-db-db-data"
       , kind /= "statefulset" || nameText nativeName == "db"
       ] of
    [single] -> single
    found -> error ("no unique " <> T.unpack kind <> ": " <> show found)

testBackend :: StoreBackend
testBackend = GcsBackend "project" "bucket"

objectFor :: Text -> Text
objectFor extension = storeObjectUrl testBackend ("databases/db/job-1." <> extension)

evidenceFor :: Text -> ScheduledReceiptEvidence
evidenceFor extension = ScheduledReceiptEvidence (ScheduledBackupReceipt (uid "job-1") (objectFor extension) (T.replicate 64 "a") (contentDigest "schedule") Nothing) "11" "12" 100 10 (contentDigest "receipt bytes")

lineageFor :: Text -> RebuildLineage
lineageFor extension =
  RebuildLineage
    (member (fst (engineDatabase Postgres)) "persistentvolumeclaim")
    (uid "uid-rebuilt-pvc")
    (RebuildProof (Just (uid "uid-old-pvc")) (FromRecoveryPoint (RecoveryPoint ScheduledRecoveryPoint (objectFor extension <> ".receipt.json") (contentDigest "receipt bytes"))))
    (contentDigest "rebuild review")

engineRequest :: Engine -> RebuildRestoreRequest
engineRequest engine =
  RebuildRestoreRequest
    { database = "db"
    , namespace = "personal"
    , restoreId = "rebuild-1"
    , targetRevision = ScopeRevision (Fixtures.ok (mkScopeGeneration 2)) (contentDigest "database revision")
    , targetStatefulUid = uid "uid-live-sts"
    , targetPvcUid = uid "uid-rebuilt-pvc"
    , lineage = (lineageFor extension) {resource = member (fst (engineDatabase engine)) "persistentvolumeclaim"}
    , escrowPvcUid = uid "uid-old-pvc"
    , evidence = evidenceFor extension
    , backend = testBackend
    , source = SourceLocation "test" "rebuild-restore"
    }
  where
    extension = case engine of
      Postgres -> "sql.gz"
      ClickHouse -> "zip.gz"
      Redis -> "rdb.gz"

-- * Volumes

volumeClaim :: ResourceId
volumeClaim = mintResourceId Fixtures.appScope (Fixtures.ok (mkLogicalKey "uploads")) (Fixtures.ok (mkName "pvc"))

volumeScope :: (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
volumeScope =
  let bound = Fixtures.bindMemberWith Fixtures.volumePolicy volumeClaim claimValue
   in (Fixtures.ok (mkScopeDeclaration Fixtures.appScope [ResourceBundle [Managed (fst bound)] [] [] [] [] []]), Map.singleton volumeClaim bound)
  where
    claimValue :: Value
    claimValue =
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("PersistentVolumeClaim" :: Text)
        , "metadata" .= object ["name" .= ("nagare-vol-web-uploads" :: Text), "namespace" .= ("personal" :: Text)]
        , "spec" .= object ["accessModes" .= ["ReadWriteOnce" :: Text], "storageClassName" .= ("local-path" :: Text), "resources" .= object ["requests" .= object ["storage" .= ("1Gi" :: Text)]]]
        ]

volumeCompile :: VolumeRebuildRestoreRequest -> Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
volumeCompile request = uncurry (compileVolumeRebuildRestoreScope request) volumeScope

snapshotObject, snapshotReceipt :: Text
snapshotObject = storeObjectUrl testBackend "manual-volumes/personal/web/uploads/snap-1.tar.gz"
snapshotReceipt = snapshotObject <> ".receipt.json"

archiveBytes :: ByteString
archiveBytes = "archive bytes"

archiveSha :: Text
archiveSha = digestText (contentDigest archiveBytes)

-- | A version-1 snapshot receipt, as the snapshot Job writes it.
receiptBytes :: Text -> Text -> ByteString
receiptBytes sourceUid checksum =
  Fixtures.ok
    ( canonicalValue
        ( object
            [ "version" .= (1 :: Int)
            , "sha256" .= checksum
            , "backup" .= object ["id" .= ("snap-1" :: Text), "object" .= snapshotObject, "sourceScope" .= scopeIdText Fixtures.appScope, "sourcePvcUid" .= sourceUid, "app" .= ("web" :: Text), "volume" .= ("uploads" :: Text)]
            ]
        )
    )

volumePoint :: RecoveryPoint
volumePoint = RecoveryPoint VolumeSnapshotRecoveryPoint snapshotReceipt (contentDigest (receiptBytes "uid-old-pvc" archiveSha))

volumeRecovery :: VolumeRecoverySource
volumeRecovery =
  VolumeRecoverySource
    { kind = VolumeSnapshotRecoveryPoint
    , objectUrl = snapshotObject
    , objectVersion = "8"
    , archiveSha256 = archiveSha
    , receiptUrl = snapshotReceipt
    , receiptVersion = "7"
    , receiptDigest = contentDigest (receiptBytes "uid-old-pvc" archiveSha)
    , sourcePvcUid = uid "uid-old-pvc"
    , expiryEpoch = Nothing
    }

volumeLineage :: RebuildLineage
volumeLineage = RebuildLineage volumeClaim (uid "uid-rebuilt-pvc") (RebuildProof (Just (uid "uid-old-pvc")) (FromRecoveryPoint volumePoint)) (contentDigest "rebuild review")

volumeRequest :: VolumeRebuildRestoreRequest
volumeRequest =
  VolumeRebuildRestoreRequest
    { app = "web"
    , volume = "uploads"
    , namespace = "personal"
    , restoreId = "rebuild-1"
    , targetRevision = ScopeRevision (Fixtures.ok (mkScopeGeneration 2)) (contentDigest "app revision")
    , targetPvcUid = uid "uid-rebuilt-pvc"
    , lineage = volumeLineage
    , recovery = volumeRecovery
    , backend = testBackend
    , credential = Nothing
    , source = SourceLocation "test" "volume-rebuild-restore"
    }

runObject, runReceipt :: Text
runObject = storeObjectUrl testBackend "scheduled-volumes/personal/web/uploads/run-1.tar.gz"
runReceipt = runObject <> ".receipt.json"

runReceiptBytes :: ByteString
runReceiptBytes = "{\"version\":5}"

-- | An accepted scheduled volume run's ingestion record (EP-183 M3).
runScope :: ScopeDeclaration
runScope =
  withScopeOverrides
    ( Map.fromList
        [ ("scheduled.backup.id", "run-1")
        , ("scheduled.backup.object", runObject)
        , ("scheduled.backup.object.version", "6")
        , ("scheduled.backup.object.sha256", archiveSha)
        , ("scheduled.backup.receipt", runReceipt)
        , ("scheduled.backup.receipt.version", "5")
        , ("scheduled.backup.receipt.digest", digestText (contentDigest runReceiptBytes))
        , ("scheduled.backup.source.kind", "volume")
        , ("scheduled.backup.source.pvc", resourceIdText volumeClaim)
        , ("scheduled.backup.source.pvc.uid", "uid-old-pvc")
        ]
    )
    (Fixtures.ok (mkScopeDeclaration (Fixtures.ok (mkScopeId Standalone "volume-scheduled-receipt-personal-nagare-volbackup-web-uploads-run-1")) []))

runRecovery :: VolumeRecoverySource
runRecovery =
  VolumeRecoverySource
    { kind = ScheduledVolumeRecoveryPoint
    , objectUrl = runObject
    , objectVersion = "6"
    , archiveSha256 = archiveSha
    , receiptUrl = runReceipt
    , receiptVersion = "5"
    , receiptDigest = contentDigest runReceiptBytes
    , sourcePvcUid = uid "uid-old-pvc"
    , expiryEpoch = Nothing
    }

-- | The accepted snapshot scope's record, as the snapshot compiler writes it.
snapshotScope :: ScopeDeclaration
snapshotScope =
  withScopeOverrides
    ( Map.fromList
        [ ("volume-backup.id", "snap-1")
        , ("volume-backup.object", snapshotObject)
        , ("volume-backup.receipt", snapshotReceipt)
        , ("volume-backup.source.scope", scopeIdText Fixtures.appScope)
        , ("volume-backup.source.pvc", resourceIdText volumeClaim)
        , ("volume-backup.source.pvc.uid", "uid-old-pvc")
        , ("volume-backup.expiry", "retain")
        ]
    )
    (Fixtures.ok (mkScopeDeclaration (Fixtures.ok (mkScopeId Standalone "volume-snapshot-personal-web-uploads-snap-1")) []))

-- | An object store holding versions of each object; the newest is current.
fakeReader :: [(Text, [(Text, ByteString)])] -> IO ObjectReader
fakeReader objects = pure (reader (const objects))

-- | A store whose bytes change under the same version between reads.
movingReader :: [(Text, [(Text, ByteString)])] -> IO ObjectReader
movingReader objects = do
  reads' <- newIORef (0 :: Int)
  pure
    ObjectReader
      { readObjectToFile = \address version path -> do
          count <- atomicModifyIORef' reads' (\n -> (n + 1, n))
          readObjectToFile (reader (const [(key, [(selected, bytes <> TE.encodeUtf8 (T.pack (show count))) | (selected, bytes) <- versions]) | (key, versions) <- objects])) address version path
      , listObjectKeys = \_ -> pure (Left "unused")
      , listObjectEntries = \_ -> pure (Left "unused")
      , listObjectVersions = \_ -> pure (Left "unused")
      }

reader :: (() -> [(Text, [(Text, ByteString)])]) -> ObjectReader
reader objects =
  ObjectReader
    { readObjectToFile = \address version path -> case lookup address (objects ()) of
        Nothing -> pure (Left ("no object " <> address))
        Just versions -> case maybe (lastMaybe versions) (\selected -> (selected,) <$> lookup selected versions) version of
          Nothing -> pure (Left "no such version")
          Just (selected, bytes) -> BS.writeFile path bytes >> pure (Right (StoredObject selected (fromIntegral (BS.length bytes))))
    , listObjectKeys = \_ -> pure (Left "unused")
    , listObjectEntries = \_ -> pure (Left "unused")
    , listObjectVersions = \_ -> pure (Left "unused")
    }
  where
    lastMaybe values = case reverse values of
      selected : _ -> Just selected
      [] -> Nothing

uid :: Text -> PhysicalIdentity
uid = Fixtures.ok . mkPhysicalIdentity
