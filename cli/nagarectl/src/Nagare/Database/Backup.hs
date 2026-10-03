-- | @nagarectl db backup NAME@ and the scheduled-backup CronJob (MasterPlan 9,
-- EP-47, Integration Point IP6): an engine-appropriate logical dump of a managed
-- database, uploaded to @gs://\<backup-bucket>/databases/\<name\>/\<ts\>.\<ext\>@.
-- Reviewed schedules check the exact stored bytes and leave pruning to a
-- separate lifecycle decision. The old Job renderer remains for dry-run output.
--
-- The dump runs in a short-lived in-cluster Job with two containers sharing an
-- @emptyDir@: an initContainer running the engine's own client image writes the
-- dump to @\/dump@, and the main container (@google/cloud-sdk:slim@) gzips and
-- @gsutil cp@s it to GCS. Legacy CronJobs run daily; reviewed schedules run
-- every fifteen minutes with a signed pre-dump recovery-point timestamp.
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
  , clickHouseSourceAffinity

    -- * Schedule
  , defaultBackupSchedule

    -- * Job / CronJob rendering (pure)
  , BackupDest (..)
  , BackupReceipt (..)
  , BackupReceiptTarget (..)
  , BackupJobInputs (..)
  , renderBackupJob
  , backupJobSpecValue
  , uploadShell
  , BackupCronInputs (..)
  , renderBackupCronJob
  , renderDbBackupCronJob
  , renderInventoryDbBackupCronJob
  , renderPreviousInventoryDbBackupCronJob
  , renderPreviousSignedInventoryDbBackupCronJob

    -- * Read-only legacy preview
  , previewDbBackup
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
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
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.BackupFreshness
  ( RecoveryPointObjective (HourlyRecoveryPoint)
  , recoveryPointObjectiveText
  , recoveryPointSchedule
  )
import Nagare.Resource.Canonical (canonicalValue, contentDigest)
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
    suffix =
      "-"
        <> T.take 20 (digestText (contentDigest (TE.encodeUtf8 databaseName)))
        <> "-"
        <> timestamp
    available = 63 - T.length prefix - T.length suffix

-- | The final (gzipped) object extension per engine.
backupExt :: Engine -> Text
backupExt Postgres = "sql.gz"
backupExt Redis = "rdb.gz"
backupExt ClickHouse = "zip.gz"

-- | The uncompressed dump-file extension per engine (the gzip strips the @.gz@).
backupRawExt :: Engine -> Text
backupRawExt Postgres = "sql"
backupRawExt Redis = "rdb"
backupRawExt ClickHouse = "zip"

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
  | -- | A runtime-selected key. Reviewed schedules use the CronJob-created
    -- Job's UID; legacy self-pruning schedules retain their timestamp key.
    BackupDestStamped
  deriving stock (Generic, Eq, Show)

-- | A checked upload receipt. A scheduled receipt also records the physical
-- Job UID, but is not accepted backup authority until separate ingestion has
-- verified its delegation and source incarnation.
data BackupReceiptTarget = FixedReceiptTarget !Text | BackupObjectReceiptTarget
  deriving stock (Generic, Eq, Show)

