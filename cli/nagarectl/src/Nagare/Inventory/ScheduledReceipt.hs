-- | Read and verify both exact provider versions of one scheduled receipt.
-- The result is candidate evidence for a later reviewed ingestion operation;
-- it does not write accepted history or authorize restore by itself.
module Nagare.Inventory.ScheduledReceipt
  ( ScheduledReceiptEvidence (..)
  , inspectScheduledReceipt
  , verifyAcceptedScheduledReceipt
  , classifyScheduledListingKeys
  ) where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Backup
  ( ScheduledBackupReceipt (..), ScheduledReceiptExpectation (..)
  , parseScheduledBackupReceipt )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ScheduledStore (ObjectReader (..), StoredObject (..))
import Nagare.Resource.Inventory (ScopeDeclaration, scopeOverrides)
import Nagare.Resource.Types (ContentDigest, mkContentDigest)
import System.Directory (getFileSize)
import System.IO.Temp (withSystemTempDirectory)

-- | Accepted runs use their immutable object addresses; a later schedule may
-- change the format suffix. New runs must still match the current schedule.
-- A second key for an accepted run is left unresolved rather than silently
-- borrowing the accepted pair's status.
classifyScheduledListingKeys
  :: Text -> Text -> Text -> Map.Map Text ScopeDeclaration -> [Text]
  -> ([(Text, Bool)], [Text])
classifyScheduledListingKeys bucketPrefix keyPrefix currentFormat accepted keys =
  ([(selected, isObject) | key <- keys,
    Just (selected, isObject) <- [classify key]],
   [key | key <- keys, classify key == Nothing])
  where
    pinned = [(key, (selected, isObject))
      | (selected, scope) <- Map.toList accepted
      , (field, isObject) <- [ ("scheduled.backup.object", True)
          , ("scheduled.backup.receipt", False) ]
      , Just address <- [Map.lookup field (scopeOverrides scope)]
      , Just key <- [T.stripPrefix bucketPrefix address]
      , keyPrefix `T.isPrefixOf` key]
    classify key = case [part | (address, part) <- pinned, address == key] of
      [part] -> Just part
      [] -> do
        suffix <- T.stripPrefix keyPrefix key
        let objectSuffix = "." <> currentFormat
            receiptSuffix = objectSuffix <> ".receipt.json"
            parsed = case T.stripSuffix receiptSuffix suffix of
              Just selected -> Just (selected, False)
              Nothing -> fmap (\selected -> (selected, True))
                (T.stripSuffix objectSuffix suffix)
        part@(selected, _) <- parsed
        if Map.member selected accepted then Nothing else Just part
      _ -> Nothing

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

-- | Accepted history already bound the signing and source proof at ingestion.
-- Recheck its exact current provider versions and bytes without requiring an
-- older receipt to match the latest CronJob metadata or source incarnation.
verifyAcceptedScheduledReceipt
  :: ObjectReader -> Text -> ScopeDeclaration -> IO (Either Text ())
verifyAcceptedScheduledReceipt reader expectedAddress scope =
  withSystemTempDirectory "nagare-accepted-scheduled-receipt" $ \scratch ->
    case pins of
      Left reason -> pure (Left reason)
      Right (objectAddress, objectVersion, objectLength, objectHash,
          receiptAddress, receiptVersion, receiptLength, receiptHash) -> do
        checkedObject <- verifyOne "backup object" objectAddress objectVersion
          objectLength (scratch <> "/object")
        case checkedObject of
          Left reason -> pure (Left reason)
          Right (_, actualHash) -> do
            if actualHash /= objectHash
              then pure (Left "accepted scheduled backup object checksum changed")
              else do
                checkedReceipt <- verifyOne "receipt" receiptAddress receiptVersion
                  receiptLength (scratch <> "/receipt")
                case checkedReceipt of
                  Left reason -> pure (Left reason)
                  Right (receiptFile, _) -> do
                    actualDigest <- contentDigest <$> BS.readFile receiptFile
                    pure $ if actualDigest == receiptHash
                      then Right ()
                      else Left "accepted scheduled receipt digest changed"
  where
    fields = scopeOverrides scope
    required key = maybe (Left ("accepted scheduled receipt lacks " <> key)) Right
      (Map.lookup key fields)
    positive key = do
      value <- required key
      case reads (T.unpack value) of
        [(number, "")] | number > (0 :: Integer) -> Right number
        _ -> Left ("accepted scheduled receipt has invalid " <> key)
    pins = do
      objectAddress <- required "scheduled.backup.object"
      objectVersion <- required "scheduled.backup.object.version"
      objectLength <- positive "scheduled.backup.object.length"
      objectHash <- required "scheduled.backup.object.sha256"
      _ <- mkContentDigest objectHash
      receiptAddress <- required "scheduled.backup.receipt"
      receiptVersion <- required "scheduled.backup.receipt.version"
      receiptLength <- positive "scheduled.backup.receipt.length"
      receiptDigest <- required "scheduled.backup.receipt.digest"
      receiptHash <- mkContentDigest receiptDigest
      if objectAddress == expectedAddress
          && receiptAddress == objectAddress <> ".receipt.json"
          && all (not . T.null) [objectVersion, receiptVersion]
        then pure (objectAddress, objectVersion, objectLength, objectHash,
          receiptAddress, receiptVersion, receiptLength, receiptHash)
        else Left "accepted scheduled receipt has invalid exact pins"
    verifyOne label address version expectedLength path = do
      current <- readObjectToFile reader address Nothing path
      case current of
        Left reason -> pure (Left reason)
        Right currentInfo -> do
          exact <- readObjectToFile reader address (Just version) (path <> "-exact")
          case exact of
            Left reason -> pure (Left reason)
            Right exactInfo -> do
              currentLength <- getFileSize path
              exactLength <- getFileSize (path <> "-exact")
              currentHash <- sha256File path
              exactHash <- sha256File (path <> "-exact")
              pure $ if currentInfo == exactInfo
                  && storedVersion currentInfo == version
                  && storedLength currentInfo == expectedLength
                  && currentLength == expectedLength
                  && exactLength == expectedLength
                  && currentHash == exactHash
                then Right (path, currentHash)
                else Left ("accepted scheduled " <> label <> " version or bytes changed")

sha256File :: FilePath -> IO Text
sha256File path = do
  bytes <- LBS.readFile path
  pure (T.pack (show (hashlazy bytes :: Digest SHA256)))
