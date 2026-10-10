-- | Decode and authenticate exact manual and scheduled backup receipts.
module Nagare.Inventory.BackupReceipt
  ( BackupReceiptExpectation (..)
  , ScheduledReceiptExpectation (..)
  , ScheduledBackupReceipt (..)
  , scheduledReceiptExpectationFromCronJob
  , scheduledVolumeReceiptExpectationFromCronJob
  , scheduleMetadataObjective
  , manualBackupJobReceiptExpectation
  , parseBackupReceipt
  , parseManualBackupReceipt
  , parseScheduledBackupReceipt
  )
where

import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict, fromJSON)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (digitToInt)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Vector qualified as V
import Nagare.Cluster.GcsJob (StoreBackend, storePrefixUrl)
import Nagare.Database.Backup (backupExt, dbBackupKeyPrefix, volumeBackupFormat, volumeBackupKeyPrefix, volumeBackupScheduleName)
import Nagare.Dsl.Database (parseEngine)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName)
import Nagare.Inventory.BackupFreshness
  ( RecoveryPointObjective (HourlyRecoveryPoint)
  , parseRecoveryPointObjective
  , recoveryPointSchedule
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory (ScopeDeclaration, scopeOverrides)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data BackupReceiptExpectation = BackupReceiptExpectation
  { receiptObjectAddress :: !T.Text
  , receiptAddress :: !T.Text
  , receiptMetadataDigest :: !ContentDigest
  }
  deriving stock (Eq, Show)

-- | Values derived from one accepted CronJob's bound native template and an
-- observed source incarnation. A receipt under a prefix is not authority by
-- itself; the caller must independently prove this expectation and the private
-- signing key belong to accepted schedule history.
data ScheduledReceiptExpectation = ScheduledReceiptExpectation
  { scheduledObjectPrefix :: !T.Text
  , scheduledFormat :: !T.Text
  , scheduledKeep :: !Int
  , scheduledPolicyRevision :: !ContentDigest
  , scheduledMetadataDigest :: !ContentDigest
  , scheduledStatefulUid :: !(Maybe PhysicalIdentity)
  -- ^ a database's StatefulSet; 'Nothing' for a volume, whose source is its claim alone
  , scheduledPvcUid :: !PhysicalIdentity
  , scheduledObjective :: !RecoveryPointObjective
  }
  deriving stock (Eq, Show)

data ScheduledBackupReceipt = ScheduledBackupReceipt
  { scheduledJobUid :: !PhysicalIdentity
  , scheduledObjectAddress :: !T.Text
  , scheduledSha256 :: !T.Text
  , scheduledScheduleRevision :: !ContentDigest
  , scheduledRecoveryPoint :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

-- | Derive receipt authority from the exact native bytes retained for an
-- accepted schedule. The caller separately proves that these bytes belong to
-- accepted history, that the signing Secret is accepted, and that the two
-- observed source UIDs are the intended incarnation. In particular, a receipt
-- cannot supply its own metadata expectation or object prefix.
scheduledReceiptExpectationFromCronJob ::
  StoreBackend ->
  T.Text ->
  T.Text ->
  PhysicalIdentity ->
  PhysicalIdentity ->
  ByteString ->
  Either T.Text ScheduledReceiptExpectation
scheduledReceiptExpectationFromCronJob backend namespaceName database statefulUid pvcUid =
  scheduledExpectationWith ("nagare-dbbackup-" <> database) namespaceName (Just statefulUid) pvcUid $ \plain fields -> do
    prefix <- plain "PREFIX"
    unless
      (prefix == storePrefixUrl backend (dbBackupKeyPrefix database))
      (Left "accepted scheduled backup uses another object key space")
    sourceName <- plain "BACKUP_SOURCE_NAME"
    unless
      (sourceName == database)
      (Left "accepted scheduled backup probes another source")
    case fields of
      _
        | KM.lookup "database" fields == Just (String database)
        , Just (String engineName) <- KM.lookup "engine" fields
        , Just (String extension) <- KM.lookup "format" fields
        , Just engine <- parseEngine engineName
        , extension == backupExt engine ->
            Right (prefix, extension)
      _ -> Left "accepted scheduled backup has invalid receipt metadata"

-- | The volume form of 'scheduledReceiptExpectationFromCronJob' (EP-183 M3).
-- The accepted CronJob's own metadata names its app and volume; the schedule
-- name, key space and probed claim must all be the ones derived from them, so
-- a receipt can no more choose its volume than its prefix.
scheduledVolumeReceiptExpectationFromCronJob ::
  StoreBackend ->
  T.Text ->
  T.Text ->
  PhysicalIdentity ->
  ByteString ->
  Either T.Text ScheduledReceiptExpectation
scheduledVolumeReceiptExpectationFromCronJob backend namespaceName schedule pvcUid =
  scheduledExpectationWith schedule namespaceName Nothing pvcUid $ \plain fields -> case fields of
    _
      | Just (String app) <- KM.lookup "app" fields
      , Just (String volume) <- KM.lookup "volume" fields
      , KM.lookup "format" fields == Just (String volumeBackupFormat)
      , volumeBackupScheduleName app volume == schedule -> do
          prefix <- plain "PREFIX"
          unless
            (prefix == storePrefixUrl backend (volumeBackupKeyPrefix namespaceName app volume))
            (Left "accepted scheduled volume backup uses another object key space")
          sourceName <- plain "BACKUP_SOURCE_NAME"
          unless
            (sourceName == pvcName app volume)
            (Left "accepted scheduled volume backup probes another claim")
          Right (prefix, volumeBackupFormat)
    _ -> Left "accepted scheduled volume backup has invalid receipt metadata"

-- | The checks every reviewed schedule shares: identity, run UID, dedicated
-- source reader, signing Secret, metadata shape and cadence. The source check
-- receives the upload container's plain environment and the metadata fields
-- and returns the exact key prefix and archive format.
scheduledExpectationWith ::
  T.Text ->
  T.Text ->
  Maybe PhysicalIdentity ->
  PhysicalIdentity ->
  ((T.Text -> Either T.Text T.Text) -> KM.KeyMap Value -> Either T.Text (T.Text, T.Text)) ->
  ByteString ->
  Either T.Text ScheduledReceiptExpectation
scheduledExpectationWith schedule namespaceName statefulUid pvcUid checkSource bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  unless
    ( lookupJsonPath ["kind"] value == Just (String "CronJob")
        && lookupJsonPath ["metadata", "name"] value == Just (String schedule)
        && lookupJsonPath ["metadata", "namespace"] value == Just (String namespaceName)
    )
    (Left "accepted scheduled backup CronJob has another identity")
  let podSpecPath = ["spec", "jobTemplate", "spec", "template", "spec"]
      containers = case lookupJsonPath (podSpecPath <> ["containers"]) value of
        Just (Array entries) -> V.toList entries
        _ -> []
      uploads =
        [ container
        | container <- containers
        , lookupJsonPath ["name"] container == Just (String "upload")
        ]
  upload <- case uploads of
    [single] -> Right single
    _ -> Left "accepted scheduled backup has no unique upload container"
  let entries = case lookupJsonPath ["env"] upload of
        Just (Array fields) -> V.toList fields
        _ -> []
      env name = case [field | field <- entries, lookupJsonPath ["name"] field == Just (String name)] of
        [field] -> Right field
        _ -> Left ("accepted scheduled backup lacks one " <> name <> " environment entry")
      plain name = do
        field <- env name
        case lookupJsonPath ["value"] field of
          Just (String result) -> Right result
          _ -> Left ("accepted scheduled backup has no plain " <> name <> " value")
  runId <- env "BACKUP_RUN_ID"
  unless
    ( lookupJsonPath ["valueFrom", "fieldRef", "fieldPath"] runId
        == Just (String "metadata.labels['batch.kubernetes.io/controller-uid']")
    )
    (Left "accepted scheduled backup has another run identity")
  unless
    ( lookupJsonPath (podSpecPath <> ["serviceAccountName"]) value
        == Just (String schedule)
    )
    (Left "accepted scheduled backup has another source reader")
  signing <- env "BACKUP_SIGNING_KEY"
  unless
    ( lookupJsonPath ["valueFrom", "secretKeyRef", "name"] signing
        == Just (String (schedule <> "-signing"))
    )
    (Left "accepted scheduled backup has another signing Secret")
  unless
    ( lookupJsonPath ["valueFrom", "secretKeyRef", "key"] signing
        == Just (String "HMAC_KEY")
    )
    (Left "accepted scheduled backup has another signing key field")
  metadataJson <- plain "BACKUP_RECEIPT_METADATA"
  metadata <- first T.pack (eitherDecodeStrict (TE.encodeUtf8 metadataJson))
  fields <- case metadata of
    Object fields -> Right fields
    _ -> Left "accepted scheduled backup has invalid receipt metadata"
  (prefix, format) <- checkSource plain fields
  (revision, keep, objective) <- case fields of
    _
      | Just objective <- scheduleMetadataObjective fields
      , KM.lookup "namespace" fields == Just (String namespaceName)
      , KM.lookup "schedule" fields == Just (String schedule)
      , Just (String digest) <- KM.lookup "scheduleRevision" fields
      , Just keepValue <- KM.lookup "keep" fields
      , Success selectedKeep <- fromJSON keepValue
      , selectedKeep > (0 :: Int) ->
          Right (digest, selectedKeep, objective)
    _ -> Left "accepted scheduled backup has invalid receipt metadata"
  unless
    ( objective == HourlyRecoveryPoint
        || lookupJsonPath ["spec", "schedule"] value
          == Just (String (recoveryPointSchedule objective))
    )
    (Left "accepted scheduled backup cadence differs from its recovery-point objective")
  policyRevision <- mkContentDigest revision
  metadataBytes <- canonicalValue metadata
  pure
    ( ScheduledReceiptExpectation
        prefix
        format
        keep
        policyRevision
        (contentDigest metadataBytes)
        statefulUid
        pvcUid
        objective
    )
  where
    lookupJsonPath [] current = Just current
    lookupJsonPath (key : rest) (Object fields) = KM.lookup key fields >>= lookupJsonPath rest
    lookupJsonPath _ _ = Nothing

-- | Hourly schedules carry exactly the seven original metadata fields; only a
-- non-default objective adds one explicit eighth field.
scheduleMetadataObjective :: KM.KeyMap Value -> Maybe RecoveryPointObjective
scheduleMetadataObjective fields = case (KM.size fields, KM.lookup "recoveryPoint" fields) of
  (7, Nothing) -> Just HourlyRecoveryPoint
  (8, Just (String selected))
    | Right objective <- parseRecoveryPointObjective selected
    , objective /= HourlyRecoveryPoint ->
        Just objective
  _ -> Nothing

-- | The exact receipt address and static metadata pinned by a bound manual
-- backup Job. Ordinary Jobs have no expectation; partial annotations refuse.
manualBackupJobReceiptExpectation :: ByteString -> Either T.Text (Maybe BackupReceiptExpectation)
manualBackupJobReceiptExpectation bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root
      | KM.lookup "kind" root == Just (String "Job")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , Just (Object annotations) <- KM.lookup "annotations" metadata
      , any
          isString
          [ KM.lookup "nagare.dev/backup-id" annotations
          , KM.lookup "nagare.dev/volume-backup-id" annotations
          ] -> do
          let required key = case KM.lookup key annotations of
                Just (String field) -> Right field
                _ -> Left ("manual backup Job lacks " <> K.toText key)
          objectAddress <- required "nagare.dev/backup-object"
          address <- required "nagare.dev/backup-receipt"
          dataEnv <- jobEnvText root "DEST"
          receiptEnv <- jobEnvText root "BACKUP_RECEIPT_DEST"
          metadataEnv <- jobEnvText root "BACKUP_RECEIPT_METADATA"
          unless
            (dataEnv == objectAddress && receiptEnv == address)
            (Left "manual backup Job receipt environment differs from its annotations")
          metadataValue <- first T.pack (eitherDecodeStrict (TE.encodeUtf8 metadataEnv))
          metadataBytes <- canonicalValue metadataValue
          let metadataDigest = contentDigest metadataBytes
          case KM.lookup "nagare.dev/backup-receipt-metadata-digest" annotations of
            Nothing -> pure () -- Accepted Jobs predating the digest annotation retain their exact env.
            Just (String annotated) -> do
              pinned <- mkContentDigest annotated
              unless
                (pinned == metadataDigest)
                (Left "manual backup Job receipt metadata digest differs from its environment")
            _ -> Left "manual backup Job has an invalid receipt metadata digest annotation"
          pure (Just (BackupReceiptExpectation objectAddress address metadataDigest))
    _ -> Right Nothing
  where
    jobEnvText root key = do
      spec <- lookupObject "spec" root
      template <- lookupObject "template" spec
      podSpec <- lookupObject "spec" template
      containers <- case KM.lookup "containers" podSpec of
        Just (Array values) -> Right (V.toList values)
        _ -> Left "manual backup Job lacks containers"
      upload <- case [ container
                     | Object container <- containers
                     , KM.lookup "name" container == Just (String "upload")
                     ] of
        [container] -> Right container
        _ -> Left "manual backup Job lacks one upload container"
      entries <- case KM.lookup "env" upload of
        Just (Array values) -> Right (V.toList values)
        _ -> Left "manual backup Job upload container lacks environment"
      case [ value
           | Object entry <- entries
           , KM.lookup "name" entry == Just (String key)
           , Just value <- [KM.lookup "value" entry]
           ] of
        [String field] -> Right field
        _ -> Left ("manual backup Job lacks one " <> key <> " environment value")
    lookupObject key root = case KM.lookup key root of
      Just (Object value) -> Right value
      _ -> Left ("manual backup Job lacks " <> K.toText key)
    isString (Just (String _)) = True
    isString _ = False

-- | Validate receipt bytes against an accepted address and static metadata.
-- The checksum must still be compared with a fresh read of the backup object
-- before restore or pruning; a completed Job proves only its earlier readback.
parseBackupReceipt :: BackupReceiptExpectation -> T.Text -> ByteString -> Either T.Text T.Text
parseBackupReceipt expectation address bytes = do
  let objectAddress = receiptObjectAddress expectation
      expectedAddress = receiptAddress expectation
  unless
    (expectedAddress == objectAddress <> ".receipt.json")
    (Left "manual backup receipt address does not match its backup object")
  unless
    (address == expectedAddress)
    (Left "observed backup receipt is at another object address")
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root
      | KM.size root == 3
      , KM.lookup "version" root == Just (Number 1)
      , Just (String checksum) <- KM.lookup "sha256" root
      , Just metadata <- KM.lookup "backup" root -> do
          unless
            (T.length checksum == 64 && T.all lowerHex checksum)
            (Left "manual backup receipt has an invalid SHA-256")
          metadataBytes <- canonicalValue metadata
          unless
            (contentDigest metadataBytes == receiptMetadataDigest expectation)
            (Left "manual backup receipt metadata differs from the accepted review")
          pure checksum
    _ -> Left "manual backup receipt has an invalid version or shape"
  where
    lowerHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

-- | Validate one receipt fetched from the exact address in an accepted scope.
parseManualBackupReceipt :: ScopeDeclaration -> T.Text -> ByteString -> Either T.Text T.Text
parseManualBackupReceipt scope address bytes = do
  objectAddress <- required "backup.object"
  receiptAddress <- required "backup.receipt"
  metadataDigest <- required "backup.receipt.metadata.digest" >>= mkContentDigest
  parseBackupReceipt (BackupReceiptExpectation objectAddress receiptAddress metadataDigest) address bytes
  where
    required key =
      maybe
        (Left ("manual backup scope lacks " <> key))
        Right
        (Map.lookup key (scopeOverrides scope))

-- | Verify a version-4 or timestamped version-5 envelope after reading it from one exact object
-- address. The payload is canonical JSON for HMAC purposes; all fields that
-- affect restore authority are inside it. A caller must still check the
-- object-store version and freshly hash the referenced backup bytes.
parseScheduledBackupReceipt ::
  ScheduledReceiptExpectation ->
  T.Text ->
  T.Text ->
  ByteString ->
  Either T.Text ScheduledBackupReceipt
parseScheduledBackupReceipt expectation receiptAddress signingKeyHex bytes = do
  unless
    (T.length signingKeyHex == 64 && T.all lowerHex signingKeyHex)
    (Left "scheduled receipt signing key is invalid")
  value <- first T.pack (eitherDecodeStrict bytes)
  (version, payload, signature) <- case value of
    Object root
      | KM.size root == 3
      , Just (Number version) <- KM.lookup "version" root
      , version == 4 || version == 5
      , Just body <- KM.lookup "payload" root
      , Just (String mac) <- KM.lookup "hmacSha256" root ->
          Right (version, body, mac)
    _ -> Left "scheduled receipt has an invalid version or envelope"
  unless
    (T.length signature == 64 && T.all lowerHex signature)
    (Left "scheduled receipt has an invalid HMAC")
  canonical <- canonicalValue payload
  let key = BS.pack (hexBytes (T.unpack signingKeyHex))
      expected = BC.pack (show (hmacGetDigest (hmac key canonical :: HMAC SHA256)))
  unless
    (BA.constEq (TE.encodeUtf8 signature) expected)
    (Left "scheduled receipt HMAC differs from the accepted signing key")
  (checksum, jobUidText, objectAddress, source, metadata) <- case payload of
    Object fields
      | KM.size fields == (if version == 5 then 6 else 5)
      , Just (String sha) <- KM.lookup "sha256" fields
      , Just (String uid) <- KM.lookup "jobUid" fields
      , Just (String address) <- KM.lookup "object" fields
      , Just sourceValue <- KM.lookup "source" fields
      , Just backupValue <- KM.lookup "backup" fields ->
          Right (sha, uid, address, sourceValue, backupValue)
    _ -> Left "scheduled receipt payload has an invalid shape"
  unless
    (T.length checksum == 64 && T.all lowerHex checksum)
    (Left "scheduled receipt has an invalid stored-byte SHA-256")
  unless
    (kubernetesUid jobUidText)
    (Left "scheduled receipt has an invalid physical Job UID")
  jobUid <- mkPhysicalIdentity jobUidText
  unless
    ( objectAddress == scheduledObjectPrefix expectation <> jobUidText <> "." <> scheduledFormat expectation
        && receiptAddress == objectAddress <> ".receipt.json"
    )
    (Left "scheduled receipt addresses another object or key space")
  -- A database names its StatefulSet and claim; a volume exactly its claim.
  (statefulText, pvcText) <- case (source, scheduledStatefulUid expectation) of
    (Object fields, Just _)
      | KM.size fields == 2
      , Just (String stateful) <- KM.lookup "statefulSetUid" fields
      , Just (String pvc) <- KM.lookup "pvcUid" fields ->
          Right (Just stateful, pvc)
    (Object fields, Nothing)
      | KM.size fields == 1
      , Just (String pvc) <- KM.lookup "pvcUid" fields ->
          Right (Nothing, pvc)
    _ -> Left "scheduled receipt source UIDs are incomplete"
  statefulUid <- traverse mkPhysicalIdentity statefulText
  pvcUid <- mkPhysicalIdentity pvcText
  unless
    ( statefulUid == scheduledStatefulUid expectation
        && pvcUid == scheduledPvcUid expectation
    )
    (Left "scheduled receipt source incarnation differs from accepted evidence")
  metadataBytes <- canonicalValue metadata
  unless
    (contentDigest metadataBytes == scheduledMetadataDigest expectation)
    (Left "scheduled receipt schedule metadata differs from accepted native evidence")
  scheduleRevision <- case metadata of
    Object fields
      | Just (String revision) <- KM.lookup "scheduleRevision" fields ->
          mkContentDigest revision
    _ -> Left "scheduled receipt lacks a schedule revision"
  recoveryPoint <-
    if version == 4
      then pure Nothing
      else case payload of
        Object fields
          | Just (String stamp) <- KM.lookup "recoveryPoint" fields ->
              Just
                <$> maybe
                  (Left "scheduled receipt recovery point is invalid")
                  Right
                  (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack stamp))
        _ -> Left "scheduled receipt lacks its recovery point"
  pure (ScheduledBackupReceipt jobUid objectAddress checksum scheduleRevision recoveryPoint)
  where
    lowerHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
    hexBytes [] = []
    hexBytes (high : low : rest) =
      fromIntegral (digitToInt high * 16 + digitToInt low) : hexBytes rest
    hexBytes _ = [] -- length is checked before conversion
    kubernetesUid uid =
      T.length uid == 36
        && and
          [ if position `elem` [8, 13, 18, 23] then character == '-' else lowerHex character
          | (position, character) <- zip [0 :: Int ..] (T.unpack uid)
          ]
