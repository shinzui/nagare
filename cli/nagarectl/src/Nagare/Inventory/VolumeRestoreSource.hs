-- | Planning-time verification of a volume snapshot's stored objects. The
-- current receipt must be byte-identical to the accepted snapshot Pod's
-- receipt, and the current archive must hash to the receipt's checksum. Each
-- object is then re-read at its exact version and must not change. A newer or
-- altered object therefore refuses before any review is saved.
module Nagare.Inventory.VolumeRestoreSource
  ( verifyVolumeBackupObjects
  , verifyRecordedVolumeSnapshot
  )
where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Lineage (RecoveryPointKind (VolumeSnapshotRecoveryPoint))
import Nagare.Inventory.ScheduledStore (ObjectReader (..), StoredObject (..))
import Nagare.Inventory.VolumeRebuildRestore (VolumeRecoverySource (..))
import Nagare.Inventory.VolumeRestore (VolumeObjectPins (..))
import Nagare.Resource.Inventory (ScopeDeclaration, scopeOverrides)
import Nagare.Resource.Types (mkPhysicalIdentity)
import System.Directory (getFileSize)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

verifyVolumeBackupObjects ::
  ObjectReader -> T.Text -> T.Text -> ByteString -> IO (Either T.Text VolumeObjectPins)
verifyVolumeBackupObjects reader objectUrl receiptUrl acceptedReceipt =
  withSystemTempDirectory "nagare-volume-restore-source" $ \scratch -> do
    receipt <- exactStoredObject reader "receipt" receiptUrl (scratch </> "receipt")
    case receipt of
      Left reason -> pure (Left reason)
      Right (receiptInfo, receiptPath) -> do
        stored <- BS.readFile receiptPath
        case checksumOf stored of
          _ | stored /= acceptedReceipt -> pure (Left "stored volume receipt differs from the accepted snapshot receipt")
          Left reason -> pure (Left reason)
          Right expected -> do
            archive <- exactStoredObject reader "archive" objectUrl (scratch </> "archive")
            case archive of
              Left reason -> pure (Left reason)
              Right (archiveInfo, archivePath) -> do
                actual <- sha256File archivePath
                pure $
                  if actual /= expected
                    then Left "stored volume archive differs from the accepted receipt checksum"
                    else
                      Right
                        VolumeObjectPins
                          { pinnedObjectVersion = storedVersion archiveInfo
                          , pinnedObjectLength = storedLength archiveInfo
                          , pinnedObjectSha256 = actual
                          , pinnedReceiptVersion = storedVersion receiptInfo
                          , pinnedReceiptLength = storedLength receiptInfo
                          , pinnedReceiptDigest = contentDigest stored
                          }
  where
    checksumOf bytes = case eitherDecodeStrict bytes of
      Right (Object root) | Just (String value) <- KM.lookup "sha256" root -> Right value
      _ -> Left "stored volume receipt has no checksum"

