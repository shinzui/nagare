-- | Reviewed restore of an accepted manual volume snapshot into a separate
-- scratch claim. Planning pins the exact stored object versions, and the
-- restore Job downloads only those versions before it writes anything.
module Nagare.Inventory.VolumeRestore
  ( VolumeRestoreRequest (..)
  , VolumeObjectPins (..)
  , volumeRestoreJobSourcePins
  , compileVolumeRestoreScope
  , compileVolumeRestoreScopeWithPins
  , ScheduledVolumeRestoreRequest (..)
  , compileScheduledVolumeRestoreScope
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (for_)
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
import Nagare.Database.Backup (volumeBackupKeyPrefix)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Backup (manualBackupJobReceiptExpectation, parseBackupReceipt)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Lineage (RecoveryPointKind (ScheduledVolumeRecoveryPoint), VolumeRecoverySource)
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
volumeRestoreJobSourcePins ::
  ByteString -> Either T.Text (Maybe [(ResourceId, PhysicalIdentity)])
volumeRestoreJobSourcePins bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root
      | KM.lookup "kind" root == Just (String "Job")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , Just (Object annotations) <- KM.lookup "annotations" metadata
      , Just (String _) <- KM.lookup "nagare.dev/volume-restore-id" annotations -> do
          let required key = case KM.lookup key annotations of
                Just (String selected) -> Right selected
                _ -> Left ("volume restore Job lacks " <> K.toText key)
          -- EP-183 M4: a rebuild restore has no backup Job; its archive is
          -- authorized by the rebuild's lineage and pinned stored versions.
          -- EP-183 M3: neither has a scratch restore of a scheduled volume
          -- run, authorized by the run's ingestion record. A Job naming a
          -- backup Job as well is refused rather than read as either.
          let unpinned =
                [ selected
                | selected <- ["nagare.dev/volume-restore-rebuild-review", "nagare.dev/volume-restore-scheduled-run"]
                , KM.member selected annotations
                ]
          source <- case unpinned of
            [_]
              | KM.member "nagare.dev/volume-restore-backup-job" annotations ->
                  Left "volume restore Job names both a backup Job and a recovery point without one"
              | otherwise -> pure []
            (_ : _ : _) -> Left "volume restore Job names more than one recovery point without a backup Job"
            [] -> do
              backup <- required "nagare.dev/volume-restore-backup-job" >>= mkResourceId
              backupUid <-
                required "nagare.dev/volume-restore-backup-job-uid"
                  >>= mkPhysicalIdentity
              pure [(backup, backupUid)]
          target <- required "nagare.dev/volume-restore-target-pvc" >>= mkResourceId
          targetUid <-
            required "nagare.dev/volume-restore-target-pvc-uid"
              >>= mkPhysicalIdentity
          credential <- case ( KM.lookup "nagare.dev/volume-restore-store-secret" annotations
                             , KM.lookup "nagare.dev/volume-restore-store-secret-uid" annotations
                             ) of
            (Nothing, Nothing) -> Right []
            (Just (String rawId), Just (String rawUid)) -> do
              secret <- mkResourceId rawId
              physical <- mkPhysicalIdentity rawUid
              pure [(secret, physical)]
            _ -> Left "volume restore Job has incomplete credential pins"
          unless
            (target `notElem` map fst source)
            (Left "volume restore Job repeats its source and target identity")
          pure (Just (source <> [(target, targetUid)] <> credential))
    _ -> Right Nothing

-- | Restore only an accepted manual volume snapshot into a distinct scratch
-- claim. The Job checks fresh object bytes against the accepted Pod receipt
-- before it extracts any archive member.
compileVolumeRestoreScope ::
  VolumeRestoreRequest ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileVolumeRestoreScope = compileVolumeRestoreScopeWithPins Nothing

-- | The exact stored objects planning read and verified: the archive and
-- receipt versions with their lengths, the archive's SHA-256 (hex) and the
-- receipt's digest. Only these versions may be restored.
data VolumeObjectPins = VolumeObjectPins
  { pinnedObjectVersion :: !T.Text
  , pinnedObjectLength :: !Integer
  , pinnedObjectSha256 :: !T.Text
  , pinnedReceiptVersion :: !T.Text
  , pinnedReceiptLength :: !Integer
  , pinnedReceiptDigest :: !ContentDigest
  }
  deriving stock (Eq, Show)

-- | With pins, the review binds the verified versions and the Job downloads
-- only them, so a newer or changed object refuses before any write. The
-- pins must agree with the accepted receipt.
compileVolumeRestoreScopeWithPins ::
  Maybe VolumeObjectPins ->
  VolumeRestoreRequest ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileVolumeRestoreScopeWithPins pins request target native = do
  let backup = volumeRestoreBackup request
      invalid message =
        inventoryError "invalid-volume-restore" message
          & #scopes
          .~ [scopeId target, scopeId backup]
          & #sources
          .~ [volumeRestoreSource request]
          & (:| [])
      app = volumeRestoreApp request
      volume = volumeRestoreName request
      ns = volumeRestoreNamespace request
      required key =
        maybe
          (Left (invalid ("volume backup lacks " <> key)))
          Right
          (Map.lookup key (scopeOverrides backup))
      scratchTarget =
        ScratchTarget
          { scratchApp = app
          , scratchVolume = volume
          , scratchNamespace = ns
          , scratchRestoreId = volumeRestoreId request
          , scratchTargetRevision = volumeRestoreTargetRevision request
          , scratchTargetPvcUid = volumeRestoreTargetPvcUid request
          , scratchBackend = volumeRestoreBackend request
          , scratchCredential = volumeRestoreCredential request
          , scratchSource = volumeRestoreSource request
          }
  resolved@(_, _, cluster) <- scratchRestoreTarget invalid scratchTarget target native
  backupJob <- case [ member
                    | bundle <- scopeBundles backup
                    , Managed member <- declarations bundle
                    , case member ^. #address of
                        Kubernetes _ "batch" kind (Just namespace) _ ->
                          nameText kind == "job" && nameText namespace == ns
                        _ -> False
                    ] of
    [single] -> Right single
    _ -> Left (invalid "accepted volume backup lacks one Job")
  backupValue <- acceptedValue invalid native backupJob
  backupBytes <- first invalid (canonicalValue backupValue)
  backupId <- required "volume-backup.id"
  when (T.null backupId) (Left (invalid "volume backup ID is empty"))
  sourceScope <- required "volume-backup.source.scope"
  unless
    (sourceScope == scopeIdText (scopeId target))
    (Left (invalid "volume backup belongs to another application scope"))
  objectUrl <- required "volume-backup.object"
  receiptUrl <- required "volume-backup.receipt"
  expiry <- required "volume-backup.expiry"
  expiryEpoch <-
    if expiry == "retain"
      then Right Nothing
      else case parseTimeM
                  True
                  defaultTimeLocale
                  "%Y-%m-%dT%H:%M:%SZ"
                  (T.unpack expiry) ::
                  Maybe UTCTime of
        Nothing -> Left (invalid "volume backup expiry policy is invalid")
        Just selected -> do
          unless
            (selected > volumeRestoreNow request)
            (Left (invalid "volume backup has expired"))
          Right (Just (floor (utcTimeToPOSIXSeconds selected)))
  unless
    ( objectUrl
        == storeObjectUrl
          (volumeRestoreBackend request)
          ( "manual-volumes/"
              <> ns
              <> "/"
              <> app
              <> "/"
              <> volume
              <> "/"
              <> backupId
              <> ".tar.gz"
          )
        && receiptUrl == objectUrl <> ".receipt.json"
    )
    (Left (invalid "volume backup object differs from the selected backend"))
  expectation <- case manualBackupJobReceiptExpectation backupBytes of
    Right (Just selected) -> Right selected
    Right Nothing -> Left (invalid "accepted volume backup Job has no receipt")
    Left reason -> Left (invalid reason)
  checksum <-
    first
      invalid
      ( parseBackupReceipt
          expectation
          receiptUrl
          (volumeRestoreReceiptBytes request)
      )
  receiptValue <-
    first
      (invalid . T.pack)
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
      unless
        ( receiptId == backupId
            && receiptApp == app
            && receiptVolume == volume
            && receiptNamespace == ns
            && receiptScope == sourceScope
        )
        (Left (invalid "volume backup receipt targets another app, volume, or scope"))
    _ -> Left (invalid "volume backup receipt lacks metadata")
  for_ pins $ \pin ->
    unless
      ( pinnedObjectSha256 pin == checksum
          && pinnedReceiptDigest pin == contentDigest (volumeRestoreReceiptBytes request)
          && not (T.null (pinnedObjectVersion pin) || T.null (pinnedReceiptVersion pin))
          && pinnedObjectLength pin > 0
          && pinnedReceiptLength pin > 0
      )
      (Left (invalid "verified stored objects differ from the accepted receipt"))
  unless
    (sameCluster cluster backupJob)
    (Left (invalid "volume backup Job belongs to another cluster"))
  let receiptHash = contentDigest (volumeRestoreReceiptBytes request)
  compileScratchRestore
    invalid
    scratchTarget
    target
    native
    resolved
    ScratchArchive
      { archiveObject = objectUrl
      , archiveReceipt = receiptUrl
      , archiveReceiptDigest = receiptHash
      , archiveSha256 = checksum
      , archiveExpiry = expiryEpoch
      , archiveVersions = fmap (\pin -> (pinnedObjectVersion pin, pinnedReceiptVersion pin)) pins
      , archivePins =
          [ ("nagare.dev/volume-restore-backup-job", resourceIdText (backupJob ^. #identity))
          , ("nagare.dev/volume-restore-backup-job-uid", physicalIdentityText (volumeRestoreBackupJobUid request))
          ]
      , archiveAfter = [backupJob ^. #identity]
      , archiveOverrides =
          Map.fromList
            [ ("volume-restore.backup.scope", scopeIdText (scopeId backup))
            ,
              ( "volume-restore.backup.revision"
              , digestText
                  (revisionDigest (volumeRestoreBackupRevision request))
              )
            , ("volume-restore.backup.job", resourceIdText (backupJob ^. #identity))
            ,
              ( "volume-restore.backup.job.uid"
              , physicalIdentityText
                  (volumeRestoreBackupJobUid request)
              )
            , ("volume-restore.backup.receipt.digest", digestText receiptHash)
            , ("volume-restore.backup.sha256", checksum)
            ]
            <> Map.fromList
              [ (field, value)
              | pin <- maybe [] pure pins
              , (field, value) <-
                  [ ("volume-restore.backup.object.version", pinnedObjectVersion pin)
                  , ("volume-restore.backup.object.length", T.pack (show (pinnedObjectLength pin)))
                  , ("volume-restore.backup.receipt.version", pinnedReceiptVersion pin)
                  , ("volume-restore.backup.receipt.length", T.pack (show (pinnedReceiptLength pin)))
                  ]
              ]
      }

-- | EP-183 M3: restore an accepted scheduled volume run into a distinct
-- scratch claim. Its ingestion review verified the receipt's signature and
-- recorded the exact archive and receipt versions; planning re-read those
-- versions ('Nagare.Inventory.VolumeRestoreSource.verifyIngestedVolumeRun'),
-- and the Job downloads only them and checks both digests before it writes.
data ScheduledVolumeRestoreRequest = ScheduledVolumeRestoreRequest
  { scheduledRestoreApp :: !T.Text
  , scheduledRestoreName :: !T.Text
  , scheduledRestoreNamespace :: !T.Text
  , scheduledRestoreId :: !T.Text
  , scheduledRestoreRun :: !ScopeDeclaration
  -- ^ The accepted ingestion scope of the run.
  , scheduledRestoreRunRevision :: !ScopeRevision
  , scheduledRestoreRecovery :: !VolumeRecoverySource
  , scheduledRestoreTargetRevision :: !ScopeRevision
  , scheduledRestoreTargetPvcUid :: !PhysicalIdentity
  , scheduledRestoreBackend :: !StoreBackend
  , scheduledRestoreCredential :: !(Maybe (ManagedResource, PhysicalIdentity))
  , scheduledRestoreSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

compileScheduledVolumeRestoreScope ::
  ScheduledVolumeRestoreRequest ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileScheduledVolumeRestoreScope request target native = do
  let run = scheduledRestoreRun request
      recovered = scheduledRestoreRecovery request
      invalid message =
        inventoryError "invalid-volume-restore" message
          & #scopes
          .~ [scopeId target, scopeId run]
          & #sources
          .~ [scheduledRestoreSource request]
          & (:| [])
      app = scheduledRestoreApp request
      volume = scheduledRestoreName request
      ns = scheduledRestoreNamespace request
      recorded key = Map.lookup key (scopeOverrides run)
      scratchTarget =
        ScratchTarget
          { scratchApp = app
          , scratchVolume = volume
          , scratchNamespace = ns
          , scratchRestoreId = scheduledRestoreId request
          , scratchTargetRevision = scheduledRestoreTargetRevision request
          , scratchTargetPvcUid = scheduledRestoreTargetPvcUid request
          , scratchBackend = scheduledRestoreBackend request
          , scratchCredential = scheduledRestoreCredential request
          , scratchSource = scheduledRestoreSource request
          }
  resolved@(targetPvc, _, _) <- scratchRestoreTarget invalid scratchTarget target native
  unless
    (recovered ^. #kind == ScheduledVolumeRecoveryPoint && recorded "scheduled.backup.source.kind" == Just "volume")
    (Left (invalid "the selected run is not an accepted scheduled volume run"))
  unless
    ( recorded "scheduled.backup.source.scope" == Just (scopeIdText (scopeId target))
        && recorded "scheduled.backup.source.pvc" == Just (resourceIdText (targetPvc ^. #identity))
        && recorded "scheduled.backup.source.pvc.uid" == Just (physicalIdentityText (recovered ^. #sourcePvcUid))
    )
    (Left (invalid "the scheduled volume run was taken from another application scope or claim"))
  unless
    ( recorded "scheduled.backup.object" == Just (recovered ^. #objectUrl)
        && recorded "scheduled.backup.object.version" == Just (recovered ^. #objectVersion)
        && recorded "scheduled.backup.object.sha256" == Just (recovered ^. #archiveSha256)
        && recorded "scheduled.backup.receipt" == Just (recovered ^. #receiptUrl)
        && recorded "scheduled.backup.receipt.version" == Just (recovered ^. #receiptVersion)
        && recorded "scheduled.backup.receipt.digest" == Just (digestText (recovered ^. #receiptDigest))
        && all (not . T.null) [recovered ^. #objectVersion, recovered ^. #receiptVersion, recovered ^. #archiveSha256]
    )
    (Left (invalid "the verified archive is not the one the run's ingestion accepted"))
  unless
    ( storeObjectUrl (scheduledRestoreBackend request) (volumeBackupKeyPrefix ns app volume)
        `T.isPrefixOf` (recovered ^. #objectUrl)
        && recovered ^. #receiptUrl == recovered ^. #objectUrl <> ".receipt.json"
    )
    (Left (invalid "the scheduled volume run's archive lies outside this volume's prefix on the selected backend"))
  compileScratchRestore
    invalid
    scratchTarget
    target
    native
    resolved
    ScratchArchive
      { archiveObject = recovered ^. #objectUrl
      , archiveReceipt = recovered ^. #receiptUrl
      , archiveReceiptDigest = recovered ^. #receiptDigest
      , archiveSha256 = recovered ^. #archiveSha256
      , archiveExpiry = Nothing
      , archiveVersions = Just (recovered ^. #objectVersion, recovered ^. #receiptVersion)
      , archivePins = [("nagare.dev/volume-restore-scheduled-run", scopeIdText (scopeId run))]
      , archiveAfter = []
      , archiveOverrides =
          Map.fromList
            [ ("volume-restore.backup.scope", scopeIdText (scopeId run))
            , ("volume-restore.backup.kind", "scheduled-volume")
            , ("volume-restore.backup.revision", digestText (revisionDigest (scheduledRestoreRunRevision request)))
            , ("volume-restore.backup.object", recovered ^. #objectUrl)
            , ("volume-restore.backup.object.version", recovered ^. #objectVersion)
            , ("volume-restore.backup.receipt", recovered ^. #receiptUrl)
            , ("volume-restore.backup.receipt.version", recovered ^. #receiptVersion)
            , ("volume-restore.backup.receipt.digest", digestText (recovered ^. #receiptDigest))
            , ("volume-restore.backup.sha256", recovered ^. #archiveSha256)
            ]
      }

-- | The application claim a scratch restore reads its size from, and what
-- every scratch restore pins.
data ScratchTarget = ScratchTarget
  { scratchApp :: !T.Text
  , scratchVolume :: !T.Text
  , scratchNamespace :: !T.Text
  , scratchRestoreId :: !T.Text
  , scratchTargetRevision :: !ScopeRevision
  , scratchTargetPvcUid :: !PhysicalIdentity
  , scratchBackend :: !StoreBackend
  , scratchCredential :: !(Maybe (ManagedResource, PhysicalIdentity))
  , scratchSource :: !SourceLocation
  }

-- | The archive a scratch restore extracts, and the source pins,
-- prerequisites and recorded fields that authorise it.
data ScratchArchive = ScratchArchive
  { archiveObject :: !T.Text
  , archiveReceipt :: !T.Text
  , archiveReceiptDigest :: !ContentDigest
  , archiveSha256 :: !T.Text
  , archiveExpiry :: !(Maybe Integer)
  , archiveVersions :: !(Maybe (T.Text, T.Text))
  , archivePins :: ![(K.Key, T.Text)]
  , archiveAfter :: ![ResourceId]
  , archiveOverrides :: !(Map T.Text T.Text)
  }

scratchRestoreTarget ::
  (T.Text -> NonEmpty InventoryError) ->
  ScratchTarget ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either (NonEmpty InventoryError) (ManagedResource, T.Text, ResourceId)
scratchRestoreTarget invalid scratchTarget target native = do
  let app = scratchApp scratchTarget
      volume = scratchVolume scratchTarget
      ns = scratchNamespace scratchTarget
      restoreKey = scratchRestoreId scratchTarget
  _ <- first invalid (mkServiceName app)
  _ <- first invalid (mkServiceName volume)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName restoreKey)
  unless
    (T.length restoreKey <= 20)
    (Left (invalid "volume restore ID must contain at most 20 characters"))
  targetPvc <- case [ member
                    | bundle <- scopeBundles target
                    , Managed member <- declarations bundle
                    , case member ^. #address of
                        Kubernetes _ "" kind (Just namespace) nativeName ->
                          nameText kind == "persistentvolumeclaim"
                            && nameText namespace == ns
                            && nameText nativeName == pvcName app volume
                        _ -> False
                    ] of
    [single] -> Right single
    _ -> Left (invalid "volume restore requires one accepted target PVC")
  targetValue <- acceptedValue invalid native targetPvc
  size <- case targetValue of
    Object root
      | Just (Object specValue) <- KM.lookup "spec" root
      , Just (Object resources) <- KM.lookup "resources" specValue
      , Just (Object requests) <- KM.lookup "requests" resources
      , Just (String selected) <- KM.lookup "storage" requests
      , KM.lookup "storageClassName" specValue == Just (String "local-path") ->
          Right selected
    _ -> Left (invalid "accepted target PVC lacks a local-path storage request")
  cluster <- case targetPvc ^. #address of
    Kubernetes selected _ _ _ _ -> Right selected
    _ -> Left (invalid "target PVC has no Kubernetes address")
  pure (targetPvc, size, cluster)

-- | Bind the scratch claim and the restore Job for an archive whose source
-- the caller has verified, against the target 'scratchRestoreTarget' resolved.
compileScratchRestore ::
  (T.Text -> NonEmpty InventoryError) ->
  ScratchTarget ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  (ManagedResource, T.Text, ResourceId) ->
  ScratchArchive ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileScratchRestore invalid scratchTarget target native (targetPvc, size, cluster) archive = do
  let app = scratchApp scratchTarget
      volume = scratchVolume scratchTarget
      ns = scratchNamespace scratchTarget
      restoreKey = scratchRestoreId scratchTarget
      backend = scratchBackend scratchTarget
      credential = scratchCredential scratchTarget
  case (backend, credential) of
    (GcsBackend {}, Nothing) -> pure ()
    (MinioBackend ref, Just (secret, _)) -> do
      expected <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "v1"
              "Secret"
              (Just ns)
              (ref ^. #secretName)
          )
      unless
        (secret ^. #address == expected)
        (Left (invalid "volume restore credential differs from its backend"))
      _ <- acceptedValue invalid native secret
      pure ()
    _ -> Left (invalid "volume restore credential differs from its backend")
  owner <-
    first
      invalid
      ( mkScopeId
          Standalone
          ("volume-restore-" <> ns <> "-" <> app <> "-" <> volume <> "-" <> restoreKey)
      )
  key <- first invalid (mkLogicalKey restoreKey)
  pvcRole <- first invalid (mkName "pvc")
  jobRole <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "restore")
  let pvcId = mintResourceId owner key pvcRole
      jobId = mintResourceId owner key jobRole
      proofId = mintResourceId owner key proofRole
      scratchName = "nagare-restore-" <> app <> "-" <> volume <> "-" <> restoreKey
      jobName = "nagare-volrestore-" <> app <> "-" <> volume <> "-" <> restoreKey
  unless
    (T.length scratchName <= 63 && T.length jobName <= 63)
    (Left (invalid "volume restore name exceeds 63 characters"))
  scratchValue <-
    first
      (invalid . T.pack . show)
      ( Yaml.decodeEither' (Volume.renderScratchPvc ns scratchName size) ::
          Either Yaml.ParseException Value
      )
  scratchCanonical <- first invalid (canonicalValue scratchValue)
  (scratch, scratchBytes) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = pvcId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = scratchValue
            , objectDigest = contentDigest scratchCanonical
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = scratchSource scratchTarget
            }
      )
  let jobInputs =
        Volume.StorageRestoreJobInputs
          ns
          jobName
          scratchName
          (archiveObject archive)
          "/restore"
          backend
      reviewed =
        Volume.ReviewedVolumeRestoreInputs
          jobInputs
          (archiveReceipt archive)
          (digestText (archiveReceiptDigest archive))
          (archiveSha256 archive)
          (archiveExpiry archive)
          (archiveVersions archive)
  rendered <-
    first
      (invalid . T.pack . show)
      ( Yaml.decodeEither' (Volume.renderReviewedVolumeRestoreJob reviewed) ::
          Either Yaml.ParseException Value
      )
  jobValue <- case rendered of
    Object root
      | Just (Object metadata) <- KM.lookup "metadata" root ->
          let annotations =
                object
                  ( ["nagare.dev/volume-restore-id" .= restoreKey]
                      <> [field .= value | (field, value) <- archivePins archive]
                      <> [ "nagare.dev/volume-restore-target-pvc"
                             .= resourceIdText (targetPvc ^. #identity)
                         , "nagare.dev/volume-restore-target-pvc-uid"
                             .= physicalIdentityText (scratchTargetPvcUid scratchTarget)
                         ]
                      <> case credential of
                        Nothing -> []
                        Just (secret, uid) ->
                          [ "nagare.dev/volume-restore-store-secret"
                              .= resourceIdText (secret ^. #identity)
                          , "nagare.dev/volume-restore-store-secret-uid"
                              .= physicalIdentityText uid
                          ]
                  )
           in Right
                ( Object
                    ( KM.insert
                        "metadata"
                        ( Object
                            (KM.insert "annotations" annotations metadata)
                        )
                        root
                    )
                )
    _ -> Left (invalid "volume restore Job lacks native metadata")
  jobCanonical <- first invalid (canonicalValue jobValue)
  (boundJob, jobBytes) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = jobId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = jobValue
            , objectDigest = contentDigest jobCanonical
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = scratchSource scratchTarget
            }
      )
  expectedScratch <-
    first
      invalid
      ( kubernetesAddress
          cluster
          "v1"
          "PersistentVolumeClaim"
          (Just ns)
          scratchName
      )
  expectedJob <-
    first
      invalid
      ( kubernetesAddress
          cluster
          "batch/v1"
          "Job"
          (Just ns)
          jobName
      )
  unless
    (scratch ^. #address == expectedScratch && boundJob ^. #address == expectedJob)
    (Left (invalid "volume restore members have unexpected native addresses"))
  let prerequisites =
        [scratch ^. #identity]
          <> archiveAfter archive
          <> [targetPvc ^. #identity]
          <> maybe [] (\(secret, _) -> [secret ^. #identity]) credential
      job = boundJob {dependencies = map OrderedAfter prerequisites}
      proof =
        DeclaredOperation
          proofId
          (jobId :| [])
          [ ContentInput (contentDigest jobBytes)
          , ContentInput (archiveReceiptDigest archive)
          ]
          VerifyBeforeRetry
          RestoreData
      overrides =
        Map.fromList
          [ ("volume-restore.id", restoreKey)
          , ("volume-restore.target.scope", scopeIdText (scopeId target))
          ,
            ( "volume-restore.target.revision"
            , digestText
                (revisionDigest (scratchTargetRevision scratchTarget))
            )
          , ("volume-restore.target.pvc", resourceIdText (targetPvc ^. #identity))
          ,
            ( "volume-restore.target.pvc.uid"
            , physicalIdentityText
                (scratchTargetPvcUid scratchTarget)
            )
          , ("volume-restore.scratch", scratchName)
          ]
          <> archiveOverrides archive
  base <-
    mkScopeDeclaration
      owner
      [ResourceBundle [Managed scratch, Managed job] [] [] [] [proof] []]
  pure
    ( withScopeOverrides
        overrides
        (withScopeConfigDigest (contentDigest jobCanonical) base)
    , Map.fromList [(pvcId, (scratch, scratchBytes)), (jobId, (job, jobBytes))]
    )
