-- | Reviewed scratch restores from accepted manual or scheduled backups.
-- Each engine checks exact receipt/object bytes before loading separate data;
-- a failed restore requires explicit forward recovery.
module Nagare.Inventory.Restore
  ( ManualRestoreRequest (..)
  , manualRestoreJobTargetPins
  , manualRestoreTargetProof
  , compileManualRestoreScope
  , restoreTargetPins
  , VolumeRestoreRequest (..)
  , volumeRestoreJobSourcePins
  , compileVolumeRestoreScope
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (forM_, traverse_)
import Data.Generics.Labels ()
import Data.List (sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..), storeObjectUrl)
import Nagare.Database.Backup (backupExt, manualBackupObjectPath, manualDatabaseJobName)
import Nagare.Database.Restore (RestoreJobInputs (..), VerifiedRestoreSource (..), renderRedisScratchService, renderRedisScratchStatefulSet, renderRedisScratchVerifyJob, renderRestoreJob)
import Nagare.Dsl.Database (Engine (..), dbSecretName, engineImage, parseEngine)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Adapter (ObservationSet, ResourceObservation (ObservedPresent), observationMap)
import Nagare.Inventory.Backup (BackupSourceProof (..), manualBackupJobReceiptExpectation, manualBackupSourceProof, parseBackupReceipt, parseManualBackupReceipt)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Identity (checkedPhysical, requireAccepted)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.ManualReceipt (manualReceiptRecord)
import Nagare.Inventory.RestoreNative (acceptedValue, sameCluster)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Inventory.VolumeRestore (VolumeRestoreRequest (..), compileVolumeRestoreScope, volumeRestoreJobSourcePins)
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

-- | ADR 27 (N6): the StatefulSet and PVC a restore pins as its target, scratch
-- or live, are the recorded incarnations, never whatever object is live.
restoreTargetPins :: Map ResourceId PhysicalIdentity -> ObservationSet -> ResourceId -> ResourceId -> Either T.Text (PhysicalIdentity, PhysicalIdentity)
restoreTargetPins recorded observed stateful pvc = (,) <$> pin "the restore target StatefulSet" stateful <*> pin "the restore target PVC" pvc
  where
    pin what resource = case Map.lookup resource (observationMap observed) of
      Just (ObservedPresent uid) -> requireAccepted what (checkedPhysical recorded resource uid)
      _ -> Left "restore target StatefulSet or PVC is absent, drifted, or not ready"

-- | Reuse the immutable source-revision check for this Job's accepted target.
manualRestoreTargetProof :: ScopeDeclaration -> Either T.Text (Maybe BackupSourceProof)
manualRestoreTargetProof scope
  | Map.notMember "restore.id" values = Right Nothing
  | otherwise =
      Just <$> do
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

-- | Exact source UIDs from a saved restore Job or Redis scratch StatefulSet.
-- An incomplete annotation set refuses execution; ordinary objects have no
-- restore target pins. The StatefulSet check runs before its init can load data.
manualRestoreJobTargetPins ::
  ByteString -> Either T.Text (Maybe [(ResourceId, PhysicalIdentity)])
manualRestoreJobTargetPins bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root
      | KM.lookup "kind" root
          `elem` [Just (String "Job"), Just (String "StatefulSet")]
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

