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
  , manualBackupJobName
  , manualDatabaseJobName
  , backupExt
  , backupRawExt

    -- * Schedule
  , defaultBackupSchedule

    -- * Job / CronJob rendering (pure)
  , BackupDest (..)
  , BackupJobInputs (..)
  , renderBackupJob
  , backupJobSpecValue
  , BackupCronInputs (..)
  , renderBackupCronJob
  , renderDbBackupCronJob
  , renderInventoryDbBackupCronJob

    -- * Command driver
  , runDbBackup
  )
where

import Control.Monad (forM_)
import Cradle
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
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
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Resource.Canonical (contentDigest)
import Nagare.Resource.Types (digestText)
import Nagare.Storage.Snapshot (snapshotTimestamp, snapshotsToPrune)
import System.Exit (ExitCode (..), exitFailure)
import System.Environment (lookupEnv)
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

-- | Keep the timestamp in a one-off Job's native name even when the database
-- name is long. A digest of the full database name distinguishes equal prefixes.
manualBackupJobName :: Text -> Text -> Text
manualBackupJobName = manualDatabaseJobName "nagare-dbbackup-"

manualDatabaseJobName :: Text -> Text -> Text -> Text
manualDatabaseJobName prefix databaseName timestamp =
  T.toLower $
    if T.length full <= 63
      then full
      else prefix <> T.take available databaseName <> suffix
  where
    full = prefix <> databaseName <> "-" <> timestamp
    suffix = "-" <> T.take 20 (digestText (contentDigest (TE.encodeUtf8 databaseName)))
      <> "-" <> timestamp
    available = 63 - T.length prefix - T.length suffix

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

-- | Where the upload container writes the dump.
data BackupDest
  = -- | A fixed object URL: the on-demand Job names its timestamp up front.
    BackupDestUrl !Text
  | -- | @$PREFIX\<ts\>.\<ext\>@, stamped when the pod runs (the CronJob). Kubernetes
    -- does not run a shell over @env@ values, so the stamp is taken in the upload
    -- shell; the key matches 'dbBackupObjectPath' so restore-by-id and pruning
    -- treat scheduled and on-demand backups alike.
    BackupDestStamped
  deriving stock (Generic, Eq, Show)

