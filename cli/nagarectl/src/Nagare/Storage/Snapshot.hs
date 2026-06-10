{-# LANGUAGE PackageImports #-}

-- | @nagarectl storage snapshot APP VOLUME@ (EP-36): point-in-time backup of an
-- app volume's file contents to GCS, plus the backup-ownership policy and
-- retention pruning (MasterPlan Integration Point IP4).
--
-- A snapshot is a @tar.gz@ of the volume's mounted contents, produced by a
-- short-lived in-cluster Kubernetes Job that co-mounts the same @local-path@ PVC
-- (read-only) and streams the archive to
-- @gs://<bucket>/volumes/<app>/<volume>/<timestamp>.tar.gz@ — the same bucket and
-- ADC conventions the Postgres/SQLite backups use. The Job is used (not
-- @kubectl exec@) because a Knative app scales to zero and has no stable pod.
--
-- The pure pieces ('snapshotObjectPath', 'snapshotGsUrl', 'snapshotTimestamp',
-- 'snapshotsToPrune', 'backupExcludedWarnings', 'renderSnapshotJob') are
-- separated from the @kubectl@/@gsutil@ IO so they are unit-testable without a
-- cluster.
module Nagare.Storage.Snapshot
  ( -- * Pure GCS path / timestamp helpers
    snapshotObjectPath
  , snapshotGsUrl
  , snapshotTimestamp
  , snapshotsToPrune

    -- * Backup-ownership policy (pure)
  , backupExcludedWarnings

    -- * Snapshot Job rendering (pure)
  , SnapshotJobInputs (..)
  , renderSnapshotJob

    -- * Command driver
  , runSnapshot
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import "generic-lens" Data.Generics.Labels ()

import Cradle
import Control.Monad (forM_)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sortBy)
import Data.Ord (Down (..), comparing)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Data.Yaml qualified as Y
import Nagare.Dsl.Types
  ( Deployment
  , RetentionPolicy (..)
  , Volume
  , namespaceText
  , serviceNameText
  , volumeNameText
  )
import Nagare.Storage.Discover (pvcName)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hClose, stderr)
import System.IO.Temp (withSystemTempFile)

-- ---------------------------------------------------------------------------
-- Pure helpers

-- | The GCS object path /within the bucket/ for one snapshot (IP4):
-- @volumes/<app>/<volume>/<timestamp>.tar.gz@. The bucket is deliberately kept
-- out so this is trivially testable.
snapshotObjectPath :: Text -> Text -> Text -> Text
snapshotObjectPath app volume timestamp =
  "volumes/" <> app <> "/" <> volume <> "/" <> timestamp <> ".tar.gz"

-- | The full @gs://@ URL for one snapshot.
snapshotGsUrl :: Text -> Text -> Text -> Text -> Text
snapshotGsUrl bucket app volume timestamp =
  "gs://" <> bucket <> "/" <> snapshotObjectPath app volume timestamp

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
      <> volumeNameText (v ^. #volName)
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
  { sjiNamespace :: !Text
  , sjiJobName :: !Text
  , sjiClaimName :: !Text
  , sjiDestUrl :: !Text
  -- ^ the @gs://@ URL from 'snapshotGsUrl'
  , sjiMountPath :: !Text
  -- ^ in-Job mount path, e.g. @/vol@
  }
  deriving stock (Generic, Eq, Show)

-- | Render the short-lived @batch/v1@ Job that tars the volume to GCS. Mounts
-- the PVC read-only by @claimName@ (single-node RWO co-mount, proven by EP-33),
-- runs @google/cloud-sdk:slim@ (ships @tar@/@gzip@/@gsutil@), points ADC at the
-- node metadata IP (@GCE_METADATA_HOST@, as the Litestream example does), pins
-- the project to @tan-nb-exp@ (the in-cluster analogue of the shell preflight),
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
          [ "name" .= sjiJobName i
          , "namespace" .= sjiNamespace i
          , "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)]
          ]
    , "spec"
        .= object
          [ "backoffLimit" .= (0 :: Int)
          , "template"
              .= object
                [ "spec"
                    .= object
                      [ "restartPolicy" .= ("Never" :: Text)
                      , "containers"
                          .= toJSON
                            [ object
                                [ "name" .= ("snapshot" :: Text)
                                , "image" .= ("google/cloud-sdk:slim" :: Text)
                                , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
                                , "args" .= toJSON [snapshotShell]
                                , "env"
                                    .= toJSON
                                      [ envVar "DEST" (sjiDestUrl i)
                                      , envVar "GCE_METADATA_HOST" "169.254.169.254"
                                      , envVar "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"
                                      ]
                                , "volumeMounts"
                                    .= toJSON
                                      [ object
                                          [ "name" .= ("vol" :: Text)
                                          , "mountPath" .= sjiMountPath i
                                          , "readOnly" .= True
                                          ]
                                      ]
                                ]
                            ]
                      , "volumes"
                          .= toJSON
                            [ object
                                [ "name" .= ("vol" :: Text)
                                , "persistentVolumeClaim" .= object ["claimName" .= sjiClaimName i]
                                ]
                            ]
                      ]
                ]
          ]
    ]
  where
    envVar n v = object ["name" .= (n :: Text), "value" .= (v :: Text)]
    -- Tar the mount and stream straight to GCS; $DEST comes from the env above.
    snapshotShell =
      "set -e; tar -C "
        <> sjiMountPath i
        <> " -czf - . | gsutil -o GSUtil:parallel_composite_upload_threshold=150M cp - \"$DEST\"" ::
        Text

