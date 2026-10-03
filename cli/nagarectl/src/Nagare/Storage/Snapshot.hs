-- | Pure volume snapshot renderers and read-only preview.
--
-- A reviewed snapshot is a @tar.gz@ of a read-only mounted PVC. It uses a
-- fixed, create-only object address and a separate checksum receipt. A Job
-- can run even when the associated Knative app has scaled to zero.
--
-- The older timestamped renderer remains available only for read-only previews.
module Nagare.Storage.Snapshot
  ( -- * Pure object-key / timestamp helpers
    snapshotObjectPath
  , snapshotTimestamp
  , snapshotsToPrune

    -- * Backup-ownership policy (pure)
  , backupExcludedWarnings

    -- * Snapshot Job rendering (pure)
  , SnapshotJobInputs (..)
  , renderSnapshotJob
  , ReviewedSnapshotJobInputs (..)
  , renderReviewedSnapshotJob

    -- * Read-only preview
  , previewSnapshot
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List (sortBy)
import Data.Ord (Down (..), comparing)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Data.Yaml qualified as Y
import Nagare.Cluster.GcsJob
  ( DataMovementJob (..)
  , MinioRef (..)
  , StoreBackend (..)
  , dataMovementJobSpec
  , storeCpCreateOnlyFromFile
  , storeCpFromStdin
  , storeCpToStdout
  , storeEnv
  , storeHostAliases
  , storeImage
  , storeObjectUrl
  , storeShellPreamble
  )
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types
  ( Deployment
  , RetentionPolicy (..)
  , Volume
  , namespaceText
  , serviceNameText
  , volumeNameText
  )
import Nagare.Storage.Discover (pvcName)
import System.Exit (exitFailure)
import System.IO (stderr)

-- ---------------------------------------------------------------------------
-- Pure helpers

-- | The object key /within the bucket/ for one snapshot (IP4):
-- @volumes/<app>/<volume>/<timestamp>.tar.gz@. Backend-independent (EP-84 keeps
-- the key layout stable across GCS and MinIO); the @gs://@/@s3://@ URL is formed
-- by 'Nagare.Cluster.GcsJob.storeObjectUrl'. The bucket is deliberately kept
-- out so this is trivially testable.
snapshotObjectPath :: Text -> Text -> Text -> Text
snapshotObjectPath app volume timestamp =
  "volumes/" <> app <> "/" <> volume <> "/" <> timestamp <> ".tar.gz"

-- | Format a 'UTCTime' as the @YYYYMMDDTHHMMSSZ@ stamp shared with
-- @scripts/backup-postgres.sh@ (@date -u +%Y%m%dT%H%M%SZ@).
snapshotTimestamp :: UTCTime -> Text
snapshotTimestamp = T.pack . formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ"

-- | Keep-last-N retention: given the keep-count and the existing snapshot object
-- names (or @gs://@ URLs) for one @<app>/<volume>@ prefix, return the subset to
-- delete. Names sort lexicographically because the timestamp is fixed-width and
-- zero-padded, so newest-first is a descending sort. Idempotent: on an
-- already-pruned set it returns @[]@.
snapshotsToPrune :: Int -> [Text] -> [Text]
snapshotsToPrune n names = drop (max 0 n) (sortBy (comparing Down) names)

-- | One warning line per volume excluded from backups, given the app name and
-- its declared volumes. A volume is backup-excluded iff its 'RetentionPolicy' is
-- 'Delete' (see EP-36 Decision Log — the field is overloaded: @Delete@ means both
-- "disposable on app deletion" and "not worth backing up"). Empty list ⇒ every
-- volume is backed up.
backupExcludedWarnings :: Text -> [Volume] -> [Text]
backupExcludedWarnings app vols =
  [ "warning: volume '"
      <> volumeNameText (v ^. #name)
      <> "' on app '"
      <> app
      <> "' is NOT backed up (backup excluded in config)"
  | v <- vols
  , (v ^. #retention) == Delete
  ]

-- ---------------------------------------------------------------------------
-- Job rendering

-- | Inputs to 'renderSnapshotJob'.
data SnapshotJobInputs = SnapshotJobInputs
  { namespace :: !Text
  , jobName :: !Text
  , claimName :: !Text
  , destinationUrl :: !Text
  -- ^ the object URL from @storeObjectUrl backend (snapshotObjectPath …)@
  , mountPath :: !Text
  -- ^ in-Job mount path, e.g. @/vol@
  , backend :: !StoreBackend
  -- ^ the object-store backend (EP-84): drives the snapshot container's image,
  -- env, and copy-to-store shell.
  }
  deriving stock (Generic, Eq, Show)

-- | Render the short-lived @batch/v1@ Job that tars the volume to GCS. Mounts
-- the PVC read-only by @claimName@ (single-node RWO co-mount, proven by EP-33),
-- runs @google/cloud-sdk:slim@ (ships @tar@/@gzip@/@gsutil@), points ADC at the
-- node metadata IP (@GCE_METADATA_HOST@, as the Litestream example does), pins
-- the project to the configured target project (the in-cluster analogue of the
-- shell preflight),
-- and streams @tar … | gsutil cp - "$DEST"@ with no large temp file.
-- @restartPolicy: Never@ + @backoffLimit: 0@ surface a failure instead of looping.
renderSnapshotJob :: SnapshotJobInputs -> ByteString
renderSnapshotJob i = Y.encode (jobValue i)

jobValue :: SnapshotJobInputs -> Value
jobValue i =
  object
    [ "apiVersion" .= ("batch/v1" :: Text)
    , "kind" .= ("Job" :: Text)
    , "metadata"
        .= object
          [ "name" .= (i ^. #jobName)
          , "namespace" .= (i ^. #namespace)
          , "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)]
          ]
    , "spec"
        .= dataMovementJobSpec
          DataMovementJob
            { templateLabels = Nothing
            , serviceAccountName = Nothing
            , backoffLimit = 0
            , hostAliases = storeHostAliases (i ^. #backend)
            , affinity = Nothing
            , initContainers = []
            , containers =
                [ object
                    [ "name" .= ("snapshot" :: Text)
                    , "image" .= storeImage (i ^. #backend)
                    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
                    , "args" .= toJSON [snapshotShell]
                    , "env"
                        .= toJSON
                          (envVar "DEST" (i ^. #destinationUrl) : storeEnv (i ^. #backend))
                    , "volumeMounts"
                        .= toJSON
                          [ object
                              [ "name" .= ("vol" :: Text)
                              , "mountPath" .= (i ^. #mountPath)
                              , "readOnly" .= True
                              ]
                          ]
                    ]
                ]
            , volumes =
                [ object
                    [ "name" .= ("vol" :: Text)
                    , "persistentVolumeClaim" .= object ["claimName" .= (i ^. #claimName)]
                    ]
                ]
            }
    ]
  where
    envVar n v = object ["name" .= (n :: Text), "value" .= (v :: Text)]
    -- Tar the mount and stream straight to the store; $DEST comes from the env
    -- above. The cloud (@gsutil@) bytes are unchanged; MinIO uses @aws s3@.
    snapshotShell =
      "set -e; "
        <> storeShellPreamble (i ^. #backend)
        <> "tar -C "
        <> i ^. #mountPath
        <> " -czf - . | "
        <> storeCpFromStdin (i ^. #backend) "\"$DEST\"" ::
        Text

-- | A fixed-key, create-only snapshot with a stored-byte checksum receipt.
-- The inventory compiler adds source identity pins to the Job metadata.
data ReviewedSnapshotJobInputs = ReviewedSnapshotJobInputs
  { snapshot :: !SnapshotJobInputs
  , receiptUrl :: !Text
  , receiptMetadata :: !Text
  }
  deriving stock (Generic, Eq, Show)

renderReviewedSnapshotJob :: ReviewedSnapshotJobInputs -> ByteString
renderReviewedSnapshotJob input =
  Y.encode $
    object
      [ "apiVersion" .= ("batch/v1" :: Text)
      , "kind" .= ("Job" :: Text)
      , "metadata"
          .= object
            [ "name" .= (job ^. #jobName)
            , "namespace" .= (job ^. #namespace)
            , "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)]
            ]
      , "spec"
          .= dataMovementJobSpec
            DataMovementJob
              { templateLabels = Nothing
              , serviceAccountName = Nothing
              , backoffLimit = 0
              , hostAliases = storeHostAliases backend
              , affinity = Nothing
              , initContainers = []
              , containers =
                  [ object
                      [ "name" .= ("upload" :: Text)
                      , "image" .= storeImage backend
                      , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
                      , "args" .= toJSON [shell]
                      , "env"
                          .= toJSON
                            ( [ envVar "DEST" (job ^. #destinationUrl)
                              , envVar "BACKUP_RECEIPT_DEST" (input ^. #receiptUrl)
                              , envVar "BACKUP_RECEIPT_METADATA" (input ^. #receiptMetadata)
                              ]
                                <> storeEnv backend
                            )
                      , "volumeMounts"
                          .= toJSON
                            [ object
                                [ "name" .= ("vol" :: Text)
                                , "mountPath" .= ("/vol" :: Text)
                                , "readOnly" .= True
                                ]
                            , object ["name" .= ("dump" :: Text), "mountPath" .= ("/dump" :: Text)]
                            ]
                      ]
                  ]
              , volumes =
                  [ object
                      [ "name" .= ("vol" :: Text)
                      , "persistentVolumeClaim"
                          .= object ["claimName" .= (job ^. #claimName)]
                      ]
                  , object ["name" .= ("dump" :: Text), "emptyDir" .= object []]
                  ]
              }
      ]
  where
    job = input ^. #snapshot
    backend = job ^. #backend
    envVar n v = object ["name" .= (n :: Text), "value" .= (v :: Text)]
    versionedLocalBucket = case backend of
      GcsBackend {} -> ""
      MinioBackend ref ->
        "aws s3api put-bucket-versioning --bucket "
          <> ref ^. #bucket
          <> " --versioning-configuration Status=Enabled --endpoint-url "
          <> ref ^. #endpoint
          <> "; "
    verifyTools = case backend of
      GcsBackend {} -> "command -v sha256sum >/dev/null 2>&1; "
      MinioBackend {} ->
        "command -v sha256sum >/dev/null 2>&1 || dnf install -y -q coreutils >/dev/null 2>&1; "
          <> "command -v sha256sum >/dev/null 2>&1; "
    shell =
      "set -e; "
        <> storeShellPreamble backend
        <> verifyTools
        <> "tar -C /vol -czf /dump/backup.tar.gz .; "
        <> "EXPECTED=$(sha256sum /dump/backup.tar.gz | cut -d' ' -f1); "
        <> "test ${#EXPECTED} -eq 64; "
        <> versionedLocalBucket
        <> storeCpCreateOnlyFromFile backend "/dump/backup.tar.gz" "\"$DEST\""
        <> "; ACTUAL=$("
        <> storeCpToStdout backend "\"$DEST\""
        <> " | sha256sum | cut -d' ' -f1); test \"$EXPECTED\" = \"$ACTUAL\"; "
        <> "printf '{\"version\":1,\"sha256\":\"%s\",\"backup\":%s}\\n'"
        <> " \"$EXPECTED\" \"$BACKUP_RECEIPT_METADATA\" > /dump/backup.receipt.json; "
        <> storeCpCreateOnlyFromFile backend "/dump/backup.receipt.json" "\"$BACKUP_RECEIPT_DEST\""
        <> "; "
        <> storeCpToStdout backend "\"$BACKUP_RECEIPT_DEST\""
        <> " > /dump/backup.receipt.readback.json; "
        <> "test \"$(sha256sum /dump/backup.receipt.json | cut -d' ' -f1)\" = "
        <> "\"$(sha256sum /dump/backup.receipt.readback.json | cut -d' ' -f1)\"; "
        <> "cat /dump/backup.receipt.readback.json > "
        <> "\"${BACKUP_TERMINATION_LOG_PATH:-/dev/termination-log}\""

-- ---------------------------------------------------------------------------
-- Read-only preview

-- | Show the legacy shape without submitting a Job or deleting stored data.
previewSnapshot :: Deployment -> Text -> StoreBackend -> IO ()
previewSnapshot dep volume backend = do
  let app = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)
      declared = map (volumeNameText . (^. #name)) (dep ^. #volumes)
  if volume `notElem` declared
    then die ("app " <> app <> " declares no volume named '" <> volume <> "'")
    else do
      now <- getCurrentTime
      let ts = snapshotTimestamp now
          claim = pvcName app volume
          dest = storeObjectUrl backend (snapshotObjectPath app volume ts)
          name = T.take 63 (T.toLower ("nagare-snapshot-" <> app <> "-" <> volume <> "-" <> ts))
          job =
            SnapshotJobInputs
              { namespace = ns
              , jobName = name
              , claimName = claim
              , destinationUrl = dest
              , mountPath = "/vol"
              , backend = backend
              }
      BS.putStr (renderSnapshotJob job)
      TIO.putStrLn ("Preview destination: " <> dest)

die :: Text -> IO a
die msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
