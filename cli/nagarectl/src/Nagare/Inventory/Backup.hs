-- | Compile one reviewed manual database backup as an independent Job scope.
-- The accepted database revision and observed source UIDs are part of its
-- immutable intent. Job completion alone is not a durable object receipt;
-- the upload script checks exact stored bytes and creates a checksum receipt
-- before completion.
module Nagare.Inventory.Backup
  ( ManualBackupRequest (..)
  , BackupSourceProof (..)
  , BackupReceiptExpectation (..)
  , ScheduledReceiptExpectation (..)
  , ScheduledBackupReceipt (..)
  , manualBackupSourceProof
  , manualBackupJobSourcePins
  , manualBackupJobReceiptExpectation
  , parseBackupReceipt
  , parseManualBackupReceipt
  , parseScheduledBackupReceipt
  , scheduledReceiptExpectationFromCronJob
  , compileManualBackupScope
  , VolumeSnapshotRequest (..)
  , volumeSnapshotJobSourcePins
  , compileVolumeSnapshotScope
  ) where

import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict, fromJSON, object, (.=))
import Data.ByteArray qualified as BA
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (digitToInt)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Vector qualified as V
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..), storeObjectUrl, storePrefixUrl)
import Nagare.Database.Backup
  ( BackupDest (..), BackupJobInputs (..), BackupReceipt (..), BackupReceiptTarget (..), backupExt, dbBackupKeyPrefix
  , manualBackupJobName, manualBackupKeyPrefix, manualBackupObjectPath, renderBackupJob )
import Nagare.Dsl.Database (dbSecretName, engineImage, parseEngine)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), RecoveryClass (VerifyBeforeRetry), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Storage.Discover (pvcName)
import Nagare.Storage.Snapshot qualified as Snapshot

data ManualBackupRequest = ManualBackupRequest
  { databaseName :: !T.Text
  , namespaceName :: !T.Text
  , backupId :: !T.Text
  , expiresAt :: !(Maybe UTCTime)
  , sourceRevision :: !ScopeRevision
  , sourceStatefulUid :: !PhysicalIdentity
  , sourcePvcUid :: !PhysicalIdentity
  , storageBackend :: !StoreBackend
  , backupSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

-- | Pins from a saved backup review. The executor rereads both source
-- resources before submitting the Job, including during resume.
data BackupSourceProof = BackupSourceProof
  { sourceScopeName :: !T.Text
  , sourceScopeGeneration :: !Integer
  , sourceScopeDigest :: !ContentDigest
  , sourceStatefulId :: !ResourceId
  , sourceStatefulPhysical :: !PhysicalIdentity
  , sourcePvcId :: !ResourceId
  , sourcePvcPhysical :: !PhysicalIdentity
  }
  deriving stock (Eq, Show)

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
  , scheduledMetadataDigest :: !ContentDigest
  , scheduledStatefulUid :: !PhysicalIdentity
  , scheduledPvcUid :: !PhysicalIdentity
  }
  deriving stock (Eq, Show)

data ScheduledBackupReceipt = ScheduledBackupReceipt
  { scheduledJobUid :: !PhysicalIdentity
  , scheduledObjectAddress :: !T.Text
  , scheduledSha256 :: !T.Text
  , scheduledScheduleRevision :: !ContentDigest
  }
  deriving stock (Eq, Show)

-- | Derive receipt authority from the exact native bytes retained for an
-- accepted schedule. The caller separately proves that these bytes belong to
-- accepted history, that the signing Secret is accepted, and that the two
-- observed source UIDs are the intended incarnation. In particular, a receipt
-- cannot supply its own metadata expectation or object prefix.
scheduledReceiptExpectationFromCronJob
  :: StoreBackend -> T.Text -> T.Text -> PhysicalIdentity -> PhysicalIdentity
  -> ByteString -> Either T.Text ScheduledReceiptExpectation
