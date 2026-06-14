-- | @nagarectl storage restore APP VOLUME BACKUP_ID [--into-live]@ (MasterPlan 13,
-- EP-1): restore a @tar.gz@ volume snapshot from GCS, scratch-first. By default
-- the archive is untarred into a disposable @\<pvc\>-restore-scratch@ PVC so live
-- data is never clobbered; @--into-live@ targets the live PVC with a loud
-- warning. This is the typed replacement for the deleted
-- @scripts/restore-volume.sh@; it gives volume restore the same scratch-first
-- safety @nagarectl db restore@ already has.
--
-- The restore runs in a one-container Job (@google/cloud-sdk:slim@) that streams
-- the object from GCS and untars it into the target PVC, then lists the restored
-- tree for comparison. The whole pod @.spec@ — including the
-- @metadata.google.internal@ @hostAliases@ that the 2026-06-10 audit found
-- missing here — comes from the shared 'Nagare.Cluster.GcsJob.dataMovementJobSpec',
-- so this renderer cannot drift from the other GCS data-movement Jobs.
module Nagare.Storage.Restore
  ( StorageRestoreJobInputs (..)
  , renderStorageRestoreJob
  , renderScratchPvc
  , runStorageRestore
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Generics.Labels ()

import Cradle
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Yaml qualified as Y
import Nagare.Cluster.GcsJob (DataMovementJob (..), dataMovementJobSpec, gcsContainerImage, metadataEnv)
import Nagare.Database.Restore (isGsUrl)
import Nagare.Dsl.Types
  ( Deployment
  , Volume
  , namespaceText
  , quantityText
  , serviceNameText
  , volumeNameText
  )
import Nagare.Storage.Discover (pvcName)
import Nagare.Storage.Snapshot (snapshotGsUrl, snapshotTimestamp)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hClose, stderr)
import System.IO.Temp (withSystemTempFile)

-- | Inputs to 'renderStorageRestoreJob'.
data StorageRestoreJobInputs = StorageRestoreJobInputs
  { sriNamespace :: !Text
  , sriJobName :: !Text
  , sriClaimName :: !Text
  -- ^ the PVC the restore writes into (scratch or live)
  , sriSrcUrl :: !Text
  -- ^ the @gs://@ @tar.gz@ object to restore
  , sriMountPath :: !Text
  -- ^ in-Job mount path, e.g. @/restore@
  , sriProject :: !Text
  -- ^ the GCP project for the restore container's @CLOUDSDK_CORE_PROJECT@
  }
  deriving stock (Generic, Eq, Show)

-- | Render the short-lived @batch/v1@ restore Job. One container on
-- @google/cloud-sdk:slim@ streams the archive from GCS and untars it into the
-- mounted PVC, then prints the restored tree. The pod @.spec@ (restartPolicy,
-- backoffLimit, metadata @hostAliases@) is the shared scaffolding from M1.
renderStorageRestoreJob :: StorageRestoreJobInputs -> ByteString
renderStorageRestoreJob i =
  Y.encode $
    object
      [ "apiVersion" .= ("batch/v1" :: Text)
      , "kind" .= ("Job" :: Text)
      , "metadata"
          .= object
            [ "name" .= sriJobName i
            , "namespace" .= sriNamespace i
            , "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)]
            ]
      , "spec"
          .= dataMovementJobSpec
            DataMovementJob
              { dmjTemplateLabels = Nothing
              , dmjInitContainers = []
              , dmjContainers = [restoreContainer i]
              , dmjVolumes =
                  [ object
                      [ "name" .= ("restore" :: Text)
                      , "persistentVolumeClaim" .= object ["claimName" .= sriClaimName i]
                      ]
                  ]
              }
      ]

restoreContainer :: StorageRestoreJobInputs -> Value
restoreContainer i =
  object
    [ "name" .= ("restore" :: Text)
    , "image" .= gcsContainerImage
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [restoreShell (sriMountPath i)]
    , "env" .= toJSON (plainEnv "SRC" (sriSrcUrl i) : metadataEnv (sriProject i))
    , "volumeMounts"
        .= toJSON
          [object ["name" .= ("restore" :: Text), "mountPath" .= sriMountPath i]]
    ]

-- | Stream the archive from GCS and untar it into the mount, then list the
-- restored tree (the same shell the deleted @scripts/restore-volume.sh@ ran).
restoreShell :: Text -> Text
restoreShell mount =
  "set -e; gsutil cp \"$SRC\" - | tar -C "
    <> mount
    <> " -xzf -; echo '--- restored tree (first 50 entries) ---'; find "
    <> mount
    <> " -maxdepth 3 | head -50"

