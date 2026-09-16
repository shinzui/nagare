{-# LANGUAGE OverloadedStrings #-}

-- | Private, transaction-bound evidence for a Pulumi apply attempt.
module Nagare.Platform.PulumiReceipt
  ( PulumiReceiptState (..)
  , PulumiRecoveryOutcome (..)
  , PulumiApplyReceipt (..)
  , pulumiReceiptPath
  , readPulumiReceipt
  , readVerifiedPulumiReceipt
  , writeStartedReceipt
  , writeResultReceipt
  , writeRecoveryReceipt
  , verifyPulumiReceipt
  , renderPulumiReceiptEvidence
  )
where

import Control.Exception (IOException, catch, try)
import Data.Aeson ((.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Infra.Plan (SavedPlanMetadata (..))
import Nagare.Platform.Upgrade (UpgradeTransaction (..))
import System.Directory
  ( createDirectoryIfMissing
  , pathIsSymbolicLink
  , removeFile
  , renameFile
  )
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, hFlush, openBinaryTempFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (fileMode, getFileStatus, isRegularFile, setFileMode)

data PulumiReceiptState
  = ReceiptStarted
  | ReceiptSucceeded
  | ReceiptFailed
  | ReceiptOperatorAttested
  deriving stock (Eq, Show)

data PulumiRecoveryOutcome = RecoveryApplied | RecoveryRetry
  deriving stock (Eq, Show)

data PulumiApplyReceipt = PulumiApplyReceipt
  { receiptSchemaVersion :: !Int
  , receiptTransactionId :: !Text
  , receiptContext :: !Text
  , receiptTargetVersion :: !Text
  , receiptPayloadId :: !Text
  , receiptPayloadDigest :: !Text
  , receiptPlanDigest :: !Text
  , receiptReviewDigest :: !Text
  , receiptProject :: !Text
  , receiptStack :: !Text
  , receiptBackend :: !Text
  , receiptPulumiVersion :: !Text
  , receiptState :: !PulumiReceiptState
  , receiptTimestamp :: !Text
  , receiptRecoveryOutcome :: !(Maybe PulumiRecoveryOutcome)
  }
  deriving stock (Generic, Eq, Show)

instance Aeson.ToJSON PulumiApplyReceipt where
  toJSON receipt =
    Aeson.object
      [ "schemaVersion" Aeson..= receiptSchemaVersion receipt
      , "transactionId" Aeson..= receiptTransactionId receipt
      , "context" Aeson..= receiptContext receipt
      , "targetVersion" Aeson..= receiptTargetVersion receipt
      , "payloadId" Aeson..= receiptPayloadId receipt
      , "payloadDigest" Aeson..= receiptPayloadDigest receipt
      , "planDigest" Aeson..= receiptPlanDigest receipt
      , "reviewDigest" Aeson..= receiptReviewDigest receipt
      , "project" Aeson..= receiptProject receipt
      , "stack" Aeson..= receiptStack receipt
      , "backend" Aeson..= receiptBackend receipt
      , "pulumiVersion" Aeson..= receiptPulumiVersion receipt
      , "state" Aeson..= receiptStateToken (receiptState receipt)
      , "timestamp" Aeson..= receiptTimestamp receipt
      , "recoveryOutcome" Aeson..= fmap recoveryOutcomeToken (receiptRecoveryOutcome receipt)
      ]

instance Aeson.FromJSON PulumiApplyReceipt where
  parseJSON = Aeson.withObject "PulumiApplyReceipt" $ \o ->
    PulumiApplyReceipt
      <$> o .: "schemaVersion"
      <*> o .: "transactionId"
      <*> o .: "context"
      <*> o .: "targetVersion"
      <*> o .: "payloadId"
      <*> o .: "payloadDigest"
      <*> o .: "planDigest"
      <*> o .: "reviewDigest"
      <*> o .: "project"
      <*> o .: "stack"
      <*> o .: "backend"
      <*> o .: "pulumiVersion"
      <*> (o .: "state" >>= parseReceiptState)
      <*> o .: "timestamp"
      <*> (traverse parseRecoveryOutcome =<< o .:? "recoveryOutcome")

receiptStateToken :: PulumiReceiptState -> Text
receiptStateToken ReceiptStarted = "started"
receiptStateToken ReceiptSucceeded = "succeeded"
receiptStateToken ReceiptFailed = "failed"
receiptStateToken ReceiptOperatorAttested = "operator-attested"

parseReceiptState :: Text -> Parser PulumiReceiptState
parseReceiptState "started" = pure ReceiptStarted
parseReceiptState "succeeded" = pure ReceiptSucceeded
parseReceiptState "failed" = pure ReceiptFailed
parseReceiptState "operator-attested" = pure ReceiptOperatorAttested
parseReceiptState other = fail ("unknown Pulumi receipt state: " <> T.unpack other)

recoveryOutcomeToken :: PulumiRecoveryOutcome -> Text
recoveryOutcomeToken RecoveryApplied = "applied"
recoveryOutcomeToken RecoveryRetry = "retry"

parseRecoveryOutcome :: Text -> Parser PulumiRecoveryOutcome
parseRecoveryOutcome "applied" = pure RecoveryApplied
parseRecoveryOutcome "retry" = pure RecoveryRetry
parseRecoveryOutcome other = fail ("unknown Pulumi recovery outcome: " <> T.unpack other)

pulumiReceiptPath :: FilePath -> UpgradeTransaction -> FilePath
pulumiReceiptPath transactionPath tx =
  takeDirectory transactionPath </> T.unpack (tx ^. #id) </> "pulumi-apply-receipt.json"

readPulumiReceipt :: FilePath -> IO (Either Text (Maybe PulumiApplyReceipt))
readPulumiReceipt path = do
  loaded <- try $ do
    linked <- pathIsSymbolicLink path
    when linked (ioError (userError "receipt is a symlink"))
    status <- getFileStatus path
    unless (isRegularFile status) (ioError (userError "receipt is not a regular file"))
    unless (fileMode status .&. 0o077 == 0) (ioError (userError "receipt is accessible by group or other users"))
    BS.readFile path
  pure $ case loaded of
    Left (err :: IOException)
      | isDoesNotExistError err -> Right Nothing
      | otherwise -> Left ("invalid Pulumi apply receipt " <> T.pack path <> ": " <> T.pack (show err))
    Right bytes -> case Aeson.eitherDecodeStrict' bytes of
      Left err -> Left ("invalid Pulumi apply receipt " <> T.pack path <> ": " <> T.pack err)
      Right receipt -> Just <$> validateReceiptShape receipt

readVerifiedPulumiReceipt :: FilePath -> UpgradeTransaction -> SavedPlanMetadata -> IO (Either Text (Maybe PulumiApplyReceipt))
readVerifiedPulumiReceipt path tx metadata = do
  loaded <- readPulumiReceipt path
  pure $ do
    receipt <- loaded
    traverse (verifyPulumiReceipt tx metadata) receipt

verifyPulumiReceipt :: UpgradeTransaction -> SavedPlanMetadata -> PulumiApplyReceipt -> Either Text PulumiApplyReceipt
verifyPulumiReceipt tx metadata receipt = do
  _ <- validateReceiptShape receipt
  traverse_ matches bindings
  pure receipt
  where
    bindings =
      [ ("transactionId", tx ^. #id, receiptTransactionId receipt)
      , ("context", tx ^. #context, receiptContext receipt)
      , ("targetVersion", tx ^. #targetVersion, receiptTargetVersion receipt)
      , ("payloadId", tx ^. #payloadId, receiptPayloadId receipt)
      , ("payloadDigest", tx ^. #payloadDigest, receiptPayloadDigest receipt)
      , ("metadata.context", metadata ^. #context, receiptContext receipt)
      , ("metadata.payloadId", metadata ^. #payloadId, receiptPayloadId receipt)
      , ("metadata.payloadDigest", metadata ^. #payloadDigest, receiptPayloadDigest receipt)
      , ("planDigest", metadata ^. #planDigest, receiptPlanDigest receipt)
      , ("reviewDigest", metadata ^. #reviewDigest, receiptReviewDigest receipt)
      , ("project", metadata ^. #project, receiptProject receipt)
      , ("stack", metadata ^. #stack, receiptStack receipt)
      , ("backend", metadata ^. #backend, receiptBackend receipt)
      , ("pulumiVersion", metadata ^. #pulumiVersion, receiptPulumiVersion receipt)
      ]
    matches (field, expected, observed)
      | expected == observed = Right ()
      | otherwise = Left ("Pulumi apply receipt " <> field <> " is '" <> observed <> "', expected '" <> expected <> "'")

writeStartedReceipt :: FilePath -> UpgradeTransaction -> SavedPlanMetadata -> Text -> IO (Either Text PulumiApplyReceipt)
writeStartedReceipt path tx metadata now = do
  existing <- readVerifiedPulumiReceipt path tx metadata
  case existing of
    Left err -> pure (Left err)
    Right Nothing -> persist newReceipt
    Right (Just receipt) -> case (receiptState receipt, receiptRecoveryOutcome receipt) of
      (ReceiptFailed, Nothing) -> persist newReceipt
      (ReceiptOperatorAttested, Just RecoveryRetry) -> persist newReceipt
      (ReceiptStarted, Nothing) -> pure (Left "Pulumi apply already has an ambiguous started receipt; use platform upgrade recover-pulumi")
      (ReceiptSucceeded, Nothing) -> pure (Left "Pulumi apply already has a verified success receipt")
      (ReceiptOperatorAttested, Just RecoveryApplied) -> pure (Left "Pulumi apply already has an operator-attested success receipt")
      _ -> pure (Left "Pulumi apply receipt has an invalid state transition")
  where
    newReceipt = makeReceipt tx metadata ReceiptStarted Nothing now
    persist = writePulumiReceipt path

writeResultReceipt :: FilePath -> UpgradeTransaction -> SavedPlanMetadata -> PulumiReceiptState -> Text -> IO (Either Text PulumiApplyReceipt)
writeResultReceipt path tx metadata resultState now
  | resultState `notElem` [ReceiptSucceeded, ReceiptFailed] = pure (Left "automatic Pulumi result must be succeeded or failed")
  | otherwise = do
      existing <- readVerifiedPulumiReceipt path tx metadata
      case existing of
        Left err -> pure (Left err)
        Right (Just receipt)
          | receiptState receipt == ReceiptStarted ->
              writePulumiReceipt path (makeReceipt tx metadata resultState Nothing now)
        Right _ -> pure (Left "Pulumi apply result requires the matching started receipt")

writeRecoveryReceipt :: FilePath -> UpgradeTransaction -> SavedPlanMetadata -> PulumiRecoveryOutcome -> Text -> IO (Either Text PulumiApplyReceipt)
writeRecoveryReceipt path tx metadata outcome now = do
  existing <- readVerifiedPulumiReceipt path tx metadata
  case existing of
    Left err -> pure (Left err)
    Right Nothing -> persist
    Right (Just receipt) -> case (receiptState receipt, receiptRecoveryOutcome receipt) of
      (ReceiptStarted, Nothing) -> persist
      (ReceiptOperatorAttested, Just oldOutcome)
        | oldOutcome == outcome -> pure (Right receipt)
        | otherwise -> pure (Left "refusing to reverse the recorded Pulumi recovery outcome")
      (ReceiptSucceeded, Nothing) -> pure (Left "automatic Pulumi success is already established")
      (ReceiptFailed, Nothing) -> pure (Left "a known failed Pulumi apply can be retried with normal --resume")
      _ -> pure (Left "Pulumi apply receipt has an invalid recovery transition")
  where
    persist = writePulumiReceipt path (makeReceipt tx metadata ReceiptOperatorAttested (Just outcome) now)

makeReceipt :: UpgradeTransaction -> SavedPlanMetadata -> PulumiReceiptState -> Maybe PulumiRecoveryOutcome -> Text -> PulumiApplyReceipt
makeReceipt tx metadata state recovery timestamp =
  PulumiApplyReceipt
    { receiptSchemaVersion = 1
    , receiptTransactionId = tx ^. #id
    , receiptContext = tx ^. #context
    , receiptTargetVersion = tx ^. #targetVersion
    , receiptPayloadId = tx ^. #payloadId
    , receiptPayloadDigest = tx ^. #payloadDigest
    , receiptPlanDigest = metadata ^. #planDigest
    , receiptReviewDigest = metadata ^. #reviewDigest
    , receiptProject = metadata ^. #project
    , receiptStack = metadata ^. #stack
    , receiptBackend = metadata ^. #backend
    , receiptPulumiVersion = metadata ^. #pulumiVersion
    , receiptState = state
    , receiptTimestamp = timestamp
    , receiptRecoveryOutcome = recovery
    }

validateReceiptShape :: PulumiApplyReceipt -> Either Text PulumiApplyReceipt
validateReceiptShape receipt
  | receiptSchemaVersion receipt /= 1 = Left ("unsupported Pulumi apply receipt schema " <> T.pack (show (receiptSchemaVersion receipt)))
  | validState = Right receipt
  | otherwise = Left "Pulumi apply receipt state and recoveryOutcome disagree"
  where
    validState = case (receiptState receipt, receiptRecoveryOutcome receipt) of
      (ReceiptOperatorAttested, Just _) -> True
      (ReceiptOperatorAttested, Nothing) -> False
      (_, Nothing) -> True
      (_, Just _) -> False

writePulumiReceipt :: FilePath -> PulumiApplyReceipt -> IO (Either Text PulumiApplyReceipt)
writePulumiReceipt path receipt = do
  createDirectoryIfMissing True (takeDirectory path)
  written <- try $ do
    (temporary, handle) <- openBinaryTempFile (takeDirectory path) ".pulumi-apply-receipt.tmp"
    let cleanup = do
          hClose handle `catch` (\(_ :: IOException) -> pure ())
          removeFile temporary `catch` (\(_ :: IOException) -> pure ())
    ( do
        setFileMode temporary 0o600
        LBS.hPut handle (Aeson.encode receipt)
        hFlush handle
        hClose handle
        renameFile temporary path
      )
      `catch` \(err :: IOException) -> cleanup >> ioError err
  pure $ case written of
    Left (err :: IOException) -> Left ("could not write Pulumi apply receipt " <> T.pack path <> ": " <> T.pack (show err))
    Right () -> Right receipt

renderPulumiReceiptEvidence :: PulumiApplyReceipt -> Text
renderPulumiReceiptEvidence receipt =
  "Pulumi apply receipt "
    <> receiptStateToken (receiptState receipt)
    <> maybe "" ((" (recovery " <>) . (<> ")") . recoveryOutcomeToken) (receiptRecoveryOutcome receipt)
    <> " at "
    <> receiptTimestamp receipt
    <> "; plan "
    <> receiptPlanDigest receipt
