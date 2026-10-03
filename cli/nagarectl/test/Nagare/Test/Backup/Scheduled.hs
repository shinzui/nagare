-- | Backup.Scheduled responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Backup.Scheduled
  ( scheduledReceiptTests
  )
where

import Control.Monad (forM_)
import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Data.Yaml qualified as Yaml
import Nagare.Database.Backup (renderInventoryDbBackupCronJob)
import Nagare.Database.Restore
  ( VerifiedRestoreSource
      ( VerifiedRestoreSource
      , backupSha256
      , expiryEpoch
      , objectVersion
      , receiptSha256
      , receiptUrl
      , receiptVersion
      , scratchDatabase
      )
  , downloadShell
  )
import Nagare.Dsl.Database (Engine (Postgres))
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Inventory.Backup
  ( ScheduledBackupReceipt
      ( ScheduledBackupReceipt
      , scheduledScheduleRevision
      , scheduledSha256
      )
  , ScheduledReceiptExpectation
    ( ScheduledReceiptExpectation
    , scheduledFormat
    , scheduledKeep
    , scheduledMetadataDigest
    , scheduledObjectPrefix
    , scheduledObjective
    )
  , scheduledReceiptExpectationFromCronJob
  )
import Nagare.Inventory.BackupFreshness
  ( BackupFreshness (..)
  , RecoveryPointGrade (RecoveryPointGrade)
  , RecoveryPointObjective (..)
  , backupFreshness
  , parseRecoveryPointObjective
  , recoveryPointDetail
  )
import Nagare.Inventory.ScheduledGcs (parseGcsObjectListing)
import Nagare.Inventory.ScheduledIngest
  ( ingestScriptFor
  , scheduledIngestEvidenceMatches
  , scheduledIngestJobSourcePins
  )
import Nagare.Inventory.ScheduledPrune
  ( ScheduledPruneCandidate (..)
  , selectScheduledPruneCandidates
  )
import Nagare.Inventory.ScheduledReceipt
  ( ScheduledReceiptEvidence (..)
  , classifyScheduledListingKeys
  , inspectScheduledReceipt
  , verifyAcceptedScheduledReceipt
  )
import Nagare.Inventory.ScheduledStore
  ( ListedObject (..)
  , ObjectReader (..)
  , StoredObject (..)
  , parseObjectEntries
  , parseObjectList
  , parseObjectStoreCredentials
  , parseObjectVersions
  , parseOfflineObjectStore
  )
import Nagare.Resource.Canonical (canonicalValue, contentDigest)
import Nagare.Resource.Inventory qualified as InventoryModel
import Nagare.Resource.Types qualified as Resource
import Nagare.Test.DataFixtures
  ( localMinioBackend
  , tnbGcsBackend
  )
import Nagare.Test.Support.Assertions (unsafe)
import System.Exit (ExitCode (ExitSuccess))
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

