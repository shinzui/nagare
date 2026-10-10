-- | DataFixtures responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.DataFixtures
  ( backupJobInputsPg
  , localMinioBackend
  , restoreJobInputsPg
  , snapshotJobInputs
  , storageRestoreJobInputs
  , tnbGcsBackend
  )
where

import Nagare.Cluster.GcsJob
  ( MinioRef (MinioRef)
  , StoreBackend (..)
  )
import Nagare.Database.Backup
  ( BackupDest (BackupDestUrl)
  , BackupJobInputs (..)
  , BackupSource (DatabaseSource)
  )
import Nagare.Database.Restore (RestoreJobInputs (..))
import Nagare.Dsl.Database (Engine (Postgres))
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Storage.Restore (StorageRestoreJobInputs (..))
import Nagare.Storage.Snapshot (SnapshotJobInputs (..))

-- ---------------------------------------------------------------------------
-- EP-47: database backups, retention, restore.

-- | The cloud (GCS) backend carrying the tan-nb-exp worked-example values; the
-- four renderer fixtures use it so their @gs://@ URLs and @CLOUDSDK_CORE_PROJECT@
-- are exactly the historic bytes (EP-84 keeps the cloud path unchanged).
tnbGcsBackend :: StoreBackend
tnbGcsBackend = GcsBackend "tan-nb-exp" "tan-nb-exp-nagare-backups"

-- | The local (MinIO) backend matching @nagare.local.env.example@'s
-- @NAGARE_LOCAL_OBJECT_STORE@, for the per-mode renderer tests (EP-84).
localMinioBackend :: StoreBackend
localMinioBackend =
  MinioBackend
    (MinioRef "http://minio.nagare-system.svc.cluster.local:9000" "nagare-backups" "nagare-minio-credentials")

backupJobInputsPg :: BackupJobInputs
backupJobInputsPg =
  BackupJobInputs
    { namespace = "personal"
    , jobName = "nagare-dbbackup-mydb-20260610t141503z"
    , source = DatabaseSource Postgres
    , clientImage = "postgres:18"
    , serviceHost = "mydb"
    , secretName = "nagare-db-mydb"
    , name = "mydb"
    , destination = BackupDestUrl "gs://tan-nb-exp-nagare-backups/databases/mydb/20260610T141503Z.sql.gz"
    , prefix = "gs://tan-nb-exp-nagare-backups/databases/mydb/"
    , keep = 7
    , selfPrune = False
    , verifyStored = False
    , receipt = Nothing
    , backend = tnbGcsBackend
    }

restoreJobInputsPg :: RestoreJobInputs
restoreJobInputsPg =
  RestoreJobInputs
    { namespace = "personal"
    , jobName = "nagare-dbrestore-mydb-20260610t141503z"
    , engine = Postgres
    , clientImage = "postgres:18"
    , serviceHost = "mydb"
    , secretName = "nagare-db-mydb"
    , name = "mydb"
    , sourceUrl = "gs://tan-nb-exp-nagare-backups/databases/mydb/20260610T141503Z.sql.gz"
    , liveTarget = False
    , verifiedSource = Nothing
    , backend = tnbGcsBackend
    }

snapshotJobInputs :: SnapshotJobInputs
snapshotJobInputs =
  SnapshotJobInputs
    { namespace = "personal"
    , jobName = "nagare-snapshot-myapp-data-20260610t141503z"
    , claimName = "nagare-vol-myapp-data"
    , destinationUrl = "gs://tan-nb-exp-nagare-backups/volumes/myapp/data/20260610T141503Z.tar.gz"
    , mountPath = "/vol"
    , backend = tnbGcsBackend
    }

storageRestoreJobInputs :: StorageRestoreJobInputs
storageRestoreJobInputs =
  StorageRestoreJobInputs
    { namespace = "personal"
    , jobName = "nagare-volrestore-myapp-data-20260610t141503z"
    , claimName = "nagare-vol-myapp-data-restore-scratch"
    , sourceUrl = "gs://tan-nb-exp-nagare-backups/volumes/myapp/data/20260610T141503Z.tar.gz"
    , mountPath = "/restore"
    , backend = tnbGcsBackend
    }