scheduledReceiptExpectationFromCronJob backend namespaceName database statefulUid pvcUid bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  unless (lookupJsonPath ["kind"] value == Just (String "CronJob")
      && lookupJsonPath ["metadata", "name"] value == Just (String schedule)
      && lookupJsonPath ["metadata", "namespace"] value == Just (String namespaceName))
    (Left "accepted scheduled backup CronJob has another identity")
  let podSpecPath = ["spec", "jobTemplate", "spec", "template", "spec"]
      containers = case lookupJsonPath (podSpecPath <> ["containers"]) value of
        Just (Array entries) -> V.toList entries
        _ -> []
      uploads = [container | container <- containers,
        lookupJsonPath ["name"] container == Just (String "upload")]
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
  prefix <- plain "PREFIX"
  unless (prefix == storePrefixUrl backend (dbBackupKeyPrefix database))
    (Left "accepted scheduled backup uses another object key space")
  sourceName <- plain "BACKUP_SOURCE_NAME"
  unless (sourceName == database)
    (Left "accepted scheduled backup probes another source")
  runId <- env "BACKUP_RUN_ID"
  unless (lookupJsonPath ["valueFrom", "fieldRef", "fieldPath"] runId
      == Just (String "metadata.labels['batch.kubernetes.io/controller-uid']"))
    (Left "accepted scheduled backup has another run identity")
  unless (lookupJsonPath (podSpecPath <> ["serviceAccountName"]) value
      == Just (String schedule))
    (Left "accepted scheduled backup has another source reader")
  signing <- env "BACKUP_SIGNING_KEY"
  unless (lookupJsonPath ["valueFrom", "secretKeyRef", "name"] signing
      == Just (String (schedule <> "-signing")))
    (Left "accepted scheduled backup has another signing Secret")
  unless (lookupJsonPath ["valueFrom", "secretKeyRef", "key"] signing
      == Just (String "HMAC_KEY"))
    (Left "accepted scheduled backup has another signing key field")
  metadataJson <- plain "BACKUP_RECEIPT_METADATA"
  metadata <- first T.pack (eitherDecodeStrict (TE.encodeUtf8 metadataJson))
  (format, revision, keep) <- case metadata of
    Object fields | KM.size fields == 7
      , KM.lookup "database" fields == Just (String database)
      , KM.lookup "namespace" fields == Just (String namespaceName)
      , KM.lookup "schedule" fields == Just (String schedule)
      , Just (String engineName) <- KM.lookup "engine" fields
      , Just (String extension) <- KM.lookup "format" fields
      , Just (String digest) <- KM.lookup "scheduleRevision" fields
      , Just keepValue <- KM.lookup "keep" fields
      , Success selectedKeep <- fromJSON keepValue
      , selectedKeep > (0 :: Int)
      , Just engine <- parseEngine engineName
      , extension == backupExt engine -> Right (extension, digest, selectedKeep)
    _ -> Left "accepted scheduled backup has invalid receipt metadata"
  _ <- mkContentDigest revision
  metadataBytes <- canonicalValue metadata
  pure (ScheduledReceiptExpectation prefix format keep
    (contentDigest metadataBytes) statefulUid pvcUid)
  where
    schedule = "nagare-dbbackup-" <> database
    lookupJsonPath [] current = Just current
    lookupJsonPath (key : rest) (Object fields) = KM.lookup key fields >>= lookupJsonPath rest
    lookupJsonPath _ _ = Nothing

manualBackupSourceProof :: ScopeDeclaration -> Either T.Text (Maybe BackupSourceProof)
manualBackupSourceProof scope
  | Map.notMember "backup.id" values = Right Nothing
  | otherwise = Just <$> do
      generationText <- required "backup.source.generation"
      generation <- case reads (T.unpack generationText) of
        [(number, "")] | number > 0 -> Right number
        _ -> Left "manual backup source generation is invalid"
      BackupSourceProof
        <$> required "backup.source.scope"
        <*> pure generation
        <*> (required "backup.source.revision" >>= mkContentDigest)
        <*> (required "backup.source.statefulset" >>= mkResourceId)
        <*> (required "backup.source.statefulset.uid" >>= mkPhysicalIdentity)
        <*> (required "backup.source.pvc" >>= mkResourceId)
        <*> (required "backup.source.pvc.uid" >>= mkPhysicalIdentity)
  where
    values = scopeOverrides scope
    required key = maybe (Left ("manual backup lacks " <> key)) Right (Map.lookup key values)

-- | Read the source UIDs from the exact bound Job object. A partial backup
-- annotation set is invalid; ordinary Jobs have no source pins.
manualBackupJobSourcePins
  :: ByteString -> Either T.Text (Maybe [(ResourceId, PhysicalIdentity)])
manualBackupJobSourcePins bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root | KM.lookup "kind" root == Just (String "Job")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , Just (Object annotations) <- KM.lookup "annotations" metadata
      , Just (String _) <- KM.lookup "nagare.dev/backup-id" annotations -> do
          let required key = case KM.lookup key annotations of
                Just (String field) -> Right field
                _ -> Left ("manual backup Job lacks " <> K.toText key)
          statefulId <- required "nagare.dev/backup-source-statefulset" >>= mkResourceId
          statefulUid <- required "nagare.dev/backup-source-statefulset-uid" >>= mkPhysicalIdentity
          pvcId <- required "nagare.dev/backup-source-pvc" >>= mkResourceId
          pvcUid <- required "nagare.dev/backup-source-pvc-uid" >>= mkPhysicalIdentity
          unless (statefulId /= pvcId) (Left "manual backup source resources repeat")
          pure (Just [(statefulId, statefulUid), (pvcId, pvcUid)])
    _ -> Right Nothing