data BackupReceipt = BackupReceipt
  { destination :: !BackupReceiptTarget
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
  -- ^ when True (only a legacy CronJob), the upload container prunes inline
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
backupJobSpecValue = backupJobSpecValueWithRecoveryPoint True

backupJobSpecValueWithRecoveryPoint :: Bool -> BackupJobInputs -> Value
backupJobSpecValueWithRecoveryPoint timed i =
  dataMovementJobSpec
    DataMovementJob
      { templateLabels = Just (labelsValue i)
      , serviceAccountName = if sourceAttested i then Just (i ^. #jobName) else Nothing
      , backoffLimit = 2
      , hostAliases = storeHostAliases (i ^. #backend)
      , affinity =
          if i ^. #engine == ClickHouse
            then
              Just (clickHouseSourceAffinity (i ^. #namespace) (i ^. #name))
            else Nothing
      , initContainers = [sourceProbeContainer timed i | sourceAttested i] <> [dumpContainer i]
      , containers = [uploadContainer timed i]
      , volumes =
          [object ["name" .= ("dump" :: Text), "emptyDir" .= object []]]
            <> [ object
                   [ "name" .= ("source-data" :: Text)
                   , "persistentVolumeClaim" .= object ["claimName" .= dbPvcName (i ^. #name)]
                   ]
               | i ^. #engine == ClickHouse
               ]
      }

-- | ClickHouse writes its consistent database archive on the server's data
-- volume. Read that exact PVC from a Job placed on the server's node; the
-- accepted source PVC/StatefulSet are independently pinned by the review.
clickHouseSourceAffinity :: Text -> Text -> Value
clickHouseSourceAffinity namespaceName databaseName =
  object
    [ "podAffinity"
        .= object
          [ "requiredDuringSchedulingIgnoredDuringExecution"
              .= toJSON
                [ object
                    [ "labelSelector"
                        .= object
                          [ "matchLabels"
                              .= object
                                [ "nagare.dev/database" .= databaseName
                                , "nagare.dev/engine" .= ("clickhouse" :: Text)
                                ]
                          ]
                    , "namespaces" .= toJSON [namespaceName]
                    , "topologyKey" .= ("kubernetes.io/hostname" :: Text)
                    ]
                ]
          ]
    ]

-- | Only reviewed schedules use a dedicated account to observe their source.
-- A manual backup already pins the source through its accepted review.
sourceAttested :: BackupJobInputs -> Bool
sourceAttested i = case i ^. #receipt of
  Just (BackupReceipt BackupObjectReceiptTarget _) -> True
  _ -> False

-- | Capture the actual source incarnation before the database dump starts.
-- The same read runs after stored-byte verification, rejecting a replacement
-- that occurred while this Job was active. The account can read only these two
-- named objects in its namespace.
sourceProbeContainer :: Bool -> BackupJobInputs -> Value
sourceProbeContainer timed i =
  object
    [ "name" .= ("source" :: Text)
    , "image" .= storeImage (i ^. #backend)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [(if timed then "set -eu; python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime(\"%Y-%m-%dT%H:%M:%SZ\"))' > /dump/recovery-point; " else "") <> sourceProbeShell <> " > /dump/source.json"]
    , "env" .= toJSON [plainEnv "BACKUP_SOURCE_NAME" (i ^. #name)]
    , "volumeMounts" .= toJSON [dumpMount]
    ]

sourceProbeShell :: Text
sourceProbeShell =
  "python3 -c 'import json,os,ssl,urllib.request; "
    <> "p=\"/var/run/secrets/kubernetes.io/serviceaccount/\"; "
    <> "ns=open(p+\"namespace\").read().strip(); "
    <> "token=open(p+\"token\").read().strip(); "
    <> "ctx=ssl.create_default_context(cafile=p+\"ca.crt\"); "
    <> "base=\"https://\"+os.environ[\"KUBERNETES_SERVICE_HOST\"]+\":\"+os.environ.get(\"KUBERNETES_SERVICE_PORT_HTTPS\",\"443\"); "
    <> "name=os.environ[\"BACKUP_SOURCE_NAME\"]; "
    <> "paths={\"statefulSetUid\":\"/apis/apps/v1/namespaces/\"+ns+\"/statefulsets/\"+name,"
    <> "\"pvcUid\":\"/api/v1/namespaces/\"+ns+\"/persistentvolumeclaims/nagare-db-\"+name+\"-data\"}; "
    <> "result={key:json.load(urllib.request.urlopen(urllib.request.Request(base+path,headers={\"Authorization\":\"Bearer \"+token}),context=ctx,timeout=20))[\"metadata\"][\"uid\"] for key,path in paths.items()}; "
    <> "assert all(result.values()); print(json.dumps(result,sort_keys=True,separators=(\",\",\":\")))'"

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
    , "env"
        .= toJSON
          ( dumpEnv (i ^. #engine) (i ^. #secretName)
              <> [backupRunEnv i | i ^. #engine == ClickHouse]
          )
    , "volumeMounts"
        .= toJSON
          ( dumpMount
              : [ object
                    [ "name" .= ("source-data" :: Text)
                    , "mountPath" .= ("/source-data" :: Text)
                    ]
                | i ^. #engine == ClickHouse
                ]
          )
    ]

backupRunEnv :: BackupJobInputs -> Value
backupRunEnv i = case i ^. #destination of
  BackupDestUrl _ -> plainEnv "BACKUP_RUN_ID" (i ^. #jobName)
  BackupDestStamped ->
    object
      [ "name" .= ("BACKUP_RUN_ID" :: Text)
      , "valueFrom"
          .= object
            [ "fieldRef"
                .= object
                  ["fieldPath" .= ("metadata.labels['batch.kubernetes.io/controller-uid']" :: Text)]
            ]
      ]

-- | The upload main container: the backend's data-movement image gzips the
-- dump and uploads it to @$DEST@. Reviewed fixed-key Jobs create only; reviewed
-- reviewed schedules use the Job UID and create only; legacy schedules retain
-- their timestamp key and inline keep-last-N deletion.
uploadContainer :: Bool -> BackupJobInputs -> Value
uploadContainer timed i =
  object
    [ "name" .= ("upload" :: Text)
    , "image" .= storeImage (i ^. #backend)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [uploadShellWithRecoveryPoint timed i]
    , "env"
        .= toJSON
          ( [plainEnv "DEST" url | BackupDestUrl url <- [i ^. #destination]]
              ++ [ plainEnv "PREFIX" (i ^. #prefix)
                 , plainEnv "KEEP" (T.pack (show (i ^. #keep)))
                 ]
              ++ [ object
                     [ "name" .= ("BACKUP_RUN_ID" :: Text)
                     , "valueFrom"
                         .= object
                           [ "fieldRef"
                               .= object
                                 ["fieldPath" .= ("metadata.labels['batch.kubernetes.io/controller-uid']" :: Text)]
                           ]
                     ]
                 | BackupDestStamped <- [i ^. #destination]
                 , not (i ^. #selfPrune)
                 ]
              ++ [plainEnv "BACKUP_SOURCE_NAME" (i ^. #name) | sourceAttested i]
              ++ [secretEnv "BACKUP_SIGNING_KEY" (i ^. #jobName <> "-signing") "HMAC_KEY" | sourceAttested i]
              ++ maybe
                []
                ( \r ->
                    [plainEnv "BACKUP_RECEIPT_METADATA" (r ^. #metadataJson)]
                      ++ case r ^. #destination of
                        FixedReceiptTarget address -> [plainEnv "BACKUP_RECEIPT_DEST" address]
                        BackupObjectReceiptTarget -> []
                )
                (i ^. #receipt)
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
  "case \"$BACKUP_RUN_ID\" in ''|*[!a-zA-Z0-9-]*) exit 1;; esac; "
    <> "ARCHIVE=\"/source-data/backups/${BACKUP_RUN_ID}.zip\"; "
    <> "test ! -e \"$ARCHIVE\"; "
    <> "clickhouse-client -h "
    <> svc
    <> " --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" "
    <> "--query \"BACKUP DATABASE default TO File('${BACKUP_RUN_ID}.zip')\"; "
    <> "test -s \"$ARCHIVE\"; cp \"$ARCHIVE\" /dump/backup.zip; "
    <> "rm -- \"$ARCHIVE\""

-- | The upload shell: gzip + a backend copy to @$DEST@. Reviewed Jobs and
-- schedules read back the exact stored bytes and compare SHA-256; fixed-key
-- Jobs create only. Legacy schedules can still use keep-last-N deletion.
uploadShell :: BackupJobInputs -> Text
uploadShell = uploadShellWithRecoveryPoint True

uploadShellWithRecoveryPoint :: Bool -> BackupJobInputs -> Text
uploadShellWithRecoveryPoint timed i =
  base <> if i ^. #selfPrune then "; " <> prune else ""
  where
    backend = i ^. #backend
    raw = backupRawExt (i ^. #engine)
    stamp = case i ^. #destination of
      BackupDestUrl _ -> ""
      BackupDestStamped
        | i ^. #selfPrune ->
            "DEST=\"${PREFIX}$(date -u +%Y%m%dT%H%M%SZ)." <> backupExt (i ^. #engine) <> "\"; "
        | otherwise ->
            "test -n \"$BACKUP_RUN_ID\"; "
              <> "case \"$BACKUP_RUN_ID\" in *[!a-f0-9-]* ) exit 1;; esac; "
              <> "DEST=\"${PREFIX}${BACKUP_RUN_ID}."
              <> backupExt (i ^. #engine)
              <> "\"; "
    base =
      "set -e; "
        <> stamp
        <> storeShellPreamble backend
        <> if i ^. #verifyStored then verifiedUpload else streamedUpload
    streamedUpload =
      "gzip -9 -c /dump/backup."
        <> raw
        <> " | "
        <> storeCpFromStdin backend "\"$DEST\""
    verifyTools = case backend of
      GcsBackend {} -> "command -v sha256sum >/dev/null 2>&1; "
      MinioBackend {} ->
        "command -v sha256sum >/dev/null 2>&1 || dnf install -y -q coreutils >/dev/null 2>&1; "
          <> "command -v sha256sum >/dev/null 2>&1; "
    createOnly = case i ^. #destination of
      BackupDestUrl _ -> not (i ^. #selfPrune)
      BackupDestStamped -> not (i ^. #selfPrune)
    uploadVerified =
      if createOnly
        then versionedLocalBucket <> storeCpCreateOnlyFromFile backend "/dump/backup.gz" "\"$DEST\""
        else storeCpFromStdin backend "\"$DEST\"" <> " < /dump/backup.gz"
    -- Reviewed local backups need a provider version ID for a later exact
    -- object deletion. Existing unversioned objects are never silently pruned.
    versionedLocalBucket = case backend of
      GcsBackend {} -> ""
      MinioBackend ref ->
        "aws s3api put-bucket-versioning --bucket "
          <> ref ^. #bucket
          <> " --versioning-configuration Status=Enabled --endpoint-url "
          <> ref ^. #endpoint
          <> "; "
    verifiedUpload =
      verifyTools
        <> "gzip -n -9 -c /dump/backup."
        <> raw
        <> " > /dump/backup.gz; "
        <> "EXPECTED=$(sha256sum /dump/backup.gz | cut -d' ' -f1); test ${#EXPECTED} -eq 64; "
        <> uploadVerified
        <> "; "
        <> "ACTUAL=$("
        <> storeCpToStdout backend "\"$DEST\""
        <> " | sha256sum | cut -d' ' -f1); test ${#ACTUAL} -eq 64; "
        <> "test \"$EXPECTED\" = \"$ACTUAL\""
        <> ( if sourceAttested i
               then
                 "; "
                   <> sourceProbeShell
                   <> " > /dump/source-after.json; "
                   <> "test \"$(sha256sum < /dump/source.json)\" = \"$(sha256sum < /dump/source-after.json)\"; "
                   <> "rm -f /dump/source-after.json"
               else ""
           )
        <> receiptUpload
        <> "; rm -f /dump/backup.gz"
    receiptUpload = case i ^. #receipt of
      Nothing -> ""
      Just receiptInput ->
        receiptPreamble (receiptInput ^. #destination)
          <> "; "
          <> receiptBody (receiptInput ^. #destination)
          <> " > /dump/backup.receipt.json"
          <> "; RECEIPT_EXPECTED=$(sha256sum /dump/backup.receipt.json | cut -d' ' -f1)"
          <> "; test ${#RECEIPT_EXPECTED} -eq 64"
          <> "; "
          <> storeCpCreateOnlyFromFile backend "/dump/backup.receipt.json" "\"$BACKUP_RECEIPT_DEST\""
          <> "; "
          <> storeCpToStdout backend "\"$BACKUP_RECEIPT_DEST\""
          <> " > /dump/backup.receipt.readback.json"
          <> "; RECEIPT_ACTUAL=$(sha256sum /dump/backup.receipt.readback.json | cut -d' ' -f1)"
          <> "; test ${#RECEIPT_ACTUAL} -eq 64"
          <> "; test \"$RECEIPT_EXPECTED\" = \"$RECEIPT_ACTUAL\""
          <> "; cat /dump/backup.receipt.readback.json > \"${BACKUP_TERMINATION_LOG_PATH:-/dev/termination-log}\""
          <> "; rm -f /dump/backup.receipt.json /dump/backup.receipt.readback.json"
          <> (if sourceAttested i then " /dump/backup.payload.json" else "")
    receiptPreamble (FixedReceiptTarget _) = ""
    receiptPreamble BackupObjectReceiptTarget =
      "; BACKUP_RECEIPT_DEST=\"${DEST}.receipt.json\""
        <> ( if timed
               then
                 "; printf '{\"sha256\":\"%s\",\"jobUid\":\"%s\",\"object\":\"%s\",\"source\":%s,\"backup\":%s,\"recoveryPoint\":\"%s\"}\\n'"
                   <> " \"$EXPECTED\" \"$BACKUP_RUN_ID\" \"$DEST\" \"$(cat /dump/source.json)\" \"$BACKUP_RECEIPT_METADATA\" \"$(cat /dump/recovery-point)\""
               else
                 "; printf '{\"sha256\":\"%s\",\"jobUid\":\"%s\",\"object\":\"%s\",\"source\":%s,\"backup\":%s}\\n'"
                   <> " \"$EXPECTED\" \"$BACKUP_RUN_ID\" \"$DEST\" \"$(cat /dump/source.json)\" \"$BACKUP_RECEIPT_METADATA\""
           )
        <> " > /dump/backup.payload.json"
        <> "; RECEIPT_SIGNATURE=$(python3 -c 'import hashlib,hmac,json,os; "
        <> "payload=json.load(open(\"/dump/backup.payload.json\")); "
        <> "body=json.dumps(payload,sort_keys=True,separators=(\",\",\":\"),ensure_ascii=False).encode(\"utf-8\"); "
        <> "print(hmac.new(bytes.fromhex(os.environ[\"BACKUP_SIGNING_KEY\"]),body,hashlib.sha256).hexdigest())')"
        <> "; test ${#RECEIPT_SIGNATURE} -eq 64"
    receiptBody (FixedReceiptTarget _) =
      "printf '{\"version\":1,\"sha256\":\"%s\",\"backup\":%s}\\n'"
        <> " \"$EXPECTED\" \"$BACKUP_RECEIPT_METADATA\""
    receiptBody BackupObjectReceiptTarget =
      (if timed then "printf '{\"version\":5,\"payload\":%s,\"hmacSha256\":\"%s\"}\\n'" else "printf '{\"version\":4,\"payload\":%s,\"hmacSha256\":\"%s\"}\\n'")
        <> " \"$(cat /dump/backup.payload.json)\" \"$RECEIPT_SIGNATURE\""
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
renderBackupCronJob = Y.encode . backupCronJobValue

backupCronJobValue :: BackupCronInputs -> Value
backupCronJobValue = backupCronJobValueWithRecoveryPoint True

backupCronJobValueWithRecoveryPoint :: Bool -> BackupCronInputs -> Value
backupCronJobValueWithRecoveryPoint timed i =
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
          , "jobTemplate" .= object ["spec" .= backupJobSpecValueWithRecoveryPoint timed (i ^. #base)]
          ]
    ]

-- | Legacy scheduled backup. Inline keep-last-N deletion is confined to
-- unadmitted contexts while reviewed pruning remains a separate lifecycle action.
renderDbBackupCronJob :: Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderDbBackupCronJob = renderDbBackupCronJobWithOptions HourlyRecoveryPoint True False True

-- | A reviewed database may schedule uploads, but the CronJob must not delete
-- older backup objects without a separate reviewed pruning decision. The Job
-- downloads the exact object and checks its SHA-256 before reporting success.
-- The context's recovery-point objective selects the cadence; a daily
-- objective is also written into the signed receipt metadata so freshness is
-- graded against the accepted schedule. Hourly omits the field, keeping the
-- bytes of schedules accepted before the objective became configurable.
renderInventoryDbBackupCronJob :: RecoveryPointObjective -> Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderInventoryDbBackupCronJob objective = renderDbBackupCronJobWithOptions objective False True True

-- | Native bytes issued before reviewed backup readback verification was added.
-- Used only to recognize and upgrade an already accepted schedule.
renderPreviousInventoryDbBackupCronJob :: Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderPreviousInventoryDbBackupCronJob = renderDbBackupCronJobWithOptions HourlyRecoveryPoint False False True

-- | Exact signed-v4 daily producer, for recognition of accepted schedules only.
renderPreviousSignedInventoryDbBackupCronJob :: Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderPreviousSignedInventoryDbBackupCronJob = renderDbBackupCronJobWithOptions HourlyRecoveryPoint False True False

renderDbBackupCronJobWithOptions :: RecoveryPointObjective -> Bool -> Bool -> Bool -> Text -> Text -> Engine -> Text -> StoreBackend -> Int -> ByteString
renderDbBackupCronJobWithOptions objective shouldPrune shouldVerify timed ns name eng version backend keep =
  Y.encode . backupCronJobValueWithRecoveryPoint timed $
    if shouldVerify
      then
        let provisional = withReceipt (T.replicate 64 "0")
            revision =
              digestText
                ( contentDigest
                    ( either
                        (error . T.unpack)
                        id
                        (canonicalValue (backupCronJobValueWithRecoveryPoint timed provisional))
                    )
                )
         in withReceipt revision
      else BackupCronInputs defaultBackupSchedule baseInputs
  where
    baseInputs =
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
    withReceipt revision =
      let metadata =
            object $
              [ "database" .= name
              , "namespace" .= ns
              , "engine" .= T.toLower (T.pack (show eng))
              , "format" .= backupExt eng
              , "schedule" .= ("nagare-dbbackup-" <> name)
              , "scheduleRevision" .= revision
              , "keep" .= keep
              ]
                <> [ "recoveryPoint" .= recoveryPointObjectiveText objective
                   | timed && objective /= HourlyRecoveryPoint
                   ]
          scheduledReceipt =
            BackupReceipt
              BackupObjectReceiptTarget
              (TE.decodeUtf8 (LBS.toStrict (Aeson.encode metadata)))
       in BackupCronInputs
            (if timed then recoveryPointSchedule objective else defaultBackupSchedule)
            (baseInputs {receipt = Just scheduledReceipt})

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
                      & #jobName
                      .~ "nagare-dbbackup-"
                      <> databaseName
                        & #destination
                        .~ BackupDestStamped
                        & #selfPrune
                        .~ True
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
