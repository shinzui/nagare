-- | Read and verify both exact provider versions of one scheduled receipt.
-- The result is candidate evidence for a later reviewed ingestion operation;
-- it does not write accepted history or authorize restore by itself.
module Nagare.Inventory.ScheduledReceipt
  ( ScheduledReceiptEvidence (..)
  , inspectScheduledReceipt
  ) where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Backup
  ( ScheduledBackupReceipt (..), ScheduledReceiptExpectation (..)
  , parseScheduledBackupReceipt )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ScheduledStore (ObjectReader (..), StoredObject (..))
import Nagare.Resource.Types (ContentDigest)
import System.Directory (getFileSize)
import System.IO.Temp (withSystemTempDirectory)

data ScheduledReceiptEvidence = ScheduledReceiptEvidence
  { scheduledReceipt :: !ScheduledBackupReceipt
  , scheduledObjectVersion :: !Text
  , scheduledReceiptVersion :: !Text
  , scheduledObjectLength :: !Integer
  , scheduledReceiptLength :: !Integer
  , scheduledReceiptDigest :: !ContentDigest
  }
  deriving stock (Eq, Show)

inspectScheduledReceipt
  :: ObjectReader -> ScheduledReceiptExpectation -> Text -> Text
  -> IO (Either Text ScheduledReceiptEvidence)
inspectScheduledReceipt reader expectation backupId signingKey =
  withSystemTempDirectory "nagare-scheduled-receipt" $ \scratch -> do
    let objectAddress = scheduledObjectPrefix expectation <> backupId
          <> "." <> scheduledFormat expectation
        receiptAddress = objectAddress <> ".receipt.json"
        receiptFile = scratch <> "/receipt"
        exactReceiptFile = scratch <> "/receipt-exact"
        objectFile = scratch <> "/object"
        exactObjectFile = scratch <> "/object-exact"
        readOne address version path = readObjectToFile reader address version path
    currentReceipt <- readOne receiptAddress Nothing receiptFile
    case currentReceipt of
      Left reason -> pure (Left reason)
      Right receiptInfo -> do
        exactReceipt <- readOne receiptAddress
          (Just (storedVersion receiptInfo)) exactReceiptFile
        case exactReceipt of
          Left reason -> pure (Left reason)
          Right exactReceiptInfo -> do
            receiptBytes <- BS.readFile receiptFile
            exactBytes <- BS.readFile exactReceiptFile
            receiptLength <- getFileSize receiptFile
            if receiptInfo /= exactReceiptInfo || receiptBytes /= exactBytes
                || receiptLength /= storedLength receiptInfo
              then pure (Left "scheduled receipt version or bytes changed during inspection")
              else case parseScheduledBackupReceipt expectation receiptAddress
                  signingKey receiptBytes of
                Left reason -> pure (Left reason)
                Right checked | scheduledObjectAddress checked /= objectAddress ->
                  pure (Left "scheduled receipt addresses another backup object")
                Right checked -> do
                  currentObject <- readOne objectAddress Nothing objectFile
                  case currentObject of
                    Left reason -> pure (Left reason)
                    Right objectInfo -> do
                      exactObject <- readOne objectAddress
                        (Just (storedVersion objectInfo)) exactObjectFile
                      case exactObject of
                        Left reason -> pure (Left reason)
                        Right exactObjectInfo -> do
                          objectLength <- getFileSize objectFile
                          exactLength <- getFileSize exactObjectFile
                          objectHash <- sha256File objectFile
                          exactHash <- sha256File exactObjectFile
                          pure $ if objectInfo /= exactObjectInfo
                              || objectLength /= storedLength objectInfo
                              || exactLength /= objectLength
                              || objectHash /= exactHash
                              || objectHash /= scheduledSha256 checked
                            then Left "scheduled backup version, length, or checksum changed"
                            else Right ScheduledReceiptEvidence
                              { scheduledReceipt = checked
                              , scheduledObjectVersion = storedVersion objectInfo
                              , scheduledReceiptVersion = storedVersion receiptInfo
                              , scheduledObjectLength = objectLength
                              , scheduledReceiptLength = receiptLength
                              , scheduledReceiptDigest = contentDigest receiptBytes
                              }

sha256File :: FilePath -> IO Text
sha256File path = do
  bytes <- LBS.readFile path
  pure (T.pack (show (hashlazy bytes :: Digest SHA256)))
