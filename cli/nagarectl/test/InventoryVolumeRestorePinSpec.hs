-- | EP-160 B2: a reviewed volume restore pins the exact stored archive and
-- receipt at planning, so a tampered backup refuses before any write.
module InventoryVolumeRestorePinSpec (inventoryVolumeRestorePinTests) where

import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Backup (VolumeSnapshotRequest (..), compileVolumeSnapshotScope)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.ScheduledStore (ObjectReader (..), StoredObject (..))
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Inventory.VolumeRestore
import Nagare.Inventory.VolumeRestoreSource (verifyVolumeBackupObjects)
import Nagare.Resource.Inventory hiding (cluster)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Storage.Discover (pvcName)
import Nagare.Storage.Restore (ReviewedVolumeRestoreInputs (..), StorageRestoreJobInputs (..), renderReviewedVolumeRestoreJob, volumeManifestPython)
import Nagare.Test.Support.Kubernetes (cluster, ok)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryVolumeRestorePinTests :: TestTree
inventoryVolumeRestorePinTests =
  testGroup
    "inventory volume restore pins"
    [ testCase "planning pins the current archive and receipt versions" $ do
        store <- newIORef (Map.fromList [(objectUrl, [("a1", archive)]), (receiptUrl, [("r1", receipt)])])
        verifyVolumeBackupObjects (reader store) objectUrl receiptUrl receipt >>= \case
          Right verified -> do
            pinnedObjectVersion verified @?= "a1"
            pinnedReceiptVersion verified @?= "r1"
            pinnedObjectLength verified @?= fromIntegral (BS.length archive)
            pinnedObjectSha256 verified @?= archiveSha
          Left reason -> assertFailure (T.unpack reason)
    , testCase "a newer archive version refuses before any review" $ do
        store <- newIORef (Map.fromList [(objectUrl, [("a1", archive), ("a2", "tampered")]), (receiptUrl, [("r1", receipt)])])
        refused =<< verifyVolumeBackupObjects (reader store) objectUrl receiptUrl receipt
    , testCase "a newer receipt version refuses before any review" $ do
        store <- newIORef (Map.fromList [(objectUrl, [("a1", archive)]), (receiptUrl, [("r1", receipt), ("r2", "{}")])])
        refused =<< verifyVolumeBackupObjects (reader store) objectUrl receiptUrl receipt
    , testCase "a change between the current and exact reads refuses" $ do
        store <- newIORef (Map.fromList [(objectUrl, [("a1", archive)]), (receiptUrl, [("r1", receipt)])])
        let racing =
              (reader store)
                { readObjectToFile = \address version path -> do
                    result <- readObjectToFile (reader store) address version path
                    when (address == objectUrl && version == Just "a1") (BS.writeFile path "changed")
                    pure result
                }
        refused =<< verifyVolumeBackupObjects racing objectUrl receiptUrl receipt
    , testCase "pinned review downloads only the verified versions and prints a manifest" $ do
        let (scope, native) = ok (compileVolumeRestoreScopeWithPins (Just pins) restoreRequest sourceScope accepted)
            bytes = restoreJobBytes native
        mapM_
          (\key -> assertBool ("review lacks " <> T.unpack key) (Map.member key (scopeOverrides scope)))
          ["volume-restore.backup.object.version", "volume-restore.backup.receipt.version", "volume-restore.backup.object.length", "volume-restore.backup.receipt.length"]
        assertBool "GCS download is not pinned" (all (`BC.isInfixOf` bytes) ["$SRC#$OBJECT_VERSION", "$RECEIPT#$RECEIPT_VERSION", "OBJECT_VERSION", "NAGARE_VOLUME_RESTORE_MANIFEST"])
        assertBool "pins that disagree with the receipt were accepted" $
          isLeft (compileVolumeRestoreScopeWithPins (Just pins {pinnedObjectSha256 = T.replicate 64 "b"}) restoreRequest sourceScope accepted)
    , testCase "an unpinned review keeps the original script bytes" $ do
        let (_, native) = ok (compileVolumeRestoreScope restoreRequest sourceScope accepted)
            bytes = restoreJobBytes native
        assertBool "unpinned script changed" (not (any (`BC.isInfixOf` bytes) ["OBJECT_VERSION", "RECEIPT_VERSION", "NAGARE_VOLUME_RESTORE_MANIFEST", "--version-id"]))
        assertBool "unpinned script lost its hash checks" (all (`BC.isInfixOf` bytes) ["RECEIPT_SHA256", "ARCHIVE_SHA256"])
    , testCase "local pinned download asserts the exact MinIO version" $ do
        let ref = MinioRef "http://minio.nagare-system.svc.cluster.local:9000" "nagare-backups" "nagare-minio-credentials"
            rendered =
              renderReviewedVolumeRestoreJob
                ReviewedVolumeRestoreInputs
                  { restoreJob = StorageRestoreJobInputs "default" "restore" "scratch" "s3://nagare-backups/manual-volumes/a.tar.gz" "/restore" (MinioBackend ref)
                  , sourceReceiptUrl = "s3://nagare-backups/manual-volumes/a.tar.gz.receipt.json"
                  , expectedReceiptSha256 = T.replicate 64 "c"
                  , expectedArchiveSha256 = T.replicate 64 "d"
                  , expiresAtEpoch = Nothing
                  , pinnedVersions = Just ("object-v", "receipt-v")
                  }
        assertBool
          "MinIO download is not version-pinned"
          ( all
              (`BC.isInfixOf` rendered)
              [ "--version-id \"$OBJECT_VERSION\""
              , "--version-id \"$RECEIPT_VERSION\""
              , "VersionId"
              , "manual-volumes/a.tar.gz.receipt.json"
              , "object-v"
              ]
          )
    , testCase "the manifest lists restored files under a stable marker" $
        withSystemTempDirectory "volume-manifest" $ \root -> do
          createDirectoryIfMissing True (root </> "nested")
          BS.writeFile (root </> "sentinel.txt") "known"
          BS.writeFile (root </> "nested" </> "b.txt") "other"
          (code, output, errors) <- readProcessWithExitCode "python3" ["-c", T.unpack volumeManifestPython, root] ""
          code @?= ExitSuccess
          let lines' = lines output
          assertBool errors (("NAGARE_VOLUME_RESTORE_FILE " <> T.unpack sentinelSha <> " 5 sentinel.txt") `elem` lines')
          case filter ("NAGARE_VOLUME_RESTORE_MANIFEST " `isPrefixOfS`) lines' of
            [summary] -> assertBool summary ("files=2 bytes=10 tree=" `isInfixOfS` summary)
            other -> assertFailure ("manifest summary missing: " <> show other)
    ]
  where
    refused = \case
      Left _ -> pure ()
      Right pins' -> assertFailure ("tampered backup was pinned: " <> show pins')
    isPrefixOfS prefix value = take (length prefix) value == prefix
    isInfixOfS needle value = any (isPrefixOfS needle) (suffixes value)
    suffixes value =
      value : case value of
        [] -> []
        _ : rest -> suffixes rest

