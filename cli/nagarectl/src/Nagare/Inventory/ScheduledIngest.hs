-- | Compile one verified scheduled backup into an independently reviewed
-- ingestion Job. The Job rereads the two fixed provider versions at apply,
-- checks the stored bytes and HMAC, and records a terminal proof. Its accepted
-- scope is the durable reference that later restore and pruning can consume.
module Nagare.Inventory.ScheduledIngest
  ( ScheduledIngestRequest (..)
  , ScheduledIngestSource (..)
  , scheduledIngestScheduleName
  , ScheduledIngestSourceProof (..)
  , scheduledIngestSourceProof
  , scheduledIngestEvidenceMatches
  , compileScheduledIngestScope
  , pendingScheduledRuns
  , compileScheduledIngestBatch
  , scheduledIngestJobSourcePins
  , ingestScriptFor
  , volumeIngestScriptFor
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, object, toJSON, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (forM_, toList)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Format (defaultTimeLocale, formatTime)
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..), storeEnv, storeHostAliases, storeImage, storeObjectUrl)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Backup (ScheduledBackupReceipt (..), ScheduledReceiptExpectation (..), scheduledReceiptExpectationFromCronJob, scheduledVolumeReceiptExpectationFromCronJob)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Identity (checkedPhysical, requireAccepted)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
  ( DataPolicy (Stateless)
  , LifecyclePolicy (DeleteWhenUnreferenced)
  , RecoveryClass (VerifyBeforeRetry)
  , Sensitivity (Private)
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | What one scheduled run backs up. A database pins its StatefulSet as well
-- as its claim; a volume (EP-183 M3) is named by its schedule, and its only
-- source is the claim the accepted CronJob is ordered after. Verification,
-- acceptance and restore authority are otherwise identical.
data ScheduledIngestSource
  = -- | database name, observed StatefulSet incarnation
    IngestDatabase !Text !PhysicalIdentity
  | -- | the volume schedule's CronJob name
    IngestVolume !Text
  deriving stock (Eq, Show)

scheduledIngestScheduleName :: ScheduledIngestSource -> Text
scheduledIngestScheduleName = \case
  IngestDatabase database _ -> "nagare-dbbackup-" <> database
  IngestVolume schedule -> schedule

data ScheduledIngestRequest = ScheduledIngestRequest
  { ingestSourceKind :: !ScheduledIngestSource
  , ingestNamespace :: !Text
  , ingestBackupId :: !Text
  , ingestSourceRevision :: !ScopeRevision
  , ingestPvcUid :: !PhysicalIdentity
  , ingestScheduleUid :: !PhysicalIdentity
  , ingestSigningUid :: !PhysicalIdentity
  , ingestEvidence :: !ScheduledReceiptEvidence
  , ingestBackend :: !StoreBackend
  , ingestSource :: !SourceLocation
  , ingestAcceptedIncarnations :: !(Map ResourceId PhysicalIdentity)
  -- ^ Accepted incarnations recorded in the head (F49); the live source must be them.
  }
  deriving stock (Eq, Show)

data ScheduledIngestSourceProof = ScheduledIngestSourceProof
  { scheduledSourceScopeName :: !Text
  , scheduledSourceGeneration :: !Integer
  , scheduledSourceDigest :: !ContentDigest
  , scheduledSourceStatefulId :: !(Maybe ResourceId)
  -- ^ 'Nothing' for a volume's run, which has no StatefulSet (EP-183 M3)
  , scheduledSourcePvcId :: !ResourceId
  , scheduledSourceScheduleId :: !ResourceId
  , scheduledSourceSigningId :: !ResourceId
  }
  deriving stock (Eq, Show)

scheduledIngestSourceProof ::
  ScopeDeclaration -> Either Text (Maybe ScheduledIngestSourceProof)
scheduledIngestSourceProof scope
  | Map.notMember "scheduled.backup.id" values = Right Nothing
  | otherwise =
      Just <$> do
        generationText <- required "scheduled.backup.source.generation"
        generation <- case reads (T.unpack generationText) of
          [(number, "")] | number > 0 -> Right number
          _ -> Left "scheduled ingestion source generation is invalid"
        ScheduledIngestSourceProof
          <$> required "scheduled.backup.source.scope"
          <*> pure generation
          <*> (required "scheduled.backup.source.revision" >>= mkContentDigest)
          <*> ( if Map.lookup "scheduled.backup.source.kind" values == Just "volume"
                  then
                    if Map.member "scheduled.backup.source.statefulset" values
                      then Left "scheduled volume ingestion names a StatefulSet"
                      else Right Nothing
                  else Just <$> (required "scheduled.backup.source.statefulset" >>= mkResourceId)
              )
          <*> (required "scheduled.backup.source.pvc" >>= mkResourceId)
          <*> (required "scheduled.backup.schedule" >>= mkResourceId)
          <*> (required "scheduled.backup.signing" >>= mkResourceId)
  where
    values = scopeOverrides scope
    required key =
      maybe
        (Left ("scheduled ingestion lacks " <> key))
        Right
        (Map.lookup key values)

-- | A current provider observation must match the exact accepted receipt pins
-- before a read-only listing may call that backup accepted.
scheduledIngestEvidenceMatches :: ScopeDeclaration -> ScheduledReceiptEvidence -> Bool
scheduledIngestEvidenceMatches scope evidence =
  Map.lookup "scheduled.backup.recovery.point" (scopeOverrides scope)
    == (T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> scheduledRecoveryPoint receipt)
    && all
      (\(key, value) -> Map.lookup key (scopeOverrides scope) == Just value)
      [ ("scheduled.backup.id", physicalIdentityText (scheduledJobUid receipt))
      , ("scheduled.backup.object", scheduledObjectAddress receipt)
      , ("scheduled.backup.object.version", scheduledObjectVersion evidence)
      , ("scheduled.backup.object.length", T.pack (show (scheduledObjectLength evidence)))
      , ("scheduled.backup.object.sha256", scheduledSha256 receipt)
      , ("scheduled.backup.receipt", scheduledObjectAddress receipt <> ".receipt.json")
      , ("scheduled.backup.receipt.version", scheduledReceiptVersion evidence)
      , ("scheduled.backup.receipt.length", T.pack (show (scheduledReceiptLength evidence)))
      , ("scheduled.backup.receipt.digest", digestText (scheduledReceiptDigest evidence))
      , ("scheduled.backup.schedule.revision", digestText (scheduledScheduleRevision receipt))
      ]
  where
    receipt = scheduledReceipt evidence

-- | EP-183 M2 (ADR 22 amendment): the runs one batch review may ingest. Both
-- the archive and its receipt are listed under the schedule's prefix, and no
-- accepted scope names the run. Accepted and pruned runs, and half-written
-- pairs, are never candidates; each candidate is still verified on its own
-- before it is compiled.
pendingScheduledRuns :: Map Text ScopeDeclaration -> [(Text, Bool)] -> [Text]
pendingScheduledRuns accepted recognized =
  [ run
  | run <- sort (Map.keys (Map.fromList [(selected, ()) | (selected, _) <- recognized]))
  , Map.notMember run accepted
  , (run, True) `elem` recognized
  , (run, False) `elem` recognized
  ]

-- | EP-183 M2 (ADR 22 amendment): one reviewed transaction that ingests every
-- verified run of one source. Each run compiles exactly as a single ingestion
-- does, into its own scope, Job and proof, so per-receipt verification, ADR 26
-- per-operation proof and restore authority are unchanged. The batch only
-- refuses requests that are not one source at one accepted revision, or that
-- name a run twice.
compileScheduledIngestBatch ::
  NonEmpty ScheduledIngestRequest ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (NonEmpty (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
compileScheduledIngestBatch requests@(first' :| _) accepted native = do
  let invalid message =
        inventoryError "invalid-scheduled-ingest" message
          & #scopes
          .~ [scopeId accepted]
          & #sources
          .~ [ingestSource first']
          & (:| [])
      source request =
        ( ingestSourceKind request
        , ingestNamespace request
        , ingestSourceRevision request
        , [ingestPvcUid request, ingestScheduleUid request, ingestSigningUid request]
        , ingestBackend request
        , ingestAcceptedIncarnations request
        )
      runs = map ingestBackupId (toList requests)
  unless
    (all ((== source first') . source) requests)
    (Left (invalid "a batch ingestion mixes sources, revisions or incarnations"))
  unless
    (length (Map.keys (Map.fromList [(run, ()) | run <- runs])) == length runs)
    (Left (invalid "a batch ingestion names a run twice"))
  traverse (\request -> compileScheduledIngestScope request accepted native) requests

compileScheduledIngestScope ::
  ScheduledIngestRequest ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileScheduledIngestScope request accepted native = do
  let invalid message =
        inventoryError "invalid-scheduled-ingest" message
          & #scopes
          .~ [scopeId accepted]
          & #sources
          .~ [ingestSource request]
          & (:| [])
      namespaceName = ingestNamespace request
      scheduleName = scheduledIngestScheduleName (ingestSourceKind request)
      select kind name =
        [ member
        | bundle <- scopeBundles accepted
        , Managed member <- declarations bundle
        , case member ^. #address of
            Kubernetes _ group nativeKind (Just nativeNamespace) nativeName ->
              group == (if kind == "CronJob" then "batch" else if kind == "StatefulSet" then "apps" else "")
                && nameText nativeKind == T.toLower kind
                && nameText nativeNamespace == namespaceName
                && nameText nativeName == name
            _ -> False
        ]
      unique kind name = case select kind name of
        [member] -> Right member
        _ -> Left (invalid ("accepted source lacks one " <> kind <> " " <> name))
      acceptedBytes member = case Map.lookup (member ^. #identity) native of
        Just (bound, bytes) | bound == member -> Right bytes
        _ -> Left (invalid "scheduled ingestion lacks matching accepted native bytes")
  cron <- unique "CronJob" scheduleName
  signing <- unique "Secret" (scheduleName <> "-signing")
  -- A database's sources are its StatefulSet and claim by name; a volume's only
  -- source is the one claim the accepted CronJob is ordered after (EP-183 M3).
  (statefulSource, pvc) <- case ingestSourceKind request of
    IngestDatabase database statefulUid -> do
      stateful <- unique "StatefulSet" database
      claim <- unique "PersistentVolumeClaim" (dbPvcName database)
      pure (Just (stateful, statefulUid), claim)
    IngestVolume _ -> case [ member
                           | bundle <- scopeBundles accepted
                           , Managed member <- declarations bundle
                           , OrderedAfter (member ^. #identity) `elem` (cron ^. #dependencies)
                           , Kubernetes _ "" nativeKind (Just nativeNamespace) _ <- [member ^. #address]
                           , nameText nativeKind == "persistentvolumeclaim"
                           , nameText nativeNamespace == namespaceName
                           ] of
      [claim] -> pure (Nothing, claim)
      _ -> Left (invalid "accepted volume schedule is not ordered after exactly one claim")
  -- A receipt from an object that replaced the accepted incarnation outside
  -- Nagare must not become a recovery point (F49).
  -- ADR 27: an unrecorded source is refused too, never read as a match.
  let acceptedSource what member uid = first (\reason -> invalid ("scheduled receipt source is not the accepted database incarnation: " <> reason)) (requireAccepted what (checkedPhysical (ingestAcceptedIncarnations request) (member ^. #identity) uid))
  forM_ statefulSource $ \(stateful, statefulUid) -> acceptedSource "the StatefulSet" stateful statefulUid
  _ <- acceptedSource "the PersistentVolumeClaim" pvc (ingestPvcUid request)
  -- N5: the HMAC key that authenticates the receipt is the accepted Secret's.
  _ <- acceptedSource "the signing Secret" signing (ingestSigningUid request)
  cronBytes <- acceptedBytes cron
  forM_ statefulSource (acceptedBytes . fst)
  _ <- acceptedBytes pvc
  _ <- acceptedBytes signing
  expectation <-
    first
      invalid
      ( case ingestSourceKind request of
          IngestDatabase database statefulUid ->
            scheduledReceiptExpectationFromCronJob
              (ingestBackend request)
              namespaceName
              database
              statefulUid
              (ingestPvcUid request)
              cronBytes
          IngestVolume schedule ->
            scheduledVolumeReceiptExpectationFromCronJob
              (ingestBackend request)
              namespaceName
              schedule
              (ingestPvcUid request)
              cronBytes
      )
  let evidence = ingestEvidence request
      receipt = scheduledReceipt evidence
      objectAddress = scheduledObjectAddress receipt
      receiptAddress = objectAddress <> ".receipt.json"
      expectedObject =
        scheduledObjectPrefix expectation
          <> ingestBackupId request
          <> "."
          <> scheduledFormat expectation
  unless
    ( objectAddress == expectedObject
        && physicalIdentityText (scheduledJobUid receipt) == ingestBackupId request
    )
    (Left (invalid "scheduled receipt identifies another run or object key"))
  unless
    ( all
        (not . T.null)
        [scheduledObjectVersion evidence, scheduledReceiptVersion evidence]
        && scheduledObjectLength evidence > 0
        && scheduledReceiptLength evidence > 0
    )
    (Left (invalid "scheduled receipt lacks exact provider versions and lengths"))
  let anchor = maybe cron fst statefulSource
  cluster <- case anchor ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "accepted scheduled source has no Kubernetes address")
  unless
    (all (sameCluster cluster) [pvc, cron, signing])
    (Left (invalid "scheduled receipt sources use different clusters"))
  owner <-
    first
      invalid
      ( mkScopeId
          Standalone
          ( ( case ingestSourceKind request of
                IngestDatabase database _ -> "database-scheduled-receipt-" <> namespaceName <> "-" <> database
                IngestVolume schedule -> "volume-scheduled-receipt-" <> namespaceName <> "-" <> schedule
            )
              <> "-"
              <> ingestBackupId request
          )
      )
  key <- first invalid (mkLogicalKey (ingestBackupId request))
  role <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "ingest")
  let jobId = mintResourceId owner key role
      proofId = mintResourceId owner key proofRole
      jobName =
        "nagare-receipt-"
          <> T.take
            40
            (digestText (contentDigest (TE.encodeUtf8 objectAddress)))
  jobValue <-
    first
      invalid
      ( renderIngestJob
          request
          expectation
          jobName
          objectAddress
          receiptAddress
          (fmap (\(stateful, statefulUid) -> (stateful ^. #identity, statefulUid)) statefulSource)
          (pvc ^. #identity, ingestPvcUid request)
          (cron ^. #identity, ingestScheduleUid request)
          (signing ^. #identity, ingestSigningUid request)
      )
  canonical <- first invalid (canonicalValue jobValue)
  (bound, bytes) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = jobId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = jobValue
            , objectDigest = contentDigest canonical
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = ingestSource request
            }
      )
  expectedAddress <-
    first
      invalid
      ( kubernetesAddress
          cluster
          "batch/v1"
          "Job"
          (Just namespaceName)
          jobName
      )
  unless
    (bound ^. #address == expectedAddress)
    (Left (invalid "scheduled ingestion Job has another native address"))
  let sources = maybe [] (pure . fst) statefulSource <> [pvc, cron, signing]
      member = bound {dependencies = sort (map (OrderedAfter . (^. #identity)) sources)}
      proof =
        DeclaredOperation
          proofId
          (jobId :| [])
          ( sort
              [ ContentInput (contentDigest bytes)
              , ContentInput (scheduledReceiptDigest evidence)
              ]
          )
          VerifyBeforeRetry
          SnapshotData
      overrides =
        Map.fromList $
          [ ("scheduled.backup.id", ingestBackupId request)
          , ("scheduled.backup.object", objectAddress)
          , ("scheduled.backup.object.version", scheduledObjectVersion evidence)
          , ("scheduled.backup.object.length", T.pack (show (scheduledObjectLength evidence)))
          , ("scheduled.backup.object.sha256", scheduledSha256 receipt)
          , ("scheduled.backup.receipt", receiptAddress)
          , ("scheduled.backup.receipt.version", scheduledReceiptVersion evidence)
          , ("scheduled.backup.receipt.length", T.pack (show (scheduledReceiptLength evidence)))
          , ("scheduled.backup.receipt.digest", digestText (scheduledReceiptDigest evidence))
          , ("scheduled.backup.schedule.revision", digestText (scheduledScheduleRevision receipt))
          , ("scheduled.backup.schedule", resourceIdText (cron ^. #identity))
          , ("scheduled.backup.schedule.uid", physicalIdentityText (ingestScheduleUid request))
          , ("scheduled.backup.signing", resourceIdText (signing ^. #identity))
          , ("scheduled.backup.signing.uid", physicalIdentityText (ingestSigningUid request))
          , ("scheduled.backup.source.scope", scopeIdText (scopeId accepted))
          ,
            ( "scheduled.backup.source.generation"
            , T.pack
                ( show
                    ( generationNumber
                        (revisionGeneration (ingestSourceRevision request))
                    )
                )
            )
          ,
            ( "scheduled.backup.source.revision"
            , digestText
                (revisionDigest (ingestSourceRevision request))
            )
          , ("scheduled.backup.source.pvc", resourceIdText (pvc ^. #identity))
          , ("scheduled.backup.source.pvc.uid", physicalIdentityText (ingestPvcUid request))
          ]
            <> case statefulSource of
              Just (stateful, statefulUid) ->
                [ ("scheduled.backup.source.statefulset", resourceIdText (stateful ^. #identity))
                , ("scheduled.backup.source.statefulset.uid", physicalIdentityText statefulUid)
                ]
              Nothing -> [("scheduled.backup.source.kind", "volume")]
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  let recoveryOverrides =
        maybe
          Map.empty
          (Map.singleton "scheduled.backup.recovery.point" . T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ")
          (scheduledRecoveryPoint receipt)
      scope = withScopeOverrides (Map.union recoveryOverrides overrides) (withScopeConfigDigest (contentDigest canonical) base)
  pure (scope, Map.singleton jobId (member, bytes))

sameCluster :: ResourceId -> ManagedResource -> Bool
sameCluster cluster member = case member ^. #address of
  Kubernetes clusterId _ _ _ _ -> clusterId == cluster
  _ -> False

renderIngestJob ::
  ScheduledIngestRequest ->
  ScheduledReceiptExpectation ->
  Text ->
  Text ->
  Text ->
  Maybe (ResourceId, PhysicalIdentity) ->
  (ResourceId, PhysicalIdentity) ->
  (ResourceId, PhysicalIdentity) ->
  (ResourceId, PhysicalIdentity) ->
  Either Text Value
renderIngestJob
  request
  expectation
  jobName
  objectAddress
  receiptAddress
  statefulPin
  pvcPin
  schedulePin
  signingPin = do
    let backend = ingestBackend request
        evidence = ingestEvidence request
        receipt = scheduledReceipt evidence
        prefix = storeObjectUrl backend ""
    objectKey <-
      maybe
        (Left "scheduled backup is outside the accepted bucket")
        Right
        (T.stripPrefix prefix objectAddress)
    receiptKey <-
      maybe
        (Left "scheduled receipt is outside the accepted bucket")
        Right
        (T.stripPrefix prefix receiptAddress)
    case backend of
      GcsBackend {} ->
        unless
          ( all
              (\value -> not (T.null value) && T.all (\c -> c >= '0' && c <= '9') value && T.any (/= '0') value)
              [scheduledObjectVersion evidence, scheduledReceiptVersion evidence]
          )
          (Left "scheduled GCS receipt requires exact decimal generations")
      _ -> pure ()
    let plain :: Text -> Text -> Value
        plain name value = object ["name" .= name, "value" .= value]
        signingEnv =
          object
            [ "name" .= ("BACKUP_SIGNING_KEY" :: Text)
            , "valueFrom"
                .= object
                  [ "secretKeyRef"
                      .= object
                        [ "name" .= (scheduledIngestScheduleName (ingestSourceKind request) <> "-signing")
                        , "key" .= ("HMAC_KEY" :: Text)
                        ]
                  ]
            ]
        backendEnv = case backend of
          MinioBackend ref -> [plain "S3_ENDPOINT" (endpoint ref), plain "BUCKET" (bucket ref)]
          GcsBackend _ bucketName -> [plain "BUCKET" bucketName]
        env =
          storeEnv backend
            <> backendEnv
            <> [ plain "OBJECT_KEY" objectKey
               , plain "RECEIPT_KEY" receiptKey
               , plain "OBJECT_VERSION" (scheduledObjectVersion evidence)
               , plain "RECEIPT_VERSION" (scheduledReceiptVersion evidence)
               , plain "OBJECT_SHA256" (scheduledSha256 receipt)
               , plain "RECEIPT_SHA256" (digestText (scheduledReceiptDigest evidence))
               , plain "OBJECT_LENGTH" (T.pack (show (scheduledObjectLength evidence)))
               , plain "RECEIPT_LENGTH" (T.pack (show (scheduledReceiptLength evidence)))
               , plain "OBJECT_ADDRESS" objectAddress
               , plain "BACKUP_RUN_ID" (ingestBackupId request)
               ]
            <> [plain "STATEFUL_UID" (physicalIdentityText uid) | Just (_, uid) <- [statefulPin]]
            <> [ plain "PVC_UID" (physicalIdentityText (ingestPvcUid request))
               , plain "METADATA_SHA256" (digestText (scheduledMetadataDigest expectation))
               , plain "SCHEDULE_REVISION" (digestText (scheduledScheduleRevision receipt))
               , plain "RECOVERY_POINT" (maybe "" (T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ") (scheduledRecoveryPoint receipt))
               , signingEnv
               ]
        -- A database's Job pins its StatefulSet; a volume's Job says it has
        -- none, so the executor requires exactly three pins (EP-183 M3).
        statefulAnnotations = case statefulPin of
          Just (resource, uid) ->
            [ "nagare.dev/scheduled-receipt-source-statefulset" .= resourceIdText resource
            , "nagare.dev/scheduled-receipt-source-statefulset-uid" .= physicalIdentityText uid
            ]
          Nothing -> ["nagare.dev/scheduled-receipt-source-kind" .= ("volume" :: Text)]
        annotation =
          object $
            [ "nagare.dev/scheduled-receipt-id" .= ingestBackupId request
            ]
              <> statefulAnnotations
              <> [ "nagare.dev/scheduled-receipt-source-pvc"
                     .= resourceIdText
                       (fst pvcPin)
                 , "nagare.dev/scheduled-receipt-source-pvc-uid"
                     .= physicalIdentityText
                       (snd pvcPin)
                 , "nagare.dev/scheduled-receipt-schedule"
                     .= resourceIdText
                       (fst schedulePin)
                 , "nagare.dev/scheduled-receipt-schedule-uid"
                     .= physicalIdentityText
                       (snd schedulePin)
                 , "nagare.dev/scheduled-receipt-signing"
                     .= resourceIdText
                       (fst signingPin)
                 , "nagare.dev/scheduled-receipt-signing-uid"
                     .= physicalIdentityText
                       (snd signingPin)
                 ]
        container =
          object
            [ "name" .= ("verify" :: Text)
            , "image" .= storeImage (ingestBackend request)
            , "command" .= toJSON (["/bin/sh", "-c"] :: [Text])
            , "args"
                .= toJSON
                  [ maybe volumeIngestScriptFor (const ingestScriptFor) statefulPin backend
                  ]
            , "env" .= toJSON env
            , "volumeMounts"
                .= toJSON
                  [ object
                      ["name" .= ("scratch" :: Text), "mountPath" .= ("/work" :: Text)]
                  ]
            ]
    pure
      ( object
          [ "apiVersion" .= ("batch/v1" :: Text)
          , "kind" .= ("Job" :: Text)
          , "metadata"
              .= object
                [ "name" .= jobName
                , "namespace" .= ingestNamespace request
                , "annotations" .= annotation
                ]
          , "spec"
              .= object
                [ "backoffLimit" .= (0 :: Int)
                , "template"
                    .= object
                      [ "spec"
                          .= object
                            [ "restartPolicy" .= ("Never" :: Text)
                            , "hostAliases" .= storeHostAliases backend
                            , "containers" .= toJSON [container]
                            , "volumes"
                                .= toJSON
                                  [ object
                                      ["name" .= ("scratch" :: Text), "emptyDir" .= object []]
                                  ]
                            ]
                      ]
                ]
          ]
      )

ingestScriptFor :: StoreBackend -> Text
ingestScriptFor = ingestScriptWith "assert payload[\"source\"]=={\"statefulSetUid\":e[\"STATEFUL_UID\"],\"pvcUid\":e[\"PVC_UID\"]}"

-- | A volume run's receipt names exactly its claim (EP-183 M3); every other
-- check is the database script's.
volumeIngestScriptFor :: StoreBackend -> Text
volumeIngestScriptFor = ingestScriptWith "assert payload[\"source\"]=={\"pvcUid\":e[\"PVC_UID\"]}"

ingestScriptWith :: Text -> StoreBackend -> Text
ingestScriptWith sourceCheck backend = T.intercalate "\n" (["set -eu"] <> downloads <> verification)
  where
    downloads = case backend of
      MinioBackend {} -> minioDownloads
      GcsBackend {} -> gcsDownloads
    minioDownloads =
      [ "aws s3api get-object --bucket \"$BUCKET\" --key \"$RECEIPT_KEY\" --version-id \"$RECEIPT_VERSION\" --endpoint-url \"$S3_ENDPOINT\" /work/receipt > /work/receipt-response.json"
      , "aws s3api get-object --bucket \"$BUCKET\" --key \"$OBJECT_KEY\" --version-id \"$OBJECT_VERSION\" --endpoint-url \"$S3_ENDPOINT\" /work/object > /work/object-response.json"
      ]
    gcsDownloads =
      [ "python3 -c 'import json,os,subprocess"
      , "e=os.environ"
      , "for label in [\"RECEIPT\",\"OBJECT\"]:"
      , " address=\"gs://\"+e[\"BUCKET\"]+\"/\"+e[label+\"_KEY\"]"
      , " version=e[label+\"_VERSION\"]"
      , " selected=address+\"#\"+version"
      , " meta=json.loads(subprocess.check_output([\"gcloud\",\"storage\",\"objects\",\"describe\",selected,\"--format=json\"]))"
      , " assert meta[\"bucket\"]==e[\"BUCKET\"] and meta[\"name\"]==e[label+\"_KEY\"] and str(meta[\"generation\"])==version"
      , " assert int(meta[\"size\"])==int(e[label+\"_LENGTH\"])"
      , " subprocess.check_call([\"gcloud\",\"storage\",\"cp\",\"--do-not-decompress\",selected,\"/work/\"+label.lower()])"
      , " json.dump({\"VersionId\":version},open(\"/work/\"+label.lower()+\"-response.json\",\"w\"))'"
      ]
    verification =
      [ "python3 -c 'import hashlib,hmac,json,os,sys"
      , "e=os.environ"
      , "def digest(path):"
      , " h=hashlib.sha256()"
      , " with open(path,\"rb\") as f:"
      , "  for chunk in iter(lambda:f.read(1048576),b\"\"): h.update(chunk)"
      , " return h.hexdigest()"
      , "r=open(\"/work/receipt\",\"rb\").read()"
      , "assert len(r)==int(e[\"RECEIPT_LENGTH\"]) and hashlib.sha256(r).hexdigest()==e[\"RECEIPT_SHA256\"]"
      , "assert os.path.getsize(\"/work/object\")==int(e[\"OBJECT_LENGTH\"]) and digest(\"/work/object\")==e[\"OBJECT_SHA256\"]"
      , "assert json.load(open(\"/work/receipt-response.json\")).get(\"VersionId\")==e[\"RECEIPT_VERSION\"]"
      , "assert json.load(open(\"/work/object-response.json\")).get(\"VersionId\")==e[\"OBJECT_VERSION\"]"
      , "envelope=json.loads(r)"
      , "assert envelope.get(\"version\") in [4,5]"
      , "payload=envelope[\"payload\"]"
      , "assert (envelope[\"version\"]==4 and not e.get(\"RECOVERY_POINT\",\"\")) or (envelope[\"version\"]==5 and payload[\"recoveryPoint\"]==e[\"RECOVERY_POINT\"])"
      , "canonical=json.dumps(payload,sort_keys=True,separators=(\",\",\":\"),ensure_ascii=False).encode(\"utf-8\")"
      , "signature=hmac.new(bytes.fromhex(e[\"BACKUP_SIGNING_KEY\"]),canonical,hashlib.sha256).hexdigest()"
      , "assert hmac.compare_digest(signature,envelope[\"hmacSha256\"])"
      , "assert payload[\"jobUid\"]==e[\"BACKUP_RUN_ID\"] and payload[\"object\"]==e[\"OBJECT_ADDRESS\"]"
      , "assert payload[\"sha256\"]==e[\"OBJECT_SHA256\"]"
      , sourceCheck
      , "metadata=json.dumps(payload[\"backup\"],sort_keys=True,separators=(\",\",\":\"),ensure_ascii=False).encode(\"utf-8\")"
      , "assert hashlib.sha256(metadata).hexdigest()==e[\"METADATA_SHA256\"]"
      , "assert payload[\"backup\"][\"scheduleRevision\"]==e[\"SCHEDULE_REVISION\"]"
      , "json.dump({\"objectVersion\":e[\"OBJECT_VERSION\"],\"receiptVersion\":e[\"RECEIPT_VERSION\"],\"sha256\":e[\"OBJECT_SHA256\"]},open(\"/dev/termination-log\",\"w\"),sort_keys=True)'"
      ]

-- | The executor must observe these exact source incarnations before
-- submitting or resuming a reviewed ingestion Job: four for a database, and
-- three for a volume's run, whose Job declares it has no StatefulSet.
scheduledIngestJobSourcePins ::
  ByteString -> Either Text (Maybe [(ResourceId, PhysicalIdentity)])
scheduledIngestJobSourcePins bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root
      | KM.lookup "kind" root == Just (String "Job")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , Just (Object annotations) <- KM.lookup "annotations" metadata
      , Just (String _) <- KM.lookup "nagare.dev/scheduled-receipt-id" annotations -> do
          let pin label = do
                resource <- case KM.lookup (K.fromText ("nagare.dev/scheduled-receipt-" <> label)) annotations of
                  Just (String field) -> mkResourceId field
                  _ -> Left ("scheduled ingestion lacks " <> label <> " resource pin")
                uid <- case KM.lookup (K.fromText ("nagare.dev/scheduled-receipt-" <> label <> "-uid")) annotations of
                  Just (String field) -> mkPhysicalIdentity field
                  _ -> Left ("scheduled ingestion lacks " <> label <> " UID pin")
                pure (resource, uid)
          labels <- case KM.lookup "nagare.dev/scheduled-receipt-source-kind" annotations of
            Nothing -> Right ["source-statefulset", "source-pvc", "schedule", "signing"]
            Just (String "volume")
              | not (KM.member "nagare.dev/scheduled-receipt-source-statefulset" annotations)
              , not (KM.member "nagare.dev/scheduled-receipt-source-statefulset-uid" annotations) ->
                  Right ["source-pvc", "schedule", "signing"]
            _ -> Left "scheduled ingestion has an invalid source kind"
          Just <$> traverse pin labels
    _ -> Right Nothing