-- | The exact receipt address and static metadata pinned by a bound manual
-- backup Job. Ordinary Jobs have no expectation; partial annotations refuse.
manualBackupJobReceiptExpectation :: ByteString -> Either T.Text (Maybe BackupReceiptExpectation)
manualBackupJobReceiptExpectation bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root | KM.lookup "kind" root == Just (String "Job")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , Just (Object annotations) <- KM.lookup "annotations" metadata
      , any isString [KM.lookup "nagare.dev/backup-id" annotations,
          KM.lookup "nagare.dev/volume-backup-id" annotations] -> do
          let required key = case KM.lookup key annotations of
                Just (String field) -> Right field
                _ -> Left ("manual backup Job lacks " <> K.toText key)
          objectAddress <- required "nagare.dev/backup-object"
          address <- required "nagare.dev/backup-receipt"
          dataEnv <- jobEnvText root "DEST"
          receiptEnv <- jobEnvText root "BACKUP_RECEIPT_DEST"
          metadataEnv <- jobEnvText root "BACKUP_RECEIPT_METADATA"
          unless (dataEnv == objectAddress && receiptEnv == address)
            (Left "manual backup Job receipt environment differs from its annotations")
          metadataValue <- first T.pack (eitherDecodeStrict (TE.encodeUtf8 metadataEnv))
          metadataBytes <- canonicalValue metadataValue
          let metadataDigest = contentDigest metadataBytes
          case KM.lookup "nagare.dev/backup-receipt-metadata-digest" annotations of
            Nothing -> pure () -- Accepted Jobs predating the digest annotation retain their exact env.
            Just (String annotated) -> do
              pinned <- mkContentDigest annotated
              unless (pinned == metadataDigest)
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
      upload <- case [container | Object container <- containers,
        KM.lookup "name" container == Just (String "upload")] of
        [container] -> Right container
        _ -> Left "manual backup Job lacks one upload container"
      entries <- case KM.lookup "env" upload of
        Just (Array values) -> Right (V.toList values)
        _ -> Left "manual backup Job upload container lacks environment"
      case [value | Object entry <- entries,
        KM.lookup "name" entry == Just (String key),
        Just value <- [KM.lookup "value" entry]] of
        [String field] -> Right field
        _ -> Left ("manual backup Job lacks one " <> key <> " environment value")
    lookupObject key root = case KM.lookup key root of
      Just (Object value) -> Right value
      _ -> Left ("manual backup Job lacks " <> K.toText key)
    isString (Just (String _)) = True
    isString _ = False

-- | Pin one accepted PVC before a reviewed volume snapshot Job starts and
-- again before its terminal receipt is accepted.
volumeSnapshotJobSourcePins
  :: ByteString -> Either T.Text (Maybe [(ResourceId, PhysicalIdentity)])
volumeSnapshotJobSourcePins bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root | KM.lookup "kind" root == Just (String "Job")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , Just (Object annotations) <- KM.lookup "annotations" metadata
      , Just (String _) <- KM.lookup "nagare.dev/volume-backup-id" annotations -> do
          let required key = case KM.lookup key annotations of
                Just (String field) -> Right field
                _ -> Left ("volume snapshot Job lacks " <> K.toText key)
          resource <- required "nagare.dev/volume-source-pvc" >>= mkResourceId
          uid <- required "nagare.dev/volume-source-pvc-uid" >>= mkPhysicalIdentity
          credential <- case (KM.lookup "nagare.dev/volume-store-secret" annotations,
              KM.lookup "nagare.dev/volume-store-secret-uid" annotations) of
            (Nothing, Nothing) -> Right []
            (Just (String rawId), Just (String rawUid)) -> do
              secret <- mkResourceId rawId
              physical <- mkPhysicalIdentity rawUid
              pure [(secret, physical)]
            _ -> Left "volume snapshot Job has incomplete store credential pins"
          pure (Just ((resource, uid) : credential))
    _ -> Right Nothing

