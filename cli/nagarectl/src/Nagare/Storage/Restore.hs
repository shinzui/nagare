-- | Pure legacy preview and reviewed scratch volume restore renderers.
--
-- The reviewed Job rereads the accepted receipt and archive, checks both
-- hashes, and extracts only into its separate scratch PVC. Both renderers use
-- the shared 'Nagare.Cluster.GcsJob.dataMovementJobSpec' pod scaffolding.
module Nagare.Storage.Restore
  ( StorageRestoreJobInputs (..)
  , renderStorageRestoreJob
  , renderScratchPvc
  , ReviewedVolumeRestoreInputs (..)
  , renderReviewedVolumeRestoreJob
  , previewStorageRestore
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
import Nagare.Database.Restore (isObjectUrl)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types
  ( Deployment
  , Volume
  , namespaceText
  , quantityText
  , serviceNameText
  , volumeNameText
  )
import Nagare.Storage.Discover (pvcName)
import Nagare.Storage.Snapshot (snapshotObjectPath, snapshotTimestamp)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Inputs to 'renderStorageRestoreJob'.
data StorageRestoreJobInputs = StorageRestoreJobInputs
  { namespace :: !Text
  , jobName :: !Text
  , claimName :: !Text
  -- ^ the PVC the restore writes into (scratch or live)
  , sourceUrl :: !Text
  -- ^ the @tar.gz@ object to restore (@gs://@ in cloud, @s3://@ in local)
  , mountPath :: !Text
  -- ^ in-Job mount path, e.g. @/restore@
  , backend :: !StoreBackend
  -- ^ the object-store backend (EP-84): drives the restore container's image,
  -- env, and copy-from-store shell.
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
              , containers = [restoreContainer i]
              , volumes =
                  [ object
                      [ "name" .= ("restore" :: Text)
                      , "persistentVolumeClaim" .= object ["claimName" .= (i ^. #claimName)]
                      ]
                  ]
              }
      ]

restoreContainer :: StorageRestoreJobInputs -> Value
restoreContainer i =
  object
    [ "name" .= ("restore" :: Text)
    , "image" .= storeImage (i ^. #backend)
    , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
    , "args" .= toJSON [restoreShell (i ^. #backend) (i ^. #mountPath)]
    , "env" .= toJSON (plainEnv "SRC" (i ^. #sourceUrl) : storeEnv (i ^. #backend))
    , "volumeMounts"
        .= toJSON
          [object ["name" .= ("restore" :: Text), "mountPath" .= (i ^. #mountPath)]]
    ]

-- | Stream the archive from the store and untar it into the mount, then list the
-- restored tree (the same shell the deleted @scripts/restore-volume.sh@ ran).
-- The cloud (@gsutil@) bytes are unchanged; MinIO uses @aws s3@.
restoreShell :: StoreBackend -> Text -> Text
restoreShell backend mount =
  "set -e; "
    <> storeShellPreamble backend
    <> storeCpToStdout backend "\"$SRC\""
    <> " | tar -C "
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

-- | A reviewed restore checks the current receipt and archive bytes before
-- extracting into a separate scratch PVC. The inventory compiler supplies
-- accepted source and physical-identity annotations.
data ReviewedVolumeRestoreInputs = ReviewedVolumeRestoreInputs
  { restoreJob :: !StorageRestoreJobInputs
  , sourceReceiptUrl :: !Text
  , expectedReceiptSha256 :: !Text
  , expectedArchiveSha256 :: !Text
  , expiresAtEpoch :: !(Maybe Integer)
  }
  deriving stock (Generic, Eq, Show)

renderReviewedVolumeRestoreJob :: ReviewedVolumeRestoreInputs -> ByteString
renderReviewedVolumeRestoreJob input = Y.encode $ object
  [ "apiVersion" .= ("batch/v1" :: Text)
  , "kind" .= ("Job" :: Text)
  , "metadata" .= object
      [ "name" .= (job ^. #jobName), "namespace" .= (job ^. #namespace)
      , "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)] ]
  , "spec" .= dataMovementJobSpec DataMovementJob
      { templateLabels = Nothing
      , serviceAccountName = Nothing
      , backoffLimit = 0
      , hostAliases = storeHostAliases backend
      , affinity = Nothing
      , initContainers = []
      , containers = [object
          [ "name" .= ("restore" :: Text)
          , "image" .= storeImage backend
          , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
          , "args" .= toJSON [shell]
          , "env" .= toJSON
              ([ plainEnv "SRC" (job ^. #sourceUrl)
               , plainEnv "RECEIPT" (input ^. #sourceReceiptUrl)
               , plainEnv "RECEIPT_SHA256" (input ^. #expectedReceiptSha256)
               , plainEnv "ARCHIVE_SHA256" (input ^. #expectedArchiveSha256)
               , plainEnv "EXPIRY_EPOCH" (maybe "0" (T.pack . show)
                   (input ^. #expiresAtEpoch)) ]
                <> storeEnv backend)
          , "volumeMounts" .= toJSON
              [object ["name" .= ("restore" :: Text), "mountPath" .= ("/restore" :: Text)]
              ,object ["name" .= ("dump" :: Text), "mountPath" .= ("/dump" :: Text)]]
          ]]
      , volumes =
          [ object ["name" .= ("restore" :: Text), "persistentVolumeClaim" .=
              object ["claimName" .= (job ^. #claimName)]]
          , object ["name" .= ("dump" :: Text), "emptyDir" .= object []] ]
      }
  ]
  where
    job = input ^. #restoreJob
    backend = job ^. #backend
    verifyTools = case backend of
      GcsBackend {} -> "command -v sha256sum >/dev/null 2>&1; "
      MinioBackend {} ->
        "command -v sha256sum >/dev/null 2>&1 || dnf install -y -q coreutils >/dev/null 2>&1; "
          <> "command -v sha256sum >/dev/null 2>&1; "
    shell =
      "set -e; " <> storeShellPreamble backend <> verifyTools
      <> "test \"$EXPIRY_EPOCH\" = 0 || test \"$(date -u +%s)\" -lt \"$EXPIRY_EPOCH\"; "
      <> storeCpToStdout backend "\"$RECEIPT\"" <> " > /dump/receipt.json; "
      <> "test \"$(sha256sum /dump/receipt.json | cut -d' ' -f1)\" = \"$RECEIPT_SHA256\"; "
      <> storeCpToStdout backend "\"$SRC\"" <> " > /dump/archive.tar.gz; "
      <> "test \"$(sha256sum /dump/archive.tar.gz | cut -d' ' -f1)\" = \"$ARCHIVE_SHA256\"; "
      <> "tar -tzf /dump/archive.tar.gz > /dev/null; "
      <> "tar -C /restore -xzf /dump/archive.tar.gz; "
      <> "echo 'verified scratch restore complete'"

-- ---------------------------------------------------------------------------
-- Read-only preview

-- | Print the older restore manifests without submitting them. @BACKUP_ID@ is
-- a timestamp in the legacy prefix or a full object URL for this preview.
previewStorageRestore :: Deployment -> Text -> Text -> Bool -> StoreBackend -> IO ()
previewStorageRestore dep volume backupId live backend = do
  let app = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)
      vols = dep ^. #volumes
      declared = map (volumeNameText . (^. #name)) vols
  if volume `notElem` declared
    then die ("app " <> app <> " declares no volume named '" <> volume <> "'")
    else do
      now <- getCurrentTime
      let ts = snapshotTimestamp now
          livePvc = pvcName app volume
          scratchPvc = T.take 63 (T.toLower (livePvc <> "-restore-scratch"))
          claim = if live then livePvc else scratchPvc
          src = if isObjectUrl backupId then backupId else storeObjectUrl backend (snapshotObjectPath app volume backupId)
          size = scratchSize volume vols
          name = T.take 63 (T.toLower ("nagare-volrestore-" <> app <> "-" <> volume <> "-" <> ts))
          job =
            StorageRestoreJobInputs
              { namespace = ns
              , jobName = name
              , claimName = claim
              , sourceUrl = src
              , mountPath = "/restore"
              , backend = backend
              }
      unless live $ do
        TIO.putStrLn "--- Scratch PVC manifest ---"
        BS.putStr (renderScratchPvc ns scratchPvc size)
        TIO.putStrLn ""
      TIO.putStrLn "--- Restore Job manifest ---"
      BS.putStr (renderStorageRestoreJob job)

-- | The scratch PVC's requested size: the declared volume's own size, so the
-- scratch claim can always hold the live volume's contents.
scratchSize :: Text -> [Volume] -> Text
scratchSize volume vols =
  case [v | v <- vols, volumeNameText (v ^. #name) == volume] of
    (v : _) -> quantityText (v ^. #size)
    [] -> "5Gi"

die :: Text -> IO a
die msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
