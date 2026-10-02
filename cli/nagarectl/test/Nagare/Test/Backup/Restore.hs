-- | Backup.Restore responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Backup.Restore
  ( restoreDownloadTests
  )
where

import Data.Aeson (Value (Array, Object, String))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as Vector
import Data.Yaml qualified as Yaml
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
import System.Directory (createDirectoryIfMissing, doesFileExist)
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
  , clickHouseProbeTest "transient verification retries only SELECT" "transient" 3 True
  , clickHouseProbeTest "unavailable verification preserves archive" "unavailable" 6 False
  , clickHouseProbeTest "missing scratch database preserves archive" "missing" 6 False
  , clickHouseProbeTest "failed RESTORE never enters verification" "restore-failure" 0 False
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

-- Run the actual rendered container command, including its shell failure paths.
-- The fake client distinguishes the data effect from read-only verification.
clickHouseProbeTest :: String -> String -> Int -> Bool -> TestTree
clickHouseProbeTest label mode expectedProbes successful =
  testCase ("ClickHouse " <> label) $
    withSystemTempDirectory "nagare-clickhouse-probe" $ \directory -> do
      let dump = directory </> "dump"
          source = directory </> "source-data"
          archive = source </> "backups/nagare-restore-scratch.zip"
          calls = directory </> "calls"
          client = directory </> "clickhouse-client"
          sleeper = directory </> "sleep"
          selected = VerifiedRestoreSource "gs://bucket/receipt" "receipt" "backup" "scratch" 0 Nothing Nothing
          rendered = renderRestoreJob (restoreJobInputsPg & #engine .~ ClickHouse & #verifiedSource .~ Just selected)
          field key (Object fields) = KeyMap.lookup key fields
          field _ _ = Nothing
          firstValue (Array values) = values Vector.!? 0
          firstValue _ = Nothing
          shell = do
            root <- either (const Nothing) Just (Yaml.decodeEither' rendered)
            spec <- field "spec" root >>= field "template" >>= field "spec"
            container <- field "containers" spec >>= firstValue
            value <- field "args" container >>= firstValue
            case value of
              String command -> Just command
              _ -> Nothing
      command <- maybe (fail "rendered restore container has no shell command") pure shell
      createDirectoryIfMissing True dump
      createDirectoryIfMissing True (source </> "backups")
      BS.writeFile (dump </> "backup.zip") "exact reviewed archive"
      BS.writeFile calls ""
      writeFile client $
        unlines
          [ "#!/bin/sh"
          , "set -eu"
          , "printf '%s\\n' \"$*\" >> \"$NAGARE_TEST_CALLS\""
          , "case \"$*\" in"
          , "  *'RESTORE DATABASE'*) test \"$NAGARE_TEST_MODE\" != restore-failure; exit $?;;"
          , "  *'SELECT count() FROM system.databases'*)"
          , "    for flag in connect_timeout send_timeout receive_timeout max_execution_time; do"
          , "      case \" $* \" in *\" --${flag}=5 \"*) :;; *) exit 7;; esac"
          , "    done"
          , "    count=$(wc -l < \"$NAGARE_TEST_CALLS\")"
          , "    case \"$NAGARE_TEST_MODE\" in"
          , "      transient) test \"$count\" -gt 3 || exit 1; echo 1;;"
          , "      missing) echo 0;;"
          , "      *) exit 1;;"
          , "    esac;;"
          , "  *) exit 8;;"
          , "esac"
          ]
      writeFile sleeper "#!/bin/sh\ntest \"$1\" = 2\n"
      setFileMode client 0o755
      setFileMode sleeper 0o755
      parentEnv <- getEnvironment
      let fixtureEnv =
            [ ("PATH", directory <> ":" <> maybe "" id (lookup "PATH" parentEnv))
            , ("NAGARE_TEST_CALLS", calls)
            , ("NAGARE_TEST_MODE", mode)
            , ("CLICKHOUSE_USER", "fixture")
            , ("CLICKHOUSE_PASSWORD", "fixture")
            ]
          run =
            readCreateProcessWithExitCode
              ( (proc "/bin/sh" ["-c", T.unpack (T.replace "/source-data" (T.pack source) (T.replace "/dump" (T.pack dump) command))])
                  { env = Just (fixtureEnv <> filter (\(key, _) -> key `notElem` map fst fixtureEnv) parentEnv)
                  }
              )
              ""
      (code, _, diagnostic) <- run
      assertBool ("unexpected restore result: " <> diagnostic) ((code == ExitSuccess) == successful)
      recorded <- lines <$> readFile calls
      length recorded @?= 1 + expectedProbes
      length (filter (T.isInfixOf "RESTORE DATABASE" . T.pack) recorded) @?= 1
      doesFileExist archive >>= (@?= not successful)
      unless successful $ do
        BS.readFile archive >>= (@?= "exact reviewed archive")
        (retryCode, _, _) <- run
        assertBool "existing archive permitted replay" (retryCode /= ExitSuccess)
        (lines <$> readFile calls) >>= (@?= recorded)