-- ---------------------------------------------------------------------------
-- Command driver

-- | Snapshot @volume@ of the app described by @dep@ to @bucket@, keeping the last
-- @keep@ snapshots for that volume. Resolves the PVC name deterministically
-- ('pvcName'); errors if the config declares no such volume. The @timestamp@ is
-- read from the wall clock here (the pure helpers take it as an argument so they
-- stay deterministic).
runSnapshot :: Deployment -> Text -> Text -> Int -> IO ()
runSnapshot dep volume bucket keep = do
  let app = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)
      declared = map (volumeNameText . (^. #volName)) (dep ^. #volumes)
  if volume `notElem` declared
    then die ("app " <> app <> " declares no volume named '" <> volume <> "'")
    else do
      now <- getCurrentTime
      let ts = snapshotTimestamp now
          claim = pvcName app volume
          dest = snapshotGsUrl bucket app volume ts
          jobName = T.take 63 (T.toLower ("nagare-snapshot-" <> app <> "-" <> volume <> "-" <> ts))
          job =
            SnapshotJobInputs
              { sjiNamespace = ns
              , sjiJobName = jobName
              , sjiClaimName = claim
              , sjiDestUrl = dest
              , sjiMountPath = "/vol"
              }
      applyJob (renderSnapshotJob job)
      waitForJob ns jobName
      -- Best-effort cleanup of the completed Job; failure here is non-fatal.
      run_ $ cmd "kubectl" & addArgs ["delete", "job", T.unpack jobName, "-n", T.unpack ns, "--ignore-not-found"]
      pruneSnapshots bucket app volume keep
      TIO.putStrLn ("Snapshot written: " <> dest)

-- | Apply a rendered manifest via a temp file (mirrors 'Nagare.Deploy.applyManifests').
applyJob :: ByteString -> IO ()
applyJob manifest = withSystemTempFile "nagare-snapshot-job.yaml" $ \fp h -> do
  BS.hPut h manifest
  hClose h
  run_ $ cmd "kubectl" & addArgs ["apply", "-f", fp]

-- | Block until the Job completes; on failure print its logs and exit non-zero.
waitForJob :: Text -> Text -> IO ()
waitForJob ns jobName = do
  (code, _ :: StdoutUntrimmed) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "wait"
          , "--for=condition=complete"
          , "--timeout=600s"
          , "job/" <> T.unpack jobName
          , "-n"
          , T.unpack ns
          ]
        & silenceStderr
  case code of
    ExitSuccess -> pure ()
    ExitFailure _ -> do
      TIO.hPutStrLn stderr ("nagarectl: snapshot job " <> jobName <> " did not complete; recent logs:")
      run_ $
        cmd "kubectl"
          & addArgs ["logs", "job/" <> T.unpack jobName, "-n", T.unpack ns, "--tail", "50"]
      exitFailure

-- | List the volume's existing snapshots and delete all but the newest @keep@.
pruneSnapshots :: Text -> Text -> Text -> Int -> IO ()
pruneSnapshots bucket app volume keep = do
  let prefix = "gs://" <> bucket <> "/" <> "volumes/" <> app <> "/" <> volume <> "/"
  (code, StdoutUntrimmed out) <-
    run $ cmd "gsutil" & addArgs ["ls", T.unpack prefix] & silenceStderr
  case code of
    ExitFailure _ -> pure () -- nothing to prune (or no objects yet)
    ExitSuccess -> do
      let objs = filter (not . T.null) (map T.strip (T.lines out))
          surplus = snapshotsToPrune keep objs
      forM_ surplus $ \o ->
        run_ $ cmd "gsutil" & addArgs ["rm", T.unpack o]

die :: Text -> IO a
die msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