-- | EP-183 M4: verify an accepted manual volume snapshot from the object
-- store alone, for a rebuild after the cluster (and its completed snapshot
-- Pod) is gone. The receipt must name exactly what the inventory recorded for
-- the snapshot (its ID, archive, source scope and source claim incarnation),
-- the archive must hash to the receipt's checksum, and both are read at one
-- exact version each.
verifyRecordedVolumeSnapshot :: ObjectReader -> ScopeDeclaration -> IO (Either T.Text VolumeRecoverySource)
verifyRecordedVolumeSnapshot reader scope = case recorded of
  Left reason -> pure (Left reason)
  Right (backupId, objectUrl, receiptUrl, sourceScope, sourceUid, expiry) ->
    withSystemTempDirectory "nagare-volume-rebuild-source" $ \scratch -> do
      receipt <- exactStoredObject reader "receipt" receiptUrl (scratch </> "receipt")
      case receipt of
        Left reason -> pure (Left reason)
        Right (receiptInfo, receiptPath) -> do
          stored <- BS.readFile receiptPath
          case recordedReceipt stored backupId objectUrl sourceScope sourceUid of
            Left reason -> pure (Left reason)
            Right expected -> do
              archive <- exactStoredObject reader "archive" objectUrl (scratch </> "archive")
              case archive of
                Left reason -> pure (Left reason)
                Right (archiveInfo, archivePath) -> do
                  actual <- sha256File archivePath
                  pure $ do
                    unless (actual == expected) (Left "stored volume archive differs from its receipt checksum")
                    physical <- mkPhysicalIdentity sourceUid
                    Right
                      VolumeRecoverySource
                        { kind = VolumeSnapshotRecoveryPoint
                        , objectUrl = objectUrl
                        , objectVersion = storedVersion archiveInfo
                        , archiveSha256 = actual
                        , receiptUrl = receiptUrl
                        , receiptVersion = storedVersion receiptInfo
                        , receiptDigest = contentDigest stored
                        , sourcePvcUid = physical
                        , expiryEpoch = expiry
                        }
  where
    overrides = scopeOverrides scope
    field key = maybe (Left ("the accepted volume snapshot lacks " <> key)) Right (Map.lookup key overrides)
    recorded = do
      backupId <- field "volume-backup.id"
      objectUrl <- field "volume-backup.object"
      receiptUrl <- field "volume-backup.receipt"
      sourceScope <- field "volume-backup.source.scope"
      sourceUid <- field "volume-backup.source.pvc.uid"
      expiryText <- field "volume-backup.expiry"
      unless (receiptUrl == objectUrl <> ".receipt.json") (Left "the accepted volume snapshot's receipt is not beside its archive")
      expiry <-
        if expiryText == "retain"
          then Right Nothing
          else case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack expiryText) :: Maybe UTCTime of
            Just selected -> Right (Just (floor (utcTimeToPOSIXSeconds selected)))
            Nothing -> Left "the accepted volume snapshot's expiry is invalid"
      pure (backupId, objectUrl, receiptUrl, sourceScope, sourceUid, expiry)
    recordedReceipt bytes backupId objectUrl sourceScope sourceUid = case eitherDecodeStrict bytes of
      Right (Object root)
        | KM.lookup "version" root == Just (Number 1)
        , Just (String checksum) <- KM.lookup "sha256" root
        , Just (Object backup) <- KM.lookup "backup" root ->
            if KM.lookup "id" backup == Just (String backupId)
              && KM.lookup "object" backup == Just (String objectUrl)
              && KM.lookup "sourceScope" backup == Just (String sourceScope)
              && KM.lookup "sourcePvcUid" backup == Just (String sourceUid)
              then Right checksum
              else Left "stored volume receipt names another snapshot, archive, scope or claim incarnation than the inventory recorded"
      _ -> Left "stored volume receipt is not a version-1 snapshot receipt"

-- | Read the current object, then the same version explicitly; both reads
-- must agree on version, length and bytes.
exactStoredObject :: ObjectReader -> T.Text -> T.Text -> FilePath -> IO (Either T.Text (StoredObject, FilePath))
exactStoredObject reader label address path = do
  current <- readObjectToFile reader address Nothing path
  case current of
    Left reason -> pure (Left reason)
    Right info
      | T.null (storedVersion info) -> pure (Left ("stored volume " <> label <> " has no object version"))
      | otherwise -> do
          exact <- readObjectToFile reader address (Just (storedVersion info)) (path <> "-exact")
          case exact of
            Left reason -> pure (Left reason)
            Right exactInfo -> do
              currentLength <- getFileSize path
              exactLength <- getFileSize (path <> "-exact")
              currentHash <- sha256File path
              exactHash <- sha256File (path <> "-exact")
              pure $
                if exactInfo == info && currentLength == storedLength info && exactLength == storedLength info && currentHash == exactHash
                  then Right (info, path)
                  else Left ("stored volume " <> label <> " version or bytes changed while reading")

sha256File :: FilePath -> IO T.Text
sha256File path = do
  bytes <- LBS.readFile path
  pure (T.pack (show (hashlazy bytes :: Digest SHA256)))
