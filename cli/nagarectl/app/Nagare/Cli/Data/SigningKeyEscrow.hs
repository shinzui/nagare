-- | Data / SigningKeyEscrow. Executable-private CLI boundary for MasterPlan 23
-- decision D1: escrow each database's scheduled-backup signing key in
-- sops-encrypted operator material, and verify a scheduled receipt with only
-- that escrow and the object store. Neither command changes a provider or the
-- inventory, and verification never grants restore authority.
module Nagare.Cli.Data.SigningKeyEscrow
  ( defaultEscrowPath
  , runEscrowSigningKey
  , runVerifyEscrowedBackup
  , decryptEscrow
  , escrowedReceiptEvidence
  )
where

import Control.Exception (IOException, try)
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (diffUTCTime, getCurrentTime)
import Nagare.Cli.Data.ScheduledReceipts
  ( ScheduledSource (ScheduledSource)
  , resolveScheduledSource
  )
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Cluster.GcsJob (StoreBackend (MinioBackend), storePrefixUrl)
import Nagare.Database.Backup (dbBackupKeyPrefix)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Backup
  ( ScheduledBackupReceipt (..)
  , ScheduledReceiptExpectation (scheduledFormat)
  )
import Nagare.Inventory.ScheduledGcs (withScheduledObjectStore)
import Nagare.Inventory.ScheduledReceipt
  ( ScheduledReceiptEvidence (..)
  , inspectScheduledReceipt
  )
import Nagare.Inventory.ScheduledStore (ObjectReader (readObjectToFile), parseOfflineObjectStore, readOfflineCredentials, readSecretFieldWithUid, withOfflineObjectStore)
import Nagare.Inventory.SigningKeyEscrow
  ( SigningKeyEscrow (SigningKeyEscrow)
  , escrowReceiptExpectation
  , parseSigningKeyEscrow
  , renderSigningKeyEscrow
  )
import Nagare.Resource.Types (digestText, physicalIdentityText)
import Nagare.Target (contextNameText, nagareConfigDir)
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitSuccess), exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (WriteMode), hClose, hSetBinaryMode)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, groupModes, nullFileMode, otherModes)
import System.Posix.IO (OpenFileFlags (..), OpenMode (WriteOnly), defaultFileFlags, fdToHandle, openFd)
import System.Posix.Types (Fd)
import System.Process (CreateProcess (cwd, env), proc, readCreateProcessWithExitCode)

-- | Operator material lives beside the context's other sops-encrypted
-- cluster secrets (ADR 13), outside this repository.
defaultEscrowPath :: Text -> Text -> Text -> IO FilePath
defaultEscrowPath context namespaceName database = do
  config <- nagareConfigDir
  pure
    ( config
        </> "cluster-secrets"
        </> T.unpack context
        </> "backup-signing"
        </> T.unpack (namespaceName <> "-" <> database <> ".sops.yaml")
    )

