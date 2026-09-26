-- | Restore Job renderers (MasterPlan 9, EP-47). The legacy preview is
-- scratch-first by default; @--into-live@ changes only its read-only output.
-- Reviewed live scratch restore binds an accepted backup receipt in the
-- inventory compiler. A restore Job has two containers: an initContainer
-- (@google/cloud-sdk:slim@) downloads + gunzips the object into a shared
-- @emptyDir@, and the main container (the engine client image) loads it.
--
-- Pure helpers (@resolveBackupObject@, @isGsUrl@, @renderRestoreJob@) are
-- unit-testable without a cluster.
module Nagare.Database.Restore
  ( isObjectUrl
  , resolveBackupObject
  , RestoreJobInputs (..)
  , VerifiedRestoreSource (..)
  , renderRestoreJob
  , downloadShell
  , previewDbRestore
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
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
import Nagare.Database.Backup (backupExt, backupRawExt, dbBackupObjectPath, manualDatabaseJobName)
import Nagare.Database.Discover (DbRow (..), getDatabase)
import Nagare.Dsl.Database (Engine (..), dbSecretName, engineImage, parseEngine)
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
-- The Job rereads both objects before creating its new scratch target.
data VerifiedRestoreSource = VerifiedRestoreSource
  { receiptUrl :: !Text
  , receiptSha256 :: !Text
  , backupSha256 :: !Text
  , scratchDatabase :: !Text
  , expiryEpoch :: !Integer
  }
  deriving stock (Generic, Eq, Show)

-- | Render the two-container restore Job (download init + engine-restore main).
renderRestoreJob :: RestoreJobInputs -> ByteString
renderRestoreJob i =
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
              , backoffLimit = 0
              , hostAliases = storeHostAliases (i ^. #backend)
              , initContainers = [downloadContainer i]
              , containers = [restoreContainer i]
              , volumes = [object ["name" .= ("dump" :: Text), "emptyDir" .= object []]]
              }
      ]
  where
    labels =
      object
        [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
        , "nagare.dev/database" .= (i ^. #name)
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
          ([plainEnv "SRC" (i ^. #sourceUrl)]
            <> maybe [] (\source ->
                 [ plainEnv "RECEIPT_URL" (source ^. #receiptUrl)
                 , plainEnv "EXPECTED_RECEIPT_SHA256" (source ^. #receiptSha256)
                 , plainEnv "EXPECTED_BACKUP_SHA256" (source ^. #backupSha256)
                 , plainEnv "BACKUP_EXPIRY_EPOCH" (T.pack (show (source ^. #expiryEpoch)))
                 ]) (i ^. #verifiedSource)
            <> storeEnv (i ^. #backend))
    , "volumeMounts" .= toJSON [dumpMount]
    ]

restoreContainer :: RestoreJobInputs -> Value
restoreContainer i =
  object
    [ "name" .= ("restore" :: Text)
    , "image" .= (i ^. #clientImage)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [maybe (restoreShell (i ^. #engine) (i ^. #serviceHost)
        (i ^. #liveTarget)) (verifiedRestoreShell (i ^. #engine) (i ^. #serviceHost))
        (i ^. #verifiedSource)]
    , "env" .= toJSON (restoreEnv (i ^. #engine) (i ^. #secretName)
        <> maybe [] (\source -> [plainEnv "SCRATCH_DATABASE" (source ^. #scratchDatabase)])
             (i ^. #verifiedSource))
    , "volumeMounts" .= toJSON [dumpMount]
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
  Just _ ->
    "set -e; test \"$BACKUP_EXPIRY_EPOCH\" -eq 0 || test \"$(date -u +%s)\" -lt \"$BACKUP_EXPIRY_EPOCH\"; "
      <> storeShellPreamble backend <> hashTools
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
  "set -e; createdb -h " <> svc <> " -U \"$POSTGRES_USER\" \"$SCRATCH_DATABASE\"; "
    <> "psql -v ON_ERROR_STOP=1 -h " <> svc
    <> " -U \"$POSTGRES_USER\" -d \"$SCRATCH_DATABASE\" -f /dump/backup.sql; "
    <> "psql -v ON_ERROR_STOP=1 -h " <> svc
    <> " -U \"$POSTGRES_USER\" -d \"$SCRATCH_DATABASE\" -c '\\dt'"
verifiedRestoreShell _ _ _ = "exit 1"

-- | The per-engine restore shell. Scratch-first: Postgres/ClickHouse restore into
-- @\<db\>_restore_scratch@ unless @live@. Redis restore is whole-instance and is
-- only performed against the live instance when @--into live@ is passed; the
-- scratch case prints guidance (a disposable Redis instance is a follow-up).
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
restoreShell ClickHouse svc live =
  "set -e; T="
    <> (if live then "default" else "default_restore_scratch")
    <> "; "
    <> warn live
    <> "echo 'ClickHouse restore (validate command live — EP-48): loading /dump/backup.native into '$T; "
    <> "clickhouse-client -h "
    <> svc
    <> " --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" --query \"CREATE DATABASE IF NOT EXISTS $T\""
restoreShell Redis svc live
  | live =
      "set -e; echo 'WARNING: restoring into the LIVE Redis instance'; "
        <> "redis-cli -h "
        <> svc
        <> " -a \"$REDIS_PASSWORD\" --pipe < /dump/backup.rdb || "
        <> "echo 'Redis RDB restore is whole-instance: place dump.rdb on the data PVC and restart the pod'"
  | otherwise =
      "set -e; echo 'Redis scratch restore is a follow-up (a disposable Redis instance). "
        <> "Pass --into live to restore into the live instance, or restore manually by placing "
        <> "/dump/backup.rdb on the data PVC and restarting the pod.'"

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
