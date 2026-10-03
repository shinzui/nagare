-- | Planning-time verification of a volume snapshot's stored objects. The
-- current receipt must be byte-identical to the accepted snapshot Pod's
-- receipt, and the current archive must hash to the receipt's checksum. Each
-- object is then re-read at its exact version and must not change. A newer or
-- altered object therefore refuses before any review is saved.
module Nagare.Inventory.VolumeRestoreSource
  ( verifyVolumeBackupObjects
  )
where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ScheduledStore (ObjectReader (..), StoredObject (..))
import Nagare.Inventory.VolumeRestore (VolumeObjectPins (..))
import System.Directory (getFileSize)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

verifyVolumeBackupObjects ::
  ObjectReader -> T.Text -> T.Text -> ByteString -> IO (Either T.Text VolumeObjectPins)
verifyVolumeBackupObjects reader objectUrl receiptUrl acceptedReceipt =
  withSystemTempDirectory "nagare-volume-restore-source" $ \scratch -> do
    receipt <- exactObject "receipt" receiptUrl (scratch </> "receipt")
    case receipt of
      Left reason -> pure (Left reason)
      Right (receiptInfo, receiptPath) -> do
        stored <- BS.readFile receiptPath
        case checksumOf stored of
          _ | stored /= acceptedReceipt -> pure (Left "stored volume receipt differs from the accepted snapshot receipt")
          Left reason -> pure (Left reason)
          Right expected -> do
            archive <- exactObject "archive" objectUrl (scratch </> "archive")
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
    -- Read the current object, then the same version explicitly. Both reads
    -- must agree on version, length and bytes.
    exactObject label address path = do
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
                    if exactInfo == info
                      && currentLength == storedLength info
                      && exactLength == storedLength info
                      && currentHash == exactHash
                      then Right (info, path)
                      else Left ("stored volume " <> label <> " version or bytes changed while reading")

sha256File :: FilePath -> IO T.Text
sha256File path = do
  bytes <- LBS.readFile path
  pure (T.pack (show (hashlazy bytes :: Digest SHA256)))