-- An in-memory versioned store: the last version of a key is current.
reader :: IORef (Map Text [(Text, ByteString)]) -> ObjectReader
reader store =
  ObjectReader
    { readObjectToFile = \address selected path -> do
        versions <- Map.findWithDefault [] address <$> readIORef store
        case (selected, reverse versions) of
          (_, []) -> pure (Left "object is absent")
          (Nothing, (version, bytes) : _) -> write path version bytes
          (Just version, _) -> case lookup version versions of
            Just bytes -> write path version bytes
            Nothing -> pure (Left "object version is absent")
    , listObjectKeys = \_ -> pure (Right [])
    , listObjectEntries = \_ -> pure (Right [])
    , listObjectVersions = \_ -> pure (Right [])
    }
  where
    write path version bytes = do
      BS.writeFile path bytes
      pure (Right (StoredObject version (fromIntegral (BS.length bytes))))

objectUrl :: Text
objectUrl = "gs://bucket/manual-volumes/default/notes/data/run-001.tar.gz"

receiptUrl :: Text
receiptUrl = objectUrl <> ".receipt.json"

archive :: ByteString
archive = "volume archive bytes"

archiveSha :: Text
archiveSha = digestText (contentDigest archive)

sentinelSha :: Text
sentinelSha = digestText (contentDigest "known")

-- The receipt the accepted snapshot Job reported, binding the archive digest.
receipt :: ByteString
receipt =
  BL.toStrict
    ( encode
        ( object
            [ "version" .= (1 :: Int)
            , "sha256" .= archiveSha
            , "backup" .= (ok (eitherDecodeStrict (TE.encodeUtf8 receiptMetadata)) :: Value)
            ]
        )
    )

pins :: VolumeObjectPins
pins = VolumeObjectPins "a1" (fromIntegral (BS.length archive)) archiveSha "r1" (fromIntegral (BS.length receipt)) (contentDigest receipt)

-- Fixture ------------------------------------------------------------------

appOwner :: ScopeId
appOwner = ok (mkScopeId Application "notes")

pvcId :: ResourceId
pvcId = mintResourceId appOwner (ok (mkLogicalKey "data")) (ok (mkName "pvc"))

