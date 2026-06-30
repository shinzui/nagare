-- | @nagarectl db backup NAME@ and the scheduled-backup CronJob (MasterPlan 9,
-- EP-47, Integration Point IP6): an engine-appropriate logical dump of a managed
-- database, uploaded to @gs://\<backup-bucket>/databases/\<name\>/\<ts\>.\<ext\>@,
-- with keep-last-N retention reusing EP-36's pure @snapshotsToPrune@.
--
-- The dump runs in a short-lived in-cluster Job with two containers sharing an
-- @emptyDir@: an initContainer running the engine's own client image writes the
-- dump to @\/dump@, and the main container (@google/cloud-sdk:slim@) gzips and
-- @gsutil cp@s it to GCS. The CronJob wraps the same Job body on a daily schedule
-- and self-prunes inline (no @nagarectl@ at the keyboard). The pure renderers and
-- path/extension helpers are unit-testable without a cluster; the live leg is
-- deferred to EP-48 (and is additionally gated on the in-pod-ADC routing fix the
-- MasterPlan records — see EP-43 Surprises).
module Nagare.Database.Backup
  ( -- * Pure object-key / extension helpers
    dbBackupObjectPath
  , dbBackupKeyPrefix
  , backupExt
  , backupRawExt

    -- * Schedule
  , defaultBackupSchedule

    -- * Job / CronJob rendering (pure)
  , BackupJobInputs (..)
  , renderBackupJob
  , backupJobSpecValue
  , BackupCronInputs (..)
  , renderBackupCronJob
  , renderDbBackupCronJob

    -- * Command driver
  , runDbBackup
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Generics.Labels ()

import Cradle
import Control.Monad (forM_)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Yaml qualified as Y
import Nagare.Cluster.GcsJob
  ( DataMovementJob (..)
  , StoreBackend (..)
  , dataMovementJobSpec
  , storeCpFromStdin
  , storeEnv
  , storeHostAliases
  , storeImage
  , storeLs
  , storeObjectUrl
  , storePrefixUrl
  , storeRmStdin
  , storeShellPreamble
  )
import Nagare.Database.Discover (DbRow (..), getDatabase)
import Nagare.Dsl.Database (Engine (..), dbSecretName, engineImage, parseEngine)
import Nagare.Storage.Snapshot (snapshotTimestamp, snapshotsToPrune)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hClose, stderr)
import System.IO.Temp (withSystemTempFile)

-- ---------------------------------------------------------------------------
-- Pure object-key / extension helpers

-- | The object key /within the bucket/ for one database backup (IP6):
-- @databases/\<name\>/\<timestamp\>.\<ext\>@. Backend-independent (EP-84 keeps
-- the key layout stable across GCS and MinIO); the @gs://@/@s3://@ URL is formed
-- by 'Nagare.Cluster.GcsJob.storeObjectUrl'. Bucket kept out so it is trivially
-- testable.
dbBackupObjectPath :: Text -> Text -> Text -> Text
dbBackupObjectPath name timestamp ext =
  "databases/" <> name <> "/" <> timestamp <> "." <> ext

-- | The object-key prefix under which a database's backups live (for
-- listing/prune): @databases/\<name\>/@. Wrap with
-- 'Nagare.Cluster.GcsJob.storePrefixUrl' to form the backend URL.
dbBackupKeyPrefix :: Text -> Text
dbBackupKeyPrefix name = "databases/" <> name <> "/"

-- | The final (gzipped) object extension per engine.
backupExt :: Engine -> Text
backupExt Postgres = "sql.gz"
backupExt Redis = "rdb.gz"
backupExt ClickHouse = "native.gz"

-- | The uncompressed dump-file extension per engine (the gzip strips the @.gz@).
backupRawExt :: Engine -> Text
backupRawExt Postgres = "sql"
backupRawExt Redis = "rdb"
backupRawExt ClickHouse = "native"

-- | The default scheduled-backup cron expression: 03:17 UTC daily (a quiet,
-- deterministic time; the odd minute avoids a top-of-hour thundering herd).
defaultBackupSchedule :: Text
defaultBackupSchedule = "17 3 * * *"

-- ---------------------------------------------------------------------------
-- Job / CronJob rendering

