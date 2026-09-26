-- | @nagarectl db backup NAME@ and the scheduled-backup CronJob (MasterPlan 9,
-- EP-47, Integration Point IP6): an engine-appropriate logical dump of a managed
-- database, uploaded to @gs://\<backup-bucket>/databases/\<name\>/\<ts\>.\<ext\>@.
-- Reviewed schedules check the exact stored bytes and leave pruning to a
-- separate lifecycle decision. The old Job renderer remains for dry-run output.
--
-- The dump runs in a short-lived in-cluster Job with two containers sharing an
-- @emptyDir@: an initContainer running the engine's own client image writes the
-- dump to @\/dump@, and the main container (@google/cloud-sdk:slim@) gzips and
-- @gsutil cp@s it to GCS. The CronJob wraps the same Job body on a daily schedule
-- and, in legacy contexts, self-prunes inline. The pure renderers and
-- path/extension helpers also support read-only legacy Job previews; reviewed
-- manual backup execution is owned by the inventory compiler and adapter.
module Nagare.Database.Backup
  ( -- * Pure object-key / extension helpers
    dbBackupObjectPath
  , dbBackupKeyPrefix
  , manualBackupKeyPrefix
  , manualBackupObjectPath
  , manualBackupJobName
  , manualDatabaseJobName
  , backupExt
  , backupRawExt

    -- * Schedule
  , defaultBackupSchedule

    -- * Job / CronJob rendering (pure)
  , BackupDest (..)
  , BackupReceipt (..)
  , BackupJobInputs (..)
  , renderBackupJob
  , backupJobSpecValue
  , uploadShell
  , BackupCronInputs (..)
  , renderBackupCronJob
  , renderDbBackupCronJob
  , renderInventoryDbBackupCronJob
  , renderPreviousInventoryDbBackupCronJob

    -- * Read-only legacy preview
  , previewDbBackup
  )
where

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
  , storeCpCreateOnlyFromFile
  , storeCpFromStdin
  , storeCpToStdout
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
import Nagare.Storage.Snapshot (snapshotTimestamp)
import System.Exit (exitFailure)
import System.IO (stderr)

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

-- | Reviewed manual backups must stay outside the legacy scheduler's broad
-- @databases/<name>/@ pruning prefix, including while an older accepted
-- CronJob still runs. The namespace also separates same-named databases.
manualBackupKeyPrefix :: Text -> Text -> Text
manualBackupKeyPrefix namespaceName name =
  "manual-databases/" <> namespaceName <> "/" <> name <> "/"

-- | Exact reviewed manual object key, retained in its independent scope.
manualBackupObjectPath :: Text -> Text -> Text -> Text -> Text
manualBackupObjectPath name namespaceName backupId ext =
  manualBackupKeyPrefix namespaceName name <> backupId <> "." <> ext

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

-- | The immutable receipt that a reviewed fixed-key Job writes only after it
-- has read back and checked the exact compressed backup object. The static
-- metadata is a JSON object; the Job adds the observed SHA-256 to it.
data BackupReceipt = BackupReceipt
  { destination :: !Text
  , metadataJson :: !Text
  }
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
  , verifyStored :: !Bool
  -- ^ when True, a successful Job read back the exact compressed object bytes.
  , receipt :: !(Maybe BackupReceipt)
  -- ^ an optional create-only per-object receipt for reviewed manual backups.
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