sourceScope :: ScopeDeclaration
sourceNative :: Map ResourceId (ManagedResource, ByteString)
(sourceScope, sourceNative) =
  let value =
        object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("PersistentVolumeClaim" :: Text)
          , "metadata" .= object ["name" .= pvcName "notes" "data", "namespace" .= ("default" :: Text)]
          , "spec"
              .= object
                [ "accessModes" .= ["ReadWriteOnce" :: Text]
                , "storageClassName" .= ("local-path" :: Text)
                , "resources" .= object ["requests" .= object ["storage" .= ("1Gi" :: Text)]]
                ]
          ]
      (pvc, bytes) =
        ok
          ( bindKubernetesObject
              KubernetesInput
                { resourceId = pvcId
                , ownerScope = appOwner
                , clusterId = cluster
                , inputObject = value
                , objectDigest = contentDigest (ok (canonicalValue value))
                , lifecyclePolicy = Retain
                , inputDataPolicy = Durable (RecoveryIntent (ok (mkName "archive")) (mkSecretRef (ok (mkName "restore-key")) (ok (mkName "v1")) :| []))
                , inputSensitivity = Private
                , sourceLocation = SourceLocation "notes" "data"
                }
          )
   in (ok (mkScopeDeclaration appOwner [ResourceBundle [Managed pvc] [] [] [] [] []]), Map.singleton pvcId (pvc, bytes))

backupScope :: ScopeDeclaration
backupNative :: Map ResourceId (ManagedResource, ByteString)
(backupScope, backupNative) =
  ok
    ( compileVolumeSnapshotScope
        VolumeSnapshotRequest
          { volumeApp = "notes"
          , volumeName = "data"
          , volumeNamespace = "default"
          , volumeBackupId = "run-001"
          , volumeExpiresAt = Nothing
          , volumeSourceRevision = ScopeRevision (ok (mkScopeGeneration 2)) (contentDigest "accepted-volume")
          , volumeSourcePvcUid = ok (mkPhysicalIdentity "pvc-uid")
          , volumeStorageBackend = GcsBackend "project" "bucket"
          , volumeStoreCredential = Nothing
          , volumeBackupSource = SourceLocation "storage snapshot" "run-001"
          }
        sourceScope
        sourceNative
    )

receiptMetadata :: Text
receiptMetadata = case [value | (_, bytes) <- Map.elems backupNative, value <- metadataValues (ok (eitherDecodeStrict bytes))] of
  [value] -> value
  _ -> error "volume snapshot lacks one receipt metadata value"
  where
    metadataValues (Object fields) =
      [selected | KM.lookup "name" fields == Just (String "BACKUP_RECEIPT_METADATA"), Just (String selected) <- [KM.lookup "value" fields]]
        <> concatMap metadataValues (KM.elems fields)
    metadataValues (Array values) = concatMap metadataValues (toList values)
    metadataValues _ = []

accepted :: Map ResourceId (ManagedResource, ByteString)
accepted = Map.union backupNative sourceNative

restoreRequest :: VolumeRestoreRequest
restoreRequest =
  VolumeRestoreRequest
    { volumeRestoreApp = "notes"
    , volumeRestoreName = "data"
    , volumeRestoreNamespace = "default"
    , volumeRestoreId = "restore-001"
    , volumeRestoreBackup = backupScope
    , volumeRestoreBackupRevision = ScopeRevision (ok (mkScopeGeneration 1)) (contentDigest "accepted-backup")
    , volumeRestoreBackupJobUid = ok (mkPhysicalIdentity "backup-job-uid")
    , volumeRestoreReceiptBytes = receipt
    , volumeRestoreNow = ok (maybe (Left ("invalid time" :: Text)) Right (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T00:00:00Z" :: Maybe UTCTime))
    , volumeRestoreTargetRevision = ScopeRevision (ok (mkScopeGeneration 2)) (contentDigest "accepted-volume")
    , volumeRestoreTargetPvcUid = ok (mkPhysicalIdentity "pvc-uid")
    , volumeRestoreBackend = GcsBackend "project" "bucket"
    , volumeRestoreCredential = Nothing
    , volumeRestoreSource = SourceLocation "storage restore" "restore-001"
    }

restoreJobBytes :: Map ResourceId (ManagedResource, ByteString) -> ByteString
restoreJobBytes native = case [bytes | (member, bytes) <- Map.elems native, isJob (member ^. #address)] of
  [bytes] -> bytes
  _ -> error "volume restore must bind one Job"
  where
    isJob (Kubernetes _ "batch" kind _ _) = nameText kind == "job"
    isJob _ = False
