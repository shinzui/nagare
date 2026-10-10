-- | EP-183 M4: restore a rebuilt application volume from the one recovery
-- point its rebuild named, before the application serves from it. The claim
-- must be the incarnation a converged rebuild created ('RebuildLineage'); the
-- archive must be the named recovery point, taken from the rebuild's
-- predecessor and verified at exact stored versions ('VolumeRecoverySource').
-- The Job restores only into an empty claim ('renderRebuildVolumeRestoreJob').
--
-- 'VolumeRecoverySource' is the seam between a recovery point's verifier and
-- this compiler: a manual snapshot's verifier
-- ('Nagare.Inventory.VolumeRestoreSource.verifyRecordedVolumeSnapshot') fills
-- it today, and scheduled volume receipts fill it with their own kind.
module Nagare.Inventory.VolumeRebuildRestore
  ( VolumeRecoverySource (..)
  , VolumeRebuildRestoreRequest (..)
  , compileVolumeRebuildRestoreScope
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Lineage (RebuildSource (..), RecoveryPointKind (..), VolumeRecoverySource (..))
import Nagare.Inventory.LineageHistory (RebuildLineage (..))
import Nagare.Inventory.RestoreNative (acceptedValue, sameCluster)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), RecoveryClass (VerifyBeforeRetry), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Storage.Discover (pvcName)
import Nagare.Storage.Restore qualified as Volume

data VolumeRebuildRestoreRequest = VolumeRebuildRestoreRequest
  { app :: !Text
  , volume :: !Text
  , namespace :: !Text
  , restoreId :: !Text
  , targetRevision :: !ScopeRevision
  , targetPvcUid :: !PhysicalIdentity
  -- ^ The live claim, checked against its recorded incarnation.
  , lineage :: !RebuildLineage
  , recovery :: !VolumeRecoverySource
  , backend :: !StoreBackend
  , credential :: !(Maybe (ManagedResource, PhysicalIdentity))
  -- ^ Local mode: the accepted object-store credential Secret the Job reads.
  , source :: !SourceLocation
  }
  deriving stock (Generic)