scheduledReceiptTests :: [TestTree]
scheduledReceiptTests =
  [ testCase "backup freshness uses the recovery point and warns before the one-hour breach" $ do
      let now = UTCTime (fromGregorian 2026 10 2) 43200
          ago seconds = addUTCTime (negate seconds) now
      backupFreshness HourlyRecoveryPoint now [] @?= NoRecoveryPoint
      backupFreshness HourlyRecoveryPoint now [ago 7200, ago 900] @?= Fresh 900
      backupFreshness HourlyRecoveryPoint now [ago 1800] @?= Deteriorating 1800
      backupFreshness HourlyRecoveryPoint now [ago 3599] @?= Deteriorating 3599
      backupFreshness HourlyRecoveryPoint now [ago 3600] @?= Breached 3600
      backupFreshness HourlyRecoveryPoint now [addUTCTime 1 now] @?= FutureRecoveryPoint
  , testCase "daily recovery-point objective warns at 25 hours and breaches at 26" $ do
      let now = UTCTime (fromGregorian 2026 10 2) 43200
          ago seconds = addUTCTime (negate seconds) now
      backupFreshness DailyRecoveryPoint now [ago 3600] @?= Fresh 3600
      backupFreshness DailyRecoveryPoint now [ago 89999] @?= Fresh 89999
      backupFreshness DailyRecoveryPoint now [ago 90000] @?= Deteriorating 90000
      backupFreshness DailyRecoveryPoint now [ago 93600] @?= Breached 93600
      map parseRecoveryPointObjective ["hourly", "daily"] @?= [Right HourlyRecoveryPoint, Right DailyRecoveryPoint]
      assertBool "an unknown objective was accepted" (isLeft (parseRecoveryPointObjective "weekly"))
      recoveryPointDetail (RecoveryPointGrade DailyRecoveryPoint (Fresh 600) True)
        @?= "healthy; age=600s; objective=daily; newest point is verified and awaits reviewed ingestion"
      recoveryPointDetail (RecoveryPointGrade HourlyRecoveryPoint (Breached 3600) False)
        @?= "unhealthy; age=3600s; hourly objective breached"
  , testCase "daily schedules bind their objective into signed metadata; hourly bytes are unchanged" $ do
      let decode bytes = either (error . show) id (Yaml.decodeEither' bytes :: Either Yaml.ParseException Aeson.Value)
          hourly = decode (renderInventoryDbBackupCronJob HourlyRecoveryPoint "personal" "mydb" Postgres "18" localMinioBackend 7)
          daily = decode (renderInventoryDbBackupCronJob DailyRecoveryPoint "personal" "mydb" Postgres "18" localMinioBackend 7)
          scheduleOf value = case value of
            Aeson.Object root
              | Just (Aeson.Object spec) <- KeyMap.lookup "spec" root ->
                  KeyMap.lookup "schedule" spec
            _ -> Nothing
          uid = either (error . T.unpack) id (Resource.mkPhysicalIdentity "22222222-2222-2222-2222-222222222222")
          expect value =
            scheduledReceiptExpectationFromCronJob
              localMinioBackend
              "personal"
              "mydb"
              uid
              uid
              (either (error . T.unpack) id (canonicalValue value))
      scheduleOf hourly @?= Just (Aeson.String "*/15 * * * *")
      scheduleOf daily @?= Just (Aeson.String "17 3 * * *")
      -- The parser accepts hourly metadata only with exactly the seven
      -- original fields, so this also proves hourly bytes did not change.
      fmap scheduledObjective (expect hourly) @?= Right HourlyRecoveryPoint
      fmap scheduledObjective (expect daily) @?= Right DailyRecoveryPoint
      let retimed = case daily of
            Aeson.Object root
              | Just (Aeson.Object spec) <- KeyMap.lookup "spec" root ->
                  Aeson.Object (KeyMap.insert "spec" (Aeson.Object (KeyMap.insert "schedule" (Aeson.String "*/15 * * * *") spec)) root)
            other -> other
      assertBool "a daily objective accepted an hourly cadence" (isLeft (expect retimed))
  , testCase "offline escrow verification accepts only a loopback store and a private credential file (F41)" $ do
      parseOfflineObjectStore "http://127.0.0.1:19000/" @?= Right "http://127.0.0.1:19000"
      parseOfflineObjectStore "http://localhost:9000" @?= Right "http://localhost:9000"
      forM_ ["https://127.0.0.1:9000", "http://minio.example.com:9000", "http://127.0.0.1", "http://127.0.0.1:9000/bucket", "http://127.0.0.1:x"] $ \endpoint ->
        assertBool ("non-loopback endpoint accepted: " <> T.unpack endpoint) (isLeft (parseOfflineObjectStore endpoint))
      parseObjectStoreCredentials "# copied\nAWS_ACCESS_KEY_ID=access\nAWS_SECRET_ACCESS_KEY=hidden-value\n" @?= Right "access:hidden-value"
      forM_ ["AWS_ACCESS_KEY_ID=a\n", "AWS_ACCESS_KEY_ID=a\nAWS_SECRET_ACCESS_KEY=b\nAWS_SECRET_ACCESS_KEY=c\n", "AWS_ACCESS_KEY_ID=a\nAWS_SECRET_ACCESS_KEY=b\nOTHER=c\n", "AWS_ACCESS_KEY_ID=a\nAWS_SECRET_ACCESS_KEY=\"b\"\n"] $ \bytes ->
        case parseObjectStoreCredentials bytes of
          Left reason -> assertBool "credential parse error echoed a value" (not (any (`T.isInfixOf` reason) ["=a", "=b", "=c"]))
          Right _ -> assertFailure ("malformed credentials accepted: " <> BC.unpack bytes)
  , testCase "scheduled GCS listing validates complete provider identities" $ do
      let entry :: Text -> Text -> Text -> Aeson.Value
          entry bucket name generation =
            Aeson.object
              [ "bucket" Aeson..= bucket
              , "name" Aeson..= name
              , "generation" Aeson..= generation
              , "size" Aeson..= ("12" :: Text)
              , "updated" Aeson..= ("2026-10-02T12:00:00.123Z" :: Text)
              ]
          good = entry "backups" "databases/mydb/run.sql.gz" "123"
          parse values =
            parseGcsObjectListing
              "backups"
              "databases/mydb/"
              (LBS.toStrict (Aeson.encode values))
      fmap (map listedKey) (parse [good]) @?= Right ["databases/mydb/run.sql.gz"]
      let withOffset = case good of
            Aeson.Object fields -> Aeson.Object (KeyMap.insert "updated" (Aeson.String "2026-10-02T12:00:00.123000+00:00") fields)
            other -> other
      parse [withOffset] @?= parse [good]
      parse ([] :: [Aeson.Value]) @?= Right []
      forM_
        [ [good, good]
        , [entry "foreign" "databases/mydb/run.sql.gz" "123"]
        , [entry "backups" "databases/other/run.sql.gz" "123"]
        , [entry "backups" "databases/mydb/run.sql.gz" "0"]
        , [Aeson.object ["name" Aeson..= ("databases/mydb/run.sql.gz" :: Text)]]
        ]
        $ \bad ->
          assertBool "incomplete or foreign GCS listing accepted" (isLeft (parse bad))
  , testCase "scheduled GCS ingestion executes fixed-generation checks and rejects changed bytes" $ do
      (status, _, errors) <-
        readProcessWithExitCode
          "python3"
          ["test/fixtures/scheduled-gcs-ingest.py"]
          (T.unpack (ingestScriptFor tnbGcsBackend))
      assertBool errors (status == ExitSuccess)
  , testCase "scheduled backup receipt expectation comes from accepted CronJob bytes" $ do
      let rendered = renderInventoryDbBackupCronJob HourlyRecoveryPoint "personal" "mydb" Postgres "18" localMinioBackend 7
          value = either (error . show) id (Yaml.decodeEither' rendered :: Either Yaml.ParseException Aeson.Value)
          native = either (error . T.unpack) id (canonicalValue value)
          uid =
            either
              (error . T.unpack)
              id
              (Resource.mkPhysicalIdentity "22222222-2222-2222-2222-222222222222")
          expectation =
            scheduledReceiptExpectationFromCronJob
              localMinioBackend
              "personal"
              "mydb"
              uid
              uid
              native
      case expectation of
        Left reason -> assertFailure ("accepted schedule was rejected: " <> T.unpack reason)
        Right checked -> do
          scheduledObjectPrefix checked @?= "s3://nagare-backups/databases/mydb/"
          scheduledFormat checked @?= "sql.gz"
          scheduledKeep checked @?= 7
      assertBool
        "wrong backend can authorize schedule"
        ( isLeft
            ( scheduledReceiptExpectationFromCronJob
                tnbGcsBackend
                "personal"
                "mydb"
                uid
                uid
                native
            )
        )
      assertBool
        "wrong source name can authorize schedule"
        ( isLeft
            ( scheduledReceiptExpectationFromCronJob
                localMinioBackend
                "personal"
                "other"
                uid
                uid
                native
            )
        )
      let zeroRendered =
            renderInventoryDbBackupCronJob
              HourlyRecoveryPoint
              "personal"
              "mydb"
              Postgres
              "18"
              localMinioBackend
              0
          zeroValue =
            either
              (error . show)
              id
              (Yaml.decodeEither' zeroRendered :: Either Yaml.ParseException Aeson.Value)
          zeroNative = either (error . T.unpack) id (canonicalValue zeroValue)
      assertBool
        "zero retention was accepted"
        ( isLeft
            ( scheduledReceiptExpectationFromCronJob
                localMinioBackend
                "personal"
                "mydb"
                uid
                uid
                zeroNative
            )
        )
  , testCase "scheduled backup inspection binds exact receipt and object versions" $ do
      let runId = "11111111-1111-1111-1111-111111111111"
          sourceUid = "22222222-2222-2222-2222-222222222222"
          objectAddress = "s3://nagare-backups/databases/mydb/" <> runId <> ".sql.gz"
          receiptAddress = objectAddress <> ".receipt.json"
          objectBytes = "scheduled-backup-bytes"
          objectSha = Resource.digestText (contentDigest objectBytes)
          metadata =
            Aeson.object
              [ "database" Aeson..= ("mydb" :: Text)
              , "namespace" Aeson..= ("personal" :: Text)
              , "engine" Aeson..= ("postgres" :: Text)
              , "format" Aeson..= ("sql.gz" :: Text)
              , "schedule" Aeson..= ("nagare-dbbackup-mydb" :: Text)
              , "scheduleRevision" Aeson..= T.replicate 64 "a"
              , "keep" Aeson..= (7 :: Int)
              ]
          canonical = either (error . T.unpack) id . canonicalValue
          payload =
            Aeson.object
              [ "sha256" Aeson..= objectSha
              , "jobUid" Aeson..= runId
              , "object" Aeson..= objectAddress
              , "source"
                  Aeson..= Aeson.object
                    [ "statefulSetUid" Aeson..= sourceUid
                    , "pvcUid" Aeson..= sourceUid
                    ]
              , "backup" Aeson..= metadata
              ]
          signingBytes = BS.replicate 32 0xaa
          signature =
            T.pack
              ( show
                  ( hmacGetDigest
                      (hmac signingBytes (canonical payload) :: HMAC SHA256)
                  )
              )
          receiptBytes =
            LBS.toStrict
              ( Aeson.encode
                  ( Aeson.object
                      [ "version" Aeson..= (4 :: Int)
                      , "payload" Aeson..= payload
                      , "hmacSha256" Aeson..= signature
                      ]
                  )
              )
          uid = either (error . T.unpack) id (Resource.mkPhysicalIdentity sourceUid)
          expectation =
            ScheduledReceiptExpectation
              "s3://nagare-backups/databases/mydb/"
              "sql.gz"
              7
              (contentDigest (canonical metadata))
              (contentDigest (canonical metadata))
              uid
              uid
              HourlyRecoveryPoint
          reader changeExactReceipt changeExactObject =
            ObjectReader
              ( \address selected path -> do
                  let (version, bytes) =
                        if address == receiptAddress
                          then
                            ( "receipt-version"
                            , if changeExactReceipt
                                && selected == Just "receipt-version"
                                then BS.map (+ 1) receiptBytes
                                else receiptBytes
                            )
                          else
                            ( "object-version"
                            , if changeExactObject
                                && selected == Just "object-version"
                                then BS.map (+ 1) objectBytes
                                else objectBytes
                            )
                  if address `notElem` [objectAddress, receiptAddress]
                    || maybe False (/= version) selected
                    then pure (Left "missing exact object")
                    else do
                      BS.writeFile path bytes
                      pure (Right (StoredObject version (fromIntegral (BS.length bytes))))
              )
              (\_ -> pure (Left "listing is unused by this test"))
              (\_ -> pure (Left "timestamp listing is unused by this test"))
              (\_ -> pure (Left "version listing is unused by this test"))
      verified <- inspectScheduledReceipt (reader False False) expectation runId (T.replicate 64 "a")
      case verified of
        Left reason -> assertFailure ("exact scheduled backup was rejected: " <> T.unpack reason)
        Right evidence -> do
          scheduledObjectVersion evidence @?= "object-version"
          scheduledReceiptVersion evidence @?= "receipt-version"
          scheduledSha256 (scheduledReceipt evidence) @?= objectSha
      changedReceipt <- inspectScheduledReceipt (reader True False) expectation runId (T.replicate 64 "a")
      assertBool "changed receipt version bytes were accepted" (isLeft changedReceipt)
      changedObject <- inspectScheduledReceipt (reader False True) expectation runId (T.replicate 64 "a")
      assertBool "changed backup version bytes were accepted" (isLeft changedObject)
      let acceptedScope =
            InventoryModel.withScopeOverrides
              ( Map.fromList
                  [ ("scheduled.backup.object", objectAddress)
                  , ("scheduled.backup.object.version", "object-version")
                  , ("scheduled.backup.object.length", T.pack (show (BS.length objectBytes)))
                  , ("scheduled.backup.object.sha256", objectSha)
                  , ("scheduled.backup.receipt", receiptAddress)
                  , ("scheduled.backup.receipt.version", "receipt-version")
                  , ("scheduled.backup.receipt.length", T.pack (show (BS.length receiptBytes)))
                  ,
                    ( "scheduled.backup.receipt.digest"
                    , Resource.digestText
                        (contentDigest receiptBytes)
                    )
                  ]
              )
              ( either
                  (error . show)
                  id
                  ( InventoryModel.mkScopeDeclaration
                      (unsafe (Resource.mkScopeId Resource.Standalone "accepted-scheduled-run"))
                      []
                  )
              )
          revisedSchedule =
            expectation
              { scheduledMetadataDigest = contentDigest "new schedule metadata"
              }
      assertBool "old receipt matched changed schedule metadata" . isLeft
        =<< inspectScheduledReceipt (reader False False) revisedSchedule runId (T.replicate 64 "a")
      historical <-
        verifyAcceptedScheduledReceipt
          (reader False False)
          objectAddress
          acceptedScope
      historical @?= Right ()
      assertBool "changed accepted receipt bytes were accepted" . isLeft
        =<< verifyAcceptedScheduledReceipt (reader True False) objectAddress acceptedScope
      assertBool "changed accepted object bytes were accepted" . isLeft
        =<< verifyAcceptedScheduledReceipt (reader False True) objectAddress acceptedScope
      assertBool "another listed object used accepted receipt pins" . isLeft
        =<< verifyAcceptedScheduledReceipt
          (reader False False)
          (objectAddress <> "-other")
          acceptedScope
      let keyPrefix = "databases/mydb/"
          oldObjectKey = keyPrefix <> runId <> ".sql.gz"
          oldReceiptKey = oldObjectKey <> ".receipt.json"
          extraKey = keyPrefix <> runId <> ".zip.gz"
          newKey = keyPrefix <> "another-run.zip.gz"
          (recognized, unknown) =
            classifyScheduledListingKeys
              "s3://nagare-backups/"
              keyPrefix
              "zip.gz"
              (Map.singleton runId acceptedScope)
              [oldObjectKey, oldReceiptKey, extraKey, newKey]
      recognized @?= [(runId, True), (runId, False), ("another-run", True)]
      unknown @?= [extraKey]
  , testCase "scheduled backup listing refuses incomplete provider pages" $ do
      let prefix = "databases/mydb/"
          key = prefix <> "11111111-1111-1111-1111-111111111111.sql.gz"
          response truncated count contents =
            BC.pack
              ( "<ListBucketResult><IsTruncated>"
                  <> truncated
                  <> "</IsTruncated><KeyCount>"
                  <> count
                  <> "</KeyCount>"
                  <> contents
                  <> "</ListBucketResult>"
              )
          item = "<Contents><Key>" <> T.unpack key <> "</Key></Contents>"
      parseObjectList prefix (response "false" "1" item) @?= Right [key]
      assertBool
        "a truncated listing hid another object"
        ( isLeft
            (parseObjectList prefix (response "true" "1" item))
        )
      assertBool
        "a wrong key count hid another object"
        ( isLeft
            (parseObjectList prefix (response "false" "2" item))
        )
      assertBool
        "a duplicate key was accepted"
        ( isLeft
            (parseObjectList prefix (response "false" "2" (item <> item)))
        )
      let dated =
            "<Contents><Key>"
              <> T.unpack key
              <> "</Key><LastModified>2026-09-27T23:16:27.123Z</LastModified></Contents>"
      case parseObjectEntries prefix (response "false" "1" dated) of
        Right [entry] -> listedKey entry @?= key
        other -> assertFailure ("dated listing was rejected: " <> show other)
      assertBool
        "missing provider modification time was accepted for retention"
        (isLeft (parseObjectEntries prefix (response "false" "1" item)))
      assertBool
        "malformed provider modification time was accepted for retention"
        ( isLeft
            ( parseObjectEntries
                prefix
                ( response
                    "false"
                    "1"
                    ( "<Contents><Key>"
                        <> T.unpack key
                        <> "</Key><LastModified>yesterday</LastModified></Contents>"
                    )
                )
            )
        )
  , testCase "scheduled recovery proves exact object-version absence from a complete list" $ do
      let prefix = "databases/mydb/"
          objectKey = prefix <> "backup.rdb.gz"
          receiptKey = objectKey <> ".receipt.json"
          entry name key version =
            "<"
              <> name
              <> "><Key>"
              <> key
              <> "</Key><VersionId>"
              <> version
              <> "</VersionId></"
              <> name
              <> ">"
          response truncated body =
            TE.encodeUtf8
              ( "<ListVersionsResult><IsTruncated>"
                  <> truncated
                  <> "</IsTruncated>"
                  <> body
                  <> "</ListVersionsResult>"
              )
          receiptVersion = entry "Version" receiptKey "receipt-v1"
          deletedMarker = entry "DeleteMarker" objectKey "marker-v1"
      parseObjectVersions
        prefix
        ( response
            "false"
            (receiptVersion <> deletedMarker)
        )
        @?= Right [(receiptKey, "receipt-v1"), (objectKey, "marker-v1")]
      assertBool
        "truncated version list proved object absence"
        ( isLeft
            (parseObjectVersions prefix (response "true" receiptVersion))
        )
      assertBool
        "duplicate version was accepted"
        ( isLeft
            ( parseObjectVersions
                prefix
                ( response
                    "false"
                    (receiptVersion <> receiptVersion)
                )
            )
        )
      assertBool
        "missing version ID was accepted"
        ( isLeft
            ( parseObjectVersions
                prefix
                ( response
                    "false"
                    (entry "Version" objectKey "")
                )
            )
        )
  , testCase "scheduled listing accepts only its pinned provider receipt" $ do
      let runId = "11111111-1111-1111-1111-111111111111"
          object = "s3://backups/databases/mydb/" <> runId <> ".sql.gz"
          receipt =
            ScheduledBackupReceipt
              (unsafe (Resource.mkPhysicalIdentity runId))
              object
              (T.replicate 64 "a")
              (contentDigest "schedule revision")
              Nothing
          evidence =
            ScheduledReceiptEvidence
              receipt
              "object-v1"
              "receipt-v1"
              123
              456
              (contentDigest "receipt bytes")
          pins =
            Map.fromList
              [ ("scheduled.backup.id", runId)
              , ("scheduled.backup.object", object)
              , ("scheduled.backup.object.version", "object-v1")
              , ("scheduled.backup.object.length", "123")
              , ("scheduled.backup.object.sha256", T.replicate 64 "a")
              , ("scheduled.backup.receipt", object <> ".receipt.json")
              , ("scheduled.backup.receipt.version", "receipt-v1")
              , ("scheduled.backup.receipt.length", "456")
              ,
                ( "scheduled.backup.receipt.digest"
                , Resource.digestText
                    (scheduledReceiptDigest evidence)
                )
              ,
                ( "scheduled.backup.schedule.revision"
                , Resource.digestText
                    (scheduledScheduleRevision receipt)
                )
              ]
          scope values =
            InventoryModel.withScopeOverrides
              values
              ( either
                  (error . show)
                  id
                  ( InventoryModel.mkScopeDeclaration
                      (unsafe (Resource.mkScopeId Resource.Standalone "scheduled-listing"))
                      []
                  )
              )
      assertBool
        "exact accepted receipt was unresolved"
        (scheduledIngestEvidenceMatches (scope pins) evidence)
      forM_ (Map.keys pins) $ \key ->
        assertBool
          ("changed accepted pin was trusted: " <> T.unpack key)
          ( not
              ( scheduledIngestEvidenceMatches
                  (scope (Map.insert key "changed" pins))
                  evidence
              )
          )
  , testCase "scheduled prune selects only older accepted exact pairs" $ do
      let source = unsafe (Resource.mkScopeId Resource.Standalone "scheduled-prune-source")
          oldId = "11111111-1111-1111-1111-111111111111"
          newId = "22222222-2222-2222-2222-222222222222"
          newestId = "33333333-3333-3333-3333-333333333333"
          bucketAddress = "s3://backups/"
          keyPrefix = "databases/mydb/"
          objectPrefix = bucketAddress <> keyPrefix
          objectKey runId = keyPrefix <> runId <> ".sql.gz"
          receiptKey runId = objectKey runId <> ".receipt.json"
          completedAt seconds =
            UTCTime
              (fromGregorian 2026 9 27)
              (secondsToDiffTime seconds)
          scope runId =
            InventoryModel.withScopeOverrides
              ( Map.fromList
                  [ ("scheduled.backup.source.scope", Resource.scopeIdText source)
                  , ("scheduled.backup.id", runId)
                  , ("scheduled.backup.object", bucketAddress <> objectKey runId)
                  , ("scheduled.backup.object.version", "object-version-" <> runId)
                  , ("scheduled.backup.object.length", "123")
                  , ("scheduled.backup.object.sha256", T.replicate 64 "a")
                  , ("scheduled.backup.receipt", bucketAddress <> receiptKey runId)
                  , ("scheduled.backup.receipt.version", "receipt-version-" <> runId)
                  , ("scheduled.backup.receipt.length", "456")
                  , ("scheduled.backup.receipt.digest", T.replicate 64 "b")
                  ]
              )
              ( either
                  (error . show)
                  id
                  ( InventoryModel.mkScopeDeclaration
                      ( unsafe
                          ( Resource.mkScopeId
                              Resource.Standalone
                              ("scheduled-receipt-" <> runId)
                          )
                      )
                      []
                  )
              )
          oldScope = scope oldId
          newScope = scope newId
          newestScope = scope newestId
          listed =
            [ ListedObject (objectKey oldId) (completedAt 1)
            , ListedObject (receiptKey oldId) (completedAt 2)
            , ListedObject (objectKey newId) (completedAt 3)
            , ListedObject (receiptKey newId) (completedAt 4)
            ]
          select protected scopes entries =
            selectScheduledPruneCandidates
              source
              bucketAddress
              objectPrefix
              "sql.gz"
              1
              protected
              scopes
              entries
      case select Set.empty [oldScope, newScope] listed of
        Right [candidate] -> do
          scheduledPruneId candidate @?= oldId
          scheduledPruneObjectVersion candidate @?= "object-version-" <> oldId
          scheduledPruneReceiptVersion candidate @?= "receipt-version-" <> oldId
        other -> assertFailure ("exact retention candidate was rejected: " <> show other)
      assertBool
        "an unknown object passed the complete-listing guard"
        ( isLeft
            ( select
                Set.empty
                [oldScope, newScope]
                (listed <> [ListedObject (keyPrefix <> "stray") (completedAt 5)])
            )
        )
      assertBool
        "a missing receipt passed the complete-listing guard"
        ( isLeft
            (select Set.empty [oldScope, newScope] (init listed))
        )
      let protected =
            Set.singleton
              ( Resource.scopeIdText
                  (InventoryModel.scopeId oldScope)
              )
      select protected [oldScope, newScope] listed @?= Right []
      let third =
            listed
              <> [ ListedObject (objectKey newestId) (completedAt 5)
                 , ListedObject (receiptKey newestId) (completedAt 6)
                 ]
      case select protected [oldScope, newScope, newestScope] third of
        Right [candidate] -> scheduledPruneId candidate @?= newId
        other ->
          assertFailure
            ( "protected run hid an independent candidate: "
                <> show other
            )
      case select
        Set.empty
        [oldScope, newScope]
        ( take 2 listed
            <> [ ListedObject (objectKey newId) (completedAt 2)
               , ListedObject (receiptKey newId) (completedAt 2)
               ]
        ) of
        Left reason ->
          assertBool
            "tie failed for an unrelated reason"
            ("tie across" `T.isInfixOf` reason)
        Right _ -> assertFailure "equal completion times crossed the keep boundary"
  , testCase "scheduled backup ingestion requires all four source UID pins" $ do
      let sourceId = "application:demo/database/statefulset" :: Text
          sourceUid = "22222222-2222-2222-2222-222222222222" :: Text
          annotations =
            KeyMap.fromList
              [ ("nagare.dev/scheduled-receipt-id", Aeson.String "11111111-1111-1111-1111-111111111111")
              , ("nagare.dev/scheduled-receipt-source-statefulset", Aeson.String sourceId)
              , ("nagare.dev/scheduled-receipt-source-statefulset-uid", Aeson.String sourceUid)
              , ("nagare.dev/scheduled-receipt-source-pvc", Aeson.String "application:demo/database/pvc")
              , ("nagare.dev/scheduled-receipt-source-pvc-uid", Aeson.String sourceUid)
              , ("nagare.dev/scheduled-receipt-schedule", Aeson.String "application:demo/database/backup")
              , ("nagare.dev/scheduled-receipt-schedule-uid", Aeson.String sourceUid)
              , ("nagare.dev/scheduled-receipt-signing", Aeson.String "application:demo/database/signing")
              , ("nagare.dev/scheduled-receipt-signing-uid", Aeson.String sourceUid)
              ]
          job fields =
            LBS.toStrict
              ( Aeson.encode
                  ( Aeson.object
                      [ "kind" Aeson..= ("Job" :: Text)
                      , "metadata" Aeson..= Aeson.object ["annotations" Aeson..= Aeson.Object fields]
                      ]
                  )
              )
      case scheduledIngestJobSourcePins (job annotations) of
        Right (Just pins) -> length pins @?= 4
        other -> assertFailure ("complete scheduled source pins were rejected: " <> show other)
      assertBool
        "partial scheduled source pins were accepted"
        ( isLeft
            ( scheduledIngestJobSourcePins
                ( job
                    (KeyMap.delete "nagare.dev/scheduled-receipt-signing-uid" annotations)
                )
            )
        )
  , testCase "scheduled backup restore downloads exact MinIO versions" $ do
      let checked =
            VerifiedRestoreSource
              { receiptUrl = "s3://nagare-backups/databases/mydb/run.sql.gz.receipt.json"
              , receiptSha256 = T.replicate 64 "a"
              , backupSha256 = T.replicate 64 "b"
              , scratchDatabase = "mydb_restore_run"
              , expiryEpoch = 0
              , objectVersion = Just "object-version"
              , receiptVersion = Just "receipt-version"
              }
          script = downloadShell localMinioBackend Postgres (Just checked)
      assertBool
        "receipt exact version is not requested"
        ("--key \"$RECEIPT_KEY\" --version-id \"$RECEIPT_VERSION\"" `T.isInfixOf` script)
      assertBool
        "backup exact version is not requested"
        ("--key \"$OBJECT_KEY\" --version-id \"$OBJECT_VERSION\"" `T.isInfixOf` script)
      assertBool
        "returned provider versions are not checked"
        ( "receipt-response.json" `T.isInfixOf` script
            && "object-response.json" `T.isInfixOf` script
        )
      assertBool
        "partial version selection is accepted"
        ( downloadShell
            localMinioBackend
            Postgres
            (Just (checked {receiptVersion = Nothing}))
            == "exit 1"
        )
  ]
