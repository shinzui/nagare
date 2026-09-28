-- | Read a version-pinned manual backup into private local files, rechecking
-- its exact stored receipt and archive bytes before a live restore or verifier
-- can use it. The callback runs while the files and store lease remain open.
module Nagare.Inventory.LiveRestoreSource
  ( captureLiveBackupVersions
  , withVerifiedLiveSource
  , verifyLiveStoredFiles
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Nagare.Cluster.GcsJob (StoreBackend (..))
import Nagare.Dsl.Prelude hiding (Context)
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.LiveRestore
import Nagare.Inventory.ScheduledStore
import System.Exit (ExitCode (..))
import System.IO (IOMode (..), hFileSize, withBinaryFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc,
  waitForProcess)

-- | Planning pins the versions returned by the object store only after both
-- provider files match the completed Job receipt and its archive checksum.
captureLiveBackupVersions :: KubernetesRuntimeConfig -> StoreBackend
  -> Text -> Text -> ByteString -> Text -> IO (Either Text (Text, Text))
captureLiveBackupVersions config backend objectAddress receiptAddress
  expectedReceipt expectedArchiveSha = case backend of
    GcsBackend {} -> pure
      (Left "cloud live restore requires exact-generation provider inspection")
    MinioBackend ref -> do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          result <- withLocalObjectStore (runtimeKubectlContext config) ref $ \reader ->
            withSystemTempDirectory "nagare-live-backup-capture" $ \scratch -> do
              let receiptPath = scratch <> "/receipt.json"
                  archivePath = scratch <> "/backup.gz"
              receipt <- readObjectToFile reader receiptAddress Nothing receiptPath
              archive <- readObjectToFile reader objectAddress Nothing archivePath
              case (receipt, archive) of
                (Right receiptObject, Right archiveObject) -> do
                  receiptSize <- fileLength receiptPath
                  archiveSize <- fileLength archivePath
                  rawReceipt <- try (BS.readFile receiptPath)
                    :: IO (Either IOException BS.ByteString)
                  archiveDigest <- hashFile archivePath
                  pure $ do
                    actualReceiptSize <- receiptSize
                    actualArchiveSize <- archiveSize
                    bytes <- first (const "live restore receipt is unreadable")
                      rawReceipt
                    digest <- archiveDigest
                    unless (storedLength receiptObject == actualReceiptSize
                        && storedLength archiveObject == actualArchiveSize
                        && bytes == expectedReceipt
                        && digest == expectedArchiveSha)
                      (Left "live restore backup store differs from its completed Job receipt")
                    pure (storedVersion archiveObject, storedVersion receiptObject)
                (Left reason, _) -> pure (Left reason)
                (_, Left reason) -> pure (Left reason)
          pure (result >>= id)

withVerifiedLiveSource :: KubernetesRuntimeConfig -> LiveRestoreProof
  -> LiveBackupProof -> (FilePath -> IO (Either Text a))
  -> IO (Either Text a)
withVerifiedLiveSource config proof backup action = do
  now <- floor <$> getPOSIXTime
  if liveBackupExpiryEpoch backup /= 0 && liveBackupExpiryEpoch backup <= now
    then pure (Left "reviewed live restore backup has expired")
    else case liveStoreBackend (liveRestoreProofStore proof) of
      Left reason -> pure (Left reason)
      Right GcsBackend {} -> pure
        (Left "cloud live restore requires exact-generation provider inspection")
      Right (MinioBackend ref) -> do
        guarded <- runtimeGuard config
        case guarded of
          Left reason -> pure (Left ("cluster guard refused: " <> reason))
          Right () -> do
            result <- withLocalObjectStore (runtimeKubectlContext config) ref $ \reader ->
              withSystemTempDirectory "nagare-live-restore" $ \scratch -> do
                let receiptPath = scratch <> "/receipt.json"
                    archivePath = scratch <> "/backup.sql.gz"
                    sqlPath = scratch <> "/backup.sql"
                receipt <- readObjectToFile reader (liveBackupReceipt backup)
                  (Just (liveBackupReceiptVersionProof backup)) receiptPath
                archive <- readObjectToFile reader (liveBackupObject backup)
                  (Just (liveBackupObjectVersionProof backup)) archivePath
                checked <- case (receipt, archive) of
                  (Right receiptObject, Right archiveObject) ->
                    verifyLiveStoredFiles backup receiptObject archiveObject
                      receiptPath archivePath
                  (Left reason, _) -> pure (Left reason)
                  (_, Left reason) -> pure (Left reason)
                case checked of
                  Left reason -> pure (Left reason)
                  Right () -> do
                    decompressed <- decompressArchive archivePath sqlPath
                    case decompressed of
                      Left reason -> pure (Left reason)
                      Right () -> action sqlPath
            pure (result >>= id)

verifyLiveStoredFiles :: LiveBackupProof -> StoredObject -> StoredObject
  -> FilePath -> FilePath -> IO (Either Text ())
verifyLiveStoredFiles backup receiptObject archiveObject receiptPath archivePath = do
  receiptSize <- fileLength receiptPath
  archiveSize <- fileLength archivePath
  rawReceipt <- try (BS.readFile receiptPath)
    :: IO (Either IOException BS.ByteString)
  archiveDigest <- hashFile archivePath
  pure $ do
    actualReceiptSize <- receiptSize
    actualArchiveSize <- archiveSize
    receiptBytes <- first (const "live restore receipt is unreadable")
      rawReceipt
    digest <- archiveDigest
    unless (storedVersion receiptObject
        == liveBackupReceiptVersionProof backup
      && storedVersion archiveObject
        == liveBackupObjectVersionProof backup
      && storedLength receiptObject == actualReceiptSize
      && storedLength archiveObject == actualArchiveSize
      && contentDigest receiptBytes == liveBackupReceiptDigest backup
      && digest == liveBackupSha256 backup)
      (Left "live restore stored receipt or archive changed since review")

fileLength :: FilePath -> IO (Either Text Integer)
fileLength path = do
  value <- try (withBinaryFile path ReadMode hFileSize)
    :: IO (Either IOException Integer)
  pure (first (const "live restore object file is unavailable") value)

hashFile :: FilePath -> IO (Either Text Text)
hashFile path = do
  value <- try (withBinaryFile path ReadMode $ \input ->
    go (hashInit :: Context SHA256) input)
    :: IO (Either IOException Text)
  pure (first (const "live restore archive hash is unavailable") value)
  where
    go context input = do
      chunk <- BS.hGetSome input 65536
      if BS.null chunk
        then pure (T.pack (show (hashFinalize context :: Digest SHA256)))
        else go (hashUpdate context chunk) input

decompressArchive :: FilePath -> FilePath -> IO (Either Text ())
decompressArchive archive outputPath = do
  result <- try (withBinaryFile outputPath WriteMode $ \output -> do
      (_, _, _, process) <- createProcess (proc "gzip" ["-dc", archive])
        {std_in = NoStream, std_out = UseHandle output, std_err = NoStream}
      waitForProcess process) :: IO (Either IOException ExitCode)
  case result of
    Right ExitSuccess -> do
      size <- fileLength outputPath
      pure $ do
        bytes <- size
        unless (bytes > 0) (Left "live restore SQL dump is empty")
    _ -> pure (Left "live restore archive is corrupt or cannot be decompressed")
