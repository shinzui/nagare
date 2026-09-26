-- | Compile one reviewed manual database backup as an independent Job scope.
-- The accepted database revision and observed source UIDs are part of its
-- immutable intent. Job completion alone is not a durable object receipt;
-- the upload script checks the exact stored bytes before completion.
module Nagare.Inventory.Backup
  ( ManualBackupRequest (..)
  , BackupSourceProof (..)
  , manualBackupSourceProof
  , manualBackupJobSourcePins
  , compileManualBackupScope
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
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend, storeObjectUrl, storePrefixUrl)
import Nagare.Database.Backup
  ( BackupDest (..), BackupJobInputs (..), backupExt, dbBackupKeyPrefix
  , dbBackupObjectPath, manualBackupJobName, renderBackupJob )
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
        (dbBackupObjectPath database (backupId request) (backupExt engine))
      expiry = maybe "retain" (T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ")
        (expiresAt request)
      inputs = BackupJobInputs
        { namespace = ns
        , jobName = jobName
        , engine = engine
        , clientImage = engineImage engine <> ":" <> version
        , serviceHost = database
        , secretName = dbSecretName database
        , name = database
        , destination = BackupDestUrl objectUrl
        , prefix = storePrefixUrl (storageBackend request) (dbBackupKeyPrefix database)
        , keep = 0
        , selfPrune = False
        , verifyStored = True
        , backend = storageBackend request
        }
  rendered <- first (invalid . T.pack . show)
    (Yaml.decodeEither' (renderBackupJob inputs) :: Either Yaml.ParseException Value)
  job <- first invalid (annotateJob request accepted pvc stateful objectUrl expiry rendered)
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
  -> T.Text -> T.Text -> Value -> Either T.Text Value
annotateJob request accepted pvc stateful objectUrl expiry = \case
  Object root | Just (Object metadata) <- KM.lookup "metadata" root ->
    let annotations = object
          [ "nagare.dev/backup-id" .= backupId request
          , "nagare.dev/backup-object" .= objectUrl
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
