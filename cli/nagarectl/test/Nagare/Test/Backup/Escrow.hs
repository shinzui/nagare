-- | Signing-key escrow and receipt verification without the cluster
-- (MasterPlan 23, D1).
module Nagare.Test.Backup.Escrow
  ( signingKeyEscrowTests
  )
where

import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Inventory.Backup
  ( ScheduledBackupReceipt (..)
  , ScheduledReceiptExpectation (scheduledObjective)
  , parseScheduledBackupReceipt
  )
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))
import Nagare.Inventory.SigningKeyEscrow
import Nagare.Resource.Canonical (canonicalValue, contentDigest)
import Nagare.Resource.Types qualified as Resource
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

signingKeyEscrowTests :: [TestTree]
signingKeyEscrowTests =
  [ testCase "signing-key escrow round-trips and never shows its key" $ do
      parseSigningKeyEscrow (renderSigningKeyEscrow escrow) @?= Right escrow
      assertBool "escrow Show leaked the key" (not (keyHex `T.isInfixOf` T.pack (show escrow)))
      assertBool
        "an escrow with an extra field was accepted"
        (isLeft (parseSigningKeyEscrow (renderSigningKeyEscrow escrow <> "extra: field\n")))
      assertBool
        "a short key was accepted"
        (isLeft (parseSigningKeyEscrow (renderSigningKeyEscrow escrow {hmacKey = "abc"})))
  , testCase "an escrowed key verifies a signed receipt without the cluster" $ do
      let prefix = "gs://bucket/databases/mydb/"
          address = prefix <> runId <> ".sql.gz.receipt.json"
          bytes = signedReceipt hourlyMetadata keyBytes sourceUid
      expectation <- either (assertFailure . T.unpack) pure (escrowReceiptExpectation escrow prefix bytes)
      scheduledObjective expectation @?= HourlyRecoveryPoint
      receipt <- either (assertFailure . T.unpack) pure (parseScheduledBackupReceipt expectation address keyHex bytes)
      scheduledRecoveryPoint receipt @?= Just recoveryPoint
      dailyExpectation <-
        either
          (assertFailure . T.unpack)
          pure
          (escrowReceiptExpectation escrow prefix (signedReceipt dailyMetadata keyBytes sourceUid))
      scheduledObjective dailyExpectation @?= DailyRecoveryPoint
  , testCase "escrow verification refuses another key, source incarnation or database" $ do
      let prefix = "gs://bucket/databases/mydb/"
          address = prefix <> runId <> ".sql.gz.receipt.json"
          check bytes = do
            expectation <- escrowReceiptExpectation escrow prefix bytes
            parseScheduledBackupReceipt expectation address keyHex bytes
      assertBool "a receipt signed with another key verified" (isLeft (check (signedReceipt hourlyMetadata (BS.replicate 32 0xbb) sourceUid)))
      assertBool
        "a receipt from another source incarnation verified"
        (isLeft (check (signedReceipt hourlyMetadata keyBytes "33333333-3333-3333-3333-333333333333")))
      assertBool
        "a receipt for another database derived an expectation"
        (isLeft (escrowReceiptExpectation escrow prefix (signedReceipt (metadataFor "other" Nothing) keyBytes sourceUid)))
  ]
  where
    runId = "11111111-1111-1111-1111-111111111111"
    sourceUid = "22222222-2222-2222-2222-222222222222"
    keyBytes = BS.replicate 32 0xaa
    keyHex = T.replicate 64 "a"
    uid value = either (error . T.unpack) id (Resource.mkPhysicalIdentity value)
    escrow =
      SigningKeyEscrow
        { context = "fixture"
        , namespace = "personal"
        , database = "mydb"
        , format = "sql.gz"
        , signingSecretUid = uid "44444444-4444-4444-4444-444444444444"
        , statefulSetUid = uid sourceUid
        , pvcUid = uid sourceUid
        , hmacKey = keyHex
        }
    recoveryPoint = UTCTime (fromGregorian 2026 10 3) 3600
    metadataFor database objective =
      Aeson.object $
        [ "database" Aeson..= (database :: Text)
        , "namespace" Aeson..= ("personal" :: Text)
        , "engine" Aeson..= ("postgres" :: Text)
        , "format" Aeson..= ("sql.gz" :: Text)
        , "schedule" Aeson..= ("nagare-dbbackup-" <> database)
        , "scheduleRevision" Aeson..= T.replicate 64 "c"
        , "keep" Aeson..= (7 :: Int)
        ]
          <> ["recoveryPoint" Aeson..= (value :: Text) | Just value <- [objective]]
    hourlyMetadata = metadataFor "mydb" Nothing
    dailyMetadata = metadataFor "mydb" (Just "daily")
    signedReceipt metadata signingKey source =
      let canonical = either (error . T.unpack) id . canonicalValue
          payload =
            Aeson.object
              [ "sha256" Aeson..= Resource.digestText (contentDigest "archive")
              , "jobUid" Aeson..= runId
              , "object" Aeson..= ("gs://bucket/databases/mydb/" <> runId <> ".sql.gz")
              , "source" Aeson..= Aeson.object ["statefulSetUid" Aeson..= source, "pvcUid" Aeson..= source]
              , "backup" Aeson..= metadata
              , "recoveryPoint" Aeson..= ("2026-10-03T01:00:00Z" :: Text)
              ]
          signature = T.pack (show (hmacGetDigest (hmac signingKey (canonical payload) :: HMAC SHA256)))
       in LBS.toStrict
            ( Aeson.encode
                ( Aeson.object
                    [ "version" Aeson..= (5 :: Int)
                    , "payload" Aeson..= payload
                    , "hmacSha256" Aeson..= signature
                    ]
                )
            )