plainEnv :: Text -> Text -> Value
plainEnv n v = object ["name" .= n, "value" .= v]

-- | Render the disposable scratch PVC the restore writes into (local-path, RWO),
-- labelled @nagare.dev/restore-scratch: "true"@ so it is obviously disposable.
renderScratchPvc :: Text -> Text -> Text -> ByteString
renderScratchPvc ns name size =
  Y.encode $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("PersistentVolumeClaim" :: Text)
      , "metadata"
          .= object
            [ "name" .= name
            , "namespace" .= ns
            , "labels"
                .= object
                  [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
                  , "nagare.dev/restore-scratch" .= ("true" :: Text)
                  ]
            ]
      , "spec"
          .= object
            [ "accessModes" .= toJSON (["ReadWriteOnce"] :: [Text])
            , "storageClassName" .= ("local-path" :: Text)
            , "resources" .= object ["requests" .= object ["storage" .= size]]
            ]
      ]

-- ---------------------------------------------------------------------------
-- Command driver

-- | Run @storage restore APP VOLUME BACKUP_ID@. Scratch-first: unless @live@, the
-- archive lands in a disposable @\<pvc\>-restore-scratch@ PVC and the live volume
-- is never mounted. @BACKUP_ID@ is a bare snapshot timestamp (composed against the
-- bucket\/app\/volume) or a full @gs://@ URL. With @dryRun@, print the manifests
-- and apply nothing.
runStorageRestore :: Deployment -> Text -> Text -> Bool -> Text -> Text -> Bool -> IO ()
runStorageRestore dep volume backupId live bucket project dryRun = do
  let app = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)
      vols = dep ^. #volumes
      declared = map (volumeNameText . (^. #volName)) vols
  if volume `notElem` declared
    then die ("app " <> app <> " declares no volume named '" <> volume <> "'")
    else do
      now <- getCurrentTime
      let ts = snapshotTimestamp now
          livePvc = pvcName app volume
          scratchPvc = T.take 63 (T.toLower (livePvc <> "-restore-scratch"))
          claim = if live then livePvc else scratchPvc
          src = if isGsUrl backupId then backupId else snapshotGsUrl bucket app volume backupId
          size = scratchSize volume vols
          jobName = T.take 63 (T.toLower ("nagare-volrestore-" <> app <> "-" <> volume <> "-" <> ts))
          job =
            StorageRestoreJobInputs
              { sriNamespace = ns
              , sriJobName = jobName
              , sriClaimName = claim
              , sriSrcUrl = src
              , sriMountPath = "/restore"
              , sriProject = project
              }
      if dryRun
        then do
          if live
            then pure ()
            else do
              TIO.putStrLn "--- Scratch PVC manifest ---"
              BS.putStr (renderScratchPvc ns scratchPvc size)
              TIO.putStrLn ""
          TIO.putStrLn "--- Restore Job manifest ---"
          BS.putStr (renderStorageRestoreJob job)
        else do
          if live
            then pure ()
            else applyManifest "nagare-volrestore-pvc.yaml" (renderScratchPvc ns scratchPvc size)
          applyManifest "nagare-volrestore-job.yaml" (renderStorageRestoreJob job)
          waitForJob ns jobName
          run_ $ cmd "kubectl" & addArgs ["logs", "job/" <> T.unpack jobName, "-n", T.unpack ns, "--tail", "60"]
          run_ $ cmd "kubectl" & addArgs ["delete", "job", T.unpack jobName, "-n", T.unpack ns, "--ignore-not-found"]
          if live
            then TIO.putStrLn ("Restored " <> app <> "/" <> volume <> " into the LIVE PVC '" <> livePvc <> "'.")
            else
              TIO.putStrLn
                ( "Restored "
                    <> app
                    <> "/"
                    <> volume
                    <> " into scratch PVC '"
                    <> scratchPvc
                    <> "' — compare the listing above, then promote manually."
                )

-- | The scratch PVC's requested size: the declared volume's own size, so the
-- scratch claim can always hold the live volume's contents.
scratchSize :: Text -> [Volume] -> Text
scratchSize volume vols =
  case [v | v <- vols, volumeNameText (v ^. #volName) == volume] of
    (v : _) -> quantityText (v ^. #size)
    [] -> "5Gi"

applyManifest :: String -> ByteString -> IO ()
applyManifest tmpl manifest = withSystemTempFile tmpl $ \fp h -> do
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