compileManualRestoreScope ::
  ManualRestoreRequest ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileManualRestoreScope request accepted native = do
  let invalid message =
        inventoryError "invalid-manual-restore" message
          & #scopes
          .~ [scopeId accepted, scopeId (restoreBackupScope request)]
          & #sources
          .~ [restoreSource request]
          & (:| [])
      db = restoreDatabaseName request
      ns = restoreNamespaceName request
      backup = restoreBackupScope request
      select scope group kind name =
        [ member
        | bundle <- scopeBundles scope
        , Managed member <- declarations bundle
        , case member ^. #address of
            Kubernetes _ api resourceKind (Just namespace) nativeName ->
              api == group
                && nameText resourceKind == kind
                && nameText namespace == ns
                && nameText nativeName == name
            _ -> False
        ]
      exactlyOne label members = case members of
        [member] -> Right member
        _ -> Left (invalid ("restore has no unique " <> label))
      sourcePinsTarget proof =
        sourceStatefulPhysical proof == restoreTargetStatefulUid request
          && sourcePvcPhysical proof == restoreTargetPvcUid request
      required key =
        maybe
          (Left (invalid ("backup scope lacks " <> key)))
          Right
          (Map.lookup key (scopeOverrides backup))
  unless
    (scopeKind (scopeId accepted) `elem` [Application, Standalone])
    (Left (invalid "restore requires an accepted database scope"))
  _ <- first invalid (mkServiceName db)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName (restoreId request))
  unless
    (T.length (restoreId request) <= 20)
    (Left (invalid "restore ID must contain at most 20 characters"))
  stateful <- exactlyOne "StatefulSet" (select accepted "apps" "statefulset" db)
  pvc <- exactlyOne "PVC" (select accepted "" "persistentvolumeclaim" (dbPvcName db))
  credential <- exactlyOne "credential" (select accepted "" "secret" (dbSecretName db))
  backupJob <- case [ member
                    | bundle <- scopeBundles backup
                    , Managed member <- declarations bundle
                    , case member ^. #address of
                        Kubernetes _ "batch" kind _ _ -> nameText kind == "job"
                        _ -> False
                    ] of
    [member] -> Right (Just member)
    [] | manualReceiptRecord backup -> Right Nothing
    _ -> Left (invalid "accepted backup scope lacks one Job")
  statefulValue <- acceptedValue invalid native stateful
  _ <- acceptedValue invalid native pvc
  _ <- acceptedValue invalid native credential
  traverse_ (acceptedValue invalid native) backupJob
  cluster <- case stateful ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "restore target StatefulSet has no Kubernetes address")
  unless
    (all (sameCluster cluster) ([pvc, credential] <> maybeToList backupJob))
    (Left (invalid "restore resources belong to different clusters"))
  backupJobId <- case backupJob of
    Just member -> Right (member ^. #identity)
    Nothing -> required "backup.job" >>= first invalid . mkResourceId
  engineName <- metadataText invalid "labels" "nagare.dev/engine" statefulValue
  engine <-
    maybe
      (Left (invalid "reviewed scratch restore has an unknown engine"))
      Right
      (parseEngine engineName)
  unless
    (engine `elem` [Postgres, Redis, ClickHouse])
    (Left (invalid "reviewed scratch restore has an unsupported engine"))
  version <- metadataText invalid "annotations" "nagare.dev/version" statefulValue
  scratchSize <-
    if engine == Redis
      then metadataText invalid "annotations" "nagare.dev/size" statefulValue
      else Right ""
  ( objectUrl
    , receiptUrl
    , backupId
    , expiryEpoch
    , receiptDigest
    , receiptChecksum
    , objectVersion
    , receiptVersion
    ) <-
    if Map.member "scheduled.backup.id" (scopeOverrides backup)
      then do
        sourceScope <- required "scheduled.backup.source.scope"
        unless
          (sourceScope == scopeIdText (scopeId accepted))
          (Left (invalid "scheduled backup belongs to another database scope"))
        objectUrl <- required "scheduled.backup.object"
        receiptUrl <- required "scheduled.backup.receipt"
        backupId <- required "scheduled.backup.id"
        receiptChecksum <- required "scheduled.backup.object.sha256"
        receiptDigestText <- required "scheduled.backup.receipt.digest"
        receiptDigest <- first invalid (mkContentDigest receiptDigestText)
        selectedObjectVersion <- required "scheduled.backup.object.version"
        selectedReceiptVersion <- required "scheduled.backup.receipt.version"
        unless
          ( receiptUrl == objectUrl <> ".receipt.json"
              && objectUrl
                == storeObjectUrl
                  (restoreStorageBackend request)
                  ("databases/" <> db <> "/" <> backupId <> "." <> backupExt engine)
              && all (not . T.null) [selectedObjectVersion, selectedReceiptVersion]
          )
          (Left (invalid "scheduled backup has another address or lacks exact versions"))
        pure
          ( objectUrl
          , receiptUrl
          , backupId
          , 0
          , receiptDigest
          , receiptChecksum
          , Just selectedObjectVersion
          , Just selectedReceiptVersion
          )
      else do
        sourceScope <- required "backup.source.scope"
        unless
          (sourceScope == scopeIdText (scopeId accepted))
          (Left (invalid "backup belongs to another database scope"))
        objectUrl <- required "backup.object"
        receiptUrl <- required "backup.receipt"
        backupId <- required "backup.id"
        expiryText <- required "backup.expiry"
        expiryEpoch <-
          if expiryText == "retain"
            then Right 0
            else case parseTimeM
                        True
                        defaultTimeLocale
                        "%Y-%m-%dT%H:%M:%SZ"
                        (T.unpack expiryText) ::
                        Maybe UTCTime of
              Just expiry -> Right (floor (utcTimeToPOSIXSeconds expiry))
              Nothing -> Left (invalid "backup expiry is invalid")
        unless
          ( objectUrl
              == storeObjectUrl
                (restoreStorageBackend request)
                (manualBackupObjectPath db ns backupId (backupExt engine))
          )
          (Left (invalid "backup object does not match the selected backend and database"))
        receiptChecksum <-
          first
            invalid
            ( parseManualBackupReceipt
                backup
                receiptUrl
                (restoreReceiptBytes request)
            )
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
            unless
              ( receiptDatabase == db
                  && receiptNamespace == ns
                  && receiptEngine == engineName
                  && receiptId == backupId
              )
              (Left (invalid "backup receipt targets another database, namespace, engine, or ID"))
          _ -> Left (invalid "backup receipt lacks metadata")
        -- ADR 27 (N12): a manual backup restores only against the incarnation
        -- it was taken from, as a scheduled one does.
        sourceProof <- first invalid (manualBackupSourceProof backup)
        forM_ sourceProof $ \proof ->
          unless
            (sourcePinsTarget proof)
            (Left (invalid "the backup was taken from another incarnation of the target database"))
        (selectedObjectVersion, selectedReceiptVersion) <- case backupJob of
          Just _ -> Right (Nothing, Nothing)
          Nothing -> do
            objectVersion <- required "backup.object.version"
            receiptVersion <- required "backup.receipt.version"
            pinnedChecksum <- required "backup.object.sha256"
            pinnedDigest <- required "backup.receipt.digest"
            unless
              ( not (T.null objectVersion)
                  && not (T.null receiptVersion)
                  && pinnedChecksum == receiptChecksum
                  && pinnedDigest == digestText (contentDigest (restoreReceiptBytes request))
              )
              (Left (invalid "stored manual receipt differs from its accepted record"))
            pure (Just objectVersion, Just receiptVersion)
        pure
          ( objectUrl
          , receiptUrl
          , backupId
          , expiryEpoch
          , contentDigest (restoreReceiptBytes request)
          , receiptChecksum
          , selectedObjectVersion
          , selectedReceiptVersion
          )
  scratch <-
    first
      invalid
      ( case engine of
          Redis -> redisScratchName db (restoreId request)
          _ -> scratchDatabaseName db (restoreId request)
      )
  when (engine == ClickHouse) $
    unless
      (T.all safeClickHouseIdentifier scratch)
      (Left (invalid "ClickHouse scratch name contains a character unsafe for its reviewed restore query"))
  owner <-
    first
      invalid
      ( mkScopeId
          Standalone
          ("database-restore-" <> ns <> "-" <> db <> "-" <> restoreId request)
      )
  key <- first invalid (mkLogicalKey (restoreId request))
  jobRole <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "restore")
  let jobId = mintResourceId owner key jobRole
      proofId = mintResourceId owner key proofRole
      jobName = manualDatabaseJobName "nagare-dbrestore-" db (restoreId request)
      inputs =
        RestoreJobInputs
          { namespace = ns
          , jobName = jobName
          , engine = engine
          , clientImage = engineImage engine <> ":" <> version
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
                    receiptChecksum
                    scratch
                    expiryEpoch
                    objectVersion
                    receiptVersion
                )
          , backend = restoreStorageBackend request
          }
  rendered <-
    first
      (invalid . T.pack . show)
      ( Yaml.decodeEither'
          ( case engine of
              Redis -> renderRedisScratchVerifyJob inputs scratch
              _ -> renderRestoreJob inputs
          ) ::
          Either Yaml.ParseException Value
      )
  job <-
    first
      invalid
      ( annotateJob
          request
          accepted
          backupJobId
          stateful
          pvc
          objectUrl
          receiptUrl
          receiptDigest
          scratch
          rendered
      )
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
            , sourceLocation = restoreSource request
            }
      )
  expected <- first invalid (kubernetesAddress cluster "batch/v1" "Job" (Just ns) jobName)
  unless
    (bound ^. #address == expected)
    (Left (invalid "restore Job has an unexpected native address"))
  let member =
        bound
          { dependencies =
              sort
                ( map
                    (OrderedAfter . (^. #identity))
                    (maybeToList backupJob <> [pvc, credential, stateful])
                )
          }
      proof =
        DeclaredOperation
          proofId
          (jobId :| [])
          (sort [ContentInput (contentDigest bytes), ContentInput receiptDigest])
          VerifyBeforeRetry
          RestoreData
      overrides =
        Map.fromList $
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
          ]
            <> maybe [] (\selected -> [("restore.backup.object.version", selected)]) objectVersion
            <> maybe [] (\selected -> [("restore.backup.receipt.version", selected)]) receiptVersion
            <> [ ("restore.target.scope", scopeIdText (scopeId accepted))
               ,
                 ( "restore.target.generation"
                 , T.pack
                     ( show
                         ( generationNumber
                             (revisionGeneration (restoreTargetRevision request))
                         )
                     )
                 )
               , ("restore.target.revision", digestText (revisionDigest (restoreTargetRevision request)))
               , ("restore.target.statefulset", resourceIdText (stateful ^. #identity))
               , ("restore.target.statefulset.uid", physicalIdentityText (restoreTargetStatefulUid request))
               , ("restore.target.pvc", resourceIdText (pvc ^. #identity))
               , ("restore.target.pvc.uid", physicalIdentityText (restoreTargetPvcUid request))
               , ("restore.target.database", scratch)
               ]
  case engine of
    Redis ->
      compileRedisScratchScope
        request
        invalid
        cluster
        owner
        key
        stateful
        pvc
        credential
        backupJob
        inputs
        scratch
        scratchSize
        member
        bytes
        proof
        overrides
    _ -> do
      base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
      pure
        ( withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base)
        , Map.singleton jobId (member, bytes)
        )

scratchDatabaseName :: T.Text -> T.Text -> Either T.Text T.Text
scratchDatabaseName db restoreKey =
  let chosen = db <> "_restore_" <> restoreKey
   in if T.length chosen <= 63
        then Right chosen
        else Left "database and restore ID exceed the 63-character scratch name limit"

safeClickHouseIdentifier :: Char -> Bool
safeClickHouseIdentifier c =
  (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || c == '_'
    || c == '-'

redisScratchName :: T.Text -> T.Text -> Either T.Text T.Text
redisScratchName db restoreKey =
  let chosen = db <> "-restore-" <> restoreKey
   in if T.length chosen <= 63
        then Right chosen
        else Left "database and restore ID exceed Kubernetes' 63-character scratch name limit"

compileRedisScratchScope ::
  ManualRestoreRequest ->
  (T.Text -> NonEmpty InventoryError) ->
  ResourceId ->
  ScopeId ->
  LogicalKey ->
  ManagedResource ->
  ManagedResource ->
  ManagedResource ->
  Maybe ManagedResource ->
  RestoreJobInputs ->
  T.Text ->
  T.Text ->
  ManagedResource ->
  ByteString ->
  DeclaredOperation ->
  Map T.Text T.Text ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileRedisScratchScope
  request
  invalid
  cluster
  owner
  key
  sourceStateful
  sourcePvc
  credential
  backupJob
  inputs
  scratch
  size
  verifyJob
  verifyBytes
  proof
  overrides = do
    serviceRole <- first invalid (mkName "service")
    pvcRole <- first invalid (mkName "pvc")
    statefulRole <- first invalid (mkName "statefulset")
    let serviceId = mintResourceId owner key serviceRole
        pvcId = mintResourceId owner key pvcRole
        statefulId = mintResourceId owner key statefulRole
        ns = restoreNamespaceName request
        bind resource bytes = do
          value <-
            first
              (invalid . T.pack . show)
              (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
          bindValue resource value
        bindValue resource value = do
          canonical <- first invalid (canonicalValue value)
          first
            (:| [])
            ( bindKubernetesObject
                KubernetesInput
                  { resourceId = resource
                  , ownerScope = owner
                  , clusterId = cluster
                  , inputObject = value
                  , objectDigest = contentDigest canonical
                  , lifecyclePolicy = DeleteWhenUnreferenced
                  , inputDataPolicy = Stateless
                  , inputSensitivity = Private
                  , sourceLocation = restoreSource request
                  }
            )
    (service, serviceBytes) <- bind serviceId (renderRedisScratchService ns scratch)
    (scratchPvc, pvcBytes) <- bind pvcId (Volume.renderScratchPvc ns scratch size)
    scratchRendered <-
      first
        (invalid . T.pack . show)
        ( Yaml.decodeEither' (renderRedisScratchStatefulSet inputs scratch scratch) ::
            Either Yaml.ParseException Value
        )
    scratchAnnotated <- first invalid (copyRestoreAnnotations verifyBytes scratchRendered)
    (scratchStateful, statefulBytes) <- bindValue statefulId scratchAnnotated
    expectedService <- first invalid (kubernetesAddress cluster "v1" "Service" (Just ns) scratch)
    expectedPvc <- first invalid (kubernetesAddress cluster "v1" "PersistentVolumeClaim" (Just ns) scratch)
    expectedStateful <- first invalid (kubernetesAddress cluster "apps/v1" "StatefulSet" (Just ns) scratch)
    unless
      ( service ^. #address == expectedService
          && scratchPvc ^. #address == expectedPvc
          && scratchStateful ^. #address == expectedStateful
      )
      (Left (invalid "Redis scratch members have unexpected native addresses"))
    let backupDependencies = maybeToList backupJob
        pvcMember =
          scratchPvc
            { dependencies =
                sort
                  ( map
                      (OrderedAfter . (^. #identity))
                      (sourcePvc : backupDependencies)
                  )
            }
        statefulMember =
          scratchStateful
            { dependencies =
                sort
                  ( map
                      (OrderedAfter . (^. #identity))
                      ([service, pvcMember, credential] <> backupDependencies)
                  )
            }
        jobMember =
          verifyJob
            { dependencies =
                sort
                  ( map
                      (OrderedAfter . (^. #identity))
                      ([statefulMember, sourceStateful, sourcePvc, credential] <> backupDependencies)
                  )
            }
        restoreProof =
          proof
            { inputs =
                sort
                  (ContentInput (contentDigest statefulBytes) : proof ^. #inputs)
            }
        native =
          Map.fromList
            [ (serviceId, (service, serviceBytes))
            , (pvcId, (pvcMember, pvcBytes))
            , (statefulId, (statefulMember, statefulBytes))
            , (jobMember ^. #identity, (jobMember, verifyBytes))
            ]
    combined <-
      first
        invalid
        ( canonicalValue
            ( object
                [ "service" .= contentDigest serviceBytes
                , "pvc" .= contentDigest pvcBytes
                , "statefulset" .= contentDigest statefulBytes
                , "verify" .= contentDigest verifyBytes
                ]
            )
        )
    base <-
      mkScopeDeclaration
        owner
        [ ResourceBundle
            (map Managed (sortOn (^. #identity) [service, pvcMember, statefulMember, jobMember]))
            []
            []
            []
            [restoreProof]
            []
        ]
    pure (withScopeOverrides overrides (withScopeConfigDigest (contentDigest combined) base), native)

copyRestoreAnnotations :: ByteString -> Value -> Either T.Text Value
copyRestoreAnnotations jobBytes = \case
  Object root | Just (Object metadata) <- KM.lookup "metadata" root -> do
    job <- first T.pack (eitherDecodeStrict jobBytes)
    annotations <- case job of
      Object jobRoot
        | Just (Object jobMetadata) <- KM.lookup "metadata" jobRoot
        , Just (Object fields) <- KM.lookup "annotations" jobMetadata ->
            Right fields
      _ -> Left "Redis restore verifier lacks reviewed source pins"
    pure
      ( Object
          ( KM.insert
              "metadata"
              ( Object
                  (KM.insert "annotations" (Object annotations) metadata)
              )
              root
          )
      )
  _ -> Left "Redis scratch StatefulSet lacks metadata"

metadataText ::
  (T.Text -> NonEmpty InventoryError) ->
  T.Text ->
  T.Text ->
  Value ->
  Either (NonEmpty InventoryError) T.Text
metadataText invalid section key value = case value of
  Object root
    | Just (Object metadata) <- KM.lookup "metadata" root
    , Just (Object fields) <- KM.lookup (K.fromText section) metadata
    , Just (String selected) <- KM.lookup (K.fromText key) fields ->
        Right selected
  _ -> Left (invalid ("database StatefulSet metadata lacks " <> key))

annotateJob ::
  ManualRestoreRequest ->
  ScopeDeclaration ->
  ResourceId ->
  ManagedResource ->
  ManagedResource ->
  T.Text ->
  T.Text ->
  ContentDigest ->
  T.Text ->
  Value ->
  Either T.Text Value
annotateJob request accepted backupJob stateful pvc objectUrl receiptUrl receiptDigest scratch = \case
  Object root
    | Just (Object metadata) <- KM.lookup "metadata" root ->
        let annotations =
              object
                [ "nagare.dev/restore-id" .= restoreId request
                , "nagare.dev/restore-backup-job" .= resourceIdText backupJob
                , "nagare.dev/restore-backup-object" .= objectUrl
                , "nagare.dev/restore-backup-receipt" .= receiptUrl
                , "nagare.dev/restore-backup-receipt-digest" .= digestText receiptDigest
                , "nagare.dev/restore-target-scope" .= scopeIdText (scopeId accepted)
                , "nagare.dev/restore-target-revision"
                    .= digestText
                      (revisionDigest (restoreTargetRevision request))
                , "nagare.dev/restore-target-statefulset" .= resourceIdText (stateful ^. #identity)
                , "nagare.dev/restore-target-statefulset-uid"
                    .= physicalIdentityText
                      (restoreTargetStatefulUid request)
                , "nagare.dev/restore-target-pvc" .= resourceIdText (pvc ^. #identity)
                , "nagare.dev/restore-target-pvc-uid" .= physicalIdentityText (restoreTargetPvcUid request)
                , "nagare.dev/restore-target-database" .= scratch
                ]
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
  _ -> Left "manual restore Job lacks native metadata"
