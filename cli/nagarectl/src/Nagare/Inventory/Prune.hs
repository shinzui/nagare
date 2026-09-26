-- | Compile expiry-gated manual backup pruning as an independent reviewed Job.
-- Its declared operation names only one accepted backup, its exact receipt,
-- and the fixed object keys. The provider script does the final version check.
module Nagare.Inventory.Prune
  ( ManualPruneRequest (..)
  , PruneSourceProof (..)
  , manualPruneSourceProof
  , manualPruneJobBackupPin
  , compileManualPruneScope
  ) where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend, storeObjectUrl)
import Nagare.Database.Backup (backupExt, manualBackupObjectPath, manualDatabaseJobName)
import Nagare.Database.Prune (PruneJobInputs (..), renderPruneJob)
import Nagare.Dsl.Database (parseEngine)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Backup (parseManualBackupReceipt)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
  ( DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced)
  , RecoveryClass (OperatorRecovery), Sensitivity (Private) )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data ManualPruneRequest = ManualPruneRequest
  { pruneDatabaseName :: !Text
  , pruneNamespaceName :: !Text
  , pruneBackupId :: !Text
  , pruneBackupRevision :: !ScopeRevision
  , pruneBackupUid :: !PhysicalIdentity
  , pruneReceiptBytes :: !ByteString
  , pruneNow :: !UTCTime
  , pruneStorageBackend :: !StoreBackend
  , pruneSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

data PruneSourceProof = PruneSourceProof
  { pruneSourceScope :: !Text
  , pruneSourceRevision :: !ContentDigest
  , pruneSourceJob :: !ResourceId
  , pruneSourceUid :: !PhysicalIdentity
  }
  deriving stock (Eq, Show)

manualPruneSourceProof :: ScopeDeclaration -> Either Text (Maybe PruneSourceProof)
manualPruneSourceProof scope
  | Map.notMember "prune.backup.scope" values = Right Nothing
  | otherwise = Just <$> (PruneSourceProof
      <$> required "prune.backup.scope"
      <*> (required "prune.backup.revision" >>= mkContentDigest)
      <*> (required "prune.backup.job" >>= mkResourceId)
      <*> (required "prune.backup.job.uid" >>= mkPhysicalIdentity))
  where
    values = scopeOverrides scope
    required key = maybe (Left ("manual prune scope lacks " <> key)) Right
      (Map.lookup key values)

manualPruneJobBackupPin :: ByteString -> Either Text (Maybe (ResourceId, PhysicalIdentity))
manualPruneJobBackupPin bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root | KM.lookup "kind" root == Just (String "Job")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , Just (Object annotations) <- KM.lookup "annotations" metadata
      , Just (String _) <- KM.lookup "nagare.dev/prune-backup-scope" annotations -> do
          job <- case KM.lookup "nagare.dev/prune-backup-job" annotations of
            Just (String field) -> Right field
            _ -> Left "manual prune Job lacks backup Job ID"
          resource <- mkResourceId job
          uid <- case KM.lookup "nagare.dev/prune-backup-job-uid" annotations of
            Just (String field) -> mkPhysicalIdentity field
            _ -> Left "manual prune Job lacks backup Job UID"
          pure (Just (resource, uid))
    _ -> Right Nothing

compileManualPruneScope
  :: ManualPruneRequest
  -> ScopeDeclaration
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileManualPruneScope request backup native = do
  let invalid message = inventoryError "invalid-manual-prune" message
        & #scopes .~ [scopeId backup]
        & #sources .~ [pruneSource request]
        & (:| [])
      required key = maybe (Left (invalid ("manual backup lacks " <> key))) Right
        (Map.lookup key (scopeOverrides backup))
      db = pruneDatabaseName request
      ns = pruneNamespaceName request
      backupId = pruneBackupId request
  _ <- first invalid (mkServiceName db)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName backupId)
  unless (T.length backupId <= 20)
    (Left (invalid "backup ID must contain at most 20 characters"))
  acceptedId <- required "backup.id"
  unless (acceptedId == backupId)
    (Left (invalid "backup ID differs from the accepted scope"))
  expiryText <- required "backup.expiry"
  expiry <- case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
    (T.unpack expiryText) :: Maybe UTCTime of
    Nothing -> Left (invalid "backup has no finite UTC expiry")
    Just selected -> Right selected
  unless (expiry <= pruneNow request)
    (Left (invalid "backup has not reached its reviewed expiry"))
  objectAddress <- required "backup.object"
  receiptAddress <- required "backup.receipt"
  unless (receiptAddress == objectAddress <> ".receipt.json")
    (Left (invalid "backup receipt address differs from the backup object"))
  checksum <- first invalid (parseManualBackupReceipt backup receiptAddress
    (pruneReceiptBytes request))
  receiptValue <- first (invalid . T.pack) (eitherDecodeStrict (pruneReceiptBytes request))
  engineName <- case receiptValue of
    Object root | Just (Object metadata) <- KM.lookup "backup" root
      , Just (String engine) <- KM.lookup "engine" metadata
      , KM.lookup "database" metadata == Just (String db)
      , KM.lookup "namespace" metadata == Just (String ns)
      , KM.lookup "id" metadata == Just (String backupId) -> Right engine
    _ -> Left (invalid "backup receipt identifies another database, namespace, or ID")
  engine <- maybe (Left (invalid "backup receipt has an unknown engine")) Right
    (parseEngine engineName)
  let expectedObject = storeObjectUrl (pruneStorageBackend request)
        (manualBackupObjectPath db ns backupId (backupExt engine))
  unless (objectAddress == expectedObject)
    (Left (invalid "backup object is outside the selected backend and database"))
  backupJob <- case [member | bundle <- scopeBundles backup,
      Managed member <- declarations bundle,
      case member ^. #address of
        Kubernetes _ "batch" kind (Just namespace) _ ->
          nameText kind == "job" && nameText namespace == ns
        _ -> False] of
    [single] -> Right single
    _ -> Left (invalid "accepted manual backup lacks one Job")
  (boundBackup, backupBytes) <- maybe
    (Left (invalid "accepted manual backup Job lacks private native evidence")) Right
    (Map.lookup (backupJob ^. #identity) native)
  unless (boundBackup == backupJob)
    (Left (invalid "accepted backup Job differs from private native evidence"))
  backupValue <- first (invalid . T.pack) (eitherDecodeStrict backupBytes)
  backupCanonical <- first invalid (canonicalValue backupValue)
  unless (backupJob ^. #spec == NativeObject (contentDigest backupCanonical))
    (Left (invalid "accepted backup Job native digest changed"))
  cluster <- case backupJob ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "accepted backup Job is not in Kubernetes")
  owner <- first invalid (mkScopeId Standalone
    ("database-prune-" <> ns <> "-" <> db <> "-" <> backupId))
  key <- first invalid (mkLogicalKey backupId)
  role <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "prune")
  let jobId = mintResourceId owner key role
      proofId = mintResourceId owner key proofRole
      receiptDigest = contentDigest (pruneReceiptBytes request)
      jobName = manualDatabaseJobName "nagare-dbprune-" db backupId
      inputs = PruneJobInputs
        { namespace = ns, jobName = jobName
        , objectUrl = objectAddress, receiptUrl = receiptAddress
        , objectSha256 = checksum, receiptSha256 = digestText receiptDigest
        , expiryEpoch = floor (utcTimeToPOSIXSeconds expiry)
        , backend = pruneStorageBackend request }
  rendered <- first (invalid . T.pack . show)
    (Yaml.decodeEither' (renderPruneJob inputs) :: Either Yaml.ParseException Value)
  annotated <- first invalid (annotateJob request backup backupJob receiptDigest checksum rendered)
  canonical <- first invalid (canonicalValue annotated)
  (bound, bytes) <- first (:| []) (bindKubernetesObject KubernetesInput
    { resourceId = jobId, ownerScope = owner, clusterId = cluster
    , inputObject = annotated, objectDigest = contentDigest canonical
    , lifecyclePolicy = DeleteWhenUnreferenced, inputDataPolicy = Stateless
    , inputSensitivity = Private, sourceLocation = pruneSource request })
  expected <- first invalid (kubernetesAddress cluster "batch/v1" "Job" (Just ns) jobName)
  unless (bound ^. #address == expected)
    (Left (invalid "prune Job has an unexpected native address"))
  let member = bound {dependencies = [OrderedAfter (backupJob ^. #identity)]}
      proof = DeclaredOperation proofId (jobId :| [])
        [ContentInput (contentDigest bytes), ContentInput receiptDigest]
        OperatorRecovery PruneData
      overrides = Map.fromList
        [ ("prune.backup.scope", scopeIdText (scopeId backup))
        , ("prune.backup.revision", digestText (revisionDigest (pruneBackupRevision request)))
        , ("prune.backup.job", resourceIdText (backupJob ^. #identity))
        , ("prune.backup.job.uid", physicalIdentityText (pruneBackupUid request))
        , ("prune.backup.id", backupId)
        , ("prune.object", objectAddress)
        , ("prune.object.sha256", checksum)
        , ("prune.receipt", receiptAddress)
        , ("prune.receipt.digest", digestText receiptDigest)
        , ("prune.expiry", expiryText)
        ]
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  pure (withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base),
    Map.singleton jobId (member, bytes))

annotateJob
  :: ManualPruneRequest -> ScopeDeclaration -> ManagedResource
  -> ContentDigest -> Text -> Value
  -> Either Text Value
annotateJob request backup backupJob receiptDigest checksum = \case
  Object root | Just (Object metadata) <- KM.lookup "metadata" root ->
    let annotations = object
          [ "nagare.dev/prune-backup-scope" .= scopeIdText (scopeId backup)
          , "nagare.dev/prune-backup-job" .= resourceIdText (backupJob ^. #identity)
          , "nagare.dev/prune-backup-job-uid" .= physicalIdentityText (pruneBackupUid request)
          , "nagare.dev/prune-receipt-digest" .= digestText receiptDigest
          , "nagare.dev/prune-object-sha256" .= checksum
          ]
     in Right (Object (KM.insert "metadata" (Object
          (KM.insert "annotations" annotations metadata)) root))
  _ -> Left "prune Job metadata is invalid"
