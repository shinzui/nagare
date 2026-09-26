-- | A reviewed, write-fenced PostgreSQL scratch restore from an accepted
-- manual backup. The fixed Job verifies fresh object bytes before creating a
-- new scratch database; a failed restore requires explicit forward recovery.
module Nagare.Inventory.Restore
  ( ManualRestoreRequest (..)
  , manualRestoreJobTargetPins
  , manualRestoreTargetProof
  , compileManualRestoreScope
  , VolumeRestoreRequest (..)
  , volumeRestoreJobSourcePins
  , compileVolumeRestoreScope
  ) where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..), storeObjectUrl)
import Nagare.Database.Backup (manualBackupObjectPath, manualDatabaseJobName)
import Nagare.Database.Restore (RestoreJobInputs (..), VerifiedRestoreSource (..), renderRestoreJob)
import Nagare.Dsl.Database (Engine (Postgres), dbSecretName, engineImage)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Backup (BackupSourceProof (..), manualBackupJobReceiptExpectation, parseBackupReceipt, parseManualBackupReceipt)
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
import Nagare.Storage.Restore qualified as Volume

data ManualRestoreRequest = ManualRestoreRequest
  { restoreDatabaseName :: !T.Text
  , restoreNamespaceName :: !T.Text
  , restoreId :: !T.Text
  , restoreBackupScope :: !ScopeDeclaration
  , restoreBackupRevision :: !ScopeRevision
  , restoreReceiptBytes :: !ByteString
  , restoreTargetRevision :: !ScopeRevision
  , restoreTargetStatefulUid :: !PhysicalIdentity
  , restoreTargetPvcUid :: !PhysicalIdentity
  , restoreStorageBackend :: !StoreBackend
  , restoreSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

-- | Reuse the immutable source-revision check for this Job's accepted target.
manualRestoreTargetProof :: ScopeDeclaration -> Either T.Text (Maybe BackupSourceProof)
manualRestoreTargetProof scope
  | Map.notMember "restore.id" values = Right Nothing
  | otherwise = Just <$> do
      generationText <- required "restore.target.generation"
      generation <- case reads (T.unpack generationText) of
        [(number, "")] | number > 0 -> Right number
        _ -> Left "manual restore target generation is invalid"
      BackupSourceProof
        <$> required "restore.target.scope"
        <*> pure generation
        <*> (required "restore.target.revision" >>= mkContentDigest)
        <*> (required "restore.target.statefulset" >>= mkResourceId)
        <*> (required "restore.target.statefulset.uid" >>= mkPhysicalIdentity)
        <*> (required "restore.target.pvc" >>= mkResourceId)
        <*> (required "restore.target.pvc.uid" >>= mkPhysicalIdentity)
  where
    values = scopeOverrides scope
    required key = maybe (Left ("manual restore scope lacks " <> key)) Right (Map.lookup key values)

-- | Exact source UIDs from a saved restore Job. An incomplete annotation set
-- refuses execution; ordinary Jobs have no restore target pins.
manualRestoreJobTargetPins
  :: ByteString -> Either T.Text (Maybe [(ResourceId, PhysicalIdentity)])
manualRestoreJobTargetPins bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root | KM.lookup "kind" root == Just (String "Job")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , Just (Object annotations) <- KM.lookup "annotations" metadata
      , Just (String _) <- KM.lookup "nagare.dev/restore-id" annotations -> do
          let required key = case KM.lookup key annotations of
                Just (String field) -> Right field
                _ -> Left ("manual restore Job lacks " <> K.toText key)
          statefulId <- required "nagare.dev/restore-target-statefulset" >>= mkResourceId
          statefulUid <- required "nagare.dev/restore-target-statefulset-uid" >>= mkPhysicalIdentity
          pvcId <- required "nagare.dev/restore-target-pvc" >>= mkResourceId
          pvcUid <- required "nagare.dev/restore-target-pvc-uid" >>= mkPhysicalIdentity
          unless (statefulId /= pvcId) (Left "manual restore target resources repeat")
          pure (Just [(statefulId, statefulUid), (pvcId, pvcUid)])
    _ -> Right Nothing

compileManualRestoreScope
  :: ManualRestoreRequest
  -> ScopeDeclaration
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileManualRestoreScope request accepted native = do
  let invalid message = inventoryError "invalid-manual-restore" message
        & #scopes .~ [scopeId accepted, scopeId (restoreBackupScope request)]
        & #sources .~ [restoreSource request]
        & (:| [])
      db = restoreDatabaseName request
      ns = restoreNamespaceName request
      backup = restoreBackupScope request
      select scope group kind name =
        [member | bundle <- scopeBundles scope,
          Managed member <- declarations bundle,
          case member ^. #address of
            Kubernetes _ api resourceKind (Just namespace) nativeName ->
              api == group && nameText resourceKind == kind
                && nameText namespace == ns && nameText nativeName == name
            _ -> False]
      exactlyOne label members = case members of
        [member] -> Right member
        _ -> Left (invalid ("restore has no unique " <> label))
      required key = maybe (Left (invalid ("backup scope lacks " <> key))) Right
        (Map.lookup key (scopeOverrides backup))
  unless (scopeKind (scopeId accepted) `elem` [Application, Standalone])
    (Left (invalid "restore requires an accepted database scope"))
  _ <- first invalid (mkServiceName db)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName (restoreId request))
  unless (T.length (restoreId request) <= 20)
    (Left (invalid "restore ID must contain at most 20 characters"))
  stateful <- exactlyOne "StatefulSet" (select accepted "apps" "statefulset" db)
  pvc <- exactlyOne "PVC" (select accepted "" "persistentvolumeclaim" (dbPvcName db))
  credential <- exactlyOne "credential" (select accepted "" "secret" (dbSecretName db))
  backupJob <- case [member | bundle <- scopeBundles backup,
    Managed member <- declarations bundle,
    case member ^. #address of
      Kubernetes _ "batch" kind _ _ -> nameText kind == "job"
      _ -> False] of
    [member] -> Right member
    _ -> Left (invalid "accepted backup scope lacks one Job")
  statefulValue <- acceptedValue invalid native stateful
  _ <- acceptedValue invalid native pvc
  _ <- acceptedValue invalid native credential
  _ <- acceptedValue invalid native backupJob
  cluster <- case stateful ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "restore target StatefulSet has no Kubernetes address")
  unless (all (sameCluster cluster) [pvc, credential, backupJob])
    (Left (invalid "restore resources belong to different clusters"))
  engineName <- metadataText invalid "labels" "nagare.dev/engine" statefulValue
  unless (engineName == "postgres")
    (Left (invalid "reviewed scratch restore currently supports PostgreSQL only"))
  version <- metadataText invalid "annotations" "nagare.dev/version" statefulValue
  sourceScope <- required "backup.source.scope"
  unless (sourceScope == scopeIdText (scopeId accepted))
    (Left (invalid "backup belongs to another database scope"))
  objectUrl <- required "backup.object"
  receiptUrl <- required "backup.receipt"
  backupId <- required "backup.id"
  expiryText <- required "backup.expiry"
  expiryEpoch <- if expiryText == "retain"
    then Right 0
    else case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
      (T.unpack expiryText) :: Maybe UTCTime of
      Just expiry -> Right (floor (utcTimeToPOSIXSeconds expiry))
      Nothing -> Left (invalid "backup expiry is invalid")
  unless (objectUrl == storeObjectUrl (restoreStorageBackend request)
      (manualBackupObjectPath db ns backupId "sql.gz"))
    (Left (invalid "backup object does not match the selected backend and database"))
  receiptChecksum <- first invalid (parseManualBackupReceipt backup receiptUrl
    (restoreReceiptBytes request))
  receiptValue <- first (invalid . T.pack) (eitherDecodeStrict (restoreReceiptBytes request))
  case receiptValue of
    Object root | Just (Object metadata) <- KM.lookup "backup" root -> do
      let field key = case KM.lookup key metadata of
            Just (String selected) -> Right selected
            _ -> Left (invalid ("backup receipt lacks " <> K.toText key))
      receiptDatabase <- field "database"
      receiptNamespace <- field "namespace"
      receiptEngine <- field "engine"
      receiptId <- field "id"
      unless (receiptDatabase == db && receiptNamespace == ns
          && receiptEngine == engineName && receiptId == backupId)
        (Left (invalid "backup receipt targets another database, namespace, engine, or ID"))
    _ -> Left (invalid "backup receipt lacks metadata")
  scratch <- first invalid (scratchDatabaseName db (restoreId request))
  owner <- first invalid (mkScopeId Standalone
    ("database-restore-" <> ns <> "-" <> db <> "-" <> restoreId request))
  key <- first invalid (mkLogicalKey (restoreId request))
  jobRole <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "restore")
  let jobId = mintResourceId owner key jobRole
      proofId = mintResourceId owner key proofRole
      jobName = manualDatabaseJobName "nagare-dbrestore-" db (restoreId request)
      receiptDigest = contentDigest (restoreReceiptBytes request)
      inputs = RestoreJobInputs
        { namespace = ns, jobName = jobName, engine = Postgres
        , clientImage = engineImage Postgres <> ":" <> version
        , serviceHost = db, secretName = dbSecretName db, name = db
        , sourceUrl = objectUrl, liveTarget = False
        , verifiedSource = Just (VerifiedRestoreSource receiptUrl
            (digestText receiptDigest) receiptChecksum scratch expiryEpoch)
        , backend = restoreStorageBackend request
        }
  rendered <- first (invalid . T.pack . show)
    (Yaml.decodeEither' (renderRestoreJob inputs) :: Either Yaml.ParseException Value)
  job <- first invalid (annotateJob request accepted backupJob stateful pvc
    objectUrl receiptUrl receiptDigest scratch rendered)
  canonical <- first invalid (canonicalValue job)
  (bound, bytes) <- first (:| []) (bindKubernetesObject KubernetesInput
    { resourceId = jobId, ownerScope = owner, clusterId = cluster
    , inputObject = job, objectDigest = contentDigest canonical
    , lifecyclePolicy = DeleteWhenUnreferenced, inputDataPolicy = Stateless
    , inputSensitivity = Private, sourceLocation = restoreSource request })
  expected <- first invalid (kubernetesAddress cluster "batch/v1" "Job" (Just ns) jobName)
  unless (bound ^. #address == expected)
    (Left (invalid "restore Job has an unexpected native address"))
  let member = bound {dependencies = map (OrderedAfter . (^. #identity))
        [backupJob, pvc, credential, stateful]}
      proof = DeclaredOperation proofId (jobId :| [])
        [ContentInput (contentDigest bytes), ContentInput receiptDigest]
        VerifyBeforeRetry RestoreData
      overrides = Map.fromList
        [ ("restore.id", restoreId request)
        , ("restore.database", db)
        , ("restore.namespace", ns)
        , ("restore.backup.id", backupId)
        , ("restore.backup.scope", scopeIdText (scopeId backup))
        , ("restore.backup.revision", digestText (revisionDigest (restoreBackupRevision request)))
        , ("restore.backup.object", objectUrl)
        , ("restore.backup.receipt", receiptUrl)
        , ("restore.backup.receipt.digest", digestText receiptDigest)
        , ("restore.backup.sha256", receiptChecksum)
        , ("restore.target.scope", scopeIdText (scopeId accepted))
        , ("restore.target.generation", T.pack (show (generationNumber
            (revisionGeneration (restoreTargetRevision request)))))
        , ("restore.target.revision", digestText (revisionDigest (restoreTargetRevision request)))
        , ("restore.target.statefulset", resourceIdText (stateful ^. #identity))
        , ("restore.target.statefulset.uid", physicalIdentityText (restoreTargetStatefulUid request))
        , ("restore.target.pvc", resourceIdText (pvc ^. #identity))
        , ("restore.target.pvc.uid", physicalIdentityText (restoreTargetPvcUid request))
        , ("restore.target.database", scratch)
        ]
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  pure (withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base),
    Map.singleton jobId (member, bytes))

scratchDatabaseName :: T.Text -> T.Text -> Either T.Text T.Text
scratchDatabaseName db restoreKey =
  let chosen = db <> "_restore_" <> restoreKey
   in if T.length chosen <= 63 then Right chosen
      else Left "database and restore ID exceed PostgreSQL's 63-byte scratch name limit"

sameCluster :: ResourceId -> ManagedResource -> Bool
sameCluster cluster member = case member ^. #address of
  Kubernetes selected _ _ _ _ -> selected == cluster
  _ -> False

acceptedValue
  :: (T.Text -> NonEmpty InventoryError)
  -> Map ResourceId (ManagedResource, ByteString)
  -> ManagedResource
  -> Either (NonEmpty InventoryError) Value
acceptedValue invalid native member = do
  (bound, bytes) <- maybe (Left (invalid "restore member lacks accepted private native evidence")) Right
    (Map.lookup (member ^. #identity) native)
  unless (bound == member)
    (Left (invalid "restore member differs from accepted private native evidence"))
  value <- first (invalid . T.pack) (eitherDecodeStrict bytes)
  canonical <- first invalid (canonicalValue value)
  let expected = case member ^. #spec of
        StatefulSet _ _ digest -> Just digest
        NativeObject digest -> Just digest
        _ -> Nothing
  unless (expected == Just (contentDigest canonical))
    (Left (invalid "restore native digest differs from accepted declaration"))
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
  :: ManualRestoreRequest -> ScopeDeclaration -> ManagedResource -> ManagedResource
  -> ManagedResource -> T.Text -> T.Text -> ContentDigest -> T.Text -> Value
  -> Either T.Text Value
annotateJob request accepted backupJob stateful pvc objectUrl receiptUrl receiptDigest scratch = \case
  Object root | Just (Object metadata) <- KM.lookup "metadata" root ->
    let annotations = object
          [ "nagare.dev/restore-id" .= restoreId request
          , "nagare.dev/restore-backup-job" .= resourceIdText (backupJob ^. #identity)
          , "nagare.dev/restore-backup-object" .= objectUrl
          , "nagare.dev/restore-backup-receipt" .= receiptUrl
          , "nagare.dev/restore-backup-receipt-digest" .= digestText receiptDigest
          , "nagare.dev/restore-target-scope" .= scopeIdText (scopeId accepted)
          , "nagare.dev/restore-target-revision" .= digestText
              (revisionDigest (restoreTargetRevision request))
          , "nagare.dev/restore-target-statefulset" .= resourceIdText (stateful ^. #identity)
          , "nagare.dev/restore-target-statefulset-uid" .= physicalIdentityText
              (restoreTargetStatefulUid request)
          , "nagare.dev/restore-target-pvc" .= resourceIdText (pvc ^. #identity)
          , "nagare.dev/restore-target-pvc-uid" .= physicalIdentityText (restoreTargetPvcUid request)
          , "nagare.dev/restore-target-database" .= scratch
          ]
     in Right (Object (KM.insert "metadata" (Object
          (KM.insert "annotations" annotations metadata)) root))
  _ -> Left "manual restore Job lacks native metadata"

data VolumeRestoreRequest = VolumeRestoreRequest
  { volumeRestoreApp :: !T.Text
  , volumeRestoreName :: !T.Text
  , volumeRestoreNamespace :: !T.Text
  , volumeRestoreId :: !T.Text
  , volumeRestoreBackup :: !ScopeDeclaration
  , volumeRestoreBackupRevision :: !ScopeRevision
  , volumeRestoreBackupJobUid :: !PhysicalIdentity
  , volumeRestoreReceiptBytes :: !ByteString
  , volumeRestoreNow :: !UTCTime
  , volumeRestoreTargetRevision :: !ScopeRevision
  , volumeRestoreTargetPvcUid :: !PhysicalIdentity
  , volumeRestoreBackend :: !StoreBackend
  , volumeRestoreCredential :: !(Maybe (ManagedResource, PhysicalIdentity))
  , volumeRestoreSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

-- | Both the completed backup Job and the current target PVC are pinned.
-- A local restore additionally pins its accepted credential copy.
volumeRestoreJobSourcePins
  :: ByteString -> Either T.Text (Maybe [(ResourceId, PhysicalIdentity)])
volumeRestoreJobSourcePins bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root | KM.lookup "kind" root == Just (String "Job")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , Just (Object annotations) <- KM.lookup "annotations" metadata
      , Just (String _) <- KM.lookup "nagare.dev/volume-restore-id" annotations -> do
          let required key = case KM.lookup key annotations of
                Just (String selected) -> Right selected
                _ -> Left ("volume restore Job lacks " <> K.toText key)
          backup <- required "nagare.dev/volume-restore-backup-job" >>= mkResourceId
          backupUid <- required "nagare.dev/volume-restore-backup-job-uid"
            >>= mkPhysicalIdentity
          target <- required "nagare.dev/volume-restore-target-pvc" >>= mkResourceId
          targetUid <- required "nagare.dev/volume-restore-target-pvc-uid"
            >>= mkPhysicalIdentity
          credential <- case (KM.lookup "nagare.dev/volume-restore-store-secret" annotations,
              KM.lookup "nagare.dev/volume-restore-store-secret-uid" annotations) of
            (Nothing, Nothing) -> Right []
            (Just (String rawId), Just (String rawUid)) -> do
              secret <- mkResourceId rawId
              physical <- mkPhysicalIdentity rawUid
              pure [(secret, physical)]
            _ -> Left "volume restore Job has incomplete credential pins"
          unless (backup /= target)
            (Left "volume restore Job repeats its source and target identity")
          pure (Just ([(backup, backupUid), (target, targetUid)] <> credential))
    _ -> Right Nothing

-- | Restore only an accepted manual volume snapshot into a distinct scratch
-- claim. The Job checks fresh object bytes against the accepted Pod receipt
-- before it extracts any archive member.
compileVolumeRestoreScope
  :: VolumeRestoreRequest -> ScopeDeclaration
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileVolumeRestoreScope request target native = do
  let backup = volumeRestoreBackup request
      invalid message = inventoryError "invalid-volume-restore" message
        & #scopes .~ [scopeId target, scopeId backup]
        & #sources .~ [volumeRestoreSource request]
        & (:| [])
      app = volumeRestoreApp request
      volume = volumeRestoreName request
      ns = volumeRestoreNamespace request
      restoreKey = volumeRestoreId request
      required key = maybe (Left (invalid ("volume backup lacks " <> key))) Right
        (Map.lookup key (scopeOverrides backup))
      selectPvc scope name =
        [member | bundle <- scopeBundles scope,
          Managed member <- declarations bundle,
          case member ^. #address of
            Kubernetes _ "" kind (Just namespace) nativeName ->
              nameText kind == "persistentvolumeclaim"
                && nameText namespace == ns && nameText nativeName == name
            _ -> False]
  _ <- first invalid (mkServiceName app)
  _ <- first invalid (mkServiceName volume)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName restoreKey)
  unless (T.length restoreKey <= 20)
    (Left (invalid "volume restore ID must contain at most 20 characters"))
  targetPvc <- case selectPvc target (pvcName app volume) of
    [single] -> Right single
    _ -> Left (invalid "volume restore requires one accepted target PVC")
  targetValue <- acceptedValue invalid native targetPvc
  size <- case targetValue of
    Object root | Just (Object specValue) <- KM.lookup "spec" root
      , Just (Object resources) <- KM.lookup "resources" specValue
      , Just (Object requests) <- KM.lookup "requests" resources
      , Just (String selected) <- KM.lookup "storage" requests
      , KM.lookup "storageClassName" specValue == Just (String "local-path") ->
        Right selected
    _ -> Left (invalid "accepted target PVC lacks a local-path storage request")
  backupJob <- case [member | bundle <- scopeBundles backup,
      Managed member <- declarations bundle,
      case member ^. #address of
        Kubernetes _ "batch" kind (Just namespace) _ ->
          nameText kind == "job" && nameText namespace == ns
        _ -> False] of
    [single] -> Right single
    _ -> Left (invalid "accepted volume backup lacks one Job")
  backupValue <- acceptedValue invalid native backupJob
  backupBytes <- first invalid (canonicalValue backupValue)
  backupId <- required "volume-backup.id"
  when (T.null backupId) (Left (invalid "volume backup ID is empty"))
  sourceScope <- required "volume-backup.source.scope"
  unless (sourceScope == scopeIdText (scopeId target))
    (Left (invalid "volume backup belongs to another application scope"))
  objectUrl <- required "volume-backup.object"
  receiptUrl <- required "volume-backup.receipt"
  expiry <- required "volume-backup.expiry"
  expiryEpoch <- if expiry == "retain" then Right Nothing else
    case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
        (T.unpack expiry) :: Maybe UTCTime of
      Nothing -> Left (invalid "volume backup expiry policy is invalid")
      Just selected -> do
        unless (selected > volumeRestoreNow request)
          (Left (invalid "volume backup has expired"))
        Right (Just (floor (utcTimeToPOSIXSeconds selected)))
  unless (objectUrl == storeObjectUrl (volumeRestoreBackend request)
      ("manual-volumes/" <> ns <> "/" <> app <> "/" <> volume <> "/"
        <> backupId <> ".tar.gz") && receiptUrl == objectUrl <> ".receipt.json")
    (Left (invalid "volume backup object differs from the selected backend"))
  expectation <- case manualBackupJobReceiptExpectation backupBytes of
    Right (Just selected) -> Right selected
    Right Nothing -> Left (invalid "accepted volume backup Job has no receipt")
    Left reason -> Left (invalid reason)
  checksum <- first invalid (parseBackupReceipt expectation receiptUrl
    (volumeRestoreReceiptBytes request))
  receiptValue <- first (invalid . T.pack)
    (eitherDecodeStrict (volumeRestoreReceiptBytes request))
  case receiptValue of
    Object root | Just (Object metadata) <- KM.lookup "backup" root -> do
      let field key = case KM.lookup key metadata of
            Just (String selected) -> Right selected
            _ -> Left (invalid ("volume backup receipt lacks " <> K.toText key))
      receiptId <- field "id"
      receiptApp <- field "app"
      receiptVolume <- field "volume"
      receiptNamespace <- field "namespace"
      receiptScope <- field "sourceScope"
      unless (receiptId == backupId && receiptApp == app
          && receiptVolume == volume && receiptNamespace == ns
          && receiptScope == sourceScope)
        (Left (invalid "volume backup receipt targets another app, volume, or scope"))
    _ -> Left (invalid "volume backup receipt lacks metadata")
  cluster <- case targetPvc ^. #address of
    Kubernetes selected _ _ _ _ -> Right selected
    _ -> Left (invalid "target PVC has no Kubernetes address")
  unless (sameCluster cluster backupJob)
    (Left (invalid "volume backup Job belongs to another cluster"))
  let credential = volumeRestoreCredential request
  case (volumeRestoreBackend request, credential) of
    (GcsBackend {}, Nothing) -> pure ()
    (MinioBackend ref, Just (secret, _)) -> do
      expected <- first invalid (kubernetesAddress cluster "v1" "Secret"
        (Just ns) (ref ^. #secretName))
      unless (secret ^. #address == expected)
        (Left (invalid "volume restore credential differs from its backend"))
      _ <- acceptedValue invalid native secret
      pure ()
    _ -> Left (invalid "volume restore credential differs from its backend")
  owner <- first invalid (mkScopeId Standalone
    ("volume-restore-" <> ns <> "-" <> app <> "-" <> volume <> "-" <> restoreKey))
  key <- first invalid (mkLogicalKey restoreKey)
  pvcRole <- first invalid (mkName "pvc")
  jobRole <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "restore")
  let pvcId = mintResourceId owner key pvcRole
      jobId = mintResourceId owner key jobRole
      proofId = mintResourceId owner key proofRole
      scratchName = "nagare-restore-" <> app <> "-" <> volume <> "-" <> restoreKey
      jobName = "nagare-volrestore-" <> app <> "-" <> volume <> "-" <> restoreKey
  unless (T.length scratchName <= 63 && T.length jobName <= 63)
    (Left (invalid "volume restore name exceeds 63 characters"))
  scratchValue <- first (invalid . T.pack . show)
    (Yaml.decodeEither' (Volume.renderScratchPvc ns scratchName size)
      :: Either Yaml.ParseException Value)
  scratchCanonical <- first invalid (canonicalValue scratchValue)
  (scratch, scratchBytes) <- first (:| []) (bindKubernetesObject KubernetesInput
    { resourceId = pvcId, ownerScope = owner, clusterId = cluster
    , inputObject = scratchValue, objectDigest = contentDigest scratchCanonical
    , lifecyclePolicy = DeleteWhenUnreferenced, inputDataPolicy = Stateless
    , inputSensitivity = Private, sourceLocation = volumeRestoreSource request })
  let jobInputs = Volume.StorageRestoreJobInputs ns jobName scratchName objectUrl
        "/restore" (volumeRestoreBackend request)
      reviewed = Volume.ReviewedVolumeRestoreInputs jobInputs receiptUrl
        (digestText (contentDigest (volumeRestoreReceiptBytes request))) checksum expiryEpoch
  rendered <- first (invalid . T.pack . show)
    (Yaml.decodeEither' (Volume.renderReviewedVolumeRestoreJob reviewed)
      :: Either Yaml.ParseException Value)
  jobValue <- case rendered of
    Object root | Just (Object metadata) <- KM.lookup "metadata" root ->
      let annotations = object
            ([ "nagare.dev/volume-restore-id" .= restoreKey
             , "nagare.dev/volume-restore-backup-job" .=
                 resourceIdText (backupJob ^. #identity)
             , "nagare.dev/volume-restore-backup-job-uid" .=
                 physicalIdentityText (volumeRestoreBackupJobUid request)
             , "nagare.dev/volume-restore-target-pvc" .=
                 resourceIdText (targetPvc ^. #identity)
             , "nagare.dev/volume-restore-target-pvc-uid" .=
                 physicalIdentityText (volumeRestoreTargetPvcUid request)
             ] <> case credential of
               Nothing -> []
               Just (secret, uid) ->
                 [ "nagare.dev/volume-restore-store-secret" .=
                     resourceIdText (secret ^. #identity)
                 , "nagare.dev/volume-restore-store-secret-uid" .=
                     physicalIdentityText uid ])
       in Right (Object (KM.insert "metadata" (Object
            (KM.insert "annotations" annotations metadata)) root))
    _ -> Left (invalid "volume restore Job lacks native metadata")
  jobCanonical <- first invalid (canonicalValue jobValue)
  (boundJob, jobBytes) <- first (:| []) (bindKubernetesObject KubernetesInput
    { resourceId = jobId, ownerScope = owner, clusterId = cluster
    , inputObject = jobValue, objectDigest = contentDigest jobCanonical
    , lifecyclePolicy = DeleteWhenUnreferenced, inputDataPolicy = Stateless
    , inputSensitivity = Private, sourceLocation = volumeRestoreSource request })
  expectedScratch <- first invalid (kubernetesAddress cluster "v1"
    "PersistentVolumeClaim" (Just ns) scratchName)
  expectedJob <- first invalid (kubernetesAddress cluster "batch/v1" "Job"
    (Just ns) jobName)
  unless (scratch ^. #address == expectedScratch && boundJob ^. #address == expectedJob)
    (Left (invalid "volume restore members have unexpected native addresses"))
  let prerequisites = [scratch ^. #identity, backupJob ^. #identity,
        targetPvc ^. #identity]
          <> maybe [] (\(secret, _) -> [secret ^. #identity]) credential
      job = boundJob {dependencies = map OrderedAfter prerequisites}
      proof = DeclaredOperation proofId (jobId :| [])
        [ContentInput (contentDigest jobBytes), ContentInput
          (contentDigest (volumeRestoreReceiptBytes request))]
        VerifyBeforeRetry RestoreData
      overrides = Map.fromList
        [ ("volume-restore.id", restoreKey)
        , ("volume-restore.backup.scope", scopeIdText (scopeId backup))
        , ("volume-restore.backup.revision", digestText
            (revisionDigest (volumeRestoreBackupRevision request)))
        , ("volume-restore.backup.job", resourceIdText (backupJob ^. #identity))
        , ("volume-restore.backup.job.uid", physicalIdentityText
            (volumeRestoreBackupJobUid request))
        , ("volume-restore.backup.receipt.digest", digestText
            (contentDigest (volumeRestoreReceiptBytes request)))
        , ("volume-restore.backup.sha256", checksum)
        , ("volume-restore.target.scope", scopeIdText (scopeId target))
        , ("volume-restore.target.revision", digestText
            (revisionDigest (volumeRestoreTargetRevision request)))
        , ("volume-restore.target.pvc", resourceIdText (targetPvc ^. #identity))
        , ("volume-restore.target.pvc.uid", physicalIdentityText
            (volumeRestoreTargetPvcUid request))
        , ("volume-restore.scratch", scratchName)
        ]
  base <- mkScopeDeclaration owner
    [ResourceBundle [Managed scratch, Managed job] [] [] [] [proof] []]
  pure (withScopeOverrides overrides
    (withScopeConfigDigest (contentDigest jobCanonical) base),
    Map.fromList [(pvcId, (scratch, scratchBytes)), (jobId, (job, jobBytes))])