data BackupJobInputs = BackupJobInputs
  { namespace :: !Text
  , jobName :: !Text
  , engine :: !Engine
  , clientImage :: !Text
  , serviceHost :: !Text
  , secretName :: !Text
  , name :: !Text
  -- ^ the database name (for labels)
  , destination :: !BackupDest
  -- ^ the destination (Job: a fixed timestamped object; CronJob: stamped at run time)
  , prefix :: !Text
  -- ^ the @gs://@ listing prefix (for the self-prune step)
  , keep :: !Int
  , selfPrune :: !Bool
  -- ^ when True (the CronJob), the upload container prunes inline after upload
  , backend :: !StoreBackend
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
      { templateLabels = Just (labelsValue i)
      , backoffLimit = 2
      , hostAliases = storeHostAliases (i ^. #backend)
      , initContainers = [dumpContainer i]
      , containers = [uploadContainer i]
      , volumes = [object ["name" .= ("dump" :: Text), "emptyDir" .= object []]]
      }

jobMetadata :: BackupJobInputs -> Value
jobMetadata i =
  object
    [ "name" .= (i ^. #jobName)
    , "namespace" .= (i ^. #namespace)
    , "labels" .= labelsValue i
    ]

labelsValue :: BackupJobInputs -> Value
labelsValue i =
  object
    [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
    , "nagare.dev/database" .= (i ^. #name)
    ]

-- | The dump initContainer: the engine client image, credentials from the
-- managed Secret, writing the uncompressed dump to @\/dump\/backup.\<rawext\>@.
dumpContainer :: BackupJobInputs -> Value
dumpContainer i =
  object
    [ "name" .= ("dump" :: Text)
    , "image" .= (i ^. #clientImage)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON ["set -e; " <> waitForServer (i ^. #engine) (i ^. #serviceHost) <> dumpShell (i ^. #engine) (i ^. #serviceHost)]
    , "env" .= toJSON (dumpEnv (i ^. #engine) (i ^. #secretName))
    , "volumeMounts" .= toJSON [dumpMount]
    ]

-- | The upload main container: the backend's data-movement image, gzip the dump
-- and copy stdin to @$DEST@ (@gsutil@/@aws s3@); when 'selfPrune' it then
-- keeps the last N.
uploadContainer :: BackupJobInputs -> Value
uploadContainer i =
  object
    [ "name" .= ("upload" :: Text)
    , "image" .= storeImage (i ^. #backend)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [uploadShell i]
    , "env"
        .= toJSON
          ( [plainEnv "DEST" url | BackupDestUrl url <- [i ^. #destination]]
              ++ [ plainEnv "PREFIX" (i ^. #prefix)
                 , plainEnv "KEEP" (T.pack (show (i ^. #keep)))
                 ]
              ++ storeEnv (i ^. #backend)
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

-- | Wait up to five minutes for the database to accept connections. A CronJob
-- that missed its schedule while the VM was stopped runs right after boot: first
-- CoreDNS does not yet resolve the Service, then the server refuses connections
-- while it starts (the pod reports Ready before Postgres listens). Each probe
-- uses the engine's own client, so it covers both.
waitForServer :: Engine -> Text -> Text
waitForServer eng svc =
  "i=0; until "
    <> readyProbe eng svc
    <> " >/dev/null 2>&1; do i=$((i+1)); if [ \"$i\" -ge 150 ]; then echo \""
    <> svc
    <> " is not accepting connections\" >&2; exit 1; fi; sleep 2; done; "

-- | A command that succeeds once the server accepts authenticated queries.
readyProbe :: Engine -> Text -> Text
readyProbe Postgres svc = "pg_isready -q -h " <> svc
readyProbe Redis svc = "redis-cli -h " <> svc <> " -a \"$REDIS_PASSWORD\" --no-auth-warning ping | grep -q PONG"
readyProbe ClickHouse svc =
  "clickhouse-client -h " <> svc <> " --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" --query \"SELECT 1\""

-- | The per-engine dump command, writing @\/dump\/backup.\<rawext\>@.
dumpShell :: Engine -> Text -> Text
dumpShell Postgres svc =
  "pg_dump --no-owner --no-privileges -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" > /dump/backup.sql"
dumpShell Redis svc =
  "redis-cli -h " <> svc <> " -a \"$REDIS_PASSWORD\" --rdb /dump/backup.rdb"
dumpShell ClickHouse svc =
  "CH=\"clickhouse-client -h "
    <> svc
    <> " --user $CLICKHOUSE_USER --password $CLICKHOUSE_PASSWORD\"; "
    <> "$CH --query \"SHOW TABLES FROM default\" | while read t; do "
    <> "$CH --query \"SELECT * FROM default.\\`$t\\` FORMAT Native\"; done > /dump/backup.native"

-- | The upload shell: gzip + a backend copy from stdin to @$DEST@; with
-- self-prune, keep the last N (backend list + delete). The cloud (@gsutil@)
-- bytes are unchanged; the MinIO path emits @aws s3 … --endpoint-url@.
uploadShell :: BackupJobInputs -> Text
uploadShell i =
  base <> if i ^. #selfPrune then "; " <> prune else ""
  where
    backend = i ^. #backend
    raw = backupRawExt (i ^. #engine)
    stamp = case i ^. #destination of
      BackupDestUrl _ -> ""
      BackupDestStamped -> "DEST=\"${PREFIX}$(date -u +%Y%m%dT%H%M%SZ)." <> backupExt (i ^. #engine) <> "\"; "
    base =
      "set -e; "
        <> stamp
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
  { schedule :: !Text
  , base :: !BackupJobInputs
  }
  deriving stock (Generic, Eq, Show)

-- | Render the @batch/v1@ CronJob wrapping the shared backup Job body on a
-- schedule. Named deterministically @nagare-dbbackup-\<name\>@ (the singleton
-- schedule), never overlapping (@concurrencyPolicy: Forbid@). The base inputs
-- should have @selfPrune = True@ so the scheduled run prunes itself.
renderBackupCronJob :: BackupCronInputs -> ByteString
renderBackupCronJob i =
  Y.encode $
    object
      [ "apiVersion" .= ("batch/v1" :: Text)
      , "kind" .= ("CronJob" :: Text)
      , "metadata" .= jobMetadata (i ^. #base)
      , "spec"
          .= object
            [ "schedule" .= (i ^. #schedule)
            , "concurrencyPolicy" .= ("Forbid" :: Text)
            , "successfulJobsHistoryLimit" .= (3 :: Int)
            , "failedJobsHistoryLimit" .= (1 :: Int)
            , "jobTemplate" .= object ["spec" .= backupJobSpecValue (i ^. #base)]
            ]
      ]

-- | Legacy scheduled backup. Inline keep-last-N deletion is confined to
-- unadmitted contexts while reviewed pruning remains a separate lifecycle action.
renderDbBackupCronJob :: Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderDbBackupCronJob = renderDbBackupCronJobWithPrune True

-- | A reviewed database may schedule uploads, but the CronJob must not delete
-- older backup objects without a separate reviewed pruning decision.
renderInventoryDbBackupCronJob :: Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderInventoryDbBackupCronJob = renderDbBackupCronJobWithPrune False

renderDbBackupCronJobWithPrune :: Bool -> Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderDbBackupCronJobWithPrune shouldPrune ns name eng version backend keep =
  renderBackupCronJob
    BackupCronInputs
      { schedule = defaultBackupSchedule
      , base =
          BackupJobInputs
            { namespace = ns
            , jobName = "nagare-dbbackup-" <> name
            , engine = eng
            , clientImage = engineImage eng <> ":" <> version
            , serviceHost = name
            , secretName = dbSecretName name
            , name = name
            , destination = BackupDestStamped
            , prefix = storePrefixUrl backend (dbBackupKeyPrefix name)
            , keep = keep
            , selfPrune = shouldPrune
            , backend = backend
            }
      }

-- ---------------------------------------------------------------------------
-- Command driver

-- | Run @db backup NAME@: resolve the database from the cluster, render and apply
-- the one-shot backup Job, wait for completion, prune to keep-last-N (reusing
-- 'snapshotsToPrune'), and (unless @--dry-run@) report the destination. With
-- @--dry-run@, print the Job (and the CronJob) manifests and apply nothing.
runDbBackup :: Text -> Text -> StoreBackend -> Int -> Bool -> IO ()
runDbBackup ns databaseName backend keep dryRun = do
  transaction <- lookupEnv "NAGARE_INVENTORY_TRANSACTION"
  when (isJust transaction) (die "db backup cannot run inside a reviewed inventory transaction")
  erow <- getDatabase ns databaseName
  case erow of
    Left err -> die err
    Right r -> case parseEngine (r ^. #engine) of
      Nothing -> die ("database '" <> databaseName <> "' has an unknown engine: " <> r ^. #engine)
      Just eng -> do
        now <- getCurrentTime
        let ts = snapshotTimestamp now
            ext = backupExt eng
            image = engineImage eng <> ":" <> r ^. #version
            secret = dbSecretName databaseName
            dest = storeObjectUrl backend (dbBackupObjectPath databaseName ts ext)
            prefix = storePrefixUrl backend (dbBackupKeyPrefix databaseName)
            jobName = manualBackupJobName databaseName ts
            jobInputs =
              BackupJobInputs
                { namespace = ns
                , jobName = jobName
                , engine = eng
                , clientImage = image
                , serviceHost = databaseName
                , secretName = secret
                , name = databaseName
                , destination = BackupDestUrl dest
                , prefix = prefix
                , keep = keep
                , selfPrune = False
                , backend = backend
                }
            cronInputs =
              BackupCronInputs
                  { schedule = defaultBackupSchedule
                  , base =
                      jobInputs
                      & #jobName .~ "nagare-dbbackup-" <> databaseName
                      & #destination .~ BackupDestStamped
                      & #selfPrune .~ True
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
waitForJob ns name = do
  (code, _ :: StdoutUntrimmed) <-
    run $
      cmd "kubectl"
        & addArgs ["wait", "--for=condition=complete", "--timeout=600s", "job/" <> T.unpack name, "-n", T.unpack ns]
        & silenceStderr
  case code of
    ExitSuccess -> pure ()
    ExitFailure _ -> do
      TIO.hPutStrLn stderr ("nagarectl: backup job " <> name <> " did not complete; recent logs:")
      run_ $ cmd "kubectl" & addArgs ["logs", "job/" <> T.unpack name, "-n", T.unpack ns, "--tail", "50"]
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
