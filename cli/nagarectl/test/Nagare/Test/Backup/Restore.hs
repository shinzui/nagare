-- | Backup.Restore responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Backup.Restore
  ( restoreDownloadTests
  )
where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Restore
  ( VerifiedRestoreSource
      ( VerifiedRestoreSource
      , backupSha256
      , expiryEpoch
      , objectVersion
      , receiptSha256
      , receiptUrl
      , receiptVersion
      , scratchDatabase
      )
  , downloadShell
  , isObjectUrl
  , renderRedisScratchService
  , renderRedisScratchStatefulSet
  , renderRedisScratchVerifyJob
  , renderRestoreJob
  , resolveBackupObject
  )
import Nagare.Dsl.Database (Engine (ClickHouse, Postgres, Redis))
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Test.DataFixtures
  ( localMinioBackend
  , restoreJobInputsPg
  , tnbGcsBackend
  )
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process
  ( CreateProcess (env)
  , proc
  , readCreateProcessWithExitCode
  )
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

restoreDownloadTests :: [TestTree]
restoreDownloadTests =
  [ testCase "isObjectUrl recognizes gs:// and s3://" $ do
      isObjectUrl "gs://b/x" @?= True
      isObjectUrl "s3://b/x" @?= True
      isObjectUrl "20260610T141503Z" @?= False
  , testCase "resolveBackupObject composes a bare timestamp (cloud)" $
      resolveBackupObject (GcsBackend "p" "b") "mydb" "sql.gz" "20260610T141503Z" @?= "gs://b/databases/mydb/20260610T141503Z.sql.gz"
  , testCase "resolveBackupObject passes a full URL through" $
      resolveBackupObject (GcsBackend "p" "b") "mydb" "sql.gz" "gs://other/x.sql.gz" @?= "gs://other/x.sql.gz"
  , testCase "renderRestoreJob targets a scratch database by default" $ do
      let y = TE.decodeUtf8 (renderRestoreJob restoreJobInputsPg)
      assertBool "kind Job" ("kind: Job" `T.isInfixOf` y)
      assertBool "download init" ("gunzip" `T.isInfixOf` y)
      assertBool "scratch target" ("_restore_scratch" `T.isInfixOf` y)
  , testCase "renderRestoreJob into live drops the scratch suffix" $ do
      let y = TE.decodeUtf8 (renderRestoreJob (restoreJobInputsPg & #liveTarget .~ True))
      assertBool "live warning" ("LIVE database" `T.isInfixOf` y)
      assertBool "no scratch suffix" (not ("_restore_scratch" `T.isInfixOf` y))
  , testCase "reviewed Redis scratch loads a pinned RDB into a separate PVC-backed server" $ do
      let scratch = "mydb-restore-rdbone"
          selected =
            VerifiedRestoreSource
              "s3://nagare-backups/databases/mydb/run-001.rdb.gz.receipt.json"
              "receipt-sha"
              "object-sha"
              scratch
              0
              (Just "object-version")
              (Just "receipt-version")
          request =
            restoreJobInputsPg
              & #engine
              .~ Redis
              & #clientImage
              .~ "redis:8"
              & #sourceUrl
              .~ "s3://nagare-backups/databases/mydb/run-001.rdb.gz"
              & #verifiedSource
              .~ Just selected
              & #backend
              .~ localMinioBackend
          service = renderRedisScratchService "personal" scratch
          stateful = renderRedisScratchStatefulSet request scratch scratch
          verify = renderRedisScratchVerifyJob request scratch
      assertBool
        "scratch Service does not select the source"
        ( BC.isInfixOf "nagare.dev/restore-scratch" service
            && not (BC.isInfixOf "nagare.dev/database" service)
        )
      assertBool
        "scratch has a persistent, separately named PVC"
        (BC.isInfixOf "claimName: mydb-restore-rdbone" stateful)
      assertBool
        "startup downloads exact versions and checks both hashes"
        ( all
            (`BC.isInfixOf` stateful)
            [ "OBJECT_VERSION"
            , "RECEIPT_VERSION"
            , "EXPECTED_BACKUP_SHA256"
            , "EXPECTED_RECEIPT_SHA256"
            , "redis-check-rdb"
            , "--dbfilename backup.rdb"
            ]
        )
      assertBool
        "retry cannot silently overwrite uncertain RDB state"
        ( all
            (`BC.isInfixOf` stateful)
            [".nagare-restore-complete", "test ! -e /dump/backup.rdb"]
        )
      assertBool
        "verification observes the isolated server"
        ( all
            (`BC.isInfixOf` verify)
            ["mydb-restore-rdbone", "DBSIZE", "loading:0"]
        )
  , testCase "reviewed ClickHouse scratch restores a pinned database ZIP" $ do
      let scratch = "mydb_restore_zipone"
          selected =
            VerifiedRestoreSource
              "s3://nagare-backups/databases/mydb/run-001.zip.gz.receipt.json"
              "receipt-sha"
              "object-sha"
              scratch
              0
              (Just "object-version")
              (Just "receipt-version")
          request =
            restoreJobInputsPg
              & #engine
              .~ ClickHouse
              & #clientImage
              .~ "clickhouse/clickhouse-server:25.8"
              & #sourceUrl
              .~ "s3://nagare-backups/databases/mydb/run-001.zip.gz"
              & #verifiedSource
              .~ Just selected
              & #backend
              .~ localMinioBackend
          rendered = renderRestoreJob request
      assertBool
        "download verifies exact versions before exposing the ZIP"
        ( all
            (`BC.isInfixOf` rendered)
            [ "OBJECT_VERSION"
            , "RECEIPT_VERSION"
            , "EXPECTED_BACKUP_SHA256"
            , "EXPECTED_RECEIPT_SHA256"
            , "/dump/backup.zip"
            ]
        )
      assertBool
        "restore shares only the accepted source PVC on its node"
        ( all
            (`BC.isInfixOf` rendered)
            ["nagare-db-mydb-data", "kubernetes.io/hostname", "/source-data"]
        )
      assertBool
        "native database restore targets a separate database once"
        ( all
            (`BC.isInfixOf` rendered)
            [ "RESTORE DATABASE default AS"
            , "mydb_restore_zipone"
            , "test ! -e"
            , "backoffLimit: 0"
            ]
        )
  , testCase "reviewed scratch restore checks fresh receipt and backup bytes before decompressing" $
      withSystemTempDirectory "nagare-reviewed-restore" $ \directory -> do
        let dump = directory </> "dump"
            source = directory </> "source.sql"
            storedBackup = directory </> "backup.gz"
            storedReceipt = directory </> "backup.receipt.json"
            fakeGsutil = directory </> "gsutil"
            objectUrl = "gs://test/manual-databases/personal/mydb/run-001.sql.gz"
            receiptUrl = objectUrl <> ".receipt.json"
        createDirectoryIfMissing True dump
        BS.writeFile source "CREATE TABLE restored (id integer);\n"
        BS.writeFile storedReceipt "{\"version\":1,\"sha256\":\"checked\"}\n"
        parentEnv <- getEnvironment
        let path = maybe "" id (lookup "PATH" parentEnv)
            fixtureEnv =
              [ ("PATH", directory <> ":" <> path)
              , ("SRC", objectUrl)
              , ("RECEIPT_URL", receiptUrl)
              , ("NAGARE_TEST_RAW", source)
              , ("NAGARE_TEST_BACKUP", storedBackup)
              , ("NAGARE_TEST_RECEIPT", storedReceipt)
              ]
            withFixture command =
              readCreateProcessWithExitCode
                ( (proc "/bin/sh" ["-c", command])
                    { env =
                        Just
                          (fixtureEnv <> filter (\(key, _) -> key `notElem` map fst fixtureEnv) parentEnv)
                    }
                )
                ""
        (gzipCode, _, gzipError) <-
          withFixture
            "gzip -n -c \"$NAGARE_TEST_RAW\" > \"$NAGARE_TEST_BACKUP\""
        assertBool
          ("could not prepare restore fixture: " <> gzipError)
          (gzipCode == ExitSuccess)
        writeFile fakeGsutil $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "[ \"$1\" = cp ] && [ \"$3\" = - ] || exit 2"
            , "case \"$2\" in"
            , "  \"$RECEIPT_URL\") cat \"$NAGARE_TEST_RECEIPT\";;"
            , "  \"$SRC\") cat \"$NAGARE_TEST_BACKUP\";;"
            , "  *) exit 3;;"
            , "esac"
            ]
        setFileMode fakeGsutil 0o755
        let fileHash pathToHash = do
              (code, output, _) <-
                readCreateProcessWithExitCode
                  (proc "sha256sum" [pathToHash])
                  ""
              code @?= ExitSuccess
              pure (T.pack (takeWhile (/= ' ') output))
        receiptHash <- fileHash storedReceipt
        backupHash <- fileHash storedBackup
        let checked =
              VerifiedRestoreSource
                { receiptUrl = T.pack receiptUrl
                , receiptSha256 = receiptHash
                , backupSha256 = backupHash
                , scratchDatabase = "mydb_restore_run001"
                , expiryEpoch = 0
                , objectVersion = Nothing
                , receiptVersion = Nothing
                }
            script selected =
              T.unpack
                ( T.replace
                    "/dump"
                    (T.pack dump)
                    (downloadShell tnbGcsBackend Postgres (Just selected))
                )
            run selected =
              readCreateProcessWithExitCode
                ( (proc "/bin/sh" ["-c", script selected])
                    { env =
                        Just
                          ( [ ("EXPECTED_RECEIPT_SHA256", T.unpack (receiptSha256 selected))
                            , ("EXPECTED_BACKUP_SHA256", T.unpack (backupSha256 selected))
                            , ("BACKUP_EXPIRY_EPOCH", show (expiryEpoch selected))
                            ]
                              <> fixtureEnv
                              <> filter
                                ( \(key, _) ->
                                    key
                                      `notElem` ["EXPECTED_RECEIPT_SHA256", "EXPECTED_BACKUP_SHA256", "BACKUP_EXPIRY_EPOCH"]
                                      && key `notElem` map fst fixtureEnv
                                )
                                parentEnv
                          )
                    }
                )
                ""
        (good, _, goodError) <- run checked
        assertBool ("verified restore download failed: " <> goodError) (good == ExitSuccess)
        BS.readFile (dump </> "backup.sql") >>= (@?= "CREATE TABLE restored (id integer);\n")
        (wrongReceipt, _, _) <- run (checked {receiptSha256 = T.replicate 64 "0"})
        assertBool "changed receipt completed reviewed restore" (wrongReceipt /= ExitSuccess)
        (wrongBackup, _, _) <- run (checked {backupSha256 = T.replicate 64 "0"})
        assertBool "changed backup completed reviewed restore" (wrongBackup /= ExitSuccess)
        (expired, _, _) <- run (checked {expiryEpoch = 1})
        assertBool "expired backup completed reviewed restore" (expired /= ExitSuccess)
  ]
