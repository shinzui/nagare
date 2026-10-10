-- | EP-183 M4: restore a rebuilt PostgreSQL database's data from the one
-- recovery point its rebuild named. ADR 27 lets a backup restore only into
-- the incarnation it was taken from; this is its single exception. The volume
-- must be the incarnation a converged rebuild created ('RebuildLineage'), the
-- receipt must be that rebuild's recovery point byte for byte, and the receipt
-- must have been verified with the escrowed key of the predecessor the rebuild
-- named. The Job loads only into an empty database, in one transaction.
module Nagare.Inventory.RebuildRestore
  ( RebuildRestoreRequest (..)
  , compileRebuildRestoreScope
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend, storeObjectUrl)
import Nagare.Database.Backup (manualDatabaseJobName)
import Nagare.Database.Restore (RestoreJobInputs (..), VerifiedRestoreSource (..), renderRebuildRestoreJob)
import Nagare.Dsl.Database (Engine (Postgres), dbSecretName, engineImage, parseEngine)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Backup (ScheduledBackupReceipt (..))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Lineage (RebuildSource (..), RecoveryPointKind (..))
import Nagare.Inventory.LineageHistory (RebuildLineage (..))
import Nagare.Inventory.RestoreNative (acceptedValue, sameCluster)
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), RecoveryClass (VerifyBeforeRetry), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data RebuildRestoreRequest = RebuildRestoreRequest
  { database :: !Text
  , namespace :: !Text
  , restoreId :: !Text
  , targetRevision :: !ScopeRevision
  , targetStatefulUid :: !PhysicalIdentity
  -- ^ The live StatefulSet, checked against its recorded incarnation.
  , targetPvcUid :: !PhysicalIdentity
  -- ^ The live volume, checked against its recorded incarnation.
  , lineage :: !RebuildLineage
  -- ^ The rebuild that created the volume's recorded incarnation.
  , escrowPvcUid :: !PhysicalIdentity
  -- ^ The source volume the escrow binds; the receipt's signature covers it.
  , evidence :: !ScheduledReceiptEvidence
  -- ^ The receipt and archive, verified with that escrowed key.
  , backend :: !StoreBackend
  , source :: !SourceLocation
  }
  deriving stock (Generic)