compileVolumeRebuildRestoreScope ::
  VolumeRebuildRestoreRequest ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileVolumeRebuildRestoreScope request accepted native = do
  let invalid message =
        inventoryError "invalid-volume-rebuild-restore" message
          & #scopes
          .~ [scopeId accepted]
          & #sources
          .~ [request ^. #source]
          & (:| [])
      ns = request ^. #namespace
      restoreKey = request ^. #restoreId
      recovered = request ^. #recovery
      lineage' = request ^. #lineage
  traverse_ (first invalid . mkServiceName) [request ^. #app, request ^. #volume, ns, restoreKey]
  unless (T.length restoreKey <= 20) (Left (invalid "volume restore ID must contain at most 20 characters"))
  pvc <- case [ member
              | bundle <- scopeBundles accepted
              , Managed member <- declarations bundle
              , case member ^. #address of
                  Kubernetes _ "" resourceKind (Just namespace') nativeName ->
                    nameText resourceKind == "persistentvolumeclaim"
                      && nameText namespace' == ns
                      && nameText nativeName == pvcName (request ^. #app) (request ^. #volume)
                  _ -> False
              ] of
    [single] -> Right single
    _ -> Left (invalid "a volume rebuild restore requires one accepted claim of the application")
  unless
    (lineage' ^. #resource == pvc ^. #identity && lineage' ^. #incarnation == request ^. #targetPvcUid)
    (Left (invalid "the target claim is not the incarnation a reviewed rebuild created; only that incarnation receives its predecessor's recovery point"))
  point <- case lineage' ^. #proof . #source of
    FromRecoveryPoint selected
      | selected ^. #kind `elem` [VolumeSnapshotRecoveryPoint, ScheduledVolumeRecoveryPoint] -> Right selected
    FromRecoveryPoint _ -> Left (invalid "the rebuild names another kind of recovery point; a volume rebuild restore loads a volume recovery point")
    Fresh -> Left (invalid "the rebuild started the volume fresh; it names no recovery point")
  unless
    (recovered ^. #kind == point ^. #kind && recovered ^. #receiptUrl == point ^. #receipt && recovered ^. #receiptDigest == point ^. #receiptDigest)
    (Left (invalid "the verified archive is not the recovery point the rebuild named"))
  unless
    (Just (recovered ^. #sourcePvcUid) == lineage' ^. #proof . #predecessor)
    (Left (invalid "the archive was taken from another incarnation than the rebuild's predecessor"))
  unless
    (all (not . T.null) [recovered ^. #objectVersion, recovered ^. #receiptVersion, recovered ^. #archiveSha256])
    (Left (invalid "the recovery point lacks exact stored versions"))
  _ <- acceptedValue invalid native pvc
  cluster <- case pvc ^. #address of
    Kubernetes selected _ _ _ _ -> Right selected
    _ -> Left (invalid "target claim has no Kubernetes address")
  credential' <- case (request ^. #backend, request ^. #credential) of
    (GcsBackend {}, Nothing) -> Right Nothing
    (MinioBackend ref, Just (secret, uid)) -> do
      expected <- first invalid (kubernetesAddress cluster "v1" "Secret" (Just ns) (ref ^. #secretName))
      unless (secret ^. #address == expected && sameCluster cluster secret) (Left (invalid "volume restore credential differs from its backend"))
      _ <- acceptedValue invalid native secret
      Right (Just (secret, uid))
    _ -> Left (invalid "volume restore credential differs from its backend")
  owner <- first invalid (mkScopeId Standalone ("volume-rebuild-" <> ns <> "-" <> request ^. #app <> "-" <> request ^. #volume <> "-" <> restoreKey))
  key <- first invalid (mkLogicalKey restoreKey)
  jobRole <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "restore")
  let jobId = mintResourceId owner key jobRole
      proofId = mintResourceId owner key proofRole
      jobName = "nagare-volrebuild-" <> request ^. #app <> "-" <> request ^. #volume <> "-" <> restoreKey
      stage = T.replace "-" "_" restoreKey
  unless (T.length jobName <= 63) (Left (invalid "volume rebuild restore Job name exceeds 63 characters"))
  let claim = case pvc ^. #address of
        Kubernetes _ _ _ _ nativeName -> nameText nativeName
        _ -> ""
      reviewed =
        Volume.ReviewedVolumeRestoreInputs
          (Volume.StorageRestoreJobInputs ns jobName claim (recovered ^. #objectUrl) "/restore" (request ^. #backend))
          (recovered ^. #receiptUrl)
          (digestText (recovered ^. #receiptDigest))
          (recovered ^. #archiveSha256)
          (recovered ^. #expiryEpoch)
          (Just (recovered ^. #objectVersion, recovered ^. #receiptVersion))
  rendered <- first (invalid . T.pack . show) (Yaml.decodeEither' (Volume.renderRebuildVolumeRestoreJob stage reviewed) :: Either Yaml.ParseException Value)
  let pins =
        [ ("nagare.dev/volume-restore-id", restoreKey)
        , ("nagare.dev/volume-restore-rebuild-review", digestText (lineage' ^. #review))
        , ("nagare.dev/volume-restore-target-pvc", resourceIdText (pvc ^. #identity))
        , ("nagare.dev/volume-restore-target-pvc-uid", physicalIdentityText (request ^. #targetPvcUid))
        ]
          <> concat
            [ [ ("nagare.dev/volume-restore-store-secret", resourceIdText (secret ^. #identity))
              , ("nagare.dev/volume-restore-store-secret-uid", physicalIdentityText uid)
              ]
            | Just (secret, uid) <- [credential']
            ]
  job <- case rendered of
    Object root
      | Just (Object fields) <- KM.lookup "metadata" root ->
          Right (Object (KM.insert "metadata" (Object (KM.insert "annotations" (object [K.fromText field .= value | (field, value) <- pins]) fields)) root))
    _ -> Left (invalid "volume rebuild restore Job lacks native metadata")
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
  unless (bound ^. #address == expected) (Left (invalid "volume rebuild restore Job has an unexpected native address"))
  let member = bound {dependencies = sort (map OrderedAfter (pvc ^. #identity : [secret ^. #identity | Just (secret, _) <- [credential']]))}
      proof = DeclaredOperation proofId (jobId :| []) (sort [ContentInput (contentDigest bytes), ContentInput (recovered ^. #receiptDigest)]) VerifyBeforeRetry RestoreData
      overrides =
        Map.fromList
          [ ("volume-restore.id", restoreKey)
          , ("volume-restore.rebuild.review", digestText (lineage' ^. #review))
          , ("volume-restore.rebuild.predecessor", physicalIdentityText (recovered ^. #sourcePvcUid))
          , ("volume-restore.backup.object", recovered ^. #objectUrl)
          , ("volume-restore.backup.object.version", recovered ^. #objectVersion)
          , ("volume-restore.backup.receipt", recovered ^. #receiptUrl)
          , ("volume-restore.backup.receipt.version", recovered ^. #receiptVersion)
          , ("volume-restore.backup.receipt.digest", digestText (recovered ^. #receiptDigest))
          , ("volume-restore.backup.sha256", recovered ^. #archiveSha256)
          , ("volume-restore.target.scope", scopeIdText (scopeId accepted))
          , ("volume-restore.target.revision", digestText (revisionDigest (request ^. #targetRevision)))
          , ("volume-restore.target.pvc", resourceIdText (pvc ^. #identity))
          , ("volume-restore.target.pvc.uid", physicalIdentityText (request ^. #targetPvcUid))
          ]
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  pure (withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base), Map.singleton jobId (member, bytes))