data BackupJobInputs = BackupJobInputs
  { bjiNamespace :: !Text
  , bjiJobName :: !Text
  , bjiEngine :: !Engine
  , bjiClientImage :: !Text
  , bjiSvcHost :: !Text
  , bjiSecretName :: !Text
  , bjiName :: !Text
  -- ^ the database name (for labels)
  , bjiDestUrl :: !Text
  -- ^ the @gs://@ destination (Job: a timestamped object; CronJob: a templated one)
  , bjiPrefix :: !Text
  -- ^ the @gs://@ listing prefix (for the self-prune step)
  , bjiKeep :: !Int
  , bjiSelfPrune :: !Bool
  -- ^ when True (the CronJob), the upload container prunes inline after upload
  , bjiBackend :: !StoreBackend
  -- ^ the object-store backend (EP-84): GCS in cloud mode, MinIO in local mode.
  -- Drives the upload container's image, env, destination URL, and shell verbs.
  }
  deriving stock (Generic, Eq, Show)

-- | Render the one-shot @batch/v1@ Job.
renderBackupJob :: BackupJobInputs -> ByteString
renderBackupJob i =
  Y.encode $
    object
      [ "apiVersion" .= ("batch/v1" :: Text)
      , "kind" .= ("Job" :: Text)
      , "metadata" .= jobMetadata i
      , "spec" .= backupJobSpecValue i
      ]

-- | The shared Job @.spec@ body (backoffLimit + pod template with the two
-- containers). Reused verbatim as a CronJob's @jobTemplate.spec@.
backupJobSpecValue :: BackupJobInputs -> Value
backupJobSpecValue i =
  dataMovementJobSpec
    DataMovementJob
      { dmjTemplateLabels = Just (labelsValue i)
      , dmjHostAliases = storeHostAliases (bjiBackend i)
      , dmjInitContainers = [dumpContainer i]
      , dmjContainers = [uploadContainer i]
      , dmjVolumes = [object ["name" .= ("dump" :: Text), "emptyDir" .= object []]]
      }

jobMetadata :: BackupJobInputs -> Value
jobMetadata i =
  object
    [ "name" .= bjiJobName i
    , "namespace" .= bjiNamespace i
    , "labels" .= labelsValue i
    ]

labelsValue :: BackupJobInputs -> Value
labelsValue i =
  object
    [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
    , "nagare.dev/database" .= bjiName i
    ]

-- | The dump initContainer: the engine client image, credentials from the
-- managed Secret, writing the uncompressed dump to @\/dump\/backup.\<rawext\>@.
dumpContainer :: BackupJobInputs -> Value
dumpContainer i =
  object
    [ "name" .= ("dump" :: Text)
    , "image" .= bjiClientImage i
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [dumpShell (bjiEngine i) (bjiSvcHost i)]
    , "env" .= toJSON (dumpEnv (bjiEngine i) (bjiSecretName i))
    , "volumeMounts" .= toJSON [dumpMount]
    ]

-- | The upload main container: the backend's data-movement image, gzip the dump
-- and copy stdin to @$DEST@ (@gsutil@/@aws s3@); when 'bjiSelfPrune' it then
-- keeps the last N.
uploadContainer :: BackupJobInputs -> Value
uploadContainer i =
  object
    [ "name" .= ("upload" :: Text)
    , "image" .= storeImage (bjiBackend i)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [uploadShell i]
    , "env"
        .= toJSON
          ( [ plainEnv "DEST" (bjiDestUrl i)
            , plainEnv "PREFIX" (bjiPrefix i)
            , plainEnv "KEEP" (T.pack (show (bjiKeep i)))
            ]
              ++ storeEnv (bjiBackend i)
          )
    , "volumeMounts" .= toJSON [dumpMount]
    ]

dumpMount :: Value
dumpMount = object ["name" .= ("dump" :: Text), "mountPath" .= ("/dump" :: Text)]

plainEnv :: Text -> Text -> Value
plainEnv n v = object ["name" .= n, "value" .= v]

-- | An env var sourced from a key of the managed Secret.
secretEnv :: Text -> Text -> Text -> Value
secretEnv n secret key =
  object
    [ "name" .= n
    , "valueFrom" .= object ["secretKeyRef" .= object ["name" .= secret, "key" .= key]]
    ]

-- | The dump container's credential env, per engine. Postgres' @pg_dump@ reads
-- @PGPASSWORD@; the others read the password directly.
dumpEnv :: Engine -> Text -> [Value]
dumpEnv Postgres secret =
  [ secretEnv "PGPASSWORD" secret "POSTGRES_PASSWORD"
  , secretEnv "POSTGRES_USER" secret "POSTGRES_USER"
  , secretEnv "POSTGRES_DB" secret "POSTGRES_DB"
  ]
dumpEnv Redis secret = [secretEnv "REDIS_PASSWORD" secret "REDIS_PASSWORD"]
dumpEnv ClickHouse secret =
  [ secretEnv "CLICKHOUSE_USER" secret "CLICKHOUSE_USER"
  , secretEnv "CLICKHOUSE_PASSWORD" secret "CLICKHOUSE_PASSWORD"
  ]