compileRebuildRestoreScope ::
  RebuildRestoreRequest ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileRebuildRestoreScope request accepted native = do
  let invalid message =
        inventoryError "invalid-rebuild-restore" message
          & #scopes
          .~ [scopeId accepted]
          & #sources
          .~ [request ^. #source]
          & (:| [])
      db = request ^. #database
      ns = request ^. #namespace
      receipt = scheduledReceipt (request ^. #evidence)
      objectUrl = scheduledObjectAddress receipt
      receiptUrl = objectUrl <> ".receipt.json"
      receiptDigest = scheduledReceiptDigest (request ^. #evidence)
      select group kind name =
        [ member
        | bundle <- scopeBundles accepted
        , Managed member <- declarations bundle
        , case member ^. #address of
            Kubernetes _ api resourceKind (Just namespace') nativeName ->
              api == group && nameText resourceKind == kind && nameText namespace' == ns && nameText nativeName == name
            _ -> False
        ]
      exactlyOne label members = case members of
        [member] -> Right member
        _ -> Left (invalid ("rebuild restore has no unique " <> label))
  unless
    (scopeKind (scopeId accepted) `elem` [Application, Standalone])
    (Left (invalid "rebuild restore requires an accepted database scope"))
  _ <- first invalid (mkServiceName db)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName (request ^. #restoreId))
  unless (T.length (request ^. #restoreId) <= 20) (Left (invalid "restore ID must contain at most 20 characters"))
  stateful <- exactlyOne "StatefulSet" (select "apps" "statefulset" db)
  pvc <- exactlyOne "PVC" (select "" "persistentvolumeclaim" (dbPvcName db))
  credential <- exactlyOne "credential" (select "" "secret" (dbSecretName db))
  -- The lineage: the volume is the incarnation a converged rebuild created.
  let lineage' = request ^. #lineage
  unless
    (lineage' ^. #resource == pvc ^. #identity && lineage' ^. #incarnation == request ^. #targetPvcUid)
    (Left (invalid "the target volume is not the incarnation a reviewed rebuild created; only that incarnation receives its predecessor's recovery point"))
  point <- case lineage' ^. #proof . #source of
    FromRecoveryPoint selected | selected ^. #kind == ScheduledRecoveryPoint -> Right selected
    FromRecoveryPoint _ -> Left (invalid "the rebuild names a manual recovery point; a rebuild restore loads only a scheduled one")
    Fresh -> Left (invalid "the rebuild started the volume fresh; it names no recovery point")
  unless
    (Just (request ^. #escrowPvcUid) == lineage' ^. #proof . #predecessor)
    (Left (invalid "the receipt was verified with the escrow of another incarnation than the rebuild's predecessor"))
  unless
    (point ^. #receipt == receiptUrl && point ^. #receiptDigest == receiptDigest)
    (Left (invalid "the verified receipt is not the recovery point the rebuild named"))
  unless
    (storeObjectUrl (request ^. #backend) ("databases/" <> db <> "/") `T.isPrefixOf` objectUrl && ".sql.gz" `T.isSuffixOf` objectUrl)
    (Left (invalid "the recovery point is not a scheduled PostgreSQL backup of this database in the selected store"))
  statefulValue <- acceptedValue invalid native stateful
  _ <- acceptedValue invalid native pvc
  _ <- acceptedValue invalid native credential
  cluster <- case stateful ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "rebuild restore target StatefulSet has no Kubernetes address")
  unless (all (sameCluster cluster) [pvc, credential]) (Left (invalid "rebuild restore resources belong to different clusters"))
  engineName <- metadata invalid "labels" "nagare.dev/engine" statefulValue
  unless (parseEngine engineName == Just Postgres) (Left (invalid "a rebuild restore loads only PostgreSQL"))
  version <- metadata invalid "annotations" "nagare.dev/version" statefulValue
  owner <- first invalid (mkScopeId Standalone ("database-rebuild-" <> ns <> "-" <> db <> "-" <> request ^. #restoreId))
  key <- first invalid (mkLogicalKey (request ^. #restoreId))
  jobRole <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "restore")
  let jobId = mintResourceId owner key jobRole
      proofId = mintResourceId owner key proofRole
      jobName = manualDatabaseJobName "nagare-dbrebuild-" db (request ^. #restoreId)
      inputs =
        RestoreJobInputs
          { namespace = ns
          , jobName = jobName
          , engine = Postgres
          , clientImage = engineImage Postgres <> ":" <> version
          , serviceHost = db
          , secretName = dbSecretName db
          , name = db
          , sourceUrl = objectUrl
          , liveTarget = False
          , verifiedSource =
              Just
                ( VerifiedRestoreSource
                    receiptUrl
                    (digestText receiptDigest)
                    (scheduledSha256 receipt)
                    db
                    0
                    (Just (scheduledObjectVersion (request ^. #evidence)))
                    (Just (scheduledReceiptVersion (request ^. #evidence)))
                )
          , backend = request ^. #backend
          }
      pins =
        [ ("nagare.dev/restore-id", request ^. #restoreId)
        , ("nagare.dev/restore-rebuild-review", digestText (lineage' ^. #review))
        , ("nagare.dev/restore-backup-object", objectUrl)
        , ("nagare.dev/restore-backup-receipt", receiptUrl)
        , ("nagare.dev/restore-backup-receipt-digest", digestText receiptDigest)
        , ("nagare.dev/restore-target-scope", scopeIdText (scopeId accepted))
        , ("nagare.dev/restore-target-revision", digestText (revisionDigest (request ^. #targetRevision)))
        , ("nagare.dev/restore-target-statefulset", resourceIdText (stateful ^. #identity))
        , ("nagare.dev/restore-target-statefulset-uid", physicalIdentityText (request ^. #targetStatefulUid))
        , ("nagare.dev/restore-target-pvc", resourceIdText (pvc ^. #identity))
        , ("nagare.dev/restore-target-pvc-uid", physicalIdentityText (request ^. #targetPvcUid))
        , ("nagare.dev/restore-target-database", db)
        ]
  rendered <- first (invalid . T.pack . show) (Yaml.decodeEither' (renderRebuildRestoreJob inputs) :: Either Yaml.ParseException Value)
  job <- case rendered of
    Object root
      | Just (Object fields) <- KM.lookup "metadata" root ->
          Right (Object (KM.insert "metadata" (Object (KM.insert "annotations" (object [K.fromText field .= value | (field, value) <- pins]) fields)) root))
    _ -> Left (invalid "rebuild restore Job lacks native metadata")
  canonical <- first invalid (canonicalValue job)
  (bound, bytes) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = jobId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = job
            , objectDigest = contentDigest canonical
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = request ^. #source
            }
      )
  expected <- first invalid (kubernetesAddress cluster "batch/v1" "Job" (Just ns) jobName)
  unless (bound ^. #address == expected) (Left (invalid "rebuild restore Job has an unexpected native address"))
  let member = bound {dependencies = sort (map (OrderedAfter . (^. #identity)) [pvc, credential, stateful])}
      proof = DeclaredOperation proofId (jobId :| []) (sort [ContentInput (contentDigest bytes), ContentInput receiptDigest]) VerifyBeforeRetry RestoreData
      -- The target keys are what 'manualRestoreTargetProof' reads, so
      -- execution reloads the target's accepted native evidence and checks
      -- the live UIDs the Job pins before it runs.
      overrides =
        Map.fromList
          [ ("restore.id", request ^. #restoreId)
          , ("restore.database", db)
          , ("restore.namespace", ns)
          , ("restore.rebuild.review", digestText (lineage' ^. #review))
          , ("restore.rebuild.predecessor", maybe "" physicalIdentityText (lineage' ^. #proof . #predecessor))
          , ("restore.backup.object", objectUrl)
          , ("restore.backup.receipt", receiptUrl)
          , ("restore.backup.receipt.digest", digestText receiptDigest)
          , ("restore.backup.sha256", scheduledSha256 receipt)
          , ("restore.backup.object.version", scheduledObjectVersion (request ^. #evidence))
          , ("restore.backup.receipt.version", scheduledReceiptVersion (request ^. #evidence))
          , ("restore.target.scope", scopeIdText (scopeId accepted))
          , ("restore.target.generation", T.pack (show (generationNumber (revisionGeneration (request ^. #targetRevision)))))
          , ("restore.target.revision", digestText (revisionDigest (request ^. #targetRevision)))
          , ("restore.target.statefulset", resourceIdText (stateful ^. #identity))
          , ("restore.target.statefulset.uid", physicalIdentityText (request ^. #targetStatefulUid))
          , ("restore.target.pvc", resourceIdText (pvc ^. #identity))
          , ("restore.target.pvc.uid", physicalIdentityText (request ^. #targetPvcUid))
          , ("restore.target.database", db)
          ]
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  pure (withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base), Map.singleton jobId (member, bytes))

metadata :: (Text -> NonEmpty InventoryError) -> Text -> Text -> Value -> Either (NonEmpty InventoryError) Text
metadata invalid section field value = case value of
  Object root
    | Just (Object fields) <- KM.lookup "metadata" root
    , Just (Object entries) <- KM.lookup (K.fromText section) fields
    , Just (String selected) <- KM.lookup (K.fromText field) entries ->
        Right selected
  _ -> Left (invalid ("database StatefulSet metadata lacks " <> field))
