-- | Expiry-gated, exact-object pruning for one accepted manual volume snapshot.
-- A fixed Job checks the completed snapshot receipt and current provider
-- versions before deleting either object. Partial deletion needs recovery.
module Nagare.Inventory.VolumePrune
  ( VolumePruneRequest (..)
  , volumePruneJobCredentialPin
  , compileVolumePruneScope
  )
where

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
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..), storeObjectUrl)
import Nagare.Database.Prune (PruneJobInputs (..), renderVolumePruneJob)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Backup (manualBackupJobReceiptExpectation, parseBackupReceipt)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
  ( DataPolicy (Stateless)
  , LifecyclePolicy (DeleteWhenUnreferenced)
  , RecoveryClass (OperatorRecovery)
  , Sensitivity (Private)
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data VolumePruneRequest = VolumePruneRequest
  { pruneVolumeApp :: !Text
  , pruneVolumeName :: !Text
  , pruneVolumeNamespace :: !Text
  , pruneVolumeBackupId :: !Text
  , pruneVolumeBackupRevision :: !ScopeRevision
  , pruneVolumeBackupUid :: !PhysicalIdentity
  , pruneVolumeReceiptBytes :: !ByteString
  , pruneVolumeNow :: !UTCTime
  , pruneVolumeBackend :: !StoreBackend
  , pruneVolumeCredential :: !(Maybe (ManagedResource, PhysicalIdentity))
  , pruneVolumeSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

volumePruneJobCredentialPin ::
  ByteString -> Either Text (Maybe (ResourceId, PhysicalIdentity))
volumePruneJobCredentialPin bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root
      | KM.lookup "kind" root == Just (String "Job")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , Just (Object annotations) <- KM.lookup "annotations" metadata
      , Just (String _) <- KM.lookup "nagare.dev/volume-prune-id" annotations ->
          case ( KM.lookup "nagare.dev/volume-prune-store-secret" annotations
               , KM.lookup "nagare.dev/volume-prune-store-secret-uid" annotations
               ) of
            (Nothing, Nothing) -> Right Nothing
            (Just (String resource), Just (String uid)) ->
              Just <$> ((,) <$> mkResourceId resource <*> mkPhysicalIdentity uid)
            _ -> Left "volume prune Job has incomplete store credential pins"
    _ -> Right Nothing

compileVolumePruneScope ::
  VolumePruneRequest ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileVolumePruneScope request backup native = do
  let invalid message =
        inventoryError "invalid-volume-prune" message
          & #scopes
          .~ [scopeId backup]
          & #sources
          .~ [pruneVolumeSource request]
          & (:| [])
      required key =
        maybe
          (Left (invalid ("volume backup lacks " <> key)))
          Right
          (Map.lookup key (scopeOverrides backup))
      app = pruneVolumeApp request
      volume = pruneVolumeName request
      ns = pruneVolumeNamespace request
      backupId = pruneVolumeBackupId request
  _ <- first invalid (mkServiceName app)
  _ <- first invalid (mkServiceName volume)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName backupId)
  unless
    (T.length backupId <= 20)
    (Left (invalid "volume snapshot ID must contain at most 20 characters"))
  acceptedId <- required "volume-backup.id"
  unless
    (acceptedId == backupId)
    (Left (invalid "volume snapshot ID differs from its accepted scope"))
  expiryText <- required "volume-backup.expiry"
  expiry <- case parseTimeM
                   True
                   defaultTimeLocale
                   "%Y-%m-%dT%H:%M:%SZ"
                   (T.unpack expiryText) ::
                   Maybe UTCTime of
    Nothing -> Left (invalid "volume snapshot has no finite UTC expiry")
    Just selected -> Right selected
  unless
    (expiry <= pruneVolumeNow request)
    (Left (invalid "volume snapshot has not reached its reviewed expiry"))
  objectAddress <- required "volume-backup.object"
  receiptAddress <- required "volume-backup.receipt"
  let expectedObject =
        storeObjectUrl
          (pruneVolumeBackend request)
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
  unless
    ( objectAddress == expectedObject
        && receiptAddress == objectAddress <> ".receipt.json"
    )
    (Left (invalid "volume snapshot objects differ from the selected backend"))
  backupJob <- case [ member
                    | bundle <- scopeBundles backup
                    , Managed member <- declarations bundle
                    , case member ^. #address of
                        Kubernetes _ "batch" kind (Just namespace) _ ->
                          nameText kind == "job" && nameText namespace == ns
                        _ -> False
                    ] of
    [single] -> Right single
    _ -> Left (invalid "accepted volume snapshot lacks one Job")
  (boundBackup, backupBytes) <-
    maybe
      (Left (invalid "accepted volume snapshot Job lacks private native evidence"))
      Right
      (Map.lookup (backupJob ^. #identity) native)
  unless
    (boundBackup == backupJob)
    (Left (invalid "accepted volume snapshot Job differs from private native evidence"))
  backupValue <- first (invalid . T.pack) (eitherDecodeStrict backupBytes)
  backupCanonical <- first invalid (canonicalValue backupValue)
  unless
    (backupJob ^. #spec == NativeObject (contentDigest backupCanonical))
    (Left (invalid "accepted volume snapshot Job native digest changed"))
  expectation <- case manualBackupJobReceiptExpectation backupBytes of
    Right (Just selected) -> Right selected
    Right Nothing -> Left (invalid "accepted volume snapshot Job has no receipt")
    Left reason -> Left (invalid reason)
  checksum <-
    first
      invalid
      ( parseBackupReceipt
          expectation
          receiptAddress
          (pruneVolumeReceiptBytes request)
      )
  receiptValue <-
    first
      (invalid . T.pack)
      (eitherDecodeStrict (pruneVolumeReceiptBytes request))
  case receiptValue of
    Object root
      | Just (Object metadata) <- KM.lookup "backup" root
      , KM.lookup "id" metadata == Just (String backupId)
      , KM.lookup "app" metadata == Just (String app)
      , KM.lookup "volume" metadata == Just (String volume)
      , KM.lookup "namespace" metadata == Just (String ns)
      , KM.lookup "expiry" metadata == Just (String expiryText) ->
          pure ()
    _ -> Left (invalid "volume receipt identifies another snapshot or expiry")
  cluster <- case backupJob ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "accepted volume snapshot Job is not in Kubernetes")
  let credential = pruneVolumeCredential request
  case (pruneVolumeBackend request, credential) of
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
        (Left (invalid "accepted volume prune credential differs from its backend"))
      (acceptedSecret, _) <-
        maybe
          (Left (invalid "volume prune credential lacks accepted private native evidence"))
          Right
          (Map.lookup (secret ^. #identity) native)
      unless
        (acceptedSecret == secret)
        (Left (invalid "volume prune credential differs from accepted native evidence"))
    _ -> Left (invalid "volume prune credential differs from its backend")
  owner <-
    first
      invalid
      ( mkScopeId
          Standalone
          ("volume-prune-" <> ns <> "-" <> app <> "-" <> volume <> "-" <> backupId)
      )
  key <- first invalid (mkLogicalKey backupId)
  role <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "prune")
  let jobId = mintResourceId owner key role
      proofId = mintResourceId owner key proofRole
      receiptDigest = contentDigest (pruneVolumeReceiptBytes request)
      jobName = "nagare-volprune-" <> app <> "-" <> volume <> "-" <> backupId
      inputs =
        PruneJobInputs
          { namespace = ns
          , jobName = jobName
          , objectUrl = objectAddress
          , receiptUrl = receiptAddress
          , objectSha256 = checksum
          , receiptSha256 = digestText receiptDigest
          , expiryEpoch = floor (utcTimeToPOSIXSeconds expiry)
          , backend = pruneVolumeBackend request
          }
  unless
    (T.length jobName <= 63)
    (Left (invalid "volume prune Job name exceeds 63 characters"))
  rendered <-
    first
      (invalid . T.pack . show)
      (Yaml.decodeEither' (renderVolumePruneJob inputs) :: Either Yaml.ParseException Value)
  annotated <- first invalid (annotateJob request backup backupJob receiptDigest checksum rendered)
  canonical <- first invalid (canonicalValue annotated)
  (bound, bytes) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = jobId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = annotated
            , objectDigest = contentDigest canonical
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = pruneVolumeSource request
            }
      )
  expected <- first invalid (kubernetesAddress cluster "batch/v1" "Job" (Just ns) jobName)
  unless
    (bound ^. #address == expected)
    (Left (invalid "volume prune Job has an unexpected native address"))
  let member =
        bound
          { dependencies =
              map
                OrderedAfter
                (backupJob ^. #identity : maybe [] (\(secret, _) -> [secret ^. #identity]) credential)
          }
      proof =
        DeclaredOperation
          proofId
          (jobId :| [])
          [ContentInput (contentDigest bytes), ContentInput receiptDigest]
          OperatorRecovery
          PruneData
      overrides =
        Map.fromList
          [ ("prune.backup.scope", scopeIdText (scopeId backup))
          , ("prune.backup.revision", digestText (revisionDigest (pruneVolumeBackupRevision request)))
          , ("prune.backup.job", resourceIdText (backupJob ^. #identity))
          , ("prune.backup.job.uid", physicalIdentityText (pruneVolumeBackupUid request))
          , ("prune.backup.id", backupId)
          , ("prune.object", objectAddress)
          , ("prune.object.sha256", checksum)
          , ("prune.receipt", receiptAddress)
          , ("prune.receipt.digest", digestText receiptDigest)
          , ("prune.expiry", expiryText)
          ]
          <> Map.fromList
            ( case credential of
                Nothing -> []
                Just (secret, uid) ->
                  [ ("prune.credential", resourceIdText (secret ^. #identity))
                  , ("prune.credential.uid", physicalIdentityText uid)
                  ]
            )
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  pure
    ( withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base)
    , Map.singleton jobId (member, bytes)
    )

annotateJob ::
  VolumePruneRequest ->
  ScopeDeclaration ->
  ManagedResource ->
  ContentDigest ->
  Text ->
  Value ->
  Either Text Value
annotateJob request backup backupJob receiptDigest checksum = \case
  Object root
    | Just (Object metadata) <- KM.lookup "metadata" root ->
        let annotations =
              object
                [ "nagare.dev/prune-backup-scope" .= scopeIdText (scopeId backup)
                , "nagare.dev/volume-prune-id" .= pruneVolumeBackupId request
                , "nagare.dev/prune-backup-job" .= resourceIdText (backupJob ^. #identity)
                , "nagare.dev/prune-backup-job-uid" .= physicalIdentityText (pruneVolumeBackupUid request)
                , "nagare.dev/prune-receipt-digest" .= digestText receiptDigest
                , "nagare.dev/prune-object-sha256" .= checksum
                ]
            credentialAnnotations = case pruneVolumeCredential request of
              Nothing -> []
              Just (secret, uid) ->
                [ "nagare.dev/volume-prune-store-secret" .= resourceIdText (secret ^. #identity)
                , "nagare.dev/volume-prune-store-secret-uid" .= physicalIdentityText uid
                ]
            complete = case annotations of
              Object values -> Object (foldr (uncurry KM.insert) values credentialAnnotations)
              _ -> annotations
         in Right
              ( Object
                  ( KM.insert
                      "metadata"
                      ( Object
                          (KM.insert "annotations" complete metadata)
                      )
                      root
                  )
              )
  _ -> Left "volume prune Job metadata is invalid"