-- | Validate receipt bytes against an accepted address and static metadata.
-- The checksum must still be compared with a fresh read of the backup object
-- before restore or pruning; a completed Job proves only its earlier readback.
parseBackupReceipt :: BackupReceiptExpectation -> T.Text -> ByteString -> Either T.Text T.Text
parseBackupReceipt expectation address bytes = do
  let objectAddress = receiptObjectAddress expectation
      expectedAddress = receiptAddress expectation
  unless (expectedAddress == objectAddress <> ".receipt.json")
    (Left "manual backup receipt address does not match its backup object")
  unless (address == expectedAddress)
    (Left "observed backup receipt is at another object address")
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root | KM.size root == 3
      , KM.lookup "version" root == Just (Number 1)
      , Just (String checksum) <- KM.lookup "sha256" root
      , Just metadata <- KM.lookup "backup" root -> do
          unless (T.length checksum == 64 && T.all lowerHex checksum)
            (Left "manual backup receipt has an invalid SHA-256")
          metadataBytes <- canonicalValue metadata
          unless (contentDigest metadataBytes == receiptMetadataDigest expectation)
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
    required key = maybe (Left ("manual backup scope lacks " <> key)) Right
      (Map.lookup key (scopeOverrides scope))

-- | Verify the version-4 envelope after reading it from one exact object
-- address. The payload is canonical JSON for HMAC purposes; all fields that
-- affect restore authority are inside it. A caller must still check the
-- object-store version and freshly hash the referenced backup bytes.
parseScheduledBackupReceipt
  :: ScheduledReceiptExpectation -> T.Text -> T.Text -> ByteString
  -> Either T.Text ScheduledBackupReceipt
parseScheduledBackupReceipt expectation receiptAddress signingKeyHex bytes = do
  unless (T.length signingKeyHex == 64 && T.all lowerHex signingKeyHex)
    (Left "scheduled receipt signing key is invalid")
  value <- first T.pack (eitherDecodeStrict bytes)
  (payload, signature) <- case value of
    Object root | KM.size root == 3
      , KM.lookup "version" root == Just (Number 4)
      , Just body <- KM.lookup "payload" root
      , Just (String mac) <- KM.lookup "hmacSha256" root -> Right (body, mac)
    _ -> Left "scheduled receipt has an invalid version or envelope"
  unless (T.length signature == 64 && T.all lowerHex signature)
    (Left "scheduled receipt has an invalid HMAC")
  canonical <- canonicalValue payload
  let key = BS.pack (hexBytes (T.unpack signingKeyHex))
      expected = BC.pack (show (hmacGetDigest (hmac key canonical :: HMAC SHA256)))
  unless (BA.constEq (TE.encodeUtf8 signature) expected)
    (Left "scheduled receipt HMAC differs from the accepted signing key")
  (checksum, jobUidText, objectAddress, source, metadata) <- case payload of
    Object fields | KM.size fields == 5
      , Just (String sha) <- KM.lookup "sha256" fields
      , Just (String uid) <- KM.lookup "jobUid" fields
      , Just (String address) <- KM.lookup "object" fields
      , Just sourceValue <- KM.lookup "source" fields
      , Just backupValue <- KM.lookup "backup" fields ->
          Right (sha, uid, address, sourceValue, backupValue)
    _ -> Left "scheduled receipt payload has an invalid shape"
  unless (T.length checksum == 64 && T.all lowerHex checksum)
    (Left "scheduled receipt has an invalid stored-byte SHA-256")
  unless (kubernetesUid jobUidText)
    (Left "scheduled receipt has an invalid physical Job UID")
  jobUid <- mkPhysicalIdentity jobUidText
  unless (objectAddress == scheduledObjectPrefix expectation <> jobUidText <> "." <> scheduledFormat expectation
      && receiptAddress == objectAddress <> ".receipt.json")
    (Left "scheduled receipt addresses another object or key space")
  (statefulText, pvcText) <- case source of
    Object fields | KM.size fields == 2
      , Just (String stateful) <- KM.lookup "statefulSetUid" fields
      , Just (String pvc) <- KM.lookup "pvcUid" fields -> Right (stateful, pvc)
    _ -> Left "scheduled receipt source UIDs are incomplete"
  statefulUid <- mkPhysicalIdentity statefulText
  pvcUid <- mkPhysicalIdentity pvcText
  unless (statefulUid == scheduledStatefulUid expectation
      && pvcUid == scheduledPvcUid expectation)
    (Left "scheduled receipt source incarnation differs from accepted evidence")
  metadataBytes <- canonicalValue metadata
  unless (contentDigest metadataBytes == scheduledMetadataDigest expectation)
    (Left "scheduled receipt schedule metadata differs from accepted native evidence")
  scheduleRevision <- case metadata of
    Object fields | Just (String revision) <- KM.lookup "scheduleRevision" fields ->
      mkContentDigest revision
    _ -> Left "scheduled receipt lacks a schedule revision"
  pure (ScheduledBackupReceipt jobUid objectAddress checksum scheduleRevision)
  where
    lowerHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
    hexBytes [] = []
    hexBytes (high : low : rest) =
      fromIntegral (digitToInt high * 16 + digitToInt low) : hexBytes rest
    hexBytes _ = [] -- length is checked before conversion
    kubernetesUid uid = T.length uid == 36 && and
      [if position `elem` [8, 13, 18, 23] then character == '-' else lowerHex character
      | (position, character) <- zip [0 :: Int ..] (T.unpack uid)]