-- | The per-engine dump shell, writing @\/dump\/backup.\<rawext\>@.
dumpShell :: Engine -> Text -> Text
dumpShell Postgres svc =
  "set -e; pg_dump --no-owner --no-privileges -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" > /dump/backup.sql"
dumpShell Redis svc =
  "set -e; redis-cli -h " <> svc <> " -a \"$REDIS_PASSWORD\" --rdb /dump/backup.rdb"
dumpShell ClickHouse svc =
  "set -e; CH=\"clickhouse-client -h "
    <> svc
    <> " --user $CLICKHOUSE_USER --password $CLICKHOUSE_PASSWORD\"; "
    <> "$CH --query \"SHOW TABLES FROM default\" | while read t; do "
    <> "$CH --query \"SELECT * FROM default.\\`$t\\` FORMAT Native\"; done > /dump/backup.native"

-- | The upload shell: gzip + a backend copy from stdin to @$DEST@; with
-- self-prune, keep the last N (backend list + delete). The cloud (@gsutil@)
-- bytes are unchanged; the MinIO path emits @aws s3 … --endpoint-url@.
uploadShell :: BackupJobInputs -> Text
uploadShell i =
  base <> if bjiSelfPrune i then "; " <> prune else ""
  where
    backend = bjiBackend i
    raw = backupRawExt (bjiEngine i)
    base =
      "set -e; "
        <> storeShellPreamble backend
        <> "gzip -9 -c /dump/backup."
        <> raw
        <> " | "
        <> storeCpFromStdin backend "\"$DEST\""
    -- keep the last $KEEP objects under $PREFIX (newest sort last with reverse sort)
    prune =
      "echo pruning; "
        <> storeLs backend "\"$PREFIX\""
        <> " | sort -r | tail -n +$((KEEP+1)) "
        <> "| (grep . | "
        <> storeRmStdin backend
        <> " || true)"

-- | Inputs to the CronJob renderer: the schedule plus the shared backup body.
data BackupCronInputs = BackupCronInputs
  { bciSchedule :: !Text
  , bciBase :: !BackupJobInputs
  }
  deriving stock (Generic, Eq, Show)

-- | Render the @batch/v1@ CronJob wrapping the shared backup Job body on a
-- schedule. Named deterministically @nagare-dbbackup-\<name\>@ (the singleton
-- schedule), never overlapping (@concurrencyPolicy: Forbid@). The base inputs
-- should have @bjiSelfPrune = True@ so the scheduled run prunes itself.
renderBackupCronJob :: BackupCronInputs -> ByteString
renderBackupCronJob i =
  Y.encode $
    object
      [ "apiVersion" .= ("batch/v1" :: Text)
      , "kind" .= ("CronJob" :: Text)
      , "metadata" .= jobMetadata (bciBase i)
      , "spec"
          .= object
            [ "schedule" .= bciSchedule i
            , "concurrencyPolicy" .= ("Forbid" :: Text)
            , "successfulJobsHistoryLimit" .= (3 :: Int)
            , "failedJobsHistoryLimit" .= (1 :: Int)
            , "jobTemplate" .= object ["spec" .= backupJobSpecValue (bciBase i)]
            ]
      ]

