{-# LANGUAGE PackageImports #-}

-- | @nagarectl db restore NAME BACKUP_ID@ (MasterPlan 9, EP-47): restore a chosen
-- GCS backup into a database, scratch-first. By default the restore lands in a
-- disposable target (a @\<db\>_restore_scratch@ database for Postgres/ClickHouse)
-- so live data is never clobbered; @--into live@ targets the live database with a
-- loud warning. The restore runs in a two-container Job: an initContainer
-- (@google/cloud-sdk:slim@) downloads + gunzips the object into a shared
-- @emptyDir@, and the main container (the engine client image) loads it.
--
-- Pure helpers (@resolveBackupObject@, @isGsUrl@, @renderRestoreJob@) are
-- unit-testable without a cluster; the live restore drill is deferred to EP-48
-- (and gated on the in-pod-ADC routing fix the MasterPlan records).
module Nagare.Database.Restore
  ( isGsUrl
  , resolveBackupObject
  , RestoreJobInputs (..)
  , renderRestoreJob
  , runDbRestore
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import "generic-lens" Data.Generics.Labels ()

import Cradle
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Yaml qualified as Y
import Nagare.Database.Backup (backupExt, backupRawExt, dbBackupGsUrl)
import Nagare.Database.Discover (DbRow (..), getDatabase)
import Nagare.Dsl.Database (Engine (..), dbSecretName, engineImage, parseEngine)
import Nagare.Storage.Snapshot (snapshotTimestamp)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hClose, stderr)
import System.IO.Temp (withSystemTempFile)

-- | Is the BACKUP_ID already a full @gs://@ URL?
isGsUrl :: Text -> Bool
isGsUrl = T.isPrefixOf "gs://"

-- | Resolve a BACKUP_ID to a full @gs://@ object URL: a full URL is used
-- verbatim; a bare timestamp is composed against the bucket/name/ext.
resolveBackupObject :: Text -> Text -> Text -> Text -> Text
resolveBackupObject bucket name ext backupId
  | isGsUrl backupId = backupId
  | otherwise = dbBackupGsUrl bucket name backupId ext

data RestoreJobInputs = RestoreJobInputs
  { rjiNamespace :: !Text
  , rjiJobName :: !Text
  , rjiEngine :: !Engine
  , rjiClientImage :: !Text
  , rjiSvcHost :: !Text
  , rjiSecretName :: !Text
  , rjiName :: !Text
  , rjiSrcUrl :: !Text
  , rjiLiveTarget :: !Bool
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
            [ "name" .= rjiJobName i
            , "namespace" .= rjiNamespace i
            , "labels" .= labels
            ]
      , "spec"
          .= object
            [ "backoffLimit" .= (0 :: Int)
            , "template"
                .= object
                  [ "metadata" .= object ["labels" .= labels]
                  , "spec"
                      .= object
                        [ "restartPolicy" .= ("Never" :: Text)
                        , "initContainers" .= toJSON [downloadContainer i]
                        , "containers" .= toJSON [restoreContainer i]
                        , "volumes" .= toJSON [object ["name" .= ("dump" :: Text), "emptyDir" .= object []]]
                        ]
                  ]
            ]
      ]
  where
    labels =
      object
        [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
        , "nagare.dev/database" .= rjiName i
        ]

dumpMount :: Value
dumpMount = object ["name" .= ("dump" :: Text), "mountPath" .= ("/dump" :: Text)]

downloadContainer :: RestoreJobInputs -> Value
downloadContainer i =
  object
    [ "name" .= ("download" :: Text)
    , "image" .= ("google/cloud-sdk:slim" :: Text)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [downloadShell (rjiEngine i)]
    , "env"
        .= toJSON
          [ plainEnv "SRC" (rjiSrcUrl i)
          , plainEnv "GCE_METADATA_HOST" "169.254.169.254"
          , plainEnv "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"
          ]
    , "volumeMounts" .= toJSON [dumpMount]
    ]

restoreContainer :: RestoreJobInputs -> Value
restoreContainer i =
  object
    [ "name" .= ("restore" :: Text)
    , "image" .= rjiClientImage i
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [restoreShell (rjiEngine i) (rjiSvcHost i) (rjiLiveTarget i)]
    , "env" .= toJSON (restoreEnv (rjiEngine i) (rjiSecretName i))
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

downloadShell :: Engine -> Text
downloadShell eng =
  "set -e; gsutil cp \"$SRC\" - | gunzip > /dump/backup." <> backupRawExt eng

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

-- | Run @db restore NAME BACKUP_ID@.
runDbRestore :: Text -> Text -> Text -> Bool -> Text -> Bool -> IO ()
runDbRestore ns name backupId live bucket dryRun = do
  erow <- getDatabase ns name
  case erow of
    Left err -> die err
    Right r -> case parseEngine (drEngine r) of
      Nothing -> die ("database '" <> name <> "' has an unknown engine: " <> drEngine r)
      Just eng -> do
        now <- getCurrentTime
        let ts = snapshotTimestamp now
            src = resolveBackupObject bucket name (backupExt eng) backupId
            image = engineImage eng <> ":" <> drVersion r
            jobName = T.take 63 (T.toLower ("nagare-dbrestore-" <> name <> "-" <> ts))
            inputs =
              RestoreJobInputs
                { rjiNamespace = ns
                , rjiJobName = jobName
                , rjiEngine = eng
                , rjiClientImage = image
                , rjiSvcHost = name
                , rjiSecretName = dbSecretName name
                , rjiName = name
                , rjiSrcUrl = src
                , rjiLiveTarget = live
                }
        if dryRun
          then do
            TIO.putStrLn "--- Restore Job manifest ---"
            BS.putStr (renderRestoreJob inputs)
          else do
            applyJob (renderRestoreJob inputs)
            waitForJob ns jobName
            run_ $ cmd "kubectl" & addArgs ["logs", "job/" <> T.unpack jobName, "-n", T.unpack ns, "--tail", "50"]
            run_ $ cmd "kubectl" & addArgs ["delete", "job", T.unpack jobName, "-n", T.unpack ns, "--ignore-not-found"]
            if live
              then TIO.putStrLn ("Restored " <> name <> " from " <> src)
              else TIO.putStrLn ("Restored " <> name <> " into a scratch target from " <> src <> " — compare, then promote manually.")

applyJob :: ByteString -> IO ()
applyJob manifest = withSystemTempFile "nagare-dbrestore-job.yaml" $ \fp h -> do
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
      TIO.hPutStrLn stderr ("nagarectl: restore job " <> jobName <> " did not complete; recent logs:")
      run_ $ cmd "kubectl" & addArgs ["logs", "job/" <> T.unpack jobName, "-n", T.unpack ns, "--tail", "50"]
      exitFailure

die :: Text -> IO a
die msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