compileManualBackupScope
  :: ManualBackupRequest
  -> ScopeDeclaration
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileManualBackupScope request accepted native = do
  let invalid message = inventoryError "invalid-manual-backup" message
        & #scopes .~ [scopeId accepted]
        & #sources .~ [backupSource request]
        & (:| [])
      database = databaseName request
      ns = namespaceName request
      select group kind name =
        [member | bundle <- scopeBundles accepted,
          Managed member <- declarations bundle,
          case member ^. #address of
            Kubernetes _ api resourceKind (Just namespace) nativeName ->
              api == group && nameText resourceKind == kind
                && nameText namespace == ns && nameText nativeName == name
            _ -> False]
      exactlyOne label members = case members of
        [member] -> Right member
        _ -> Left (invalid ("accepted database has no unique " <> label))
  unless (scopeKind (scopeId accepted) `elem` [Application, Standalone])
    (Left (invalid "manual backup requires an accepted database scope"))
  _ <- first invalid (mkServiceName database)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName (backupId request))
  unless (T.length (backupId request) <= 20)
    (Left (invalid "backup ID must contain at most 20 characters"))
  stateful <- exactlyOne "StatefulSet" (select "apps" "statefulset" database)
  pvc <- exactlyOne "PVC" (select "" "persistentvolumeclaim" (dbPvcName database))
  credential <- exactlyOne "credential" (select "" "secret" (dbSecretName database))
  statefulValue <- acceptedValue invalid native stateful
  _ <- acceptedValue invalid native pvc
  _ <- acceptedValue invalid native credential
  cluster <- case stateful ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "accepted database StatefulSet has no Kubernetes address")
  unless (all (sameCluster cluster) [pvc, credential])
    (Left (invalid "database PVC or credential belongs to another cluster"))
  engineName <- metadataText invalid "labels" "nagare.dev/engine" statefulValue
  engine <- maybe (Left (invalid "database engine label is unknown")) Right (parseEngine engineName)
  version <- metadataText invalid "annotations" "nagare.dev/version" statefulValue
  owner <- first invalid (mkScopeId Standalone
    ("database-backup-" <> ns <> "-" <> database <> "-" <> backupId request))
  key <- first invalid (mkLogicalKey (backupId request))
  role <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "snapshot")
  let jobId = mintResourceId owner key role
      proofId = mintResourceId owner key proofRole
      jobName = manualBackupJobName database (backupId request)
      objectUrl = storeObjectUrl (storageBackend request)
        (manualBackupObjectPath database ns (backupId request) (backupExt engine))
      receiptUrl = objectUrl <> ".receipt.json"
      expiry = maybe "retain" (T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ")
        (expiresAt request)
      receiptMetadataValue = object
        [ "id" .= backupId request
        , "database" .= database
        , "namespace" .= ns
        , "engine" .= engineName
        , "object" .= objectUrl
        , "expiry" .= expiry
        , "sourceScope" .= scopeIdText (scopeId accepted)
        , "sourceGeneration" .= generationNumber (revisionGeneration (sourceRevision request))
        , "sourceRevision" .= digestText (revisionDigest (sourceRevision request))
        , "sourceStatefulSet" .= resourceIdText (stateful ^. #identity)
        , "sourceStatefulSetUid" .= physicalIdentityText (sourceStatefulUid request)
        , "sourcePvc" .= resourceIdText (pvc ^. #identity)
        , "sourcePvcUid" .= physicalIdentityText (sourcePvcUid request)
        , "verification" .= ("sha256-readback" :: T.Text)
        ]
  receiptMetadataBytes <- first invalid (canonicalValue receiptMetadataValue)
  receiptProbe <- first invalid (canonicalValue (object
    [ "version" .= (1 :: Int)
    , "sha256" .= T.replicate 64 "0"
    , "backup" .= receiptMetadataValue ]))
  unless (BS.length receiptProbe + 1 <= 4096)
    (Left (invalid "manual backup receipt exceeds the Kubernetes termination-message limit"))
  let receiptMetadata = TE.decodeUtf8 receiptMetadataBytes
      inputs = BackupJobInputs
        { namespace = ns
        , jobName = jobName
        , engine = engine
        , clientImage = engineImage engine <> ":" <> version
        , serviceHost = database
        , secretName = dbSecretName database
        , name = database
        , destination = BackupDestUrl objectUrl
        , prefix = storePrefixUrl (storageBackend request) (manualBackupKeyPrefix ns database)
        , keep = 0
        , selfPrune = False
        , verifyStored = True
        , receipt = Just (BackupReceipt (FixedReceiptTarget receiptUrl) receiptMetadata)
        , backend = storageBackend request
        }
  rendered <- first (invalid . T.pack . show)
    (Yaml.decodeEither' (renderBackupJob inputs) :: Either Yaml.ParseException Value)
  job <- first invalid (annotateJob request accepted pvc stateful objectUrl receiptUrl
    (contentDigest receiptMetadataBytes) expiry rendered)
  canonical <- first invalid (canonicalValue job)
  (bound, bytes) <- first (:| []) (bindKubernetesObject KubernetesInput
    { resourceId = jobId
    , ownerScope = owner
    , clusterId = cluster
    , inputObject = job
    , objectDigest = contentDigest canonical
    , lifecyclePolicy = DeleteWhenUnreferenced
    , inputDataPolicy = Stateless
    , inputSensitivity = Private
    , sourceLocation = backupSource request
    })
  expected <- first invalid (kubernetesAddress cluster "batch/v1" "Job" (Just ns) jobName)
  unless (bound ^. #address == expected)
    (Left (invalid "manual backup Job has an unexpected native address"))
  let member = bound {dependencies = map (OrderedAfter . (^. #identity))
        [pvc, credential, stateful]}
      proof = DeclaredOperation proofId (jobId :| [])
        [ContentInput (contentDigest bytes)] VerifyBeforeRetry SnapshotData
      overrides = Map.fromList
        [ ("backup.id", backupId request)
        , ("backup.object", objectUrl)
        , ("backup.receipt", receiptUrl)
        , ("backup.receipt.metadata.digest", digestText (contentDigest receiptMetadataBytes))
        , ("backup.source.scope", scopeIdText (scopeId accepted))
        , ("backup.source.generation", T.pack (show (generationNumber
            (revisionGeneration (sourceRevision request)))))
        , ("backup.source.revision", digestText (revisionDigest (sourceRevision request)))
        , ("backup.source.statefulset", resourceIdText (stateful ^. #identity))
        , ("backup.source.statefulset.uid", physicalIdentityText (sourceStatefulUid request))
        , ("backup.source.pvc", resourceIdText (pvc ^. #identity))
        , ("backup.source.pvc.uid", physicalIdentityText (sourcePvcUid request))
        , ("backup.expiry", expiry)
        , ("backup.verification", "sha256-readback")
        ]
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  let scope = withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base)
  pure (scope, Map.singleton jobId (member, bytes))

sameCluster :: ResourceId -> ManagedResource -> Bool
sameCluster cluster member = case member ^. #address of
  Kubernetes clusterId _ _ _ _ -> clusterId == cluster
  _ -> False

acceptedValue
  :: (T.Text -> NonEmpty InventoryError)
  -> Map ResourceId (ManagedResource, ByteString)
  -> ManagedResource
  -> Either (NonEmpty InventoryError) Value
acceptedValue invalid native member = do
  (bound, bytes) <- maybe (Left (invalid "database member lacks private native evidence")) Right
    (Map.lookup (member ^. #identity) native)
  unless (bound == member)
    (Left (invalid "accepted database member differs from its private native evidence"))
  value <- first (invalid . T.pack . show)
    (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  canonical <- first invalid (canonicalValue value)
  let expected = case member ^. #spec of
        StatefulSet _ _ digest -> Just digest
        NativeObject digest -> Just digest
        _ -> Nothing
  unless (expected == Just (contentDigest canonical))
    (Left (invalid "accepted database native digest differs from its declaration"))
  pure value

metadataText
  :: (T.Text -> NonEmpty InventoryError)
  -> T.Text -> T.Text -> Value -> Either (NonEmpty InventoryError) T.Text
metadataText invalid section key value = case value of
  Object root
    | Just (Object metadata) <- KM.lookup "metadata" root
    , Just (Object fields) <- KM.lookup (K.fromText section) metadata
    , Just (String selected) <- KM.lookup (K.fromText key) fields -> Right selected
  _ -> Left (invalid ("database StatefulSet metadata lacks " <> key))

annotateJob
  :: ManualBackupRequest -> ScopeDeclaration -> ManagedResource -> ManagedResource
  -> T.Text -> T.Text -> ContentDigest -> T.Text -> Value -> Either T.Text Value
annotateJob request accepted pvc stateful objectUrl receiptUrl metadataDigest expiry = \case
  Object root | Just (Object metadata) <- KM.lookup "metadata" root ->
    let annotations = object
          [ "nagare.dev/backup-id" .= backupId request
          , "nagare.dev/backup-object" .= objectUrl
          , "nagare.dev/backup-receipt" .= receiptUrl
          , "nagare.dev/backup-receipt-metadata-digest" .= digestText metadataDigest
          , "nagare.dev/backup-source-scope" .= scopeIdText (scopeId accepted)
          , "nagare.dev/backup-source-generation" .= T.pack (show (generationNumber
              (revisionGeneration (sourceRevision request))))
          , "nagare.dev/backup-source-revision" .= digestText (revisionDigest (sourceRevision request))
          , "nagare.dev/backup-source-statefulset" .= resourceIdText (stateful ^. #identity)
          , "nagare.dev/backup-source-statefulset-uid" .= physicalIdentityText (sourceStatefulUid request)
          , "nagare.dev/backup-source-pvc" .= resourceIdText (pvc ^. #identity)
          , "nagare.dev/backup-source-pvc-uid" .= physicalIdentityText (sourcePvcUid request)
          , "nagare.dev/backup-expiry" .= expiry
          , "nagare.dev/backup-verification" .= ("sha256-readback" :: T.Text)
          ]
     in Right (Object (KM.insert "metadata" (Object
          (KM.insert "annotations" annotations metadata)) root))
  _ -> Left "manual backup Job lacks native metadata"

data VolumeSnapshotRequest = VolumeSnapshotRequest
  { volumeApp :: !T.Text
  , volumeName :: !T.Text
  , volumeNamespace :: !T.Text
  , volumeBackupId :: !T.Text
  , volumeExpiresAt :: !(Maybe UTCTime)
  , volumeSourceRevision :: !ScopeRevision
  , volumeSourcePvcUid :: !PhysicalIdentity
  , volumeStorageBackend :: !StoreBackend
  , volumeStoreCredential :: !(Maybe (ManagedResource, PhysicalIdentity))
  , volumeBackupSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

-- | Compile a fixed-key volume archive and receipt as one independently
-- reviewed Job. It never deletes an earlier archive or writes into the PVC.
compileVolumeSnapshotScope
  :: VolumeSnapshotRequest -> ScopeDeclaration
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileVolumeSnapshotScope request accepted native = do
  let invalid message = inventoryError "invalid-volume-snapshot" message
        & #scopes .~ [scopeId accepted]
        & #sources .~ [volumeBackupSource request]
        & (:| [])
      app = volumeApp request
      volume = volumeName request
      ns = volumeNamespace request
      backupId = volumeBackupId request
      claim = pvcName app volume
  _ <- first invalid (mkServiceName app)
  _ <- first invalid (mkServiceName volume)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName backupId)
  unless (T.length backupId <= 20)
    (Left (invalid "volume snapshot ID must contain at most 20 characters"))
  pvc <- case [member | bundle <- scopeBundles accepted,
      Managed member <- declarations bundle,
      case member ^. #address of
        Kubernetes _ "" kind (Just namespace) nativeName ->
          nameText kind == "persistentvolumeclaim"
            && nameText namespace == ns && nameText nativeName == claim
        _ -> False] of
    [single] -> Right single
    _ -> Left (invalid "volume snapshot requires one accepted source PVC")
  _ <- acceptedValue invalid native pvc
  cluster <- case pvc ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "source PVC has no Kubernetes address")
  let credential = volumeStoreCredential request
  case (volumeStorageBackend request, credential) of
    (GcsBackend {}, Nothing) -> pure ()
    (MinioBackend ref, Just (secret, _)) -> do
      expected <- first invalid (kubernetesAddress cluster "v1" "Secret"
        (Just ns) (ref ^. #secretName))
      unless (secret ^. #address == expected)
        (Left (invalid "accepted MinIO credential differs from the snapshot Job reference"))
      _ <- acceptedValue invalid native secret
      pure ()
    _ -> Left (invalid "volume snapshot store credential differs from its backend")
  owner <- first invalid (mkScopeId Standalone
    ("volume-snapshot-" <> ns <> "-" <> app <> "-" <> volume <> "-" <> backupId))
  key <- first invalid (mkLogicalKey backupId)
  role <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "snapshot")
  let jobId = mintResourceId owner key role
      proofId = mintResourceId owner key proofRole
      jobName = "nagare-snapshot-" <> app <> "-" <> volume <> "-" <> backupId
      objectUrl = storeObjectUrl (volumeStorageBackend request)
        ("manual-volumes/" <> ns <> "/" <> app <> "/" <> volume <> "/" <> backupId <> ".tar.gz")
      receiptUrl = objectUrl <> ".receipt.json"
      expiry = maybe "retain" (T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ")
        (volumeExpiresAt request)
  unless (T.length jobName <= 63)
    (Left (invalid "volume snapshot Job name exceeds 63 characters"))
  let receiptMetadataValue = object
        [ "id" .= backupId, "app" .= app, "volume" .= volume, "namespace" .= ns
        , "object" .= objectUrl, "expiry" .= expiry
        , "sourceScope" .= scopeIdText (scopeId accepted)
        , "sourceGeneration" .= generationNumber (revisionGeneration (volumeSourceRevision request))
        , "sourceRevision" .= digestText (revisionDigest (volumeSourceRevision request))
        , "sourcePvc" .= resourceIdText (pvc ^. #identity)
        , "sourcePvcUid" .= physicalIdentityText (volumeSourcePvcUid request)
        , "verification" .= ("sha256-readback" :: T.Text)
        ]
  metadataBytes <- first invalid (canonicalValue receiptMetadataValue)
  receiptProbe <- first invalid (canonicalValue (object
    [ "version" .= (1 :: Int), "sha256" .= T.replicate 64 "0",
      "backup" .= receiptMetadataValue ]))
  unless (BS.length receiptProbe + 1 <= 4096)
    (Left (invalid "volume snapshot receipt exceeds the Kubernetes termination-message limit"))
  let jobInputs = Snapshot.SnapshotJobInputs ns jobName claim objectUrl "/vol"
        (volumeStorageBackend request)
      reviewed = Snapshot.ReviewedSnapshotJobInputs jobInputs receiptUrl
        (TE.decodeUtf8 metadataBytes)
  rendered <- first (invalid . T.pack . show)
    (Yaml.decodeEither' (Snapshot.renderReviewedSnapshotJob reviewed)
      :: Either Yaml.ParseException Value)
  job <- case rendered of
    Object root | Just (Object metadata) <- KM.lookup "metadata" root ->
      let annotations = object
            ([ "nagare.dev/volume-backup-id" .= backupId
             , "nagare.dev/backup-object" .= objectUrl
             , "nagare.dev/backup-receipt" .= receiptUrl
             , "nagare.dev/backup-receipt-metadata-digest" .=
                 digestText (contentDigest metadataBytes)
             , "nagare.dev/volume-source-pvc" .= resourceIdText (pvc ^. #identity)
             , "nagare.dev/volume-source-pvc-uid" .=
                 physicalIdentityText (volumeSourcePvcUid request)
             ] <> case credential of
               Nothing -> []
               Just (secret, uid) ->
                 [ "nagare.dev/volume-store-secret" .= resourceIdText (secret ^. #identity)
                 , "nagare.dev/volume-store-secret-uid" .= physicalIdentityText uid ])
       in Right (Object (KM.insert "metadata" (Object
            (KM.insert "annotations" annotations metadata)) root))
    _ -> Left (invalid "volume snapshot Job lacks native metadata")
  canonical <- first invalid (canonicalValue job)
  (bound, bytes) <- first (:| []) (bindKubernetesObject KubernetesInput
    { resourceId = jobId, ownerScope = owner, clusterId = cluster
    , inputObject = job, objectDigest = contentDigest canonical
    , lifecyclePolicy = DeleteWhenUnreferenced, inputDataPolicy = Stateless
    , inputSensitivity = Private, sourceLocation = volumeBackupSource request })
  expected <- first invalid (kubernetesAddress cluster "batch/v1" "Job" (Just ns) jobName)
  unless (bound ^. #address == expected)
    (Left (invalid "volume snapshot Job has an unexpected native address"))
  let sourceIds = pvc ^. #identity : maybe [] (\(secret, _) -> [secret ^. #identity]) credential
      member = bound {dependencies = map OrderedAfter sourceIds}
      proof = DeclaredOperation proofId (jobId :| [])
        [ContentInput (contentDigest bytes)] VerifyBeforeRetry SnapshotData
      overrides = Map.fromList
        [ ("volume-backup.id", backupId), ("volume-backup.object", objectUrl)
        , ("volume-backup.receipt", receiptUrl)
        , ("volume-backup.source.scope", scopeIdText (scopeId accepted))
        , ("volume-backup.source.generation", T.pack (show (generationNumber
            (revisionGeneration (volumeSourceRevision request)))))
        , ("volume-backup.source.revision", digestText
            (revisionDigest (volumeSourceRevision request)))
        , ("volume-backup.source.pvc", resourceIdText (pvc ^. #identity))
        , ("volume-backup.source.pvc.uid", physicalIdentityText (volumeSourcePvcUid request))
        , ("volume-backup.expiry", expiry)
        , ("volume-backup.verification", "sha256-readback")
        ]
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  pure (withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base),
    Map.singleton jobId (member, bytes))
