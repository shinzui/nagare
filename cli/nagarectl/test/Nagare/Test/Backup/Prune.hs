-- | Backup.Prune responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Backup.Prune
  ( backupPruneTests
  )
where

import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Backup (renderBackupJob)
import Nagare.Database.Prune
  ( PruneJobInputs (PruneJobInputs)
  , pruneShell
  , renderPruneJob
  , renderScheduledPruneJob
  , renderScheduledReceiptRecoveryJob
  , scheduledPruneShell
  , scheduledReceiptRecoveryShell
  )
import Nagare.Database.Restore (renderRestoreJob)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Test.DataFixtures
  ( backupJobInputsPg
  , localMinioBackend
  , restoreJobInputsPg
  )
import System.Directory (doesFileExist, removeFile)
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

backupPruneTests :: [TestTree]
backupPruneTests =
  [ testCase "backup Jobs wait for the server and retry" $ do
      let y = TE.decodeUtf8 (renderBackupJob backupJobInputsPg)
      assertBool "waits for the server before the dump" ("until pg_isready -q -h mydb" `T.isInfixOf` y)
      assertBool "retries" ("backoffLimit: 2" `T.isInfixOf` y)
      assertBool "on-demand keeps its fixed DEST" ("value: gs://tan-nb-exp-nagare-backups/databases/mydb/20260610T141503Z.sql.gz" `T.isInfixOf` y)
  , testCase "restore Jobs still never retry" $
      assertBool "backoffLimit 0" ("backoffLimit: 0" `T.isInfixOf` TE.decodeUtf8 (renderRestoreJob restoreJobInputsPg))
  , testCase "reviewed prune deletes only verified GCS generations" $
      withSystemTempDirectory "nagare-reviewed-prune" $ \directory -> do
        let object = directory </> "backup.gz"
            receipt = directory </> "backup.gz.receipt.json"
            fakeGcloud = directory </> "gcloud"
            objectUrl = "gs://test/manual-databases/personal/mydb/run-001.sql.gz"
            receiptUrl = objectUrl <> ".receipt.json"
        BS.writeFile object "verified backup bytes"
        BS.writeFile receipt "verified receipt bytes"
        let fileHash pathToHash = do
              (code, output, _) <-
                readCreateProcessWithExitCode
                  (proc "sha256sum" [pathToHash])
                  ""
              code @?= ExitSuccess
              pure (T.pack (takeWhile (/= ' ') output))
        objectHash <- fileHash object
        receiptHash <- fileHash receipt
        let inputs =
              PruneJobInputs
                "personal"
                "nagare-dbprune-mydb-run-001"
                (T.pack objectUrl)
                (T.pack receiptUrl)
                objectHash
                receiptHash
                0
                (GcsBackend "project" "test")
            rendered = TE.decodeUtf8 (renderPruneJob inputs)
        assertBool
          "prune Job may retry an uncertain delete"
          ("backoffLimit: 0" `T.isInfixOf` rendered)
        writeFile fakeGcloud $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "if [ \"$1 $2\" = \"auth print-access-token\" ]; then echo token; exit 0; fi"
            , "[ \"$1\" = storage ] || exit 2; shift"
            , "case \"$1\" in"
            , "  objects)"
            , "    [ \"$2\" = describe ] || exit 2"
            , "    case \"$3\" in"
            , "      \"$OBJECT\") echo 7;;"
            , "      \"$RECEIPT\") echo 9;;"
            , "      *) exit 2;;"
            , "    esac;;"
            , "  cp)"
            , "    [ \"$3\" = - ] || exit 2"
            , "    case \"$2\" in"
            , "      \"$OBJECT#7\") cat \"$NAGARE_TEST_DATA\";;"
            , "      \"$RECEIPT#9\") cat \"$NAGARE_TEST_RECEIPT\";;"
            , "      *) exit 2;;"
            , "    esac;;"
            , "  rm)"
            , "    case \"$2:$3\" in"
            , "      \"$OBJECT:--if-generation-match=7\") rm \"$NAGARE_TEST_DATA\";;"
            , "      \"$RECEIPT:--if-generation-match=9\") rm \"$NAGARE_TEST_RECEIPT\";;"
            , "      *) exit 2;;"
            , "    esac;;"
            , "  *) exit 2;;"
            , "esac"
            ]
        setFileMode fakeGcloud 0o755
        -- The JSON API answers 404 once no live object remains at the key.
        writeFile (directory </> "curl") $
          unlines
            [ "#!/bin/sh"
            , "for last in \"$@\"; do :; done"
            , "case \"$last\" in"
            , "  *.receipt.json) test -e \"$NAGARE_TEST_RECEIPT\" && printf 200 || printf 404;;"
            , "  *) test -e \"$NAGARE_TEST_DATA\" && printf 200 || printf 404;;"
            , "esac"
            ]
        setFileMode (directory </> "curl") 0o755
        parentEnv <- getEnvironment
        let path = maybe "" id (lookup "PATH" parentEnv)
            variables =
              [ ("PATH", directory <> ":" <> path)
              , ("OBJECT", objectUrl)
              , ("RECEIPT", receiptUrl)
              , ("NAGARE_TEST_DATA", object)
              , ("NAGARE_TEST_RECEIPT", receipt)
              , ("EXPECTED_OBJECT_SHA256", T.unpack objectHash)
              , ("EXPECTED_RECEIPT_SHA256", T.unpack receiptHash)
              , ("EXPIRY_EPOCH", "0")
              ]
            run =
              readCreateProcessWithExitCode
                ( (proc "/bin/sh" ["-c", T.unpack (pruneShell inputs)])
                    { env =
                        Just
                          ( variables
                              <> filter (\(key, _) -> key `notElem` map fst variables) parentEnv
                          )
                    }
                )
                ""
            runPinned objectVersion receiptVersion =
              let pins =
                    [ ("EXPECTED_OBJECT_VERSION", T.unpack objectVersion)
                    , ("EXPECTED_RECEIPT_VERSION", T.unpack receiptVersion)
                    ]
               in readCreateProcessWithExitCode
                    ( ( proc
                          "/bin/sh"
                          [ "-c"
                          , T.unpack
                              (scheduledPruneShell inputs)
                          ]
                      )
                        { env =
                            Just
                              ( pins
                                  <> variables
                                  <> filter (\(key, _) -> key `notElem` map fst (pins <> variables)) parentEnv
                              )
                        }
                    )
                    ""
        let scheduledManifest =
              TE.decodeUtf8
                (renderScheduledPruneJob inputs "7" "9")
        assertBool
          "scheduled prune manifest lacks exact version pins"
          ( "EXPECTED_OBJECT_VERSION" `T.isInfixOf` scheduledManifest
              && "EXPECTED_RECEIPT_VERSION" `T.isInfixOf` scheduledManifest
              && "nagare.dev/scheduled-prune" `T.isInfixOf` scheduledManifest
          )
        (wrongVersion, _, _) <- runPinned "8" "9"
        assertBool "changed reviewed version was deleted" (wrongVersion /= ExitSuccess)
        doesFileExist object >>= (@?= True)
        doesFileExist receipt >>= (@?= True)
        BS.writeFile object "changed backup bytes"
        (changed, _, _) <- run
        assertBool "changed data was pruned" (changed /= ExitSuccess)
        doesFileExist object >>= (@?= True)
        doesFileExist receipt >>= (@?= True)
        BS.writeFile object "verified backup bytes"
        (deleted, _, diagnostic) <- run
        assertBool ("exact prune failed: " <> diagnostic) (deleted == ExitSuccess)
        doesFileExist object >>= (@?= False)
        doesFileExist receipt >>= (@?= False)
        BS.writeFile object "verified backup bytes"
        BS.writeFile receipt "verified receipt bytes"
        (pinnedDelete, _, pinnedDiagnostic) <- runPinned "7" "9"
        assertBool
          ("exact scheduled prune failed: " <> pinnedDiagnostic)
          (pinnedDelete == ExitSuccess)
        doesFileExist object >>= (@?= False)
        doesFileExist receipt >>= (@?= False)
  , testCase "reviewed local prune refuses unversioned MinIO objects" $
      withSystemTempDirectory "nagare-unversioned-prune" $ \directory -> do
        let fakeAws = directory </> "aws"
            fakeDnf = directory </> "dnf"
            marker = directory </> "delete-called"
            objectUrl = "s3://nagare-backups/manual-databases/personal/mydb/run-001.sql.gz"
            inputs =
              PruneJobInputs
                "personal"
                "nagare-dbprune-mydb-run-001"
                objectUrl
                (objectUrl <> ".receipt.json")
                (T.replicate 64 "a")
                (T.replicate 64 "b")
                0
                localMinioBackend
        writeFile fakeAws $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "if [ \"$1\" = s3api ] && [ \"$2\" = head-object ]; then"
            , "  echo None"
            , "else touch \"$NAGARE_TEST_MARKER\"; exit 99; fi"
            ]
        writeFile fakeDnf "#!/bin/sh\nexit 0\n"
        mapM_ (`setFileMode` 0o755) [fakeAws, fakeDnf]
        parentEnv <- getEnvironment
        let path = maybe "" id (lookup "PATH" parentEnv)
            variables =
              [ ("PATH", directory <> ":" <> path)
              , ("OBJECT", T.unpack objectUrl)
              , ("RECEIPT", T.unpack (objectUrl <> ".receipt.json"))
              , ("EXPIRY_EPOCH", "0")
              , ("NAGARE_TEST_MARKER", marker)
              ]
        (result, _, _) <-
          readCreateProcessWithExitCode
            ( (proc "/bin/sh" ["-c", T.unpack (pruneShell inputs)])
                { env =
                    Just
                      ( variables
                          <> filter (\(key, _) -> key `notElem` map fst variables) parentEnv
                      )
                }
            )
            ""
        assertBool "unversioned local backup was pruned" (result /= ExitSuccess)
        doesFileExist marker >>= (@?= False)
  , testCase "reviewed MinIO prune deletes selected versions and refuses an exposed older version" $
      withSystemTempDirectory "nagare-versioned-prune" $ \directory -> do
        let fakeAws = directory </> "aws"
            fakeDnf = directory </> "dnf"
            object = directory </> "backup.gz"
            receipt = directory </> "backup.gz.receipt.json"
            objectUrl = "s3://nagare-backups/manual-databases/personal/mydb/run-001.sql.gz"
            objectKey = "manual-databases/personal/mydb/run-001.sql.gz"
        writeFile fakeAws $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "[ \"$1\" = s3api ] || exit 2; ACTION=$2; shift 2"
            , "KEY=; VERSION=; PREFIX=; OUT="
            , "while [ \"$#\" -gt 0 ]; do"
            , "  case \"$1\" in"
            , "    --key) KEY=$2; shift 2;;"
            , "    --version-id) VERSION=$2; shift 2;;"
            , "    --prefix) PREFIX=$2; shift 2;;"
            , "    --bucket|--query|--output|--endpoint-url) shift 2;;"
            , "    *) OUT=$1; shift;;"
            , "  esac"
            , "done"
            , "case \"$KEY$PREFIX\" in"
            , "  \"$NAGARE_TEST_KEY\") TARGET=$NAGARE_TEST_DATA; EXPECTED=v1;;"
            , "  \"$NAGARE_TEST_KEY.receipt.json\") TARGET=$NAGARE_TEST_RECEIPT; EXPECTED=v2;;"
            , "  *) exit 3;;"
            , "esac"
            , "case \"$ACTION\" in"
            , "  head-object) [ -f \"$TARGET\" ] || exit 4; echo \"$EXPECTED\";;"
            , "  get-object) [ \"$VERSION\" = \"$EXPECTED\" ] || exit 5;"
            , "    cat \"$TARGET\" > \"$OUT\"; echo '{}' ;;"
            , "  delete-object) [ \"$VERSION\" = \"$EXPECTED\" ] || exit 6;"
            , "    if [ \"$NAGARE_TEST_OLDER\" != 1 ] || [ \"$KEY\" != \"$NAGARE_TEST_KEY\" ]; then"
            , "      rm \"$TARGET\""
            , "    fi; echo '{}' ;;"
            , "  list-objects-v2) if [ -f \"$TARGET\" ]; then echo \"$KEY$PREFIX\";"
            , "    elif [ \"$PREFIX\" = \"$NAGARE_TEST_KEY\" ] && [ -f \"$NAGARE_TEST_RECEIPT\" ]; then"
            , "      echo \"$NAGARE_TEST_KEY.receipt.json\"; else echo None; fi;;"
            , "  *) exit 7;;"
            , "esac"
            ]
        writeFile fakeDnf "#!/bin/sh\nexit 0\n"
        mapM_ (`setFileMode` 0o755) [fakeAws, fakeDnf]
        parentEnv <- getEnvironment
        let fileHash pathToHash = do
              (code, output, _) <-
                readCreateProcessWithExitCode
                  (proc "sha256sum" [pathToHash])
                  ""
              code @?= ExitSuccess
              pure (T.pack (takeWhile (/= ' ') output))
            path = maybe "" id (lookup "PATH" parentEnv)
            run older dataHash selectedReceiptHash inputs = do
              let variables =
                    [ ("PATH", directory <> ":" <> path)
                    , ("OBJECT", T.unpack objectUrl)
                    , ("RECEIPT", T.unpack (objectUrl <> ".receipt.json"))
                    , ("EXPIRY_EPOCH", "0")
                    , ("EXPECTED_OBJECT_SHA256", T.unpack dataHash)
                    , ("EXPECTED_RECEIPT_SHA256", T.unpack selectedReceiptHash)
                    , ("NAGARE_TEST_DATA", object)
                    , ("NAGARE_TEST_RECEIPT", receipt)
                    , ("NAGARE_TEST_KEY", objectKey)
                    , ("NAGARE_TEST_OLDER", if older then "1" else "0")
                    ]
              readCreateProcessWithExitCode
                ( (proc "/bin/sh" ["-c", T.unpack (pruneShell inputs)])
                    { env =
                        Just
                          ( variables
                              <> filter (\(key, _) -> key `notElem` map fst variables) parentEnv
                          )
                    }
                )
                ""
        BS.writeFile object "versioned backup bytes"
        BS.writeFile receipt "versioned receipt bytes"
        objectHash <- fileHash object
        receiptHash <- fileHash receipt
        let inputs =
              PruneJobInputs
                "personal"
                "nagare-dbprune-mydb-run-001"
                objectUrl
                (objectUrl <> ".receipt.json")
                objectHash
                receiptHash
                0
                localMinioBackend
        (exposed, _, _) <- run True objectHash receiptHash inputs
        assertBool "older local version was treated as absent" (exposed /= ExitSuccess)
        doesFileExist receipt >>= (@?= True)
        (deleted, _, diagnostic) <- run False objectHash receiptHash inputs
        assertBool
          ("versioned local prune failed: " <> diagnostic)
          (deleted == ExitSuccess)
        doesFileExist object >>= (@?= False)
        doesFileExist receipt >>= (@?= False)
  , testCase "reviewed scheduled partial prune deletes only the remaining receipt version" $
      withSystemTempDirectory "nagare-partial-scheduled-prune" $ \directory -> do
        let fakeAws = directory </> "aws"
            fakeDnf = directory </> "dnf"
            object = directory </> "backup.rdb.gz"
            receipt = directory </> "backup.rdb.gz.receipt.json"
            objectKey = "databases/mydb/run-001.rdb.gz"
            objectUrl = "s3://nagare-backups/" <> objectKey
            inputs receiptHash =
              PruneJobInputs
                "personal"
                "nagare-schedprune-recover"
                (T.pack objectUrl)
                (T.pack (objectUrl <> ".receipt.json"))
                (T.replicate 64 "a")
                receiptHash
                0
                localMinioBackend
        writeFile fakeAws $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "if [ \"$1\" = --no-paginate ]; then shift; fi"
            , "[ \"$1\" = s3api ] || exit 2; ACTION=$2; shift 2"
            , "KEY=; PREFIX=; VERSION=; OUT="
            , "while [ \"$#\" -gt 0 ]; do"
            , "  case \"$1\" in"
            , "    --key) KEY=$2; shift 2;;"
            , "    --prefix) PREFIX=$2; shift 2;;"
            , "    --version-id) VERSION=$2; shift 2;;"
            , "    --bucket|--query|--output|--endpoint-url) shift 2;;"
            , "    *) OUT=$1; shift;;"
            , "  esac"
            , "done"
            , "case \"$ACTION\" in"
            , "  list-object-versions)"
            , "    printf '{\"IsTruncated\":false,\"Versions\":['"
            , "    if [ \"$PREFIX\" = \"$NAGARE_TEST_DATA_KEY\" ] && [ -f \"$NAGARE_TEST_DATA\" ]; then"
            , "      printf '{\"Key\":\"%s\",\"VersionId\":\"v1\"},' \"$NAGARE_TEST_DATA_KEY\""
            , "    fi"
            , "    if [ -f \"$NAGARE_TEST_RECEIPT\" ]; then"
            , "      printf '{\"Key\":\"%s\",\"VersionId\":\"v2\"}' \"$NAGARE_TEST_RECEIPT_KEY\""
            , "    fi"
            , "    printf ']}\\n';;"
            , "  head-object) [ \"$KEY\" = \"$NAGARE_TEST_RECEIPT_KEY\" ] || exit 3;"
            , "    [ -f \"$NAGARE_TEST_RECEIPT\" ] || exit 4; echo v2;;"
            , "  get-object) [ \"$KEY:$VERSION\" = \"$NAGARE_TEST_RECEIPT_KEY:v2\" ] || exit 5;"
            , "    cat \"$NAGARE_TEST_RECEIPT\" > \"$OUT\"; echo '{}' ;;"
            , "  delete-object) [ \"$KEY:$VERSION\" = \"$NAGARE_TEST_RECEIPT_KEY:v2\" ] || exit 6;"
            , "    rm \"$NAGARE_TEST_RECEIPT\"; echo '{}' ;;"
            , "  *) exit 7;;"
            , "esac"
            ]
        writeFile fakeDnf "#!/bin/sh\nexit 0\n"
        mapM_ (`setFileMode` 0o755) [fakeAws, fakeDnf]
        parentEnv <- getEnvironment
        let path = maybe "" id (lookup "PATH" parentEnv)
            run receiptHash = do
              let variables =
                    [ ("PATH", directory <> ":" <> path)
                    , ("OBJECT", objectUrl)
                    , ("RECEIPT", objectUrl <> ".receipt.json")
                    , ("EXPECTED_OBJECT_VERSION", "v1")
                    , ("EXPECTED_RECEIPT_VERSION", "v2")
                    , ("EXPECTED_RECEIPT_SHA256", T.unpack receiptHash)
                    , ("EXPECTED_OBJECT_SHA256", replicate 64 'a')
                    , ("NAGARE_VERSION_LIST_FILE", directory </> "versions.json")
                    , ("NAGARE_TEST_DATA", object)
                    , ("NAGARE_TEST_RECEIPT", receipt)
                    , ("NAGARE_TEST_DATA_KEY", objectKey)
                    , ("NAGARE_TEST_RECEIPT_KEY", objectKey <> ".receipt.json")
                    ]
              readCreateProcessWithExitCode
                ( ( proc
                      "/bin/sh"
                      [ "-c"
                      , T.unpack
                          (scheduledReceiptRecoveryShell (inputs receiptHash))
                      ]
                  )
                    { env =
                        Just
                          ( variables
                              <> filter (\(key, _) -> key `notElem` map fst variables) parentEnv
                          )
                    }
                )
                ""
        BS.writeFile receipt "reviewed remaining receipt"
        (_, digestOutput, _) <-
          readCreateProcessWithExitCode
            (proc "sha256sum" [receipt])
            ""
        let receiptHash = T.pack (takeWhile (/= ' ') digestOutput)
            manifest =
              TE.decodeUtf8
                ( renderScheduledReceiptRecoveryJob
                    (inputs receiptHash)
                    "v1"
                    "v2"
                )
        assertBool
          "recovery Job lacks exact version pins"
          ( "EXPECTED_OBJECT_VERSION" `T.isInfixOf` manifest
              && "EXPECTED_RECEIPT_VERSION" `T.isInfixOf` manifest
          )
        BS.writeFile object "unreviewed older object version"
        (stillPresent, _, _) <- run receiptHash
        assertBool
          "recovery deleted receipt while data key still existed"
          (stillPresent /= ExitSuccess)
        doesFileExist receipt >>= (@?= True)
        removeFile object
        (recovered, _, diagnostic) <- run receiptHash
        assertBool
          ("exact remaining receipt recovery failed: " <> diagnostic)
          (recovered == ExitSuccess)
        doesFileExist receipt >>= (@?= False)
  ]
