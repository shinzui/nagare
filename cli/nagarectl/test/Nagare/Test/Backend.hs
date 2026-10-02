-- | Backend responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Backend
  ( backupProjectTests
  , gcsJobHostAliasesTests
  , storeBackendModeTests
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.GcsJob
  ( StoreBackend (GcsBackend, MinioBackend)
  , parseLocalObjectStore
  )
import Nagare.Database.Backup
  ( BackupDest (BackupDestUrl)
  , renderBackupJob
  )
import Nagare.Database.Restore (renderRestoreJob)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Storage.Restore (renderStorageRestoreJob)
import Nagare.Storage.Snapshot (renderSnapshotJob)
import Nagare.Test.DataFixtures
  ( backupJobInputsPg
  , localMinioBackend
  , restoreJobInputsPg
  , snapshotJobInputs
  , storageRestoreJobInputs
  , tnbGcsBackend
  )
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- EP-62: the rendered backup Job's CLOUDSDK_CORE_PROJECT follows the GCS
-- backend's project (fail-before/pass-after evidence: before EP-62 the value was
-- the literal @tan-nb-exp@ regardless of inputs). EP-84 carries the project on
-- 'backend' ('GcsBackend' project bucket) instead of a separate field.

backupProjectTests :: [TestTree]
backupProjectTests =
  [ testCase "backup Job CLOUDSDK_CORE_PROJECT defaults to tan-nb-exp" $
      assertBool "tan-nb-exp present" ("tan-nb-exp" `T.isInfixOf` rendered "tan-nb-exp")
  , testCase "backup Job CLOUDSDK_CORE_PROJECT follows the resolved project" $ do
      assertBool "acme-prod present" ("acme-prod" `T.isInfixOf` rendered "acme-prod")
      assertBool
        "no tan-nb-exp project leaked"
        (not ("value: tan-nb-exp" `T.isInfixOf` rendered "acme-prod"))
  ]
  where
    rendered project =
      TE.decodeUtf8 (renderBackupJob (backupJobInputsPg & #backend .~ GcsBackend project "tan-nb-exp-nagare-backups"))

-- | Recurrence guard (EP-1): every GCS data-movement Job renderer must emit the
-- metadata @hostAliases@ and the @google/cloud-sdk:slim@ image. All four render
-- through the shared 'Nagare.Cluster.GcsJob', so dropping the @hostAliases@ there
-- fails every case at once.
gcsJobHostAliasesTests :: [TestTree]
gcsJobHostAliasesTests =
  [ testCase (name <> " renders the metadata hostAliases and the cloud-sdk image") $ do
      let y = TE.decodeUtf8 rendered
      assertBool "hostAliases for metadata.google.internal" ("metadata.google.internal" `T.isInfixOf` y)
      assertBool "metadata IP" ("169.254.169.254" `T.isInfixOf` y)
      assertBool "cloud-sdk image" ("google/cloud-sdk:slim" `T.isInfixOf` y)
      assertBool "restartPolicy Never" ("Never" `T.isInfixOf` y)
  | (name, rendered) <-
      [ ("db backup Job", renderBackupJob backupJobInputsPg)
      , ("db restore Job", renderRestoreJob restoreJobInputsPg)
      , ("volume snapshot Job", renderSnapshotJob snapshotJobInputs)
      , ("volume restore Job", renderStorageRestoreJob storageRestoreJobInputs)
      ]
  ]

-- | EP-84 (MasterPlan 16 Integration Point 3): each of the four data-movement
-- Job renderers must differ correctly by store backend. Under 'GcsBackend' it
-- renders exactly the cloud shape (cloud-sdk image, metadata @hostAliases@/IP,
-- @gs://@, @gsutil@); under 'MinioBackend' it renders the MinIO shape
-- (@amazon/aws-cli@, @s3://@, @--endpoint-url@, a @secretKeyRef@ to
-- @nagare-minio-credentials@) and carries NO metadata server reference. All four
-- render through the shared 'Nagare.Cluster.GcsJob', so the per-mode branch is
-- proven once per verb.
storeBackendModeTests :: [TestTree]
storeBackendModeTests =
  parseTests <> renderTests
  where
    parseTests =
      [ testCase "parseLocalObjectStore splits endpoint and bucket on the last /" $
          parseLocalObjectStore "http://minio.nagare-system.svc.cluster.local:9000/nagare-backups"
            @?= Just ("http://minio.nagare-system.svc.cluster.local:9000", "nagare-backups")
      , testCase "parseLocalObjectStore rejects an empty string" $
          parseLocalObjectStore "" @?= Nothing
      ]
    renderTests =
      [ testCase (name <> ": " <> show backend <> " renders the right backend shape") $ do
          let y = TE.decodeUtf8 (render backend)
          case backend of
            GcsBackend {} -> do
              assertBool "cloud image" ("google/cloud-sdk:slim" `T.isInfixOf` y)
              assertBool "metadata dns" ("metadata.google.internal" `T.isInfixOf` y)
              assertBool "metadata ip" ("169.254.169.254" `T.isInfixOf` y)
              assertBool "gs url" ("gs://" `T.isInfixOf` y)
              assertBool "no tar/gzip install in cloud" (not ("dnf install" `T.isInfixOf` y))
            MinioBackend {} -> do
              assertBool "minio image" ("amazon/aws-cli" `T.isInfixOf` y)
              assertBool "s3 url" ("s3://" `T.isInfixOf` y)
              assertBool "endpoint" ("--endpoint-url" `T.isInfixOf` y)
              assertBool "secret ref" ("nagare-minio-credentials" `T.isInfixOf` y)
              -- amazon/aws-cli ships no tar/gzip; the Job installs them (EP-84).
              assertBool "installs tar+gzip" ("dnf install -y -q tar gzip" `T.isInfixOf` y)
              assertBool "no metadata ip" (not ("169.254.169.254" `T.isInfixOf` y))
              assertBool "no metadata dns" (not ("metadata.google.internal" `T.isInfixOf` y))
      | (name, render) <-
          [
            ( "db backup Job"
            , \b ->
                renderBackupJob $
                  backupJobInputsPg
                    & #backend
                    .~ b
                    & #destination
                    .~ BackupDestUrl (destFor b "databases/mydb/20260610T141503Z.sql.gz")
                    & #prefix
                    .~ destFor b "databases/mydb/"
            )
          ,
            ( "db restore Job"
            , \b ->
                renderRestoreJob $
                  restoreJobInputsPg
                    & #backend
                    .~ b
                    & #sourceUrl
                    .~ destFor b "databases/mydb/20260610T141503Z.sql.gz"
            )
          ,
            ( "volume snapshot Job"
            , \b ->
                renderSnapshotJob $
                  snapshotJobInputs
                    & #backend
                    .~ b
                    & #destinationUrl
                    .~ destFor b "volumes/myapp/data/20260610T141503Z.tar.gz"
            )
          ,
            ( "volume restore Job"
            , \b ->
                renderStorageRestoreJob $
                  storageRestoreJobInputs
                    & #backend
                    .~ b
                    & #sourceUrl
                    .~ destFor b "volumes/myapp/data/20260610T141503Z.tar.gz"
            )
          ]
      , backend <- [tnbGcsBackend, localMinioBackend]
      ]
    -- The full object URL for a key under the backend's bucket, so each fixture's
    -- DEST/SRC carries the right scheme for the backend under test.
    destFor (GcsBackend _ bucket) key = "gs://" <> bucket <> "/" <> key
    destFor (MinioBackend ref) key = "s3://" <> ref ^. #bucket <> "/" <> key
