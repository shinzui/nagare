-- | Backup.Rendering responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Backup.Rendering
  ( backupRendererTests
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.Backup
  ( BackupCronInputs (BackupCronInputs, base, schedule)
  , BackupDest (BackupDestUrl)
  , BackupJobInputs
    ( backend
    , clientImage
    , destination
    , serviceHost
    , source
    )
  , BackupSource (DatabaseSource)
  , defaultBackupSchedule
  , renderBackupCronJob
  , renderBackupJob
  , renderDbBackupCronJob
  )
import Nagare.Dsl.Database (Engine (ClickHouse, Postgres))
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Test.DataFixtures
  ( backupJobInputsPg
  , localMinioBackend
  , tnbGcsBackend
  )
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, testCase)

backupRendererTests :: [TestTree]
backupRendererTests =
  [ testCase "renderBackupJob is a two-container Job" $ do
      let y = TE.decodeUtf8 (renderBackupJob backupJobInputsPg)
      assertBool "kind Job" ("kind: Job" `T.isInfixOf` y)
      assertBool "initContainers" ("initContainers" `T.isInfixOf` y)
      assertBool "dump container" ("pg_dump" `T.isInfixOf` y)
      assertBool "upload image" ("google/cloud-sdk:slim" `T.isInfixOf` y)
      assertBool "metadata host" ("169.254.169.254" `T.isInfixOf` y)
      assertBool "hostAliases for metadata.google.internal" ("metadata.google.internal" `T.isInfixOf` y)
      assertBool "no self-prune for on-demand" (not ("pruning" `T.isInfixOf` y))
  , testCase "ClickHouse producer stages a database ZIP from its source PVC" $ do
      let inputs =
            backupJobInputsPg
              { source = DatabaseSource ClickHouse
              , clientImage = "clickhouse/clickhouse-server:25.8"
              , serviceHost = "mydb"
              , destination = BackupDestUrl "s3://nagare-backups/manual-databases/personal/mydb/one.zip.gz"
              , backend = localMinioBackend
              }
          y = TE.decodeUtf8 (renderBackupJob inputs)
      assertBool "database-native archive" ("BACKUP DATABASE default TO File" `T.isInfixOf` y)
      assertBool "no concatenated table streams" (not ("FORMAT Native" `T.isInfixOf` y))
      assertBool "source PVC" ("nagare-db-mydb-data" `T.isInfixOf` y)
      assertBool "source node placement" ("kubernetes.io/hostname" `T.isInfixOf` y)
      assertBool "private archive staging" ("/dump/backup.zip" `T.isInfixOf` y)
      assertBool "temporary server archive cleanup" ("rm --" `T.isInfixOf` y)
  , testCase "renderBackupCronJob wraps the body on a schedule and self-prunes" $ do
      let cron =
            BackupCronInputs
              { schedule = defaultBackupSchedule
              , base = backupJobInputsPg & #selfPrune .~ True
              }
          y = TE.decodeUtf8 (renderBackupCronJob cron)
      assertBool "kind CronJob" ("kind: CronJob" `T.isInfixOf` y)
      assertBool "schedule" ("17 3 * * *" `T.isInfixOf` y)
      assertBool "no overlap" ("Forbid" `T.isInfixOf` y)
      assertBool "self-prune" ("pruning" `T.isInfixOf` y)
  , testCase "renderDbBackupCronJob stamps the object key when the pod runs" $ do
      let y = TE.decodeUtf8 (renderDbBackupCronJob "nagare-system" "en-db" Postgres "18" tnbGcsBackend 7)
      -- Kubernetes never runs a shell over env values, so a $(date) in DEST
      -- was uploaded verbatim and every run overwrote one object.
      assertBool "stamp computed in the upload shell" ("DEST=\"${PREFIX}$(date -u +%Y%m%dT%H%M%SZ).sql.gz\"" `T.isInfixOf` y)
      assertBool "no scheduled- key prefix" (not ("scheduled-" `T.isInfixOf` y))
      assertBool "no DEST env var" (not ("name: DEST" `T.isInfixOf` y))
      assertBool "listing prefix" ("gs://tan-nb-exp-nagare-backups/databases/en-db/" `T.isInfixOf` y)
  ]
