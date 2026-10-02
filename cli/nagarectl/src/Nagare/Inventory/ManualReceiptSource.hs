-- | Read one accepted manual backup's exact stored objects before recording
-- their provider versions in a reviewed receipt scope. Reads are private;
-- only the version, length and digest pins enter accepted history.
module Nagare.Inventory.ManualReceiptSource
  ( inspectManualReceipt
  , parseGcsManualMetadata
  , withGcsManualObjectReader
  )
where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import Data.Aeson (Result (Success), Value (..), eitherDecodeStrict, fromJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Prelude hiding (Context)
import Nagare.Inventory.Backup (parseManualBackupReceipt)
import Nagare.Inventory.ManualReceipt (ManualReceiptEvidence (..))
import Nagare.Inventory.ScheduledStore (StoredObject (..))
import Nagare.Resource.Inventory (ScopeDeclaration, scopeOverrides)
import Nagare.Resource.Types (PhysicalIdentity)
import System.Exit (ExitCode (..))
import System.IO (IOMode (ReadMode), hFileSize, withBinaryFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)

-- | The reader must return the version and length of the bytes it wrote, not
-- merely metadata for the current key. The GCS reader below first selects one
-- generation and downloads that generation; MinIO supplies its GET version.
inspectManualReceipt ::
  (Text -> FilePath -> IO (Either Text StoredObject)) ->
  ScopeDeclaration ->
  PhysicalIdentity ->
  IO (Either Text ManualReceiptEvidence)
inspectManualReceipt readOne accepted jobUid =
  withSystemTempDirectory "nagare-manual-receipt" $ \scratch -> do
    let values = scopeOverrides accepted
        required key =
          maybe
            (Left ("accepted manual backup lacks " <> key))
            Right
            (Map.lookup key values)
    case (,) <$> required "backup.object" <*> required "backup.receipt" of
      Left reason -> pure (Left reason)
      Right (objectAddress, receiptAddress) ->
        readVerified readOne accepted jobUid scratch objectAddress receiptAddress

readVerified ::
  (Text -> FilePath -> IO (Either Text StoredObject)) ->
  ScopeDeclaration ->
  PhysicalIdentity ->
  FilePath ->
  Text ->
  Text ->
  IO (Either Text ManualReceiptEvidence)
readVerified readOne accepted jobUid scratch objectAddress receiptAddress = do
  let receiptPath = scratch <> "/receipt.json"
      objectPath = scratch <> "/archive"
  receiptResult <- readOne receiptAddress receiptPath
  case receiptResult of
    Left reason -> pure (Left reason)
    Right receiptObject -> do
      rawReceipt <- readReceiptFile receiptPath
      receiptSize <- fileLength receiptPath
      case (,)
        <$> first (const "manual backup receipt is unreadable") rawReceipt
        <*> receiptSize of
        Left reason -> pure (Left reason)
        Right (bytes, actualReceiptSize) -> do
          let checksum = parseManualBackupReceipt accepted receiptAddress bytes
          case checksum of
            Left reason -> pure (Left reason)
            Right expectedSha
              | actualReceiptSize == storedLength receiptObject
                  && actualReceiptSize > 0 -> do
                  archiveResult <- readOne objectAddress objectPath
                  case archiveResult of
                    Left reason -> pure (Left reason)
                    Right archiveObject -> do
                      archiveSize <- fileLength objectPath
                      archiveDigest <- hashFile objectPath
                      pure $ do
                        actualArchiveSize <- archiveSize
                        sha <- archiveDigest
                        unless
                          ( actualArchiveSize == storedLength archiveObject
                              && actualArchiveSize > 0
                              && sha == expectedSha
                          )
                          (Left "manual backup archive differs from its accepted receipt")
                        pure
                          ManualReceiptEvidence
                            { manualJobUid = jobUid
                            , manualObjectVersion = storedVersion archiveObject
                            , manualObjectLength = actualArchiveSize
                            , manualObjectSha256 = sha
                            , manualReceiptVersion = storedVersion receiptObject
                            , manualReceiptLength = actualReceiptSize
                            , manualReceiptBytes = bytes
                            }
            Right _ -> pure (Left "manual backup receipt length differs from downloaded bytes")

-- | `gcloud storage objects describe` selects a current generation; copying
-- its versioned URL then either retrieves those bytes or fails. Both URL and
-- returned bucket/name must match the accepted backend and exact address.
withGcsManualObjectReader ::
  StoreBackend ->
  ((Text -> FilePath -> IO (Either Text StoredObject)) -> IO a) ->
  IO (Either Text a)
withGcsManualObjectReader (GcsBackend project bucket) action =
  Right <$> action (readGcs project bucket)
withGcsManualObjectReader _ _ = pure (Left "manual GCS reader needs a cloud backend")

readGcs :: Text -> Text -> Text -> FilePath -> IO (Either Text StoredObject)
readGcs project bucket address output = do
  let prefix = "gs://" <> bucket <> "/"
  case T.stripPrefix prefix address of
    Nothing -> pure (Left "manual backup address is outside the accepted GCS bucket")
    Just name
      | T.null name || T.any (== '#') name ->
          pure (Left "manual backup has an invalid GCS object name")
    Just name -> do
      described <-
        try
          ( readProcessWithExitCode
              "gcloud"
              [ "--project"
              , T.unpack project
              , "storage"
              , "objects"
              , "describe"
              , T.unpack address
              , "--format=json"
              ]
              ""
          ) ::
          IO (Either IOException (ExitCode, String, String))
      case described of
        Right (ExitSuccess, body, _) -> case parseGcsManualMetadata bucket name (BC.pack body) of
          Left reason -> pure (Left reason)
          Right selected@(StoredObject generation expectedLength) -> do
            copied <-
              try
                ( readProcessWithExitCode
                    "gcloud"
                    [ "--project"
                    , T.unpack project
                    , "storage"
                    , "cp"
                    , "--do-not-decompress"
                    , T.unpack (address <> "#" <> generation)
                    , output
                    ]
                    ""
                ) ::
                IO (Either IOException (ExitCode, String, String))
            case copied of
              Right (ExitSuccess, _, _) -> do
                lengthResult <- fileLength output
                pure $ do
                  actualLength <- lengthResult
                  unless
                    (actualLength == expectedLength)
                    (Left "manual GCS generation length differs from downloaded bytes")
                  pure selected
              _ -> pure (Left "manual GCS generation could not be downloaded")
        _ -> pure (Left "manual GCS object metadata is unavailable")

parseGcsManualMetadata :: Text -> Text -> BS.ByteString -> Either Text StoredObject
parseGcsManualMetadata bucket name bytes = do
  value <-
    first
      (const "manual GCS object metadata is malformed")
      (eitherDecodeStrict bytes)
  case value of
    Object fields -> do
      let field key = case KM.lookup key fields of
            Just (String selected) -> Right selected
            Just number@(Number _) -> case fromJSON number of
              Success (integer :: Integer) -> Right (T.pack (show integer))
              _ -> Left "manual GCS object metadata has a non-integer field"
            _ -> Left "manual GCS object metadata lacks a required field"
      selectedBucket <- field "bucket"
      selectedName <- field "name"
      generation <- field "generation"
      sizeText <- field "size"
      unless
        ( selectedBucket == bucket
            && selectedName == name
            && decimal generation
            && decimal sizeText
        )
        (Left "manual GCS object metadata has another identity or invalid generation")
      size <- case reads (T.unpack sizeText) of
        [(amount, "")] | amount > 0 -> Right amount
        _ -> Left "manual GCS object size is invalid"
      pure (StoredObject generation size)
    _ -> Left "manual GCS object metadata is not an object"
  where
    decimal value =
      not (T.null value)
        && T.all (\character -> character >= '0' && character <= '9') value
        && T.any (/= '0') value

fileLength :: FilePath -> IO (Either Text Integer)
fileLength path = do
  value <-
    try (withBinaryFile path ReadMode hFileSize) ::
      IO (Either IOException Integer)
  pure (first (const "manual backup object file is unavailable") value)

readReceiptFile :: FilePath -> IO (Either IOException BS.ByteString)
readReceiptFile path = try (BS.readFile path)

hashFile :: FilePath -> IO (Either Text Text)
hashFile path = do
  value <-
    try
      ( withBinaryFile path ReadMode $ \input ->
          go (hashInit :: Context SHA256) input
      ) ::
      IO (Either IOException Text)
  pure (first (const "manual backup archive hash is unavailable") value)
  where
    go context input = do
      chunk <- BS.hGetSome input 65536
      if BS.null chunk
        then pure (T.pack (show (hashFinalize context :: Digest SHA256)))
        else go (hashUpdate context chunk) input
