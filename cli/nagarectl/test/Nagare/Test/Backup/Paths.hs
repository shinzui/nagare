-- | Backup.Paths responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Backup.Paths
  ( backupPathTests
  )
where

import Data.Text qualified as T
import Nagare.Database.Backup
  ( backupExt
  , backupRawExt
  , dbBackupKeyPrefix
  , dbBackupObjectPath
  , defaultBackupSchedule
  , manualBackupJobName
  , manualBackupKeyPrefix
  , manualBackupObjectPath
  , manualDatabaseJobName
  )
import Nagare.Dsl.Database (Engine (ClickHouse, Postgres, Redis))
import Nagare.Dsl.Prelude hiding ((<.>))
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

backupPathTests :: [TestTree]
backupPathTests =
  [ testCase "dbBackupObjectPath builds databases/<name>/<ts>.<ext>" $
      dbBackupObjectPath "mydb" "20260610T141503Z" "sql.gz" @?= "databases/mydb/20260610T141503Z.sql.gz"
  , testCase "dbBackupKeyPrefix builds databases/<name>/" $
      dbBackupKeyPrefix "mydb" @?= "databases/mydb/"
  , testCase "manual backup keys separate namespaces and schedules" $ do
      manualBackupKeyPrefix "personal" "mydb"
        @?= "manual-databases/personal/mydb/"
      manualBackupObjectPath "mydb" "personal" "run-001" "sql.gz"
        @?= "manual-databases/personal/mydb/run-001.sql.gz"
      manualBackupObjectPath "mydb" "other" "run-001" "sql.gz"
        @?= "manual-databases/other/mydb/run-001.sql.gz"
      assertBool
        "legacy schedule pruning can list a manual backup"
        ( not
            ( dbBackupKeyPrefix "mydb"
                `T.isPrefixOf` manualBackupObjectPath "mydb" "personal" "run-001" "sql.gz"
            )
        )
  , testCase "manual backup Job keeps database and timestamp identities" $ do
      manualBackupJobName "mydb" "20260610T141503Z"
        @?= "nagare-dbbackup-mydb-20260610t141503z"
      let firstJob = manualBackupJobName (T.replicate 40 "a" <> "one") "20260610T141503Z"
          secondJob = manualBackupJobName (T.replicate 40 "a" <> "two") "20260610T141503Z"
      assertBool "long backup Job name exceeds the native limit" (T.length firstJob <= 63)
      assertBool "backup Job loses its timestamp" (T.isSuffixOf "20260610t141503z" firstJob)
      assertBool "distinct databases share a backup Job" (firstJob /= secondJob)
      let restore =
            manualDatabaseJobName
              "nagare-dbrestore-"
              (T.replicate 40 "a" <> "one")
              "20260610T141503Z"
      assertBool "long restore Job name exceeds the native limit" (T.length restore <= 63)
      assertBool "restore Job loses its timestamp" (T.isSuffixOf "20260610t141503z" restore)
  , testCase "backupExt per engine" $
      map backupExt [Postgres, Redis, ClickHouse] @?= ["sql.gz", "rdb.gz", "zip.gz"]
  , testCase "backupRawExt per engine" $
      map backupRawExt [Postgres, Redis, ClickHouse] @?= ["sql", "rdb", "zip"]
  , testCase "defaultBackupSchedule is daily 03:17 UTC" $
      defaultBackupSchedule @?= "17 3 * * *"
  ]