runEscrowSigningKey :: Maybe String -> Text -> Text -> Maybe FilePath -> IO ()
runEscrowSigningKey mctx database namespaceName output = do
  ScheduledSource active _ _ statefulUid pvcUid signingUid _ expectation <-
    resolveScheduledSource mctx database namespaceName Nothing
  let context = contextNameText (active ^. #contextName)
  (secretUid, key) <-
    readSecretFieldWithUid context namespaceName ("nagare-dbbackup-" <> database <> "-signing") "HMAC_KEY"
      >>= either dieT pure
  unless
    (secretUid == Just (physicalIdentityText signingUid))
    (dieT "signing Secret changed between observation and read; rerun the escrow")
  let escrow =
        SigningKeyEscrow
          context
          namespaceName
          database
          (scheduledFormat expectation)
          signingUid
          statefulUid
          pvcUid
          key
  path <- maybe (defaultEscrowPath context namespaceName database) pure output >>= makeAbsolute
  exists <- doesFileExist path
  if exists
    then do
      stored <- decryptEscrow path
      if stored == escrow
        then TIO.putStrLn ("Signing key already escrowed for " <> namespaceName <> "/" <> database <> " at " <> T.pack path)
        else dieT "an escrow with a different key or source identity exists; refusing to overwrite it"
    else do
      createDirectoryIfMissing True (takeDirectory path)
      ciphertext <- sopsEncrypt path (renderSigningKeyEscrow escrow)
      roundTrip <- sopsDecryptBytes (takeDirectory path) ciphertext
      unless
        (roundTrip == Right escrow)
        (dieT "the encrypted escrow does not decrypt with the available age key; check .sops.yaml recipients and SOPS_AGE_KEY_FILE")
      createExclusive path ciphertext
      TIO.putStrLn ("Escrowed the scheduled-backup signing key for " <> namespaceName <> "/" <> database <> " at " <> T.pack path)
      TIO.putStrLn "Keep this file in the context's private operator repository; it verifies receipts without the cluster."

-- | Verify one scheduled receipt with only the escrow and the object store.
-- Success is evidence about stored bytes; restore still requires reviewed
-- ingestion of the receipt.
-- An offline target (F41) reads a copied local object store at an explicit
-- loopback endpoint, so verification does not need the source cluster.
runVerifyEscrowedBackup :: Maybe String -> Text -> Text -> FilePath -> Maybe String -> Text -> Maybe (String, FilePath) -> IO ()
runVerifyEscrowedBackup mctx requestedDatabase requestedNamespace escrowPath bucketArg backupId offline = do
  active <- activeTarget mctx
  escrow@(SigningKeyEscrow context namespaceName database _ _ _ _ _) <- decryptEscrow escrowPath
  unless
    (context == contextNameText (active ^. #contextName))
    (dieT "the escrow belongs to another context")
  unless
    (database == requestedDatabase && namespaceName == requestedNamespace)
    (dieT "the escrow belongs to another database or namespace")
  backend <- resolveStoreBackend mctx bucketArg
  evidence <- escrowedReceiptEvidence escrow backend backupId offline >>= either dieT pure
  now <- getCurrentTime
  let receipt = scheduledReceipt evidence
  TIO.putStrLn ("Verified scheduled backup " <> backupId <> " of " <> namespaceName <> "/" <> database <> " with the escrowed signing key.")
  TIO.putStrLn ("  object:  " <> scheduledObjectAddress receipt <> " (version " <> scheduledObjectVersion evidence <> ")")
  TIO.putStrLn ("  receipt: version " <> scheduledReceiptVersion evidence)
  TIO.putStrLn ("  sha256:  " <> scheduledSha256 receipt)
  -- EP-183 M4: what a rebuild decision names as this recovery point.
  TIO.putStrLn ("  rebuild recovery point: " <> scheduledObjectAddress receipt <> ".receipt.json@" <> digestText (scheduledReceiptDigest evidence))
  case scheduledRecoveryPoint receipt of
    Just point ->
      TIO.putStrLn
        ( "  recovery point: "
            <> T.pack (show point)
            <> " (age "
            <> T.pack (show (floor (diffUTCTime now point) :: Integer))
            <> "s)"
        )
    Nothing -> TIO.putStrLn "  recovery point: none (version-4 receipt)"
  TIO.putStrLn "This is evidence only; restore requires reviewed ingestion of the receipt."

-- | Read and verify one scheduled receipt and its archive with only the
-- escrowed key and the object store, never the cluster or the inventory store.
escrowedReceiptEvidence :: SigningKeyEscrow -> StoreBackend -> Text -> Maybe (String, FilePath) -> IO (Either Text ScheduledReceiptEvidence)
escrowedReceiptEvidence escrow@(SigningKeyEscrow context _ database format _ _ _ key) backend backupId offline = do
  let prefix = storePrefixUrl backend (dbBackupKeyPrefix database)
      receiptAddress = prefix <> backupId <> "." <> format <> ".receipt.json"
  withStore <- case (offline, backend) of
    (Nothing, _) -> pure (Right (withScheduledObjectStore context backend))
    (Just (endpoint, credentialFile), MinioBackend ref) -> do
      user <- readOfflineCredentials credentialFile
      pure (withOfflineObjectStore <$> parseOfflineObjectStore (T.pack endpoint) <*> user <*> pure ref)
    (Just _, _) -> pure (Left "--offline-object-store applies only to a local MinIO object store")
  case withStore of
    Left reason -> pure (Left reason)
    Right with -> do
      checked <- with $ \reader ->
        withSystemTempDirectory "nagare-escrowed-receipt" $ \scratch -> do
          current <- readObjectToFile reader receiptAddress Nothing (scratch </> "receipt")
          case current of
            Left reason -> pure (Left reason)
            Right _ -> do
              bytes <- BS.readFile (scratch </> "receipt")
              case escrowReceiptExpectation escrow prefix bytes of
                Left reason -> pure (Left reason)
                Right expectation -> inspectScheduledReceipt reader expectation backupId key
      pure (checked >>= id)

decryptEscrow :: FilePath -> IO SigningKeyEscrow
decryptEscrow path = do
  exists <- doesFileExist path
  unless exists (dieT ("signing-key escrow not found: " <> T.pack path))
  ciphertext <- BS.readFile path
  sopsDecryptBytes (takeDirectory path) ciphertext >>= either dieT pure

-- | Plaintext travels on standard input only, never in argv or a temp file.
-- Running from the destination directory lets sops find the operator's
-- @.sops.yaml@ creation rules beside the escrow.
sopsEncrypt :: FilePath -> BS.ByteString -> IO BS.ByteString
sopsEncrypt path plaintext = do
  environment <- sopsEnvironment
  outcome <-
    try
      ( readCreateProcessWithExitCode
          ( proc
              "sops"
              ["encrypt", "--filename-override", path, "--input-type", "yaml", "--output-type", "yaml", "/dev/stdin"]
          )
            { cwd = Just (takeDirectory path)
            , env = Just environment
            }
          (BC.unpack plaintext)
      ) ::
      IO (Either IOException (ExitCode, String, String))
  case outcome of
    Right (ExitSuccess, ciphertext, _) | not (null ciphertext) -> pure (BC.pack ciphertext)
    Right (_, _, errors) -> dieT ("sops could not encrypt the escrow: " <> T.strip (T.pack errors))
    Left _ -> dieT "sops is not available; install sops and configure .sops.yaml for the escrow directory"

sopsDecryptBytes :: FilePath -> BS.ByteString -> IO (Either Text SigningKeyEscrow)
sopsDecryptBytes directory ciphertext = do
  environment <- sopsEnvironment
  outcome <-
    try
      ( readCreateProcessWithExitCode
          (proc "sops" ["decrypt", "--input-type", "yaml", "--output-type", "yaml", "/dev/stdin"])
            { cwd = Just directory
            , env = Just environment
            }
          (BC.unpack ciphertext)
      ) ::
      IO (Either IOException (ExitCode, String, String))
  pure $ case outcome of
    Right (ExitSuccess, plaintext, _) -> parseSigningKeyEscrow (BC.pack plaintext)
    Right _ -> Left "could not decrypt the signing-key escrow with the available age key"
    Left _ -> Left "sops is not available"

-- | The conventional age key location used by the other operator-secret
-- readers, unless SOPS_AGE_KEY_FILE is already set.
sopsEnvironment :: IO [(String, String)]
sopsEnvironment = do
  environment <- getEnvironment
  age <- lookupEnv "SOPS_AGE_KEY_FILE"
  case age of
    Just value | not (null value) -> pure environment
    _ -> do
      config <- nagareConfigDir
      let conventional = config </> ".." </> "sops/age/keys.txt"
      found <- doesFileExist conventional
      pure (if found then ("SOPS_AGE_KEY_FILE", conventional) : environment else environment)

-- | Create-only: an escrow appearing concurrently is never overwritten.
createExclusive :: FilePath -> BS.ByteString -> IO ()
createExclusive path bytes = do
  opened <- try (openFd path WriteOnly defaultFileFlags {exclusive = True, creat = Just 0o600}) :: IO (Either IOException Fd)
  case opened of
    Left _ -> dieT "the escrow file appeared while writing; refusing to overwrite it"
    Right fd -> do
      handle <- fdToHandle fd
      hSetBinaryMode handle True
      BS.hPut handle bytes
      hClose handle
