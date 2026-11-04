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
import Nagare.Database.Secret (b64encode)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Inventory.Adapters.CredentialTemplate (materializeCredentialWith, materializeLocalObjectStoreCredentialWith)
import Nagare.Inventory.Backup
  ( ScheduledBackupReceipt (..)
  , ScheduledReceiptExpectation (scheduledObjective)
  , parseScheduledBackupReceipt
  )
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), runKubectlWith, withKubectlInterpreter)
import Nagare.Inventory.ShomeiKeyEscrow
import Nagare.Inventory.SigningKeyEscrow
import Nagare.Resource.Canonical (canonicalValue, contentDigest)
import Nagare.Resource.Types qualified as Resource
import Nagare.Test.Support.Environment (withTestEnv)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

signingKeyEscrowTests :: [TestTree]
signingKeyEscrowTests =
  [ testCase "F146: Shomei's key escrow round-trips and never shows its key" $ do
      let stored = ShomeiKeyEscrow "ctx" shomeiKey
      parseShomeiKeyEscrow (renderShomeiKeyEscrow stored) @?= Right stored
      assertBool "escrow Show leaked the key" (not (shomeiKey `T.isInfixOf` T.pack (show stored)))
      assertBool
        "a short key was accepted"
        (isLeft (parseShomeiKeyEscrow (renderShomeiKeyEscrow stored {keyEncryptionKey = "abc="})))
      assertBool
        "an escrow with an extra field was accepted"
        (isLeft (parseShomeiKeyEscrow (renderShomeiKeyEscrow stored <> "extra: field\n")))
  , testCase "F146: a recreated Shomei Secret takes the escrowed key" $ do
      let escrowed = pure (Right (Just shomeiKey))
      created <- materializeCredentialWith escrowed (authTemplate "nagare-shomei-keys") >>= either (assertFailure . T.unpack) pure
      assertBool "the Secret did not hold the escrowed key" (b64encode shomeiKey `T.isInfixOf` created)
      generated <- materializeCredentialWith (pure (Right Nothing)) (authTemplate "nagare-shomei-keys") >>= either (assertFailure . T.unpack) pure
      assertBool "no escrow still used a key" (not (b64encode shomeiKey `T.isInfixOf` generated))
      unreadable <- materializeCredentialWith (pure (Left "cannot decrypt")) (authTemplate "nagare-shomei-keys")
      unreadable @?= Left "cannot decrypt"
      other <- materializeCredentialWith (pure (Left "must not be read")) (authTemplate "nagare-access")
      assertBool "another auth Secret read the escrow" (not (isLeft other))
  , testCase "F146: a real apply's cached runtime still reads the escrow" $
      withSystemTempDirectory "shomei-escrow" $ \root -> withTestEnv [("XDG_CONFIG_HOME", Just root)] $ do
        path <- shomeiKeyEscrowPath "escrow-context"
        createDirectoryIfMissing True (takeDirectory path)
        BS.writeFile path "not an encrypted escrow\n"
        let live = KubernetesRuntimeConfig (either (error . T.unpack) id (Resource.mkContextId "escrow-context")) "escrow-context" (pure (Right ()))
            cached = withKubectlInterpreter (runKubectlWith (\_ -> pure (Left "must not read Kubernetes"))) live
        refused <-
          materializeLocalObjectStoreCredentialWith
            (pure (Left "must not read the object store's Secret"))
            cached
            (authTemplate "nagare-shomei-keys")
        assertBool "an unreadable escrow was replaced with a new key" (isLeft refused)
  , testCase "a replaced database's escrow keeps the old one; a changed key is refused" $ do
      let replaced = escrow {pvcUid = otherUid, hmacKey = T.replicate 64 "b"}
      escrowDecision escrow escrow @?= AlreadyEscrowed
      escrowDecision escrow replaced @?= KeepPrevious
      escrowDecision escrow escrow {hmacKey = T.replicate 64 "b"} @?= DifferentEscrow
      escrowDecision escrow replaced {database = "other"} @?= DifferentEscrow
      archivedEscrowPath "/s/nagare-system-en-db.sops.yaml" escrow
        @?= "/s/nagare-system-en-db." <> T.unpack (Resource.physicalIdentityText (pvcUid escrow)) <> ".sops.yaml"
  , testCase "signing-key escrow round-trips and never shows its key" $ do
      parseSigningKeyEscrow (renderSigningKeyEscrow escrow) @?= Right escrow
      assertBool "escrow Show leaked the key" (not (keyHex `T.isInfixOf` T.pack (show escrow)))
      assertBool
        "an escrow with an extra field was accepted"
        (isLeft (parseSigningKeyEscrow (renderSigningKeyEscrow escrow <> "extra: field\n")))
      assertBool
        "a short key was accepted"
        (isLeft (parseSigningKeyEscrow (renderSigningKeyEscrow escrow {hmacKey = "abc"})))
  , testCase "F145: an escrow written before app databases still reads as a server's" $ do
      let current = TE.decodeUtf8 (renderSigningKeyEscrow escrow)
      assertBool "a server's escrow gained a field" (not ("source:" `T.isInfixOf` current))
      fmap sourceKind (parseSigningKeyEscrow (renderSigningKeyEscrow escrow)) @?= Right DatabaseEscrow
  , testCase "F145: an app database's escrow round-trips and keeps to its own key space" $ do
      parseSigningKeyEscrow (renderSigningKeyEscrow appEscrow) @?= Right appEscrow
      assertBool
        "another source was accepted"
        (isLeft (parseSigningKeyEscrow (TE.encodeUtf8 (T.replace "appDatabase" "other" (TE.decodeUtf8 (renderSigningKeyEscrow appEscrow))))))
      escrowObjectPrefix appEscrow @?= "app-databases/personal/kansoku-pg/"
      escrowObjectPrefix escrow @?= "databases/mydb/"
      escrowDecision appEscrow appEscrow {pvcUid = otherUid} @?= KeepPrevious
      escrowDecision escrow escrow {sourceKind = AppDatabaseEscrow, pvcUid = otherUid} @?= DifferentEscrow
  , testCase "F145: an app database's escrow verifies its own receipts and refuses others" $ do
      let prefix = "gs://bucket/" <> escrowObjectPrefix appEscrow
          address = prefix <> runId <> ".dump.gz.receipt.json"
          bytes = signedReceiptAt (prefix <> runId <> ".dump.gz") (appMetadata "kansoku-pg") keyBytes sourceUid
      expectation <- either (assertFailure . T.unpack) pure (escrowReceiptExpectation appEscrow prefix bytes)
      receipt <- either (assertFailure . T.unpack) pure (parseScheduledBackupReceipt expectation address keyHex bytes)
      scheduledRecoveryPoint receipt @?= Just recoveryPoint
      assertBool
        "another app database's receipt was accepted"
        (isLeft (escrowReceiptExpectation appEscrow prefix (signedReceipt (appMetadata "kansoku-ch") keyBytes sourceUid)))
      assertBool
        "a server's receipt was accepted"
        (isLeft (escrowReceiptExpectation appEscrow prefix (signedReceipt hourlyMetadata keyBytes sourceUid)))
      assertBool
        "an app database's receipt verified under a server's escrow"
        (isLeft (escrowReceiptExpectation escrow prefix bytes))
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
        , sourceKind = DatabaseEscrow
        }
    appEscrow = escrow {database = "kansoku-pg", format = "dump.gz", sourceKind = AppDatabaseEscrow}
    appMetadata name =
      Aeson.object
        [ "appDatabase" Aeson..= (name :: T.Text)
        , "server" Aeson..= ("labs-postgres" :: T.Text)
        , "databases" Aeson..= (["kansoku"] :: [T.Text])
        , "declaration" Aeson..= digest
        , "namespace" Aeson..= ("personal" :: T.Text)
        , "engine" Aeson..= ("postgres" :: T.Text)
        , "format" Aeson..= ("dump.gz" :: T.Text)
        , "schedule" Aeson..= ("nagare-appdb-" <> name)
        , "scheduleRevision" Aeson..= digest
        , "keep" Aeson..= (7 :: Int)
        ]
    digest = T.replicate 64 "c"
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
    shomeiKey = T.replicate 43 "k" <> "="
    otherUid = either (error . T.unpack) id (Resource.mkPhysicalIdentity "55555555-5555-5555-5555-555555555555")
    authTemplate name =
      "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"annotations\":{\"nagare.dev/auth-credential-template\":\"v1\"},\"name\":\""
        <> name
        <> "\",\"namespace\":\"nagare-system\"},\"type\":\"Opaque\"}"
    signedReceipt = signedReceiptAt ("gs://bucket/databases/mydb/" <> runId <> ".sql.gz")
    signedReceiptAt object metadata signingKey source =
      let canonical = either (error . T.unpack) id . canonicalValue
          payload =
            Aeson.object
              [ "sha256" Aeson..= Resource.digestText (contentDigest "archive")
              , "jobUid" Aeson..= runId
              , "object" Aeson..= (object :: Text)
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