-- | Convenience renderer for the scheduled-backup CronJob of a database, from
-- its identity (the values EP-45's @db create@ has on hand). Self-pruning, daily
-- default schedule. EP-45 applies this at create time unless retention = Delete.
-- The @backend@ (EP-84) selects GCS or MinIO for the upload.
renderDbBackupCronJob :: Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderDbBackupCronJob ns name eng version backend keep =
  renderBackupCronJob
    BackupCronInputs
      { bciSchedule = defaultBackupSchedule
      , bciBase =
          BackupJobInputs
            { bjiNamespace = ns
            , bjiJobName = "nagare-dbbackup-" <> name
            , bjiEngine = eng
            , bjiClientImage = engineImage eng <> ":" <> version
            , bjiSvcHost = name
            , bjiSecretName = dbSecretName name
            , bjiName = name
            , bjiDestUrl =
                storeObjectUrl backend ("databases/" <> name <> "/scheduled-$(date -u +%Y%m%dT%H%M%SZ)." <> backupExt eng)
            , bjiPrefix = storePrefixUrl backend (dbBackupKeyPrefix name)
            , bjiKeep = keep
            , bjiSelfPrune = True
            , bjiBackend = backend
            }
      }

-- ---------------------------------------------------------------------------
-- Command driver

-- | Run @db backup NAME@: resolve the database from the cluster, render and apply
-- the one-shot backup Job, wait for completion, prune to keep-last-N (reusing
-- 'snapshotsToPrune'), and (unless @--dry-run@) report the destination. With
-- @--dry-run@, print the Job (and the CronJob) manifests and apply nothing.
runDbBackup :: Text -> Text -> StoreBackend -> Int -> Bool -> IO ()
runDbBackup ns name backend keep dryRun = do
  erow <- getDatabase ns name
  case erow of
    Left err -> die err
    Right r -> case parseEngine (drEngine r) of
      Nothing -> die ("database '" <> name <> "' has an unknown engine: " <> drEngine r)
      Just eng -> do
        now <- getCurrentTime
        let ts = snapshotTimestamp now
            ext = backupExt eng
            image = engineImage eng <> ":" <> drVersion r
            secret = dbSecretName name
            dest = storeObjectUrl backend (dbBackupObjectPath name ts ext)
            prefix = storePrefixUrl backend (dbBackupKeyPrefix name)
            jobName = T.take 63 (T.toLower ("nagare-dbbackup-" <> name <> "-" <> ts))
            jobInputs =
              BackupJobInputs
                { bjiNamespace = ns
                , bjiJobName = jobName
                , bjiEngine = eng
                , bjiClientImage = image
                , bjiSvcHost = name
                , bjiSecretName = secret
                , bjiName = name
                , bjiDestUrl = dest
                , bjiPrefix = prefix
                , bjiKeep = keep
                , bjiSelfPrune = False
                , bjiBackend = backend
                }
            cronInputs =
              BackupCronInputs
                { bciSchedule = defaultBackupSchedule
                , bciBase =
                    jobInputs
                      { bjiJobName = "nagare-dbbackup-" <> name
                      , bjiDestUrl = storeObjectUrl backend ("databases/" <> name <> "/scheduled-$(date -u +%Y%m%dT%H%M%SZ)." <> ext)
                      , bjiSelfPrune = True
                      }
                }
        if dryRun
          then do
            TIO.putStrLn "--- Backup Job manifest ---"
            BS.putStr (renderBackupJob jobInputs)
            TIO.putStrLn ""
            TIO.putStrLn "--- Backup CronJob manifest ---"
            BS.putStr (renderBackupCronJob cronInputs)
          else do
            applyJob (renderBackupJob jobInputs)
            waitForJob ns jobName
            run_ $ cmd "kubectl" & addArgs ["delete", "job", T.unpack jobName, "-n", T.unpack ns, "--ignore-not-found"]
            -- Laptop-side prune uses @gsutil@ and the cloud bucket; in local mode
            -- the MinIO Service is in-cluster (unreachable from the laptop), so the
            -- on-demand prune is skipped and retention is left to the in-pod
            -- self-prune (the CronJob) — EP-84 Decision Log.
            case backend of
              GcsBackend {} -> pruneBackups prefix keep
              MinioBackend {} -> pure ()
            TIO.putStrLn ("Backup written: " <> dest)

applyJob :: ByteString -> IO ()
applyJob manifest = withSystemTempFile "nagare-dbbackup-job.yaml" $ \fp h -> do
  BS.hPut h manifest
  hClose h
  run_ $ cmd "kubectl" & addArgs ["apply", "-f", fp]

waitForJob :: Text -> Text -> IO ()
waitForJob ns jobName = do
  (code, _ :: StdoutUntrimmed) <-
    run $
      cmd "kubectl"
        & addArgs ["wait", "--for=condition=complete", "--timeout=600s", "job/" <> T.unpack jobName, "-n", T.unpack ns]
        & silenceStderr
  case code of
    ExitSuccess -> pure ()
    ExitFailure _ -> do
      TIO.hPutStrLn stderr ("nagarectl: backup job " <> jobName <> " did not complete; recent logs:")
      run_ $ cmd "kubectl" & addArgs ["logs", "job/" <> T.unpack jobName, "-n", T.unpack ns, "--tail", "50"]
      exitFailure

-- | List the database's backups and delete all but the newest @keep@, reusing
-- the pure 'snapshotsToPrune' (IP6).
pruneBackups :: Text -> Int -> IO ()
pruneBackups prefix keep = do
  (code, StdoutUntrimmed out) <- run $ cmd "gsutil" & addArgs ["ls", T.unpack prefix] & silenceStderr
  case code of
    ExitFailure _ -> pure ()
    ExitSuccess -> do
      let objs = filter (not . T.null) (map T.strip (T.lines out))
          surplus = snapshotsToPrune keep objs
      forM_ surplus $ \o -> run_ $ cmd "gsutil" & addArgs ["rm", T.unpack o]

die :: Text -> IO a
die msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
