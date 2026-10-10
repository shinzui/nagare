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
  , renderRebuildVolumeRestoreJob
  , safeVolumeExtractPython
  , volumeManifestPython
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
  , MinioRef (..)
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
  , pinnedVersions :: !(Maybe (Text, Text))
  -- ^ Exact archive and receipt object versions verified at planning. When
  -- present the Job downloads only those versions; without them it keeps the
  -- original current-object script, so earlier saved reviews stay valid.
  }
  deriving stock (Generic, Eq, Show)

renderReviewedVolumeRestoreJob :: ReviewedVolumeRestoreInputs -> ByteString
renderReviewedVolumeRestoreJob = renderVolumeRestoreWith Nothing

-- | EP-183 M4: restore a verified archive into a rebuilt volume, never over
-- data. The Job refuses a claim holding anything but @lost+found@, extracts
-- into a staging directory named for the restore on the same claim, checks
-- again that nothing else arrived, and then renames each entry into place, so
-- a failed extraction leaves the claim's root as it was.
renderRebuildVolumeRestoreJob :: Text -> ReviewedVolumeRestoreInputs -> ByteString
renderRebuildVolumeRestoreJob stage = renderVolumeRestoreWith (Just stage)

renderVolumeRestoreWith :: Maybe Text -> ReviewedVolumeRestoreInputs -> ByteString
renderVolumeRestoreWith rebuild input =
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
                      [ "name" .= ("restore" :: Text)
                      , "image" .= storeImage backend
                      , "command" .= toJSON ["/bin/sh" :: Text, "-c"]
                      , "args" .= toJSON [shell]
                      , "env"
                          .= toJSON
                            ( [ plainEnv "SRC" (job ^. #sourceUrl)
                              , plainEnv "RECEIPT" (input ^. #sourceReceiptUrl)
                              , plainEnv "RECEIPT_SHA256" (input ^. #expectedReceiptSha256)
                              , plainEnv "ARCHIVE_SHA256" (input ^. #expectedArchiveSha256)
                              , plainEnv
                                  "EXPIRY_EPOCH"
                                  ( maybe
                                      "0"
                                      (T.pack . show)
                                      (input ^. #expiresAtEpoch)
                                  )
                              ]
                                <> pinnedEnv
                                <> storeEnv backend
                            )
                      , "volumeMounts"
                          .= toJSON
                            [ object ["name" .= ("restore" :: Text), "mountPath" .= ("/restore" :: Text)]
                            , object ["name" .= ("dump" :: Text), "mountPath" .= ("/dump" :: Text)]
                            ]
                      ]
                  ]
              , volumes =
                  [ object
                      [ "name" .= ("restore" :: Text)
                      , "persistentVolumeClaim"
                          .= object ["claimName" .= (job ^. #claimName)]
                      ]
                  , object ["name" .= ("dump" :: Text), "emptyDir" .= object []]
                  ]
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
    pinnedEnv = case (backend, input ^. #pinnedVersions) of
      (_, Nothing) -> []
      (GcsBackend {}, Just (objectVersion, receiptVersion)) ->
        [plainEnv "OBJECT_VERSION" objectVersion, plainEnv "RECEIPT_VERSION" receiptVersion]
      (MinioBackend ref, Just (objectVersion, receiptVersion)) ->
        let prefix = "s3://" <> ref ^. #bucket <> "/"
            key url = fromMaybe "" (T.stripPrefix prefix url)
         in [ plainEnv "STORE_ENDPOINT" (ref ^. #endpoint)
            , plainEnv "STORE_BUCKET" (ref ^. #bucket)
            , plainEnv "OBJECT_KEY" (key (job ^. #sourceUrl))
            , plainEnv "RECEIPT_KEY" (key (input ^. #sourceReceiptUrl))
            , plainEnv "OBJECT_VERSION" objectVersion
            , plainEnv "RECEIPT_VERSION" receiptVersion
            ]
    -- Download exactly the reviewed versions; a newer object at the same key
    -- is never read. Hashes are still compared before the first write.
    download = case (backend, input ^. #pinnedVersions) of
      (_, Nothing) ->
        storeCpToStdout backend "\"$RECEIPT\""
          <> " > /dump/receipt.json; "
          <> "test \"$(sha256sum /dump/receipt.json | cut -d' ' -f1)\" = \"$RECEIPT_SHA256\"; "
          <> storeCpToStdout backend "\"$SRC\""
          <> " > /dump/archive.tar.gz; "
      (MinioBackend {}, Just _) ->
        "aws s3api get-object --bucket \"$STORE_BUCKET\" --key \"$RECEIPT_KEY\" --version-id \"$RECEIPT_VERSION\" --endpoint-url \"$STORE_ENDPOINT\" /dump/receipt.json > /dump/receipt-response.json; "
          <> "aws s3api get-object --bucket \"$STORE_BUCKET\" --key \"$OBJECT_KEY\" --version-id \"$OBJECT_VERSION\" --endpoint-url \"$STORE_ENDPOINT\" /dump/archive.tar.gz > /dump/object-response.json; "
          <> "python3 -c 'import json,os; assert json.load(open(\"/dump/receipt-response.json\")).get(\"VersionId\")==os.environ[\"RECEIPT_VERSION\"]; assert json.load(open(\"/dump/object-response.json\")).get(\"VersionId\")==os.environ[\"OBJECT_VERSION\"]'; "
          <> "test \"$(sha256sum /dump/receipt.json | cut -d' ' -f1)\" = \"$RECEIPT_SHA256\"; "
      (GcsBackend {}, Just _) ->
        "gcloud storage cp --do-not-decompress \"$RECEIPT#$RECEIPT_VERSION\" /dump/receipt.json; "
          <> "test \"$(sha256sum /dump/receipt.json | cut -d' ' -f1)\" = \"$RECEIPT_SHA256\"; "
          <> "gcloud storage cp --do-not-decompress \"$SRC#$OBJECT_VERSION\" /dump/archive.tar.gz; "
    shell =
      "set -e; "
        <> storeShellPreamble backend
        <> verifyTools
        <> maybe "" (\_ -> "python3 - /restore <<'NAGARE_VOLUME_EMPTY'\n" <> rebuildEmptyPython <> "NAGARE_VOLUME_EMPTY\n") rebuild
        <> "test \"$EXPIRY_EPOCH\" = 0 || test \"$(date -u +%s)\" -lt \"$EXPIRY_EPOCH\"; "
        <> download
        <> "test \"$(sha256sum /dump/archive.tar.gz | cut -d' ' -f1)\" = \"$ARCHIVE_SHA256\"; "
        <> case rebuild of
          Nothing ->
            "python3 - /dump/archive.tar.gz /restore <<'NAGARE_VOLUME_EXTRACT'\n"
              <> safeVolumeExtractPython
              <> "NAGARE_VOLUME_EXTRACT\n"
          Just stage ->
            "mkdir /restore/.nagare-rebuild-"
              <> stage
              <> "; python3 - /dump/archive.tar.gz /restore/.nagare-rebuild-"
              <> stage
              <> " <<'NAGARE_VOLUME_EXTRACT'\n"
              <> safeVolumeExtractPython
              <> "NAGARE_VOLUME_EXTRACT\n"
              <> "python3 - /restore .nagare-rebuild-"
              <> stage
              <> " <<'NAGARE_VOLUME_PLACE'\n"
              <> rebuildPlacePython
              <> "NAGARE_VOLUME_PLACE\n"
        <> manifest
    -- A pinned restore also prints the verified tree to its log, so a reader
    -- can check restored content without mounting the scratch claim.
    manifest = case input ^. #pinnedVersions of
      Nothing | isNothing rebuild -> ""
      Nothing -> "exit 1\n"
      Just _ ->
        "python3 - /restore <<'NAGARE_VOLUME_MANIFEST'\n"
          <> volumeManifestPython
          <> "NAGARE_VOLUME_MANIFEST\n"

-- | Refuse a rebuilt claim that holds anything but @lost+found@ and the
-- staging directories of earlier failed attempts, which a later restore under
-- a new ID ignores.
rebuildEmptyPython :: Text
rebuildEmptyPython =
  T.unlines
    [ "import os, sys"
    , "entries = sorted(name for name in os.listdir(sys.argv[1]) if name != 'lost+found' and not name.startswith('.nagare-rebuild-'))"
    , "if entries:"
    , "    raise SystemExit('the rebuilt volume already holds %d entries (%s); refusing to restore over data' % (len(entries), ', '.join(entries[:5])))"
    ]

-- | Move each staged entry into the claim's root after checking again that
-- the root holds nothing but @lost+found@ and staging directories.
rebuildPlacePython :: Text
rebuildPlacePython =
  T.unlines
    [ "import os, sys"
    , "root, stage = sys.argv[1], sys.argv[2]"
    , "staged = os.path.join(root, stage)"
    , "others = sorted(name for name in os.listdir(root) if name != 'lost+found' and not name.startswith('.nagare-rebuild-'))"
    , "if others:"
    , "    raise SystemExit('data reached the rebuilt volume during the restore (%s); %s is kept' % (', '.join(others[:5]), stage))"
    , "for name in sorted(os.listdir(staged)):"
    , "    os.rename(os.path.join(staged, name), os.path.join(root, name))"
    , "os.rmdir(staged)"
    , "fd = os.open(root, os.O_RDONLY)"
    , "os.fsync(fd)"
    , "os.close(fd)"
    ]

-- | Print one line per restored regular file, at most 1,000, in byte order:
-- @NAGARE_VOLUME_RESTORE_FILE <sha256> <bytes> <path>@. Then print one summary
-- line: @NAGARE_VOLUME_RESTORE_MANIFEST files=<n> bytes=<total> tree=<sha256>@.
-- The tree digest covers every file line, including any beyond the printed
-- bound.
volumeManifestPython :: Text
volumeManifestPython =
  T.unlines
    [ "import hashlib, os, sys"
    , "root = os.path.realpath(sys.argv[1])"
    , "entries = []"
    , "for directory, _, names in os.walk(root):"
    , "    for name in names:"
    , "        path = os.path.join(directory, name)"
    , "        if os.path.islink(path) or not os.path.isfile(path):"
    , "            continue"
    , "        digest = hashlib.sha256()"
    , "        with open(path, 'rb') as source:"
    , "            for chunk in iter(lambda: source.read(1024 * 1024), b''):"
    , "                digest.update(chunk)"
    , "        entries.append((os.path.relpath(path, root), digest.hexdigest(), os.path.getsize(path)))"
    , "entries.sort(key=lambda entry: entry[0].encode())"
    , "tree = hashlib.sha256()"
    , "for index, (relative, sha, size) in enumerate(entries):"
    , "    line = 'NAGARE_VOLUME_RESTORE_FILE %s %d %s' % (sha, size, relative)"
    , "    tree.update((line + '\\n').encode())"
    , "    if index < 1000:"
    , "        print(line)"
    , "print('NAGARE_VOLUME_RESTORE_MANIFEST files=%d bytes=%d tree=%s' % (len(entries), sum(entry[2] for entry in entries), tree.hexdigest()))"
    ]

-- | Reject links, special files, duplicate paths, escapes, and existing
-- symlink parents before the first write. Files are copied and fsynced through
-- no-follow descriptors, then every resulting byte is compared to the
-- authenticated archive. A failed extraction leaves the reviewed Job failed;
-- the future live path must keep its data fence until explicit recovery.
safeVolumeExtractPython :: Text
safeVolumeExtractPython =
  T.unlines
    [ "import hashlib, os, posixpath, shutil, stat, sys, tarfile"
    , "archive_path, root = sys.argv[1:]"
    , "root = os.path.realpath(root)"
    , "def reject(reason):"
    , "    raise SystemExit('unsafe volume archive: ' + reason)"
    , "if not os.path.isdir(root):"
    , "    reject('target volume is not a directory')"
    , "def sha256_file(path):"
    , "    digest = hashlib.sha256()"
    , "    with open(path, 'rb') as source:"
    , "        for chunk in iter(lambda: source.read(1024 * 1024), b''):"
    , "            digest.update(chunk)"
    , "    return digest.digest()"
    , "with tarfile.open(archive_path, 'r:gz') as archive:"
    , "    members = []"
    , "    seen = set()"
    , "    file_paths = set()"
    , "    for member in archive.getmembers():"
    , "        name = member.name"
    , "        if not name or name.startswith('/') or '\\x00' in name or '..' in name.split('/'):"
    , "            reject('absolute, empty, or parent path')"
    , "        normalized = posixpath.normpath(name)"
    , "        if normalized == '.':"
    , "            if not member.isdir():"
    , "                reject('root is not a directory')"
    , "            continue"
    , "        if normalized in seen or not (member.isdir() or member.isfile()):"
    , "            reject('duplicate path or unsupported entry type')"
    , "        seen.add(normalized)"
    , "        if member.isfile():"
    , "            file_paths.add(normalized)"
    , "        target = os.path.join(root, *normalized.split('/'))"
    , "        if os.path.commonpath([root, os.path.realpath(target)]) != root:"
    , "            reject('path leaves target volume')"
    , "        cursor = root"
    , "        parts = normalized.split('/')"
    , "        for index, part in enumerate(parts):"
    , "            cursor = os.path.join(cursor, part)"
    , "            if os.path.islink(cursor):"
    , "                reject('existing symlink in target path')"
    , "            if index < len(parts) - 1 and os.path.exists(cursor) and not os.path.isdir(cursor):"
    , "                reject('path parent is not a directory')"
    , "        if os.path.lexists(target):"
    , "            existing = os.lstat(target)"
    , "            if member.isdir() and not stat.S_ISDIR(existing.st_mode):"
    , "                reject('directory collides with non-directory')"
    , "            if member.isfile() and (not stat.S_ISREG(existing.st_mode) or existing.st_nlink != 1):"
    , "                reject('file collides with special or linked target')"
    , "        members.append((member, target))"
    , "    for name in seen:"
    , "        parent = posixpath.dirname(name)"
    , "        while parent not in ('', '.'):"
    , "            if parent in file_paths:"
    , "                reject('file is also an archive path parent')"
    , "            parent = posixpath.dirname(parent)"
    , "    for member, target in members:"
    , "        if member.isdir():"
    , "            os.makedirs(target, exist_ok=True)"
    , "            if not os.path.isdir(target):"
    , "                reject('directory collides with file')"
    , "            continue"
    , "        os.makedirs(os.path.dirname(target), exist_ok=True)"
    , "        source = archive.extractfile(member)"
    , "        if source is None:"
    , "            reject('regular file has no content')"
    , "        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW"
    , "        with source, os.fdopen(os.open(target, flags, member.mode & 0o777), 'wb') as dest:"
    , "            shutil.copyfileobj(source, dest, 1024 * 1024)"
    , "            dest.flush()"
    , "            os.fsync(dest.fileno())"
    , "        os.chmod(target, member.mode & 0o777)"
    , "        source = archive.extractfile(member)"
    , "        if source is None:"
    , "            reject('regular file disappeared during verification')"
    , "        digest = hashlib.sha256()"
    , "        with source:"
    , "            for chunk in iter(lambda: source.read(1024 * 1024), b''):"
    , "                digest.update(chunk)"
    , "        if digest.digest() != sha256_file(target):"
    , "            reject('extracted content differs from archive')"
    , "print('verified volume archive and extracted files')"
    ]

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
