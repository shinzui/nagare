{-# LANGUAGE RankNTypes #-}

-- | Types responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Types
  ( AdmissionError (..)
  , ExecutablePlan (..)
  , OperatorRecoveryInput (..)
  , RecoveryAction (..)
  , TransactionResult (..)
  , ambiguousFallback
  , decodeOperatorRecoveryInput
  , failure
  , fallbackResult
  , reviewAdmission
  , reviewDocumentDigest
  , showText
  , timestamp
  , transactionFor
  )
where

import Data.Aeson
  ( FromJSON (..)
  , eitherDecodeStrict'
  , withObject
  , (.:)
  )
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( PlannedOperation (plannedOperationId)
  , ReviewBarrier
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal
  ( FailureClass
  , OperationId
  , TransactionId
  , mkOperationId
  , mkTransactionId
  )
import Nagare.Inventory.Plan
  ( ReviewDocument (reviewOperations)
  , ReviewError (reviewErrorCode, reviewErrorMessage)
  , ReviewOperation (reviewPlannedOperation)
  , ReviewedPlan
  , encodeReviewDocument
  )
import Nagare.Resource.Types
  ( ContentDigest
  , digestText
  , mkContentDigest
  )

data AdmissionError = AdmissionError
  { admissionErrorCode :: !Text
  , admissionErrorMessage :: !Text
  }
  deriving stock (Eq, Show, Generic)

data RecoveryAction
  = AcceptAdapterProof
  | RetryAfterAdapterProof
  | ContinueFencedOperation
  | VerifyFencedEffect
  | RecoverFencedBackup
  | ForwardFencedRelease
  | AbandonPartialPrune
  | AbandonPartialVolumeRestore
  | AbandonPartialDatabaseRestore
  | StopIncompleteApplication
  | AbandonRefusedOperation
  | RecoverBootstrapRegistry !ContentDigest
  deriving stock (Eq, Show)

data OperatorRecoveryInput = OperatorRecoveryInput
  { recoveryTransaction :: !TransactionId
  , recoveryOperation :: !OperationId
  , recoveryReview :: !ContentDigest
  , recoveryAction :: !RecoveryAction
  }
  deriving stock (Eq, Show)

decodeOperatorRecoveryInput :: ByteString -> Either Text OperatorRecoveryInput
decodeOperatorRecoveryInput = first T.pack . eitherDecodeStrict'

instance FromJSON OperatorRecoveryInput where
  parseJSON = withObject "OperatorRecoveryInput" $ \o -> do
    unless
      (all (`elem` ["version", "transaction", "operation", "review", "action"]) (KM.keys o))
      (fail "operator recovery input has an unknown field")
    version <- o .: "version" :: Parser Int
    unless (version == 1) (fail "unsupported operator recovery version")
    action <- o .: "action" :: Parser Text
    decision <- case action of
      "accept-adapter-proof" -> pure AcceptAdapterProof
      "retry-after-adapter-proof" -> pure RetryAfterAdapterProof
      "continue-fenced-operation" -> pure ContinueFencedOperation
      "verify-fenced-effect" -> pure VerifyFencedEffect
      "recover-fenced-backup" -> pure RecoverFencedBackup
      "forward-fenced-release" -> pure ForwardFencedRelease
      "abandon-partial-prune" -> pure AbandonPartialPrune
      "abandon-partial-volume-restore" -> pure AbandonPartialVolumeRestore
      "abandon-partial-database-restore" -> pure AbandonPartialDatabaseRestore
      "stop-incomplete-application" -> pure StopIncompleteApplication
      "abandon-refused-operation" -> pure AbandonRefusedOperation
      _
        | Just native <- T.stripPrefix "recover-bootstrap-registry:" action ->
            RecoverBootstrapRegistry <$> either (fail . T.unpack) pure (mkContentDigest native)
        | otherwise -> fail "unsupported operator recovery action"
    OperatorRecoveryInput
      <$> o .: "transaction"
      <*> o .: "operation"
      <*> o .: "review"
      <*> pure decision

data ExecutablePlan s = ExecutablePlan
  { executableTransaction :: !TransactionId
  , executableReviewed :: !ReviewedPlan
  }

data TransactionResult
  = Converged !TransactionId
  | PausedAtBarrier !TransactionId !(NonEmpty ReviewBarrier)
  | StoppedFailed !TransactionId !OperationId !FailureClass
  | StoppedAmbiguous !TransactionId !OperationId
  | -- | ADR 26: the transaction was closed by per-operation proof.
    Closed !TransactionId
  deriving stock (Eq, Show, Generic)

transactionFor :: ReviewDocument -> TransactionId
transactionFor document =
  either (error . T.unpack) id (mkTransactionId ("tx-" <> digestText (reviewDocumentDigest document)))

reviewDocumentDigest :: ReviewDocument -> ContentDigest
reviewDocumentDigest = contentDigest . encodeReviewDocument

timestamp :: IO Text
timestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime

failure :: Text -> Text -> Either (NonEmpty AdmissionError) a
failure code message = Left (AdmissionError code message :| [])

reviewAdmission :: ReviewError -> AdmissionError
reviewAdmission errorValue = AdmissionError (reviewErrorCode errorValue) (reviewErrorMessage errorValue)

showText :: (Show a) => a -> Text
showText = T.pack . show

ambiguousFallback :: TransactionId -> ReviewDocument -> IO TransactionResult
ambiguousFallback transaction document = pure (fallbackResult transaction document)

fallbackResult :: TransactionId -> ReviewDocument -> TransactionResult
fallbackResult transaction document =
  case reviewOperations document of
    operation : _ -> StoppedAmbiguous transaction (plannedOperationId (reviewPlannedOperation operation))
    [] -> StoppedAmbiguous transaction fallbackOperation
  where
    fallbackOperation = either (error . T.unpack) id (mkOperationId "op-store")
