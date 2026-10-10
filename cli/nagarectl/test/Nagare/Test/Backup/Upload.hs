-- | Backup.Upload responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Backup.Upload
  ( backupUploadTests
  )
where

import Control.Monad (forM_)
import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.Backup
  ( BackupDest (BackupDestStamped, BackupDestUrl)
  , BackupReceipt (BackupReceipt)
  , BackupReceiptTarget
    ( BackupObjectReceiptTarget
    , FixedReceiptTarget
    )
  , renderInventoryDbBackupCronJob
  , uploadShell
  )
import Nagare.Dsl.Database (Engine (Postgres))
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Inventory.Backup
  ( ScheduledBackupReceipt (scheduledJobUid, scheduledRecoveryPoint)
  , ScheduledReceiptExpectation
    ( ScheduledReceiptExpectation
    , scheduledPvcUid
    )
  , parseScheduledBackupReceipt
  )
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))
import Nagare.Resource.Canonical (canonicalValue, contentDigest)
import Nagare.Resource.Types qualified as Resource
import Nagare.Test.DataFixtures
  ( backupJobInputsPg
  , localMinioBackend
  , tnbGcsBackend
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , findExecutable
  , removeFile
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process
  ( CreateProcess (env)
  , proc
  , readCreateProcessWithExitCode
  )
import Test.Tasty (TestTree)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

backupUploadTests :: [TestTree]
backupUploadTests =
  [ testCase "reviewed backup reads back exact stored bytes for both backends" $ do
      let cloud = TE.decodeUtf8 (renderInventoryDbBackupCronJob HourlyRecoveryPoint "personal" "mydb" Postgres "18" tnbGcsBackend 7)
          local = TE.decodeUtf8 (renderInventoryDbBackupCronJob HourlyRecoveryPoint "personal" "mydb" Postgres "18" localMinioBackend 7)
          cloudScript =
            uploadShell
              ( backupJobInputsPg
                  & #verifyStored
                  .~ True
                  & #destination
                  .~ BackupDestStamped
              )
          localScript =
            uploadShell
              ( backupJobInputsPg
                  & #verifyStored
                  .~ True
                  & #destination
                  .~ BackupDestStamped
                  & #backend
                  .~ localMinioBackend
              )
      assertBool "GCS upload has no readback" ("gsutil cp \"$DEST\" - | sha256sum" `T.isInfixOf` cloudScript)
      assertBool "MinIO upload has no readback" ("aws s3 cp \"$DEST\" - --endpoint-url" `T.isInfixOf` localScript)
      assertBool "GCS does not compare digests" ("test \"$EXPECTED\" = \"$ACTUAL\"" `T.isInfixOf` cloudScript)
      assertBool "MinIO does not compare digests" ("test \"$EXPECTED\" = \"$ACTUAL\"" `T.isInfixOf` localScript)
      assertBool "reviewed backup still prunes" (all (not . T.isInfixOf "pruning") [cloud, local])
      assertBool
        "scheduled backup key is bound to the Job UID"
        (all (T.isInfixOf "${BACKUP_RUN_ID}.sql.gz") [cloud, local])
      assertBool
        "scheduled backup reads the Job controller UID"
        (all (T.isInfixOf "metadata.labels['batch.kubernetes.io/controller-uid']") [cloud, local])
      assertBool
        "scheduled GCS backup creates only"
        ("--if-generation-match=0" `T.isInfixOf` cloudScript)
      assertBool
        "scheduled S3 backup creates only"
        ("--if-none-match" `T.isInfixOf` localScript)
  , testCase "reviewed backup Job fails when stored bytes differ" $
      withSystemTempDirectory "nagare-backup-verification" $ \directory -> do
        let dump = directory </> "dump"
            fakeGsutil = directory </> "gsutil"
            fakeGcloud = directory </> "gcloud"
            fakeAws = directory </> "aws"
            fakeDnf = directory </> "dnf"
            brokenTools = directory </> "broken-tools"
            fakeHash = brokenTools </> "sha256sum"
            stored = directory </> "object.gz"
            cloudScript =
              T.unpack
                ( T.replace
                    "/dump"
                    (T.pack dump)
                    ( uploadShell
                        ( backupJobInputsPg
                            & #verifyStored
                            .~ True
                            & #destination
                            .~ BackupDestStamped
                        )
                    )
                )
            localScript =
              T.unpack
                ( T.replace
                    "/dump"
                    (T.pack dump)
                    ( uploadShell
                        ( backupJobInputsPg
                            & #verifyStored
                            .~ True
                            & #destination
                            .~ BackupDestStamped
                            & #backend
                            .~ localMinioBackend
                        )
                    )
                )
        createDirectoryIfMissing True dump
        createDirectoryIfMissing True brokenTools
        BS.writeFile (dump </> "backup.sql") "verified backup payload\n"
        writeFile fakeGsutil $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "if [ \"$1\" = -o ]; then shift 2; fi"
            , "[ \"$1\" = cp ] || exit 2"
            , "if [ \"$2\" = - ]; then cat > \"$NAGARE_TEST_OBJECT\"; exit; fi"
            , "if [ \"$NAGARE_TEST_CORRUPT\" = 1 ]; then printf corrupt; else cat \"$NAGARE_TEST_OBJECT\"; fi"
            ]
        writeFile fakeGcloud $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "[ \"$1\" = storage ] && [ \"$2\" = cp ] && [ \"$5\" = --if-generation-match=0 ] || exit 2"
            , "cp \"$3\" \"$NAGARE_TEST_OBJECT\""
            ]
        writeFile fakeAws $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "if [ \"$1\" = s3api ] && [ \"$2\" = put-bucket-versioning ]; then exit 0; fi"
            , "if [ \"$1\" = s3api ] && [ \"$2\" = put-object ]; then cp \"$8\" \"$NAGARE_TEST_OBJECT\"; exit; fi"
            , "[ \"$1\" = s3 ] && [ \"$2\" = cp ] || exit 2"
            , "if [ \"$3\" = - ]; then cat > \"$NAGARE_TEST_OBJECT\"; exit; fi"
            , "if [ \"$NAGARE_TEST_CORRUPT\" = 1 ]; then printf corrupt; else cat \"$NAGARE_TEST_OBJECT\"; fi"
            ]
        writeFile fakeDnf "#!/bin/sh\nexit 0\n"
        writeFile fakeHash "#!/bin/sh\nexit 0\n"
        setFileMode fakeGsutil 0o755
        setFileMode fakeGcloud 0o755
        setFileMode fakeAws 0o755
        setFileMode fakeDnf 0o755
        setFileMode fakeHash 0o755
        parentEnv <- getEnvironment
        let path = maybe "" id (lookup "PATH" parentEnv)
            run script prefix corrupt badHash =
              readCreateProcessWithExitCode
                ( (proc "/bin/sh" ["-c", script])
                    { env =
                        Just
                          ( [ ("PATH", (if badHash then brokenTools <> ":" else "") <> directory <> ":" <> path)
                            , ("DEST", "gs://test/backup.gz")
                            , ("PREFIX", prefix)
                            , ("BACKUP_RUN_ID", "12345678-1234-1234-1234-123456789abc")
                            , ("NAGARE_TEST_OBJECT", stored)
                            , ("NAGARE_TEST_CORRUPT", corrupt)
                            ]
                              <> filter
                                ( \(key, _) ->
                                    key
                                      `notElem` ["PATH", "DEST", "PREFIX", "BACKUP_RUN_ID", "NAGARE_TEST_OBJECT", "NAGARE_TEST_CORRUPT"]
                                )
                                parentEnv
                          )
                    }
                )
                ""
        forM_
          [ ("GCS", cloudScript, "gs://test/")
          , ("MinIO", localScript, "s3://nagare-backups/databases/test/")
          ]
          $ \(label, script, prefix) -> do
            (good, _, goodError) <- run script prefix "0" False
            assertBool
              (label <> " verified upload did not complete: " <> show good <> " " <> goodError)
              (good == ExitSuccess)
            (bad, _, _) <- run script prefix "1" False
            case bad of
              ExitFailure _ -> pure ()
              ExitSuccess -> assertFailure (label <> " corrupted stored bytes completed the backup Job")
            (emptyHash, _, _) <- run script prefix "0" True
            case emptyHash of
              ExitFailure _ -> pure ()
              ExitSuccess -> assertFailure (label <> " empty digests completed the backup Job")
  , testCase "reviewed manual backup never overwrites an existing object" $
      withSystemTempDirectory "nagare-backup-create-only" $ \directory -> do
        let dump = directory </> "dump"
            fakeGcloud = directory </> "gcloud"
            fakeGsutil = directory </> "gsutil"
            fakeAws = directory </> "aws"
            fakeDnf = directory </> "dnf"
            cloudScript =
              T.unpack
                ( T.replace
                    "/dump"
                    (T.pack dump)
                    ( uploadShell
                        ( backupJobInputsPg
                            & #verifyStored
                            .~ True
                            & #destination
                            .~ BackupDestUrl "gs://test/manual-databases/personal/mydb/run-001.sql.gz"
                        )
                    )
                )
            localScript =
              T.unpack
                ( T.replace
                    "/dump"
                    (T.pack dump)
                    ( uploadShell
                        ( backupJobInputsPg
                            & #verifyStored
                            .~ True
                            & #destination
                            .~ BackupDestUrl "s3://nagare-backups/manual-databases/personal/mydb/run-001.sql.gz"
                            & #backend
                            .~ localMinioBackend
                        )
                    )
                )
            localMultipartScript =
              T.unpack
                ( T.replace
                    "4294967296"
                    "1"
                    ( T.replace
                        "/dump"
                        (T.pack dump)
                        ( uploadShell
                            ( backupJobInputsPg
                                & #verifyStored
                                .~ True
                                & #destination
                                .~ BackupDestUrl "s3://nagare-backups/manual-databases/personal/mydb/run-002.sql.gz"
                                & #backend
                                .~ localMinioBackend
                            )
                        )
                    )
                )
        createDirectoryIfMissing True dump
        writeFile fakeGcloud $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "[ \"$1\" = storage ] && [ \"$2\" = cp ] && [ \"$5\" = --if-generation-match=0 ] || exit 2"
            , "[ ! -e \"$NAGARE_TEST_OBJECT\" ] || exit 47"
            , "cat \"$3\" > \"$NAGARE_TEST_OBJECT\""
            ]
        writeFile fakeGsutil "#!/bin/sh\nset -eu\n[ \"$1\" = cp ] || exit 2\ncat \"$NAGARE_TEST_OBJECT\"\n"
        writeFile fakeAws $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "if [ \"$1\" = s3api ] && [ \"$2\" = put-bucket-versioning ]; then"
            , "  [ \"$3\" = --bucket ] && [ \"$4\" = nagare-backups ] || exit 4"
            , "  [ \"$5\" = --versioning-configuration ] && [ \"$6\" = Status=Enabled ] || exit 4"
            , "elif [ \"$1\" = s3api ] && [ \"$2\" = put-object ]; then"
            , "  shift 2; BODY=; CONDITIONAL=0; BUCKET=; KEY="
            , "  while [ \"$#\" -gt 0 ]; do"
            , "    case \"$1\" in"
            , "      --body) BODY=$2;; --bucket) BUCKET=$2;; --key) KEY=$2;;"
            , "      --if-none-match) [ \"$2\" = '*' ] || exit 3; CONDITIONAL=1;;"
            , "    esac"
            , "    shift 2"
            , "  done"
            , "  [ \"$CONDITIONAL\" = 1 ] && [ \"$BUCKET\" = nagare-backups ] && [ -n \"$KEY\" ] || exit 4"
            , "  [ ! -e \"$NAGARE_TEST_OBJECT\" ] || exit 47"
            , "  cat \"$BODY\" > \"$NAGARE_TEST_OBJECT\""
            , "elif [ \"$1\" = s3api ] && [ \"$2\" = create-multipart-upload ]; then"
            , "  echo upload-001"
            , "elif [ \"$1\" = s3api ] && [ \"$2\" = upload-part ]; then"
            , "  shift 2; BODY="
            , "  while [ \"$#\" -gt 0 ]; do"
            , "    case \"$1\" in --body) BODY=$2;; esac"
            , "    shift 2"
            , "  done"
            , "  cat \"$BODY\" > \"$NAGARE_TEST_OBJECT.part\""
            , "  echo '\"testetag\"'"
            , "elif [ \"$1\" = s3api ] && [ \"$2\" = complete-multipart-upload ]; then"
            , "  shift 2; CONDITIONAL=0; PARTS="
            , "  while [ \"$#\" -gt 0 ]; do"
            , "    case \"$1\" in"
            , "      --if-none-match) [ \"$2\" = '*' ] || exit 3; CONDITIONAL=1;;"
            , "      --multipart-upload) PARTS=${2#file://};;"
            , "    esac"
            , "    shift 2"
            , "  done"
            , "  [ \"$CONDITIONAL\" = 1 ] && [ -f \"$PARTS\" ] || exit 4"
            , "  grep -q '\"PartNumber\":1' \"$PARTS\" || exit 5"
            , "  [ ! -e \"$NAGARE_TEST_OBJECT\" ] || exit 47"
            , "  cat \"$NAGARE_TEST_OBJECT.part\" > \"$NAGARE_TEST_OBJECT\""
            , "elif [ \"$1\" = s3api ] && [ \"$2\" = abort-multipart-upload ]; then"
            , "  rm -f \"$NAGARE_TEST_OBJECT.part\""
            , "elif [ \"$1\" = s3 ] && [ \"$2\" = cp ]; then"
            , "  cat \"$NAGARE_TEST_OBJECT\""
            , "else exit 2; fi"
            ]
        writeFile fakeDnf "#!/bin/sh\nexit 0\n"
        mapM_ (`setFileMode` 0o755) [fakeGcloud, fakeGsutil, fakeAws, fakeDnf]
        parentEnv <- getEnvironment
        let path = maybe "" id (lookup "PATH" parentEnv)
            run script destination stored =
              readCreateProcessWithExitCode
                ( (proc "/bin/sh" ["-c", script])
                    { env =
                        Just
                          ( [ ("PATH", directory <> ":" <> path)
                            , ("DEST", destination)
                            , ("NAGARE_TEST_OBJECT", stored)
                            ]
                              <> filter
                                ( \(key, _) ->
                                    key
                                      `notElem` ["PATH", "DEST", "NAGARE_TEST_OBJECT"]
                                )
                                parentEnv
                          )
                    }
                )
                ""
        forM_
          [ ("GCS", cloudScript, "gs://test/manual-databases/personal/mydb/run-001.sql.gz")
          , ("MinIO", localScript, "s3://nagare-backups/manual-databases/personal/mydb/run-001.sql.gz")
          ]
          $ \(label, script, destination) -> do
            let stored = directory </> label <> ".gz"
            BS.writeFile (dump </> "backup.sql") "first backup payload\n"
            (created, _, createdError) <- run script destination stored
            assertBool
              (label <> " create-only upload failed: " <> createdError)
              (created == ExitSuccess)
            firstBytes <- BS.readFile stored
            BS.writeFile (dump </> "backup.sql") "changed backup payload\n"
            (overwrote, _, _) <- run script destination stored
            case overwrote of
              ExitFailure _ -> pure ()
              ExitSuccess -> assertFailure (label <> " overwrote an existing backup object")
            BS.readFile stored >>= (@?= firstBytes)
        let multipartStored = directory </> "MinIO-multipart.gz"
            multipartDestination = "s3://nagare-backups/manual-databases/personal/mydb/run-002.sql.gz"
        BS.writeFile (dump </> "backup.sql") "multipart first payload\n"
        (multipartCreated, _, multipartError) <- run localMultipartScript multipartDestination multipartStored
        assertBool
          ("MinIO conditional multipart upload failed: " <> multipartError)
          (multipartCreated == ExitSuccess)
        multipartFirstBytes <- BS.readFile multipartStored
        BS.writeFile (dump </> "backup.sql") "multipart changed payload\n"
        (multipartOverwrote, _, _) <- run localMultipartScript multipartDestination multipartStored
        case multipartOverwrote of
          ExitFailure _ -> pure ()
          ExitSuccess -> assertFailure "MinIO multipart upload overwrote an existing backup object"
        BS.readFile multipartStored >>= (@?= multipartFirstBytes)
        abandonedPart <- doesFileExist (multipartStored <> ".part")
        assertBool "failed multipart upload left an uncommitted part" (not abandonedPart)
  , testCase "reviewed backup writes a verified create-only receipt" $
      withSystemTempDirectory "nagare-backup-receipt" $ \directory -> do
        let dump = directory </> "dump"
            dataObject = directory </> "backup.gz"
            receiptObject = directory </> "backup.gz.receipt.json"
            terminationLog = directory </> "termination-log"
            dataUrl = "gs://test/backup.gz"
            receiptUrl = dataUrl <> ".receipt.json"
            metadata = "{\"id\":\"run-001\",\"object\":\"gs://test/backup.gz\"}"
            script =
              T.unpack
                ( T.replace
                    "/dump"
                    (T.pack dump)
                    ( uploadShell
                        ( backupJobInputsPg
                            & #verifyStored
                            .~ True
                            & #receipt
                            .~ Just (BackupReceipt (FixedReceiptTarget (T.pack receiptUrl)) (T.pack metadata))
                        )
                    )
                )
            fakeGcloud = directory </> "gcloud"
            fakeGsutil = directory </> "gsutil"
        createDirectoryIfMissing True dump
        writeFile fakeGcloud $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "[ \"$1\" = storage ] && [ \"$2\" = cp ] && [ \"$5\" = --if-generation-match=0 ] || exit 2"
            , "case \"$4\" in"
            , "  \"$DEST\") TARGET=$NAGARE_TEST_DATA;;"
            , "  \"$BACKUP_RECEIPT_DEST\") TARGET=$NAGARE_TEST_RECEIPT;;"
            , "  *) exit 3;;"
            , "esac"
            , "[ ! -e \"$TARGET\" ] || exit 47"
            , "cat \"$3\" > \"$TARGET\""
            ]
        writeFile fakeGsutil $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "[ \"$1\" = cp ] && [ \"$3\" = - ] || exit 2"
            , "case \"$2\" in"
            , "  \"$DEST\") cat \"$NAGARE_TEST_DATA\";;"
            , "  \"$BACKUP_RECEIPT_DEST\") cat \"$NAGARE_TEST_RECEIPT\";;"
            , "  *) exit 3;;"
            , "esac"
            ]
        mapM_ (`setFileMode` 0o755) [fakeGcloud, fakeGsutil]
        parentEnv <- getEnvironment
        let path = maybe "" id (lookup "PATH" parentEnv)
            receiptEnv =
              [ ("PATH", directory <> ":" <> path)
              , ("DEST", dataUrl)
              , ("BACKUP_RECEIPT_DEST", receiptUrl)
              , ("BACKUP_RECEIPT_METADATA", metadata)
              , ("BACKUP_TERMINATION_LOG_PATH", terminationLog)
              , ("NAGARE_TEST_DATA", dataObject)
              , ("NAGARE_TEST_RECEIPT", receiptObject)
              ]
            run =
              readCreateProcessWithExitCode
                ( (proc "/bin/sh" ["-c", script])
                    { env =
                        Just
                          (receiptEnv <> filter (\(key, _) -> key `notElem` map fst receiptEnv) parentEnv)
                    }
                )
                ""
        BS.writeFile (dump </> "backup.sql") "verified receipt source\n"
        (created, _, createError) <- run
        assertBool ("backup receipt upload failed: " <> createError) (created == ExitSuccess)
        dataBytes <- BS.readFile dataObject
        receiptBytes <- BS.readFile receiptObject
        BS.readFile terminationLog >>= (@?= receiptBytes)
        (hashExit, hashOutput, _) <-
          readCreateProcessWithExitCode
            (proc "sha256sum" [dataObject])
            ""
        hashExit @?= ExitSuccess
        case eitherDecodeStrict receiptBytes of
          Right (Aeson.Object root) -> do
            KeyMap.lookup "version" root @?= Just (Aeson.Number 1)
            KeyMap.lookup "sha256" root
              @?= Just (Aeson.String (T.pack (takeWhile (/= ' ') hashOutput)))
            case KeyMap.lookup "backup" root of
              Just (Aeson.Object backup) -> do
                KeyMap.lookup "id" backup @?= Just (Aeson.String "run-001")
                KeyMap.lookup "object" backup @?= Just (Aeson.String (T.pack dataUrl))
              other -> assertFailure ("receipt backup metadata missing: " <> show other)
          other -> assertFailure ("backup receipt JSON invalid: " <> show other)
        BS.writeFile (dump </> "backup.sql") "different receipt source\n"
        (duplicate, _, _) <- run
        case duplicate of
          ExitFailure _ -> pure ()
          ExitSuccess -> assertFailure "duplicate backup replaced an object"
        BS.readFile dataObject >>= (@?= dataBytes)
        BS.readFile receiptObject >>= (@?= receiptBytes)
  , testCase "reviewed scheduled backup writes a UID-bound receipt after stored-byte verification" $
      withSystemTempDirectory "nagare-scheduled-backup-receipt" $ \directory -> do
        realPython <-
          findExecutable "python3"
            >>= maybe
              (assertFailure "scheduled receipt test requires python3" >> pure "")
              pure
        let dump = directory </> "dump"
            dataObject = directory </> "backup.gz"
            receiptObject = directory </> "backup.gz.receipt.json"
            terminationLog = directory </> "termination-log"
            runId = "12345678-1234-1234-1234-123456789abc"
            dataUrl = "gs://test/databases/mydb/" <> runId <> ".sql.gz"
            receiptUrl = dataUrl <> ".receipt.json"
            metadata = "{\"database\":\"mydb\",\"schedule\":\"nagare-dbbackup-mydb\",\"scheduleRevision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"
            script =
              T.unpack
                ( T.replace
                    "/dump"
                    (T.pack dump)
                    ( uploadShell
                        ( backupJobInputsPg
                            & #verifyStored
                            .~ True
                            & #destination
                            .~ BackupDestStamped
                            & #receipt
                            .~ Just (BackupReceipt BackupObjectReceiptTarget (T.pack metadata))
                        )
                    )
                )
            fakeGcloud = directory </> "gcloud"
            fakeGsutil = directory </> "gsutil"
            fakePython = directory </> "python3"
            source = directory </> "source.json"
            sourceBytes = "{\"pvcUid\":\"11111111-1111-1111-1111-111111111111\",\"statefulSetUid\":\"22222222-2222-2222-2222-222222222222\"}\n"
        createDirectoryIfMissing True dump
        writeFile fakeGcloud $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "[ \"$1\" = storage ] && [ \"$2\" = cp ] && [ \"$5\" = --if-generation-match=0 ] || exit 2"
            , "case \"$4\" in"
            , "  \"$NAGARE_TEST_DATA_URL\") TARGET=$NAGARE_TEST_DATA;;"
            , "  \"$NAGARE_TEST_RECEIPT_URL\") TARGET=$NAGARE_TEST_RECEIPT;;"
            , "  *) exit 3;;"
            , "esac"
            , "[ ! -e \"$TARGET\" ] || exit 47"
            , "cat \"$3\" > \"$TARGET\""
            ]
        writeFile fakeGsutil $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "[ \"$1\" = cp ] && [ \"$3\" = - ] || exit 2"
            , "[ \"${NAGARE_TEST_FAIL_READBACK:-}\" != 1 ] || exit 49"
            , "case \"$2\" in"
            , "  \"$NAGARE_TEST_DATA_URL\") cat \"$NAGARE_TEST_DATA\";;"
            , "  \"$NAGARE_TEST_RECEIPT_URL\") cat \"$NAGARE_TEST_RECEIPT\";;"
            , "  *) exit 3;;"
            , "esac"
            ]
        writeFile fakePython $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "case \"$2\" in *urllib.request*) cat \"$NAGARE_TEST_SOURCE\";;"
            , "*) exec \"$NAGARE_TEST_REAL_PYTHON\" \"$@\";; esac"
            ]
        mapM_ (`setFileMode` 0o755) [fakeGcloud, fakeGsutil, fakePython]
        parentEnv <- getEnvironment
        let path = maybe "" id (lookup "PATH" parentEnv)
            receiptEnv =
              [ ("PATH", directory <> ":" <> path)
              , ("PREFIX", "gs://test/databases/mydb/")
              , ("BACKUP_RUN_ID", runId)
              , ("BACKUP_RECEIPT_METADATA", metadata)
              , ("BACKUP_SIGNING_KEY", replicate 64 'a')
              , ("BACKUP_TERMINATION_LOG_PATH", terminationLog)
              , ("NAGARE_TEST_DATA", dataObject)
              , ("NAGARE_TEST_RECEIPT", receiptObject)
              , ("NAGARE_TEST_DATA_URL", dataUrl)
              , ("NAGARE_TEST_RECEIPT_URL", receiptUrl)
              , ("NAGARE_TEST_SOURCE", source)
              , ("NAGARE_TEST_REAL_PYTHON", realPython)
              ]
            run failReadback =
              readCreateProcessWithExitCode
                ( (proc "/bin/sh" ["-c", script])
                    { env =
                        Just
                          ( ("NAGARE_TEST_FAIL_READBACK", failReadback)
                              : receiptEnv
                                <> filter
                                  ( \(key, _) ->
                                      key `notElem` map fst receiptEnv
                                        && key /= "NAGARE_TEST_FAIL_READBACK"
                                  )
                                  parentEnv
                          )
                    }
                )
                ""
        BS.writeFile (dump </> "backup.sql") "scheduled receipt source\n"
        BS.writeFile source sourceBytes
        BS.writeFile (dump </> "source.json") sourceBytes
        BS.writeFile (dump </> "recovery-point") "2026-10-02T12:00:00Z\n"
        (interrupted, _, _) <- run "1"
        assertBool "readback failure completed a scheduled receipt" (interrupted /= ExitSuccess)
        doesFileExist dataObject >>= (@?= True)
        doesFileExist receiptObject >>= (@?= False)
        (orphanRetry, _, _) <- run ""
        assertBool "retry overwrote an unreceipted object" (orphanRetry /= ExitSuccess)
        doesFileExist receiptObject >>= (@?= False)
        removeFile dataObject
        (created, _, createError) <- run ""
        assertBool ("scheduled receipt upload failed: " <> createError) (created == ExitSuccess)
        receiptBytes <- BS.readFile receiptObject
        BS.readFile terminationLog >>= (@?= receiptBytes)
        (hashExit, hashOutput, _) <-
          readCreateProcessWithExitCode
            (proc "sha256sum" [dataObject])
            ""
        hashExit @?= ExitSuccess
        case eitherDecodeStrict receiptBytes of
          Right (Aeson.Object root) -> do
            KeyMap.lookup "version" root @?= Just (Aeson.Number 5)
            case KeyMap.lookup "payload" root of
              Just payload@(Aeson.Object fields) -> do
                KeyMap.lookup "sha256" fields
                  @?= Just (Aeson.String (T.pack (takeWhile (/= ' ') hashOutput)))
                KeyMap.lookup "jobUid" fields @?= Just (Aeson.String (T.pack runId))
                KeyMap.lookup "object" fields @?= Just (Aeson.String (T.pack dataUrl))
                KeyMap.lookup "source" fields @?= either (error . show) id (eitherDecodeStrict sourceBytes)
                case KeyMap.lookup "backup" fields of
                  Just (Aeson.Object backup) ->
                    KeyMap.lookup "schedule" backup @?= Just (Aeson.String "nagare-dbbackup-mydb")
                  other -> assertFailure ("scheduled receipt metadata missing: " <> show other)
                let canonical = either (error . T.unpack) id (canonicalValue payload)
                    signature =
                      T.pack
                        ( show
                            ( hmacGetDigest
                                (hmac (BS.replicate 32 0xaa) canonical :: HMAC SHA256)
                            )
                        )
                KeyMap.lookup "hmacSha256" root @?= Just (Aeson.String signature)
              other -> assertFailure ("scheduled receipt payload missing: " <> show other)
          other -> assertFailure ("scheduled receipt JSON invalid: " <> show other)
        let metadataValue = either (error . show) id (eitherDecodeStrict (BC.pack metadata))
            metadataDigest = contentDigest (either (error . T.unpack) id (canonicalValue metadataValue))
            sourceUid value = either (error . T.unpack) id (Resource.mkPhysicalIdentity value)
            expectation =
              ScheduledReceiptExpectation
                "gs://test/databases/mydb/"
                "sql.gz"
                7
                metadataDigest
                metadataDigest
                (Just (sourceUid "22222222-2222-2222-2222-222222222222"))
                (sourceUid "11111111-1111-1111-1111-111111111111")
                HourlyRecoveryPoint
            accepted =
              parseScheduledBackupReceipt
                expectation
                (T.pack receiptUrl)
                (T.replicate 64 "a")
                receiptBytes
        case accepted of
          Left reason -> assertFailure ("signed scheduled receipt was rejected: " <> T.unpack reason)
          Right checked -> do
            Resource.physicalIdentityText (scheduledJobUid checked) @?= T.pack runId
            fmap show (scheduledRecoveryPoint checked) @?= Just "2026-10-02 12:00:00 UTC"
        assertBool
          "foreign receipt address was accepted"
          ( isLeft
              ( parseScheduledBackupReceipt
                  expectation
                  "gs://test/other.receipt.json"
                  (T.replicate 64 "a")
                  receiptBytes
              )
          )
        assertBool
          "changed signing key was accepted"
          ( isLeft
              ( parseScheduledBackupReceipt
                  expectation
                  (T.pack receiptUrl)
                  (T.replicate 64 "b")
                  receiptBytes
              )
          )
        assertBool
          "changed source UID was accepted"
          ( isLeft
              ( parseScheduledBackupReceipt
                  (expectation {scheduledPvcUid = sourceUid "33333333-3333-3333-3333-333333333333"})
                  (T.pack receiptUrl)
                  (T.replicate 64 "a")
                  receiptBytes
              )
          )
        (duplicate, _, _) <- run ""
        case duplicate of
          ExitFailure _ -> pure ()
          ExitSuccess -> assertFailure "duplicate scheduled run replaced an existing object"
        removeFile dataObject
        removeFile receiptObject
        BS.writeFile source "{\"pvcUid\":\"33333333-3333-3333-3333-333333333333\",\"statefulSetUid\":\"22222222-2222-2222-2222-222222222222\"}\n"
        (changedSource, _, _) <- run ""
        assertBool "source replacement completed a scheduled receipt" (changedSource /= ExitSuccess)
        doesFileExist receiptObject >>= (@?= False)
  ]
