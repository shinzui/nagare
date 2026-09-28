-- | An operation-only live database restore binds one accepted target and two
-- independently verified manual backups. The source is the requested content;
-- the recovery backup is the pre-change rollback position. Neither backup
-- authorizes a target from another revision or physical incarnation.
module Nagare.Inventory.LiveRestore
  ( LiveBackupInput (..)
  , LiveBackupProof (..)
  , LiveRestoreRequest (..)
  , LiveRestoreProof (..)
  , liveRestoreProof
  , compileLiveRestoreScope
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), defaultOptions,
  eitherDecodeStrict', genericParseJSON, genericToJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Nagare.Cluster.GcsJob (StoreBackend, storeObjectUrl)
import Nagare.Database.Backup (backupExt, manualBackupObjectPath)
import Nagare.Dsl.Database (Engine (Postgres), engineToken, parseEngine)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Backup (parseManualBackupReceipt)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryClass (OperatorRecovery))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data LiveBackupInput = LiveBackupInput
  { liveBackupScope :: !ScopeDeclaration
  , liveBackupRevision :: !ScopeRevision
  , liveBackupJobUid :: !PhysicalIdentity
  , liveBackupReceiptBytes :: !ByteString
  }
  deriving stock (Eq, Show)

data LiveBackupProof = LiveBackupProof
  { liveBackupScopeId :: !ScopeId
  , liveBackupScopeRevision :: !ScopeRevision
  , liveBackupJob :: !ResourceId
  , liveBackupPhysical :: !PhysicalIdentity
  , liveBackupId :: !Text
  , liveBackupObject :: !Text
  , liveBackupReceipt :: !Text
  , liveBackupReceiptDigest :: !ContentDigest
  , liveBackupSha256 :: !Text
  , liveBackupExpiryEpoch :: !Integer
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON LiveBackupProof where toJSON = genericToJSON defaultOptions
instance FromJSON LiveBackupProof where parseJSON = genericParseJSON defaultOptions

data LiveRestoreRequest = LiveRestoreRequest
  { liveRestoreDatabase :: !Text
  , liveRestoreNamespace :: !Text
  , liveRestoreId :: !Text
  , liveRestoreTargetRevision :: !ScopeRevision
  , liveRestoreStatefulUid :: !PhysicalIdentity
  , liveRestorePvcUid :: !PhysicalIdentity
  , liveRestorePodUid :: !PhysicalIdentity
  , liveRestoreSourceBackup :: !LiveBackupInput
  , liveRestoreRecoveryBackup :: !LiveBackupInput
  , liveRestoreBackend :: !StoreBackend
  , liveRestoreSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

data LiveRestoreProof = LiveRestoreProof
  { liveRestoreProofId :: !Text
  , liveRestoreProofEngine :: !Text
  , liveRestoreProofDatabase :: !Text
  , liveRestoreProofNamespace :: !Text
  , liveRestoreProofTargetScope :: !ScopeId
  , liveRestoreProofTargetRevision :: !ScopeRevision
  , liveRestoreProofStateful :: !ResourceId
  , liveRestoreProofStatefulUid :: !PhysicalIdentity
  , liveRestoreProofPvc :: !ResourceId
  , liveRestoreProofPvcUid :: !PhysicalIdentity
  , liveRestoreProofPodUid :: !PhysicalIdentity
  , liveRestoreProofSource :: !LiveBackupProof
  , liveRestoreProofRecovery :: !LiveBackupProof
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON LiveRestoreProof where toJSON = genericToJSON defaultOptions
instance FromJSON LiveRestoreProof where parseJSON = genericParseJSON defaultOptions

liveRestoreProof :: ScopeDeclaration -> Either Text (Maybe LiveRestoreProof)
liveRestoreProof scope = case Map.lookup "live.restore.proof" (scopeOverrides scope) of
  Nothing -> Right Nothing
  Just encoded -> Just <$> do
    let bytes = TE.encodeUtf8 encoded
    proof <- first T.pack (eitherDecodeStrict' bytes)
    canonical <- canonicalValue (toJSON (proof :: LiveRestoreProof))
    unless (canonical == bytes)
      (Left "live restore proof is not canonical or has unknown fields")
    _ <- mkServiceName (liveRestoreProofId proof)
    _ <- mkServiceName (liveRestoreProofDatabase proof)
    _ <- mkServiceName (liveRestoreProofNamespace proof)
    unless (T.length (liveRestoreProofId proof) <= 20
      && parseEngine (liveRestoreProofEngine proof) == Just Postgres
      && liveBackupId (liveRestoreProofSource proof)
        /= liveBackupId (liveRestoreProofRecovery proof)
      && liveBackupScopeId (liveRestoreProofSource proof)
        /= liveBackupScopeId (liveRestoreProofRecovery proof))
      (Left "live restore proof has unsupported engine, session, or recovery")
    owner <- mkScopeId Standalone
      ("database-live-restore-" <> liveRestoreProofNamespace proof <> "-"
        <> liveRestoreProofDatabase proof <> "-" <> liveRestoreProofId proof)
    key <- mkLogicalKey (liveRestoreProofId proof)
    role <- mkName "restore"
    let operations = [operation | bundle <- scopeBundles scope,
          operation <- Nagare.Resource.Inventory.operations bundle]
    unless (scopeId scope == owner
      && scopeConfigDigest scope == Just (contentDigest bytes)
      && Map.size (scopeOverrides scope) == 1
      && case operations of
        [operation] -> operation == DeclaredOperation
          (mintResourceId owner key role)
          (liveRestoreProofStateful proof :| [])
          [ContentInput (contentDigest bytes)] OperatorRecovery RestoreLiveData
        _ -> False)
      (Left "live restore operation differs from its canonical source proof")
    pure proof

compileLiveRestoreScope :: LiveRestoreRequest -> ScopeDeclaration
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError) ScopeDeclaration
compileLiveRestoreScope request accepted native = do
  let invalid message = inventoryError "invalid-live-restore" message
        & #scopes .~ [scopeId accepted,
            scopeId (liveBackupScope (liveRestoreSourceBackup request)),
            scopeId (liveBackupScope (liveRestoreRecoveryBackup request))]
        & #sources .~ [liveRestoreSource request]
        & (:| [])
      db = liveRestoreDatabase request
      ns = liveRestoreNamespace request
      select group kind name = [member | bundle <- scopeBundles accepted,
        Managed member <- declarations bundle,
        case member ^. #address of
          Kubernetes _ api selectedKind (Just selectedNamespace) selectedName ->
            api == group && nameText selectedKind == kind
              && nameText selectedNamespace == ns && nameText selectedName == name
          _ -> False]
      one label = \case
        [member] -> Right member
        _ -> Left (invalid ("live restore requires one accepted " <> label))
      nativeValue member = case Map.lookup (member ^. #identity) native of
        Just (bound, bytes) | bound == member ->
          first (invalid . T.pack) (eitherDecodeStrict' bytes)
        _ -> Left (invalid "live restore lacks matching accepted native bytes")
  _ <- first invalid (mkServiceName db)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName (liveRestoreId request))
  unless (T.length (liveRestoreId request) <= 20
    && scopeKind (scopeId accepted) `elem` [Application, Standalone])
    (Left (invalid "live restore ID or target scope is invalid"))
  stateful <- one "database StatefulSet" (select "apps" "statefulset" db)
  pvc <- one "database PVC" (select "" "persistentvolumeclaim" (dbPvcName db))
  unless (case (stateful ^. #address, pvc ^. #address) of
      (Kubernetes statefulCluster _ _ _ _, Kubernetes pvcCluster _ _ _ _) ->
        statefulCluster == pvcCluster
      _ -> False)
    (Left (invalid "live restore target StatefulSet and PVC belong to different clusters"))
  statefulValue <- nativeValue stateful
  _ <- nativeValue pvc
  unless (case statefulValue of
      Object root | Just (Object metadata) <- KM.lookup "metadata" root
        , Just (Object labels) <- KM.lookup "labels" metadata ->
            KM.lookup "nagare.dev/engine" labels
              == Just (String (engineToken Postgres))
      _ -> False)
    (Left (invalid "live restore currently requires an accepted PostgreSQL database"))
  source <- validateBackup invalid request accepted native stateful pvc
    (liveRestoreSourceBackup request)
  recovery <- validateBackup invalid request accepted native stateful pvc
    (liveRestoreRecoveryBackup request)
  unless (liveBackupId source /= liveBackupId recovery
      && liveBackupScopeId source /= liveBackupScopeId recovery)
    (Left (invalid "live restore source and recovery backups must be distinct"))
  let proof = LiveRestoreProof
        (liveRestoreId request) (engineToken Postgres) db ns
        (scopeId accepted) (liveRestoreTargetRevision request)
        (stateful ^. #identity) (liveRestoreStatefulUid request)
        (pvc ^. #identity) (liveRestorePvcUid request)
        (liveRestorePodUid request) source recovery
  proofBytes <- first invalid (canonicalValue (toJSON proof))
  owner <- first invalid (mkScopeId Standalone
    ("database-live-restore-" <> ns <> "-" <> db <> "-" <> liveRestoreId request))
  key <- first invalid (mkLogicalKey (liveRestoreId request))
  role <- first invalid (mkName "restore")
  let operationId = mintResourceId owner key role
      operation = DeclaredOperation operationId (stateful ^. #identity :| [])
        [ContentInput (contentDigest proofBytes)] OperatorRecovery RestoreLiveData
  base <- mkScopeDeclaration owner [ResourceBundle [] [] [] [] [operation] []]
  pure (withScopeOverrides (Map.singleton "live.restore.proof"
    (TE.decodeUtf8 proofBytes))
    (withScopeConfigDigest (contentDigest proofBytes) base))

validateBackup :: (Text -> NonEmpty InventoryError) -> LiveRestoreRequest
  -> ScopeDeclaration -> Map ResourceId (ManagedResource, ByteString)
  -> ManagedResource -> ManagedResource -> LiveBackupInput
  -> Either (NonEmpty InventoryError) LiveBackupProof
validateBackup invalid request target native stateful pvc backup = do
  let scope = liveBackupScope backup
      fields = scopeOverrides scope
      required key = maybe (Left (invalid ("live backup lacks " <> key))) Right
        (Map.lookup key fields)
      expectedScope = scopeIdText (scopeId target)
      expectedGeneration = T.pack (show (generationNumber
        (revisionGeneration (liveRestoreTargetRevision request))))
      expectedRevision = digestText
        (revisionDigest (liveRestoreTargetRevision request))
      expectedStateful = resourceIdText (stateful ^. #identity)
      expectedPvc = resourceIdText (pvc ^. #identity)
  unless (Map.notMember "scheduled.backup.id" fields
      && Map.lookup "backup.source.scope" fields == Just expectedScope
      && Map.lookup "backup.source.generation" fields == Just expectedGeneration
      && Map.lookup "backup.source.revision" fields == Just expectedRevision
      && Map.lookup "backup.source.statefulset" fields == Just expectedStateful
      && Map.lookup "backup.source.statefulset.uid" fields
        == Just (physicalIdentityText (liveRestoreStatefulUid request))
      && Map.lookup "backup.source.pvc" fields == Just expectedPvc
      && Map.lookup "backup.source.pvc.uid" fields
        == Just (physicalIdentityText (liveRestorePvcUid request)))
    (Left (invalid "live backup belongs to another target revision or incarnation"))
  backupId <- required "backup.id"
  objectUrl <- required "backup.object"
  receiptUrl <- required "backup.receipt"
  expiry <- required "backup.expiry"
  let expectedObject = storeObjectUrl (liveRestoreBackend request)
        (manualBackupObjectPath (liveRestoreDatabase request)
          (liveRestoreNamespace request) backupId (backupExt Postgres))
  unless (objectUrl == expectedObject && receiptUrl == objectUrl <> ".receipt.json")
    (Left (invalid "live backup object or receipt has another address"))
  expiryEpoch <- if expiry == "retain" then Right 0 else
    case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
      (T.unpack expiry) :: Maybe UTCTime of
      Just deadline -> Right (floor (utcTimeToPOSIXSeconds deadline))
      Nothing -> Left (invalid "live backup expiry is malformed")
  checksum <- first invalid (parseManualBackupReceipt scope receiptUrl
    (liveBackupReceiptBytes backup))
  receiptValue <- first (invalid . T.pack)
    (eitherDecodeStrict' (liveBackupReceiptBytes backup))
  unless (case receiptValue of
      Object root | Just (Object metadata) <- KM.lookup "backup" root ->
        all (\(key, expected) -> KM.lookup key metadata == Just (String expected))
          [("database", liveRestoreDatabase request),
            ("namespace", liveRestoreNamespace request),
            ("engine", engineToken Postgres), ("id", backupId)]
      _ -> False)
    (Left (invalid "live backup receipt names another database or engine"))
  job <- case [member | bundle <- scopeBundles scope,
    Managed member <- declarations bundle,
    case member ^. #address of
      Kubernetes _ "batch" kind (Just namespace) _ ->
        nameText kind == "job" && nameText namespace == liveRestoreNamespace request
      _ -> False] of
    [member] -> Right member
    _ -> Left (invalid "live backup has no unique accepted Job")
  unless (case Map.lookup (job ^. #identity) native of
      Just (bound, _) -> bound == job
      Nothing -> False)
    (Left (invalid "live backup Job lacks accepted native evidence"))
  unless (case (stateful ^. #address, job ^. #address) of
      (Kubernetes targetCluster _ _ _ _, Kubernetes backupCluster _ _ _ _) ->
        targetCluster == backupCluster
      _ -> False)
    (Left (invalid "live backup Job belongs to another cluster"))
  pure LiveBackupProof
    { liveBackupScopeId = scopeId scope
    , liveBackupScopeRevision = liveBackupRevision backup
    , liveBackupJob = job ^. #identity
    , liveBackupPhysical = liveBackupJobUid backup
    , liveBackupId = backupId
    , liveBackupObject = objectUrl
    , liveBackupReceipt = receiptUrl
    , liveBackupReceiptDigest = contentDigest (liveBackupReceiptBytes backup)
    , liveBackupSha256 = checksum
    , liveBackupExpiryEpoch = expiryEpoch
    }
