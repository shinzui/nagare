-- | Turn one completed manual backup into a durable, Job-free receipt scope.
-- The caller must observe the accepted Job's completed UID and read both
-- provider objects at the versions supplied here before compiling this scope.
module Nagare.Inventory.ManualReceipt
  ( ManualReceiptEvidence (..)
  , compileManualReceiptScope
  , manualReceiptRecord
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Backup
  ( BackupReceiptExpectation (..)
  , manualBackupJobReceiptExpectation
  , parseManualBackupReceipt
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Types

data ManualReceiptEvidence = ManualReceiptEvidence
  { manualJobUid :: !PhysicalIdentity
  , manualObjectVersion :: !Text
  , manualObjectLength :: !Integer
  , manualObjectSha256 :: !Text
  , manualReceiptVersion :: !Text
  , manualReceiptLength :: !Integer
  , manualReceiptBytes :: !ByteString
  }
  deriving stock (Eq, Show)

-- | A record has no managed Job. Its original Job becomes a retained member
-- during a reviewed scope replacement, and can then be collected separately.
manualReceiptRecord :: ScopeDeclaration -> Bool
manualReceiptRecord scope =
  Map.lookup "backup.record" (scopeOverrides scope) == Just "verified-v1"

compileManualReceiptScope ::
  ScopeRevision ->
  ScopeDeclaration ->
  Map.Map ResourceId (ManagedResource, ByteString) ->
  ManualReceiptEvidence ->
  Either (NonEmpty InventoryError) ScopeDeclaration
compileManualReceiptScope producerRevision accepted native evidence = do
  let invalid message =
        inventoryError "invalid-manual-receipt" message
          & #scopes
          .~ [scopeId accepted]
          & (:| [])
      required key =
        maybe
          (Left (invalid ("manual backup lacks " <> key)))
          Right
          (Map.lookup key (scopeOverrides accepted))
      jobs =
        [ member
        | bundle <- scopeBundles accepted
        , Managed member <- declarations bundle
        , case member ^. #address of
            Kubernetes _ "batch" kind _ _ -> nameText kind == "job"
            _ -> False
        ]
  when
    (manualReceiptRecord accepted)
    (Left (invalid "manual backup already has a durable receipt record"))
  job <- case jobs of
    [single] -> Right single
    _ -> Left (invalid "accepted manual backup lacks one Job")
  (bound, bytes) <-
    maybe
      (Left (invalid "manual backup Job lacks accepted private native bytes"))
      Right
      (Map.lookup (job ^. #identity) native)
  unless
    (bound == job)
    (Left (invalid "manual backup Job differs from its accepted native bytes"))
  unless
    (job ^. #spec == NativeObject (contentDigest bytes))
    (Left (invalid "manual backup Job native digest changed"))
  expectation <-
    first invalid (manualBackupJobReceiptExpectation bytes) >>= \case
      Just selected -> Right selected
      Nothing -> Left (invalid "accepted Job has no manual backup receipt expectation")
  objectAddress <- required "backup.object"
  selectedReceiptAddress <- required "backup.receipt"
  metadataDigest <- required "backup.receipt.metadata.digest"
  unless
    ( objectAddress == receiptObjectAddress expectation
        && selectedReceiptAddress == receiptAddress expectation
        && metadataDigest == digestText (receiptMetadataDigest expectation)
    )
    (Left (invalid "accepted scope and Job disagree on backup receipt identity"))
  checksum <-
    first
      invalid
      ( parseManualBackupReceipt
          accepted
          selectedReceiptAddress
          (manualReceiptBytes evidence)
      )
  unless
    (checksum == manualObjectSha256 evidence)
    (Left (invalid "stored archive hash differs from its accepted receipt"))
  unless
    ( manualObjectLength evidence > 0
        && manualReceiptLength evidence == fromIntegral (BS.length (manualReceiptBytes evidence))
        && not (T.null (manualObjectVersion evidence))
        && not (T.null (manualReceiptVersion evidence))
    )
    (Left (invalid "manual backup lacks exact provider versions and lengths"))
  when
    ( "gs://" `T.isPrefixOf` objectAddress
        && not
          ( all
              decimalVersion
              [ manualObjectVersion evidence
              , manualReceiptVersion evidence
              ]
          )
    )
    (Left (invalid "GCS backup versions must be decimal generations"))
  let extra =
        Map.fromList
          [ ("backup.record", "verified-v1")
          , ("backup.job", resourceIdText (job ^. #identity))
          , ("backup.job.uid", physicalIdentityText (manualJobUid evidence))
          ,
            ( "backup.producer.generation"
            , T.pack
                ( show
                    ( generationNumber
                        (revisionGeneration producerRevision)
                    )
                )
            )
          , ("backup.producer.revision", digestText (revisionDigest producerRevision))
          , ("backup.object.version", manualObjectVersion evidence)
          , ("backup.object.length", T.pack (show (manualObjectLength evidence)))
          , ("backup.object.sha256", checksum)
          , ("backup.receipt.version", manualReceiptVersion evidence)
          , ("backup.receipt.length", T.pack (show (manualReceiptLength evidence)))
          , ("backup.receipt.digest", digestText (contentDigest (manualReceiptBytes evidence)))
          ]
  base <-
    mkScopeDeclaration
      (scopeId accepted)
      [ResourceBundle [] [] [] [] [] []]
  pure
    ( withScopeOverrides
        (Map.union extra (scopeOverrides accepted))
        (withScopeConfigDigest (contentDigest (manualReceiptBytes evidence)) base)
    )
  where
    decimalVersion value =
      not (T.null value)
        && T.all (\character -> character >= '0' && character <= '9') value
        && T.any (/= '0') value
