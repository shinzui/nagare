-- | Restore renderers (MasterPlan 9, EP-47). The legacy preview is read-only.
-- The reviewed PostgreSQL Job downloads and loads an accepted backup into a
-- new scratch database. Redis uses a separate PVC-backed scratch StatefulSet
-- and a verifier Job because an RDB loads when Redis starts.
--
-- Pure helpers (@resolveBackupObject@, @isGsUrl@, @renderRestoreJob@) are
-- unit-testable without a cluster.
module Nagare.Database.Restore
  ( isObjectUrl
  , resolveBackupObject
  , RestoreJobInputs (..)
  , VerifiedRestoreSource (..)
  , renderRestoreJob
  , renderRebuildRestoreJob
  , renderRedisScratchService
  , renderRedisScratchStatefulSet
  , renderRedisScratchVerifyJob
  , downloadShell
  , previewDbRestore
  )
where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Yaml qualified as Y
import Nagare.Cluster.GcsJob
  ( DataMovementJob (..)
  , StoreBackend (..)
  , dataMovementJobSpec
  , storeCpToStdout
  , storeEnv
  , storeHostAliases
  , storeImage
  , storeObjectUrl
  , storeShellPreamble
  )
import Nagare.Database.Backup (backupExt, backupRawExt, clickHouseSourceAffinity, dbBackupObjectPath, manualDatabaseJobName)
import Nagare.Database.Discover (DbRow (..), getDatabase)
import Nagare.Dsl.Database (Engine (..), dbSecretName, engineImage, engineToken, parseEngine)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Storage.Snapshot (snapshotTimestamp)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Is the BACKUP_ID already a full object URL (@gs://@ in cloud mode or
-- @s3://@ in local mode)?
isObjectUrl :: Text -> Bool
isObjectUrl t = "gs://" `T.isPrefixOf` t || "s3://" `T.isPrefixOf` t

-- | Resolve a BACKUP_ID to a full object URL for the backend: a full URL is used
-- verbatim; a bare timestamp is composed against the backend/name/ext (EP-84).
resolveBackupObject :: StoreBackend -> Text -> Text -> Text -> Text
resolveBackupObject backend name ext backupId
  | isObjectUrl backupId = backupId
  | otherwise = storeObjectUrl backend (dbBackupObjectPath name backupId ext)

data RestoreJobInputs = RestoreJobInputs
  { namespace :: !Text
  , jobName :: !Text
  , engine :: !Engine
  , clientImage :: !Text
  , serviceHost :: !Text
  , secretName :: !Text
  , name :: !Text
  , sourceUrl :: !Text
  , liveTarget :: !Bool
  , verifiedSource :: !(Maybe VerifiedRestoreSource)
  , backend :: !StoreBackend
  -- ^ the object-store backend (EP-84): drives the download container's image,
  -- env, and copy-from-store shell.
  }
  deriving stock (Generic, Eq, Show)

-- | A reviewed restore pins the bytes checked by its accepted backup receipt.
-- The PostgreSQL Job or Redis scratch init rereads both objects before loading.
data VerifiedRestoreSource = VerifiedRestoreSource
  { receiptUrl :: !Text
  , receiptSha256 :: !Text
  , backupSha256 :: !Text
  , scratchDatabase :: !Text
  , expiryEpoch :: !Integer
  , objectVersion :: !(Maybe Text)
  , receiptVersion :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | Render the two-container restore Job (download init + engine-restore main).
renderRestoreJob :: RestoreJobInputs -> ByteString
renderRestoreJob i = renderJobWith (i ^. #engine == ClickHouse) (restoreContainer i) i

-- | EP-183 M4: load a verified recovery point into the rebuilt database
-- itself, never over data. Each engine first refuses a target that already
-- holds data, then loads as close to all-or-nothing as the engine allows:
--
-- * PostgreSQL: the dump loads in one transaction, so a failed load leaves the
--   database empty and a second run is refused only once data is present.
-- * ClickHouse: the archive restores into a staging database named for the
--   restore; a failure leaves @default@ empty. One @RENAME TABLE@ statement then
--   moves every table into @default@, after a second emptiness check, and the
--   empty staging database is dropped.
-- * Redis: the RDB is placed beside the data directory and renamed onto
--   @dump.rdb@ (an atomic rename) after snapshots are switched off; the server
--   then shuts down without saving, loads the file whole when its container
--   restarts, and must report exactly the key count the RDB holds.
renderRebuildRestoreJob :: RestoreJobInputs -> ByteString
renderRebuildRestoreJob i =
  renderJobWith
    (i ^. #engine /= Postgres)
    ( object
        [ "name" .= ("restore" :: Text)
        , "image" .= (i ^. #clientImage)
        , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
        , "args" .= toJSON [rebuildRestoreShell (i ^. #engine) (i ^. #serviceHost) (maybe "" (^. #scratchDatabase) (i ^. #verifiedSource))]
        , "env" .= toJSON (restoreEnv (i ^. #engine) (i ^. #secretName))
        , "volumeMounts"
            .= toJSON
              ( dumpMount
                  : [ object ["name" .= ("source-data" :: Text), "mountPath" .= ("/source-data" :: Text)]
                    | i ^. #engine /= Postgres
                    ]
              )
        ]
    )
    i

-- | The staging name (ClickHouse) or file (Redis) is the restore's own, so a
-- leftover from a failed attempt refuses rather than mixing with a new one.
rebuildRestoreShell :: Engine -> Text -> Text -> Text
rebuildRestoreShell Postgres svc _ =
  "set -e; relations=\"$(psql -tA -v ON_ERROR_STOP=1 -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -c \"select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_toast%' and n.nspname not like 'pg_temp%'\")\"; "
    <> "test \"$relations\" = 0 || { echo \"the rebuilt database already holds $relations relations; refusing to restore over data\" >&2; exit 3; }; "
    <> "psql -v ON_ERROR_STOP=1 --single-transaction -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -f /dump/backup.sql"
rebuildRestoreShell ClickHouse svc stage =
  "set -e; ch() { clickhouse-client -h "
    <> svc
    <> " --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" --query \"$1\"; }; "
    <> "tables=\"$(ch \"SELECT count() FROM system.tables WHERE database = 'default'\")\"; "
    <> "test \"$tables\" = 0 || { echo \"the rebuilt database already holds $tables tables; refusing to restore over data\" >&2; exit 3; }; "
    <> "test \"$(ch \"SELECT count() FROM system.databases WHERE name = '"
    <> stage
    <> "'\")\" = 0; "
    <> "ARCHIVE=\"/source-data/backups/nagare-restore-"
    <> stage
    <> ".zip\"; test ! -e \"$ARCHIVE\"; mkdir -p /source-data/backups; cp /dump/backup.zip \"$ARCHIVE\"; "
    <> "ch \"RESTORE DATABASE default AS \\`"
    <> stage
    <> "\\` FROM File('nagare-restore-"
    <> stage
    <> ".zip')\"; rm -- \"$ARCHIVE\"; "
    <> "moves=\"$(ch \"SELECT arrayStringConcat(groupArray(concat('\\`"
    <> stage
    <> "\\`.\\`', name, '\\` TO default.\\`', name, '\\`')), ', ') FROM system.tables WHERE database = '"
    <> stage
    <> "'\")\"; "
    <> "test \"$(ch \"SELECT count() FROM system.tables WHERE database = 'default'\")\" = 0 || { echo \"data reached the rebuilt database during the restore; the staging database "
    <> stage
    <> " is kept\" >&2; exit 3; }; "
    <> "if test -n \"$moves\"; then ch \"RENAME TABLE $moves\"; fi; "
    <> "ch \"DROP DATABASE \\`"
    <> stage
    <> "\\`\"; ch \"SELECT name, total_rows FROM system.tables WHERE database = 'default' ORDER BY name\""
rebuildRestoreShell Redis svc stage =
  "set -e; rc() { redis-cli -h "
    <> svc
    <> " -a \"$REDIS_PASSWORD\" --no-auth-warning \"$@\"; }; "
    <> "expected=\"$(redis-check-rdb /dump/backup.rdb | sed -n 's/.*\\[info\\] \\([0-9][0-9]*\\) keys read.*/\\1/p' | tail -n 1)\"; "
    <> "test -n \"$expected\" || { echo \"the recovery point's key count cannot be read\" >&2; exit 4; }; "
    <> "keys=\"$(rc DBSIZE)\"; "
    <> "test \"$keys\" = 0 || { echo \"the rebuilt database already holds $keys keys; refusing to restore over data\" >&2; exit 3; }; "
    <> "STAGED=/source-data/nagare-rebuild-"
    <> stage
    <> ".rdb; test ! -e \"$STAGED\"; cp /dump/backup.rdb \"$STAGED\"; sync; "
    <> "rc CONFIG SET save '' >/dev/null; "
    <> "test \"$(rc DBSIZE)\" = 0 || { echo \"data reached the rebuilt database during the restore; $STAGED is kept\" >&2; exit 3; }; "
    <> "mv -- \"$STAGED\" /source-data/dump.rdb; sync; "
    <> "rc SHUTDOWN NOSAVE >/dev/null 2>&1 || true; "
    <> "attempt=0; until test \"$(rc PING 2>/dev/null)\" = PONG; do attempt=$((attempt + 1)); test \"$attempt\" -lt 150 || exit 5; sleep 2; done; "
    <> "loaded=\"$(rc DBSIZE)\"; "
    <> "test \"$loaded\" = \"$expected\" || { echo \"the restarted server holds $loaded keys, the recovery point $expected\" >&2; exit 6; }; "
    <> "echo \"restored $loaded keys\""

-- | The data PVC is mounted, on the database's node, when the engine needs it.
renderJobWith :: Bool -> Value -> RestoreJobInputs -> ByteString
renderJobWith mountData container i =
  Y.encode $
    object
      [ "apiVersion" .= ("batch/v1" :: Text)
      , "kind" .= ("Job" :: Text)
      , "metadata"
          .= object
            [ "name" .= (i ^. #jobName)
            , "namespace" .= (i ^. #namespace)
            , "labels" .= labels
            ]
      , "spec"
          .= dataMovementJobSpec
            DataMovementJob
              { templateLabels = Just labels
              , serviceAccountName = Nothing
              , backoffLimit = 0
              , hostAliases = storeHostAliases (i ^. #backend)
              , affinity =
                  if mountData
                    then Just (dataSourceAffinity (i ^. #engine) (i ^. #namespace) (i ^. #name))
                    else Nothing
              , initContainers = [downloadContainer i]
              , containers = [container]
              , volumes =
                  [object ["name" .= ("dump" :: Text), "emptyDir" .= object []]]
                    <> [ object
                           [ "name" .= ("source-data" :: Text)
                           , "persistentVolumeClaim" .= object ["claimName" .= dbPvcName (i ^. #name)]
                           ]
                       | mountData
                       ]
              }
      ]
  where
    labels =
      object
        [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
        , "nagare.dev/database" .= (i ^. #name)
        ]

-- | A Job that mounts a database's data PVC runs on the database Pod's node.
dataSourceAffinity :: Engine -> Text -> Text -> Value
dataSourceAffinity ClickHouse namespaceName databaseName = clickHouseSourceAffinity namespaceName databaseName
dataSourceAffinity engine namespaceName databaseName =
  object
    [ "podAffinity"
        .= object
          [ "requiredDuringSchedulingIgnoredDuringExecution"
              .= toJSON
                [ object
                    [ "labelSelector" .= object ["matchLabels" .= object ["nagare.dev/database" .= databaseName, "nagare.dev/engine" .= engineToken engine]]
                    , "namespaces" .= toJSON [namespaceName]
                    , "topologyKey" .= ("kubernetes.io/hostname" :: Text)
                    ]
                ]
          ]
    ]

-- | Redis RDB files load at server startup. A reviewed scratch restore therefore
-- owns a separate Service, PVC, and StatefulSet; the source instance is never
-- given the RDB. The startup init container pins and verifies both store versions
-- before publishing the file on the scratch PVC. A partial first load refuses
-- restart until an operator reviews the PVC instead of silently replacing data.
renderRedisScratchService :: Text -> Text -> ByteString
renderRedisScratchService ns scratch =
  Y.encode $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Service" :: Text)
      , "metadata"
          .= object
            ["name" .= scratch, "namespace" .= ns, "labels" .= redisScratchLabels scratch]
      , "spec"
          .= object
            [ "clusterIP" .= ("None" :: Text)
            , "selector" .= redisScratchSelector scratch
            , "ports"
                .= toJSON
                  [ object
                      [ "name" .= ("redis" :: Text)
                      , "port" .= (6379 :: Int)
                      , "targetPort" .= (6379 :: Int)
                      ]
                  ]
            ]
      ]

renderRedisScratchStatefulSet :: RestoreJobInputs -> Text -> Text -> ByteString
renderRedisScratchStatefulSet i scratch claim =
  Y.encode $
    object
      [ "apiVersion" .= ("apps/v1" :: Text)
      , "kind" .= ("StatefulSet" :: Text)
      , "metadata"
          .= object
            [ "name" .= scratch
            , "namespace" .= (i ^. #namespace)
            , "labels" .= redisScratchLabels scratch
            ]
      , "spec"
          .= object
            [ "serviceName" .= scratch
            , "replicas" .= (1 :: Int)
            , "selector" .= object ["matchLabels" .= redisScratchSelector scratch]
            , "template"
                .= object
                  [ "metadata" .= object ["labels" .= redisScratchLabels scratch]
                  , "spec"
                      .= object
                        ( [ "initContainers" .= toJSON [redisScratchDownloadContainer i]
                          , "containers" .= toJSON [redisScratchServer i]
                          , "volumes"
                              .= toJSON
                                [ object
                                    [ "name" .= ("dump" :: Text)
                                    , "persistentVolumeClaim" .= object ["claimName" .= claim]
                                    ]
                                ]
                          ]
                            <> maybe
                              []
                              (\aliases -> ["hostAliases" .= aliases])
                              (storeHostAliases (i ^. #backend))
                        )
                  ]
            ]
      ]

renderRedisScratchVerifyJob :: RestoreJobInputs -> Text -> ByteString
renderRedisScratchVerifyJob i scratch =
  Y.encode $
    object
      [ "apiVersion" .= ("batch/v1" :: Text)
      , "kind" .= ("Job" :: Text)
      , "metadata"
          .= object
            [ "name" .= (i ^. #jobName)
            , "namespace" .= (i ^. #namespace)
            , "labels" .= redisScratchLabels scratch
            ]
      , "spec"
          .= dataMovementJobSpec
            DataMovementJob
              { templateLabels = Just (redisScratchLabels scratch)
              , serviceAccountName = Nothing
              , backoffLimit = 0
              , hostAliases = storeHostAliases (i ^. #backend)
              , affinity = Nothing
              , initContainers = []
              , containers =
                  [ object
                      [ "name" .= ("verify" :: Text)
                      , "image" .= (i ^. #clientImage)
                      , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
                      , "args"
                          .= toJSON
                            [ "set -e; i=0; until test \"$(REDISCLI_AUTH=\"$REDIS_PASSWORD\" redis-cli -h "
                                <> scratch
                                <> " --no-auth-warning ping)\" = PONG; do i=$((i+1)); "
                                <> "if test \"$i\" -ge 150; then exit 1; fi; sleep 2; done; "
                                <> "REDISCLI_AUTH=\"$REDIS_PASSWORD\" redis-cli -h "
                                <> scratch
                                <> " --no-auth-warning INFO persistence | grep -q 'loading:0'; "
                                <> "REDISCLI_AUTH=\"$REDIS_PASSWORD\" redis-cli -h "
                                <> scratch
                                <> " --no-auth-warning DBSIZE"
                            ]
                      , "env" .= toJSON (restoreEnv Redis (i ^. #secretName))
                      ]
                  ]
              , volumes = []
              }
      ]

redisScratchSelector :: Text -> Value
redisScratchSelector scratch = object ["nagare.dev/restore-scratch" .= scratch]

redisScratchLabels :: Text -> Value
redisScratchLabels scratch =
  object
    [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
    , "nagare.dev/restore-scratch" .= scratch
    ]

redisScratchDownloadContainer :: RestoreJobInputs -> Value
redisScratchDownloadContainer i = case downloadContainer i of
  -- The base downloader already supplies exact-version env, store credentials,
  -- both SHA checks, and the PVC mount at /dump.
  Object fields -> Object (KM.insert "args" (toJSON [redisScratchDownloadShell i]) fields)
  other -> other

redisScratchDownloadShell :: RestoreJobInputs -> Text
redisScratchDownloadShell i =
  "set -e; if test -e /dump/.nagare-restore-complete; then "
    <> "test \"$(cat /dump/.nagare-restore-complete)\" = \"$EXPECTED_BACKUP_SHA256\"; "
    <> "command -v sha256sum >/dev/null 2>&1 || dnf install -y -q coreutils >/dev/null 2>&1; "
    <> "test \"$(sha256sum /dump/backup.gz | cut -d' ' -f1)\" = \"$EXPECTED_BACKUP_SHA256\"; "
    <> "test -s /dump/backup.rdb; "
    <> "else test ! -e /dump/backup.gz && test ! -e /dump/backup.rdb; "
    <> downloadShell (i ^. #backend) Redis (i ^. #verifiedSource)
    <> "; test -s /dump/backup.rdb; "
    <> "printf %s \"$EXPECTED_BACKUP_SHA256\" > /dump/.nagare-restore-complete; fi"

redisScratchServer :: RestoreJobInputs -> Value
redisScratchServer i =
  object
    [ "name" .= ("redis" :: Text)
    , "image" .= (i ^. #clientImage)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args"
        .= toJSON
          [ ("set -e; redis-check-rdb /data/backup.rdb >/dev/null; " :: Text)
              <> "exec redis-server --requirepass \"$REDIS_PASSWORD\" "
              <> "--dir /data --dbfilename backup.rdb --save '' --appendonly no"
          ]
    , "env" .= toJSON (restoreEnv Redis (i ^. #secretName))
    , "ports" .= toJSON [object ["containerPort" .= (6379 :: Int)]]
    , "readinessProbe"
        .= object
          [ "exec"
              .= object
                [ "command"
                    .= toJSON
                      ["/bin/sh" :: Text, "-c", "test \"$(REDISCLI_AUTH=\"$REDIS_PASSWORD\" redis-cli --no-auth-warning ping)\" = PONG"]
                ]
          , "periodSeconds" .= (5 :: Int)
          , "timeoutSeconds" .= (5 :: Int)
          ]
    , "volumeMounts"
        .= toJSON
          [ object
              ["name" .= ("dump" :: Text), "mountPath" .= ("/data" :: Text)]
          ]
    ]

dumpMount :: Value
dumpMount = object ["name" .= ("dump" :: Text), "mountPath" .= ("/dump" :: Text)]

downloadContainer :: RestoreJobInputs -> Value
downloadContainer i =
  object
    [ "name" .= ("download" :: Text)
    , "image" .= storeImage (i ^. #backend)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [downloadShell (i ^. #backend) (i ^. #engine) (i ^. #verifiedSource)]
    , "env"
        .= toJSON
          ( [plainEnv "SRC" (i ^. #sourceUrl)]
              <> maybe
                []
                ( \source ->
                    [ plainEnv "RECEIPT_URL" (source ^. #receiptUrl)
                    , plainEnv "EXPECTED_RECEIPT_SHA256" (source ^. #receiptSha256)
                    , plainEnv "EXPECTED_BACKUP_SHA256" (source ^. #backupSha256)
                    , plainEnv "BACKUP_EXPIRY_EPOCH" (T.pack (show (source ^. #expiryEpoch)))
                    ]
                )
                (i ^. #verifiedSource)
              <> case (i ^. #backend, i ^. #verifiedSource) of
                (GcsBackend {}, Just source)
                  | Just selectedObject <- source ^. #objectVersion
                  , Just selectedReceipt <- source ^. #receiptVersion ->
                      [ plainEnv "OBJECT_VERSION" selectedObject
                      , plainEnv "RECEIPT_VERSION" selectedReceipt
                      ]
                (MinioBackend ref, Just source)
                  | Just selectedObject <- source ^. #objectVersion
                  , Just selectedReceipt <- source ^. #receiptVersion ->
                      let prefix = "s3://" <> ref ^. #bucket <> "/"
                          objectKey = maybe "" id (T.stripPrefix prefix (i ^. #sourceUrl))
                          receiptKey = maybe "" id (T.stripPrefix prefix (source ^. #receiptUrl))
                       in [ plainEnv "STORE_ENDPOINT" (ref ^. #endpoint)
                          , plainEnv "STORE_BUCKET" (ref ^. #bucket)
                          , plainEnv "OBJECT_KEY" objectKey
                          , plainEnv "RECEIPT_KEY" receiptKey
                          , plainEnv "OBJECT_VERSION" selectedObject
                          , plainEnv "RECEIPT_VERSION" selectedReceipt
                          ]
                _ -> []
              <> storeEnv (i ^. #backend)
          )
    , "volumeMounts" .= toJSON [dumpMount]
    ]

restoreContainer :: RestoreJobInputs -> Value
restoreContainer i =
  object
    [ "name" .= ("restore" :: Text)
    , "image" .= (i ^. #clientImage)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args"
        .= toJSON
          [ maybe
              ( restoreShell
                  (i ^. #engine)
                  (i ^. #serviceHost)
                  (i ^. #liveTarget)
              )
              (verifiedRestoreShell (i ^. #engine) (i ^. #serviceHost))
              (i ^. #verifiedSource)
          ]
    , "env"
        .= toJSON
          ( restoreEnv (i ^. #engine) (i ^. #secretName)
              <> maybe
                []
                (\source -> [plainEnv "SCRATCH_DATABASE" (source ^. #scratchDatabase)])
                (i ^. #verifiedSource)
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

plainEnv :: Text -> Text -> Value
plainEnv n v = object ["name" .= n, "value" .= v]

secretEnv :: Text -> Text -> Text -> Value
secretEnv n secret key =
  object
    [ "name" .= n
    , "valueFrom" .= object ["secretKeyRef" .= object ["name" .= secret, "key" .= key]]
    ]

restoreEnv :: Engine -> Text -> [Value]
restoreEnv Postgres secret =
  [ secretEnv "PGPASSWORD" secret "POSTGRES_PASSWORD"
  , secretEnv "POSTGRES_USER" secret "POSTGRES_USER"
  , secretEnv "POSTGRES_DB" secret "POSTGRES_DB"
  ]
restoreEnv Redis secret = [secretEnv "REDIS_PASSWORD" secret "REDIS_PASSWORD"]
restoreEnv ClickHouse secret =
  [ secretEnv "CLICKHOUSE_USER" secret "CLICKHOUSE_USER"
  , secretEnv "CLICKHOUSE_PASSWORD" secret "CLICKHOUSE_PASSWORD"
  ]

downloadShell :: StoreBackend -> Engine -> Maybe VerifiedRestoreSource -> Text
downloadShell backend eng = \case
  Nothing ->
    "set -e; "
      <> storeShellPreamble backend
      <> storeCpToStdout backend "\"$SRC\""
      <> " | gunzip > /dump/backup."
      <> backupRawExt eng
  Just source
    | Just _ <- source ^. #objectVersion
    , Just _ <- source ^. #receiptVersion -> case backend of
        MinioBackend {} ->
          "set -e; test \"$BACKUP_EXPIRY_EPOCH\" -eq 0 || test \"$(date -u +%s)\" -lt \"$BACKUP_EXPIRY_EPOCH\"; "
            <> storeShellPreamble backend
            <> hashTools
            <> "aws s3api get-object --bucket \"$STORE_BUCKET\" --key \"$RECEIPT_KEY\" --version-id \"$RECEIPT_VERSION\" --endpoint-url \"$STORE_ENDPOINT\" /dump/backup.receipt.json > /dump/receipt-response.json; "
            <> "aws s3api get-object --bucket \"$STORE_BUCKET\" --key \"$OBJECT_KEY\" --version-id \"$OBJECT_VERSION\" --endpoint-url \"$STORE_ENDPOINT\" /dump/backup.gz > /dump/object-response.json; "
            <> "python3 -c 'import json,os; assert json.load(open(\"/dump/receipt-response.json\")).get(\"VersionId\")==os.environ[\"RECEIPT_VERSION\"]; assert json.load(open(\"/dump/object-response.json\")).get(\"VersionId\")==os.environ[\"OBJECT_VERSION\"]'; "
            <> "test \"$(sha256sum /dump/backup.receipt.json | cut -d' ' -f1)\" = \"$EXPECTED_RECEIPT_SHA256\"; "
            <> "test \"$(sha256sum /dump/backup.gz | cut -d' ' -f1)\" = \"$EXPECTED_BACKUP_SHA256\"; "
            <> "gunzip -c /dump/backup.gz > /dump/backup."
            <> backupRawExt eng
        GcsBackend {} ->
          "set -e; test \"$BACKUP_EXPIRY_EPOCH\" -eq 0 || test \"$(date -u +%s)\" -lt \"$BACKUP_EXPIRY_EPOCH\"; "
            <> hashTools
            <> "gcloud storage cp --do-not-decompress \"$RECEIPT_URL#$RECEIPT_VERSION\" /dump/backup.receipt.json; "
            <> "gcloud storage cp --do-not-decompress \"$SRC#$OBJECT_VERSION\" /dump/backup.gz; "
            <> "test \"$(sha256sum /dump/backup.receipt.json | cut -d' ' -f1)\" = \"$EXPECTED_RECEIPT_SHA256\"; "
            <> "test \"$(sha256sum /dump/backup.gz | cut -d' ' -f1)\" = \"$EXPECTED_BACKUP_SHA256\"; "
            <> "gunzip -c /dump/backup.gz > /dump/backup."
            <> backupRawExt eng
  Just source
    | isJust (source ^. #objectVersion) || isJust (source ^. #receiptVersion) ->
        "exit 1"
  Just _ ->
    "set -e; test \"$BACKUP_EXPIRY_EPOCH\" -eq 0 || test \"$(date -u +%s)\" -lt \"$BACKUP_EXPIRY_EPOCH\"; "
      <> storeShellPreamble backend
      <> hashTools
      <> storeCpToStdout backend "\"$RECEIPT_URL\""
      <> " > /dump/backup.receipt.json; "
      <> "test \"$(sha256sum /dump/backup.receipt.json | cut -d' ' -f1)\" = \"$EXPECTED_RECEIPT_SHA256\"; "
      <> storeCpToStdout backend "\"$SRC\""
      <> " > /dump/backup.gz; "
      <> "test \"$(sha256sum /dump/backup.gz | cut -d' ' -f1)\" = \"$EXPECTED_BACKUP_SHA256\"; "
      <> "gunzip -c /dump/backup.gz > /dump/backup."
      <> backupRawExt eng
  where
    hashTools = case backend of
      GcsBackend {} -> "command -v sha256sum >/dev/null 2>&1; "
      MinioBackend {} ->
        "command -v sha256sum >/dev/null 2>&1 || dnf install -y -q coreutils >/dev/null 2>&1; "
          <> "command -v sha256sum >/dev/null 2>&1; "

-- | Create a scratch database once. A failed or uncertain restore leaves its
-- name occupied for explicit recovery; retries cannot drop its contents.
verifiedRestoreShell :: Engine -> Text -> VerifiedRestoreSource -> Text
verifiedRestoreShell Postgres svc _ =
  "set -e; createdb -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" \"$SCRATCH_DATABASE\"; "
    <> "psql -v ON_ERROR_STOP=1 -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" -d \"$SCRATCH_DATABASE\" -f /dump/backup.sql; "
    <> "psql -v ON_ERROR_STOP=1 -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" -d \"$SCRATCH_DATABASE\" -c '\\dt'"
verifiedRestoreShell ClickHouse svc source =
  "set -e; ARCHIVE=\"/source-data/backups/nagare-restore-"
    <> source ^. #scratchDatabase
    <> ".zip\"; "
    <> "test ! -e \"$ARCHIVE\"; cp /dump/backup.zip \"$ARCHIVE\"; "
    <> "clickhouse-client -h "
    <> svc
    <> " --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" "
    <> "--query \"RESTORE DATABASE default AS \\`"
    <> source ^. #scratchDatabase
    <> "\\` FROM File('nagare-restore-"
    <> source ^. #scratchDatabase
    <> ".zip')\"; "
    <> "attempt=1; while :; do "
    <> "if result=$(clickhouse-client -h "
    <> svc
    <> " --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" "
    <> "--connect_timeout=5 --send_timeout=5 --receive_timeout=5 --max_execution_time=5 "
    <> "--query \"SELECT count() FROM system.databases WHERE name = '"
    <> source ^. #scratchDatabase
    <> "'\") && test \"$result\" = 1; then "
    <> "rm -- \"$ARCHIVE\"; break; fi; "
    <> "test \"$attempt\" -lt 6 || exit 1; attempt=$((attempt + 1)); sleep 2; done"
verifiedRestoreShell _ _ _ = "exit 1"

-- | Legacy read-only Job preview. Reviewed execution uses accepted inventory
-- scopes and separate Redis scratch resources instead of these Redis branches.
restoreShell :: Engine -> Text -> Bool -> Text
restoreShell Postgres svc live =
  "set -e; T="
    <> (if live then "\"$POSTGRES_DB\"" else "\"${POSTGRES_DB}_restore_scratch\"")
    <> "; "
    <> warn live
    <> "dropdb -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" --if-exists \"$T\"; createdb -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" \"$T\"; psql -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" -d \"$T\" -f /dump/backup.sql; "
    <> "echo restored into \"$T\"; psql -h "
    <> svc
    <> " -U \"$POSTGRES_USER\" -d \"$T\" -c '\\dt'"
restoreShell ClickHouse _ live
  | live = "echo 'Read-only preview: reviewed ClickHouse live-target restore is unavailable.'"
  | otherwise =
      "echo 'Read-only preview: use db restore with --restore-id and --save-plan "
        <> "for a reviewed ClickHouse scratch database.'"
restoreShell Redis _ live
  | live = "echo 'Read-only preview: reviewed Redis live-target restore is unavailable.'"
  | otherwise =
      "echo 'Read-only preview: use db restore with --restore-id and --save-plan "
        <> "for a reviewed Redis scratch instance.'"

warn :: Bool -> Text
warn True = "echo 'WARNING: restoring into the LIVE database'; "
warn False = ""

-- | Render the old restore Job without submitting it to Kubernetes. Live
-- scratch restores use accepted backup receipts and reviewed Job scopes.
previewDbRestore :: Text -> Text -> Text -> Bool -> StoreBackend -> IO ()
previewDbRestore ns databaseName backupId live backend = do
  erow <- getDatabase ns databaseName
  case erow of
    Left err -> die err
    Right r -> case parseEngine (r ^. #engine) of
      Nothing -> die ("database '" <> databaseName <> "' has an unknown engine: " <> r ^. #engine)
      Just eng -> do
        now <- getCurrentTime
        let ts = snapshotTimestamp now
            inputs =
              RestoreJobInputs
                { namespace = ns
                , jobName = manualDatabaseJobName "nagare-dbrestore-" databaseName ts
                , engine = eng
                , clientImage = engineImage eng <> ":" <> r ^. #version
                , serviceHost = databaseName
                , secretName = dbSecretName databaseName
                , name = databaseName
                , sourceUrl = resolveBackupObject backend databaseName (backupExt eng) backupId
                , liveTarget = live
                , verifiedSource = Nothing
                , backend = backend
                }
        TIO.putStrLn "--- Restore Job manifest ---"
        BS.putStr (renderRestoreJob inputs)

die :: Text -> IO a
die msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