-- | The upload main container: the backend's data-movement image gzips the
-- dump and uploads it to @$DEST@. Reviewed fixed-key Jobs create only; reviewed
-- schedules read the object back; legacy schedules also keep the last N.
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
              ++ maybe [] (\r ->
                   [ plainEnv "BACKUP_RECEIPT_DEST" (r ^. #destination)
                   , plainEnv "BACKUP_RECEIPT_METADATA" (r ^. #metadataJson)
                   ]) (i ^. #receipt)
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

-- | The upload shell: gzip + a backend copy to @$DEST@. Reviewed Jobs and
-- schedules read back the exact stored bytes and compare SHA-256; fixed-key
-- Jobs create only. Legacy schedules can still use keep-last-N deletion.
uploadShell :: BackupJobInputs -> Text
uploadShell i =
  base <> if i ^. #selfPrune then "; " <> prune else ""
  where
    backend = i ^. #backend
    raw = backupRawExt (i ^. #engine)
    stamp = case i ^. #destination of
      BackupDestUrl _ -> ""
      BackupDestStamped -> "DEST=\"${PREFIX}$(date -u +%Y%m%dT%H%M%SZ)." <> backupExt (i ^. #engine) <> "\"; "
    base = "set -e; " <> stamp <> storeShellPreamble backend <>
      if i ^. #verifyStored then verifiedUpload else streamedUpload
    streamedUpload = "gzip -9 -c /dump/backup." <> raw <> " | "
      <> storeCpFromStdin backend "\"$DEST\""
    verifyTools = case backend of
      GcsBackend {} -> "command -v sha256sum >/dev/null 2>&1; "
      MinioBackend {} ->
        "command -v sha256sum >/dev/null 2>&1 || dnf install -y -q coreutils >/dev/null 2>&1; "
          <> "command -v sha256sum >/dev/null 2>&1; "
    createOnly = case i ^. #destination of
      BackupDestUrl _ -> not (i ^. #selfPrune)
      BackupDestStamped -> False
    uploadVerified =
      if createOnly
        then versionedLocalBucket <> storeCpCreateOnlyFromFile backend "/dump/backup.gz" "\"$DEST\""
        else storeCpFromStdin backend "\"$DEST\"" <> " < /dump/backup.gz"
    -- Reviewed local backups need a provider version ID for a later exact
    -- object deletion. Existing unversioned objects are never silently pruned.
    versionedLocalBucket = case backend of
      GcsBackend {} -> ""
      MinioBackend ref ->
        "aws s3api put-bucket-versioning --bucket " <> ref ^. #bucket
          <> " --versioning-configuration Status=Enabled --endpoint-url "
          <> ref ^. #endpoint <> "; "
    verifiedUpload =
      verifyTools <> "gzip -n -9 -c /dump/backup." <> raw <> " > /dump/backup.gz; "
      <> "EXPECTED=$(sha256sum /dump/backup.gz | cut -d' ' -f1); test ${#EXPECTED} -eq 64; "
      <> uploadVerified <> "; "
      <> "ACTUAL=$(" <> storeCpToStdout backend "\"$DEST\""
      <> " | sha256sum | cut -d' ' -f1); test ${#ACTUAL} -eq 64; "
      <> "test \"$EXPECTED\" = \"$ACTUAL\""
      <> receiptUpload
      <> "; rm -f /dump/backup.gz"
    receiptUpload = case i ^. #receipt of
      Nothing -> ""
      Just _ ->
        "; printf '{\"version\":1,\"sha256\":\"%s\",\"backup\":%s}\\n'"
          <> " \"$EXPECTED\" \"$BACKUP_RECEIPT_METADATA\" > /dump/backup.receipt.json"
          <> "; RECEIPT_EXPECTED=$(sha256sum /dump/backup.receipt.json | cut -d' ' -f1)"
          <> "; test ${#RECEIPT_EXPECTED} -eq 64"
          <> "; " <> storeCpCreateOnlyFromFile backend "/dump/backup.receipt.json" "\"$BACKUP_RECEIPT_DEST\""
          <> "; " <> storeCpToStdout backend "\"$BACKUP_RECEIPT_DEST\""
          <> " > /dump/backup.receipt.readback.json"
          <> "; RECEIPT_ACTUAL=$(sha256sum /dump/backup.receipt.readback.json | cut -d' ' -f1)"
          <> "; test ${#RECEIPT_ACTUAL} -eq 64"
          <> "; test \"$RECEIPT_EXPECTED\" = \"$RECEIPT_ACTUAL\""
          <> "; cat /dump/backup.receipt.readback.json > \"${BACKUP_TERMINATION_LOG_PATH:-/dev/termination-log}\""
          <> "; rm -f /dump/backup.receipt.json /dump/backup.receipt.readback.json"
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
-- determines its own upload verification and pruning policy.
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
renderDbBackupCronJob = renderDbBackupCronJobWithOptions True False

-- | A reviewed database may schedule uploads, but the CronJob must not delete
-- older backup objects without a separate reviewed pruning decision. The Job
-- downloads the exact object and checks its SHA-256 before reporting success.
renderInventoryDbBackupCronJob :: Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderInventoryDbBackupCronJob = renderDbBackupCronJobWithOptions False True

-- | Native bytes issued before reviewed backup readback verification was added.
-- Used only to recognize and upgrade an already accepted schedule.
renderPreviousInventoryDbBackupCronJob :: Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderPreviousInventoryDbBackupCronJob = renderDbBackupCronJobWithOptions False False

renderDbBackupCronJobWithOptions :: Bool -> Bool -> Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderDbBackupCronJobWithOptions shouldPrune shouldVerify ns name eng version backend keep =
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
            , verifyStored = shouldVerify
            , receipt = Nothing
            , backend = backend
            }
      }

-- ---------------------------------------------------------------------------
-- Command driver

-- | Render the old backup Job and CronJob without submitting either to Kubernetes.
-- This preview is read-only; live manual backups use reviewed Job scopes.
previewDbBackup :: Text -> Text -> StoreBackend -> Int -> IO ()
previewDbBackup ns databaseName backend keep = do
  erow <- getDatabase ns databaseName
  case erow of
    Left err -> die err
    Right r -> case parseEngine (r ^. #engine) of
      Nothing -> die ("database '" <> databaseName <> "' has an unknown engine: " <> r ^. #engine)
      Just eng -> do
        now <- getCurrentTime
        let ts = snapshotTimestamp now
            image = engineImage eng <> ":" <> r ^. #version
            dest = storeObjectUrl backend (dbBackupObjectPath databaseName ts (backupExt eng))
            jobInputs =
              BackupJobInputs
                { namespace = ns
                , jobName = manualBackupJobName databaseName ts
                , engine = eng
                , clientImage = image
                , serviceHost = databaseName
                , secretName = dbSecretName databaseName
                , name = databaseName
                , destination = BackupDestUrl dest
                , prefix = storePrefixUrl backend (dbBackupKeyPrefix databaseName)
                , keep = keep
                , selfPrune = False
                , verifyStored = False
                , receipt = Nothing
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
        TIO.putStrLn "--- Backup Job manifest ---"
        BS.putStr (renderBackupJob jobInputs)
        TIO.putStrLn ""
        TIO.putStrLn "--- Backup CronJob manifest ---"
        BS.putStr (renderBackupCronJob cronInputs)

die :: Text -> IO a
die msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
