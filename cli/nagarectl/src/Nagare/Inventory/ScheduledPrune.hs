-- | Select exact scheduled backup versions for a reviewed keep-last-N prune.
-- The complete provider listing is compared with accepted receipt history;
-- random Job UIDs and ingestion order never stand in for completion order.
module Nagare.Inventory.ScheduledPrune
  ( ScheduledPruneCandidate (..)
  , ScheduledPruneRequest (..)
  , selectScheduledPruneCandidates
  , recoverScheduledPruneCandidate
  , compileScheduledPruneScope
  , compileScheduledPruneRecoveryScope
  ) where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Control.Monad (forM_, unless)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Text.Read (readMaybe)
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (..), storeObjectUrl)
import Nagare.Database.Prune (PruneJobInputs (..), renderScheduledPruneJob, renderScheduledReceiptRecoveryJob)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.ScheduledStore (ListedObject (..))
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
  ( DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced)
  , RecoveryClass (OperatorRecovery), Sensitivity (Private) )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data ScheduledPruneCandidate = ScheduledPruneCandidate
  { scheduledPruneScope :: !ScopeId
  , scheduledPruneId :: !Text
  , scheduledPruneObject :: !Text
  , scheduledPruneObjectVersion :: !Text
  , scheduledPruneObjectLength :: !Integer
  , scheduledPruneObjectSha256 :: !Text
  , scheduledPruneReceipt :: !Text
  , scheduledPruneReceiptVersion :: !Text
  , scheduledPruneReceiptLength :: !Integer
  , scheduledPruneReceiptDigest :: !Text
  , scheduledPruneCompleted :: !UTCTime
  }
  deriving stock (Eq, Show)

data ScheduledPruneRequest = ScheduledPruneRequest
  { scheduledPruneDatabase :: !Text
  , scheduledPruneNamespace :: !Text
  , scheduledPruneCandidate :: !ScheduledPruneCandidate
  , scheduledPruneBackupRevision :: !ScopeRevision
  , scheduledPruneBackupJobUid :: !PhysicalIdentity
  , scheduledPrunePolicyScope :: !ScopeId
  , scheduledPrunePolicyRevision :: !ScopeRevision
  , scheduledPruneKeep :: !Int
  , scheduledPruneBackend :: !StoreBackend
  , scheduledPruneSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

-- | Refuse incomplete, unaccepted, already-pruned-but-visible, or unknown
-- provider objects. A tie across the retention boundary has no provable
-- newest-N ordering. Accepted restore dependencies retain their runs while
-- unrelated older runs may still become exact deletion candidates.
selectScheduledPruneCandidates
  :: ScopeId -> Text -> Text -> Text -> Int -> Set Text
  -> [ScopeDeclaration] -> [ListedObject]
  -> Either Text [ScheduledPruneCandidate]
selectScheduledPruneCandidates source bucketAddress prefix format keep protected scopes listed = do
  unless (keep > 0)
    (Left "scheduled backup retention must keep at least one run")
  unless (bucketAddress `T.isPrefixOf` prefix
      && not (T.null bucketAddress) && T.isSuffixOf "/" bucketAddress)
    (Left "scheduled backup prefix is outside the listed provider bucket")
  unless (Set.size (Set.fromList (map listedKey listed)) == length listed)
    (Left "scheduled backup provider listing repeats a key")
  let fields scope = scopeOverrides scope
      sourceName = scopeIdText source
      sameSource scope = Map.lookup "scheduled.backup.source.scope" (fields scope)
        == Just sourceName
      pruned = Set.fromList
        [selected | scope <- scopes,
          Just selected <- [Map.lookup "scheduled.prune.backup.scope" (fields scope)]]
      backups = filter (\scope -> sameSource scope
        && Set.notMember (scopeIdText (scopeId scope)) pruned) scopes
      visible = Map.fromList [(bucketAddress <> listedKey item, listedModified item)
        | item <- listed]
  entries <- traverse (accepted prefix format visible) backups
  let identifiers = map (scopeIdText . scheduledPruneScope) entries
  unless (Set.size (Set.fromList identifiers) == length entries
      && Set.size (Set.fromList (map scheduledPruneId entries)) == length entries)
    (Left "scheduled backup accepted history repeats a run")
  let expected = Set.fromList (concat
        [[scheduledPruneObject entry, scheduledPruneReceipt entry]
          | entry <- entries])
  unless (Map.keysSet visible == expected)
    (Left "scheduled backup listing differs from accepted unpruned receipts")
  let newest = sortOn (Down . scheduledPruneCompleted) entries
      (retained, eligible) = splitAt keep newest
  case (reverse retained, eligible) of
    (boundary : _, next : _)
      | scheduledPruneCompleted boundary == scheduledPruneCompleted next ->
          Left "scheduled backup completion times tie across the retention boundary"
    _ -> pure ()
  pure (sortOn scheduledPruneCompleted
    (filter (\entry -> Set.notMember
      (scopeIdText (scheduledPruneScope entry)) protected) eligible))

accepted :: Text -> Text -> Map.Map Text UTCTime -> ScopeDeclaration
  -> Either Text ScheduledPruneCandidate
accepted prefix format visible scope = do
  let fields = scopeOverrides scope
      required key = maybe (Left ("scheduled prune lacks " <> key)) Right
        (Map.lookup key fields)
      positive key = do
        raw <- required key
        value <- maybe (Left ("scheduled prune has invalid " <> key)) Right
          (readMaybe (T.unpack raw) :: Maybe Integer)
        unless (value > 0) (Left ("scheduled prune has empty " <> key))
        pure value
      digest key = do
        raw <- required key
        unless (T.length raw == 64 && T.all lowerHex raw)
          (Left ("scheduled prune has invalid " <> key))
        pure raw
  backupId <- required "scheduled.backup.id"
  unless (validUid backupId)
    (Left "scheduled prune backup ID is not a Job UID")
  objectAddress <- required "scheduled.backup.object"
  receipt <- required "scheduled.backup.receipt"
  unless (objectAddress == prefix <> backupId <> "." <> format
      && receipt == objectAddress <> ".receipt.json")
    (Left "scheduled prune backup addresses another key space")
  objectTime <- maybe (Left "scheduled backup object is missing") Right
    (Map.lookup objectAddress visible)
  receiptTime <- maybe (Left "scheduled backup receipt is missing") Right
    (Map.lookup receipt visible)
  unless (receiptTime >= objectTime)
    (Left "scheduled backup receipt predates its object")
  objectVersion <- required "scheduled.backup.object.version"
  receiptVersion <- required "scheduled.backup.receipt.version"
  unless (not (T.null objectVersion) && not (T.null receiptVersion))
    (Left "scheduled prune lacks exact provider versions")
  objectLength <- positive "scheduled.backup.object.length"
  receiptLength <- positive "scheduled.backup.receipt.length"
  objectSha <- digest "scheduled.backup.object.sha256"
  receiptDigest <- digest "scheduled.backup.receipt.digest"
  pure ScheduledPruneCandidate
    { scheduledPruneScope = scopeId scope
    , scheduledPruneId = backupId
    , scheduledPruneObject = objectAddress
    , scheduledPruneObjectVersion = objectVersion
    , scheduledPruneObjectLength = objectLength
    , scheduledPruneObjectSha256 = objectSha
    , scheduledPruneReceipt = receipt
    , scheduledPruneReceiptVersion = receiptVersion
    , scheduledPruneReceiptLength = receiptLength
    , scheduledPruneReceiptDigest = receiptDigest
    , scheduledPruneCompleted = receiptTime
    }

lowerHex :: Char -> Bool
lowerHex character = character >= '0' && character <= '9'
  || character >= 'a' && character <= 'f'

validUid :: Text -> Bool
validUid uid = T.length uid == 36 && and
  [if position `elem` [8, 13, 18, 23] then character == '-'
    else lowerHex character
    | (position, character) <- zip [0 :: Int ..] (T.unpack uid)]

-- | Reconstruct only the candidate already named by an immutable failed
-- review. The data version may now be absent, so ordinary retention selection
-- cannot authorize recovery from the current-key listing.
recoverScheduledPruneCandidate
  :: ScopeDeclaration -> ScopeDeclaration -> UTCTime
  -> Either Text ScheduledPruneCandidate
recoverScheduledPruneCandidate backup failed receiptTime = do
  let backupFields = scopeOverrides backup
      failedFields = scopeOverrides failed
      required fields key = maybe (Left ("scheduled recovery lacks " <> key)) Right
        (Map.lookup key fields)
  backupId <- required backupFields "scheduled.backup.id"
  objectAddress <- required backupFields "scheduled.backup.object"
  receiptAddress <- required backupFields "scheduled.backup.receipt"
  let (prefix, leaf) = T.breakOnEnd "/" objectAddress
  format <- maybe (Left "scheduled recovery object has another run key") Right
    (T.stripPrefix (backupId <> ".") leaf)
  unless (not (T.null prefix) && not (T.null format))
    (Left "scheduled recovery object has no accepted prefix or format")
  candidate <- accepted prefix format (Map.fromList
    [(objectAddress, receiptTime), (receiptAddress, receiptTime)]) backup
  let exact =
        [ ("scheduled.prune.backup.scope", scopeIdText (scopeId backup))
        , ("scheduled.prune.object", objectAddress)
        , ("scheduled.prune.object.version", scheduledPruneObjectVersion candidate)
        , ("scheduled.prune.receipt", receiptAddress)
        , ("scheduled.prune.receipt.version", scheduledPruneReceiptVersion candidate)
        ]
  forM_ exact $ \(key, expected) -> do
    actual <- required failedFields key
    unless (actual == expected)
      (Left ("scheduled recovery changes reviewed " <> key))
  pure candidate

-- | One selected run becomes one independent, reviewed Job. The existing
-- prune adapter checks the accepted ingestion Job's UID/native bytes at apply;
-- the Job itself checks both reviewed provider versions and hashes before the
-- first deletion. A partial failure is OperatorRecovery, never an auto retry.
compileScheduledPruneScope
  :: ScheduledPruneRequest -> ScopeDeclaration
  -> Map.Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileScheduledPruneScope request backup native =
  compileScheduledPruneScopeWith Nothing request backup native

compileScheduledPruneRecoveryScope
  :: ScheduledPruneRequest -> ScopeDeclaration
  -> Map.Map ResourceId (ManagedResource, ByteString)
  -> ScopeDeclaration -> PhysicalIdentity -> ContentDigest
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileScheduledPruneRecoveryScope request backup native failed failedUid reviewDigest =
  compileScheduledPruneScopeWith (Just (failed, failedUid, reviewDigest))
    request backup native

compileScheduledPruneScopeWith
  :: Maybe (ScopeDeclaration, PhysicalIdentity, ContentDigest)
  -> ScheduledPruneRequest -> ScopeDeclaration
  -> Map.Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileScheduledPruneScopeWith recovery request backup native = do
  let candidate = scheduledPruneCandidate request
      invalid message = inventoryError "invalid-scheduled-prune" message
        & #scopes .~ [scopeId backup]
        & #sources .~ [scheduledPruneSource request]
        & (:| [])
      fields = scopeOverrides backup
      required key = maybe (Left (invalid ("scheduled receipt lacks " <> key))) Right
        (Map.lookup key fields)
      db = scheduledPruneDatabase request
      ns = scheduledPruneNamespace request
      backupId = scheduledPruneId candidate
  _ <- first invalid (mkServiceName db)
  _ <- first invalid (mkServiceName ns)
  unless (scopeId backup == scheduledPruneScope candidate && validUid backupId)
    (Left (invalid "selected candidate differs from the accepted receipt scope"))
  unless (Map.lookup "scheduled.backup.source.scope" fields
      == Just (scopeIdText (scheduledPrunePolicyScope request))
      && scheduledPruneKeep request > 0)
    (Left (invalid "scheduled prune policy source or keep count is invalid"))
  case recovery of
    Nothing -> pure ()
    Just (failed, _, _) -> do
      _ <- case scheduledPruneBackend request of
        MinioBackend {} -> Right ()
        GcsBackend {} -> Left (invalid "cloud scheduled prune recovery requires exact-generation evidence")
      checked <- first invalid (recoverScheduledPruneCandidate backup failed
        (scheduledPruneCompleted candidate))
      unless (checked == candidate
          && Map.lookup "scheduled.prune.policy.scope" (scopeOverrides failed)
            == Just (scopeIdText (scheduledPrunePolicyScope request))
          && Map.lookup "scheduled.prune.policy.revision" (scopeOverrides failed)
            == Just (digestText (revisionDigest
              (scheduledPrunePolicyRevision request)))
          && Map.lookup "scheduled.prune.policy.keep" (scopeOverrides failed)
            == Just (T.pack (show (scheduledPruneKeep request))))
        (Left (invalid "scheduled recovery changes the failed retention candidate or policy"))
  let exact =
        [ ("scheduled.backup.id", backupId)
        , ("scheduled.backup.object", scheduledPruneObject candidate)
        , ("scheduled.backup.object.version", scheduledPruneObjectVersion candidate)
        , ("scheduled.backup.object.length", T.pack (show
            (scheduledPruneObjectLength candidate)))
        , ("scheduled.backup.object.sha256", scheduledPruneObjectSha256 candidate)
        , ("scheduled.backup.receipt", scheduledPruneReceipt candidate)
        , ("scheduled.backup.receipt.version", scheduledPruneReceiptVersion candidate)
        , ("scheduled.backup.receipt.length", T.pack (show
            (scheduledPruneReceiptLength candidate)))
        , ("scheduled.backup.receipt.digest", scheduledPruneReceiptDigest candidate)
        ]
  forM_ exact $ \(key, expected) -> do
    actual <- required key
    unless (actual == expected)
      (Left (invalid ("selected candidate changes " <> key)))
  let objectPrefix = storeObjectUrl (scheduledPruneBackend request)
        ("databases/" <> db <> "/" <> backupId <> ".")
  unless (objectPrefix `T.isPrefixOf` scheduledPruneObject candidate
      && scheduledPruneReceipt candidate
        == scheduledPruneObject candidate <> ".receipt.json")
    (Left (invalid "scheduled prune candidate addresses another backend or database"))
  ingestionJob <- case [member | bundle <- scopeBundles backup,
      Managed member <- declarations bundle,
      case member ^. #address of
        Kubernetes _ "batch" kind (Just namespace) _ ->
          nameText kind == "job" && nameText namespace == ns
        _ -> False] of
    [single] -> Right single
    _ -> Left (invalid "accepted scheduled receipt lacks one ingestion Job")
  (acceptedJob, jobBytes) <- maybe
    (Left (invalid "accepted ingestion Job lacks private native evidence")) Right
    (Map.lookup (ingestionJob ^. #identity) native)
  unless (acceptedJob == ingestionJob)
    (Left (invalid "accepted ingestion Job native member changed"))
  jobValue <- first (invalid . T.pack) (eitherDecodeStrict jobBytes)
  jobCanonical <- first invalid (canonicalValue jobValue)
  unless (ingestionJob ^. #spec == NativeObject (contentDigest jobCanonical))
    (Left (invalid "accepted ingestion Job native digest changed"))
  cluster <- case ingestionJob ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "accepted ingestion Job has no Kubernetes address")
  let ownerPrefix = case recovery of
        Nothing -> "database-scheduled-prune-"
        Just _ -> "database-scheduled-prune-recovery-"
  owner <- first invalid (mkScopeId Standalone
    (ownerPrefix <> ns <> "-" <> db <> "-" <> backupId))
  key <- first invalid (mkLogicalKey backupId)
  jobRole <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "prune")
  let pruneJobId = mintResourceId owner key jobRole
      proofId = mintResourceId owner key proofRole
      jobName = case recovery of
        Nothing -> "nagare-schedprune-" <> T.take 40
          (digestText (contentDigest (TE.encodeUtf8 (scheduledPruneObject candidate))))
        Just _ -> "nagare-schedprune-recover-" <> T.take 35
          (digestText (contentDigest (TE.encodeUtf8 (scheduledPruneObject candidate))))
      inputs = PruneJobInputs
        { namespace = ns, jobName = jobName
        , objectUrl = scheduledPruneObject candidate
        , receiptUrl = scheduledPruneReceipt candidate
        , objectSha256 = scheduledPruneObjectSha256 candidate
        , receiptSha256 = scheduledPruneReceiptDigest candidate
        , expiryEpoch = 0
        , backend = scheduledPruneBackend request }
  let jobManifest = case recovery of
        Nothing -> renderScheduledPruneJob inputs
          (scheduledPruneObjectVersion candidate)
          (scheduledPruneReceiptVersion candidate)
        Just _ -> renderScheduledReceiptRecoveryJob inputs
          (scheduledPruneObjectVersion candidate)
          (scheduledPruneReceiptVersion candidate)
  rendered <- first (invalid . T.pack . show)
    (Yaml.decodeEither' jobManifest :: Either Yaml.ParseException Value)
  annotated <- case rendered of
    Object root | Just (Object metadata) <- KM.lookup "metadata" root ->
      let annotations = object $
            [ "nagare.dev/prune-backup-scope" .= scopeIdText (scopeId backup)
            , "nagare.dev/prune-backup-job" .=
                resourceIdText (ingestionJob ^. #identity)
            , "nagare.dev/prune-backup-job-uid" .=
                physicalIdentityText (scheduledPruneBackupJobUid request)
            , "nagare.dev/scheduled-prune-backup-id" .= backupId
            ] <> case recovery of
              Nothing -> []
              Just (failed, failedUid, reviewDigest) ->
                [ "nagare.dev/scheduled-prune-failed-scope" .= scopeIdText (scopeId failed)
                , "nagare.dev/scheduled-prune-failed-job-uid" .= physicalIdentityText failedUid
                , "nagare.dev/scheduled-prune-failed-review" .= digestText reviewDigest
                ]
       in Right (Object (KM.insert "metadata" (Object
            (KM.insert "annotations" annotations metadata)) root))
    _ -> Left (invalid "scheduled prune Job lacks native metadata")
  canonical <- first invalid (canonicalValue annotated)
  (bound, bytes) <- first (:| []) (bindKubernetesObject KubernetesInput
    { resourceId = pruneJobId, ownerScope = owner, clusterId = cluster
    , inputObject = annotated, objectDigest = contentDigest canonical
    , lifecyclePolicy = DeleteWhenUnreferenced, inputDataPolicy = Stateless
    , inputSensitivity = Private, sourceLocation = scheduledPruneSource request })
  expectedAddress <- first invalid (kubernetesAddress cluster "batch/v1"
    "Job" (Just ns) jobName)
  unless (bound ^. #address == expectedAddress)
    (Left (invalid "scheduled prune Job has another native address"))
  let member = bound {dependencies = [OrderedAfter (ingestionJob ^. #identity)]}
  receiptDigest <- first invalid (mkContentDigest
    (scheduledPruneReceiptDigest candidate))
  let
      proof = DeclaredOperation proofId (pruneJobId :| [])
        [ContentInput (contentDigest bytes), ContentInput receiptDigest]
        OperatorRecovery PruneData
      overrides = Map.fromList
        [ ("scheduled.prune.backup.scope", scopeIdText (scopeId backup))
        , ("prune.backup.scope", scopeIdText (scopeId backup))
        , ("prune.backup.revision", digestText
            (revisionDigest (scheduledPruneBackupRevision request)))
        , ("prune.backup.job", resourceIdText (ingestionJob ^. #identity))
        , ("prune.backup.job.uid", physicalIdentityText
            (scheduledPruneBackupJobUid request))
        , ("scheduled.prune.policy.scope", scopeIdText
            (scheduledPrunePolicyScope request))
        , ("scheduled.prune.policy.revision", digestText
            (revisionDigest (scheduledPrunePolicyRevision request)))
        , ("scheduled.prune.policy.keep", T.pack (show
            (scheduledPruneKeep request)))
        , ("scheduled.prune.object", scheduledPruneObject candidate)
        , ("scheduled.prune.object.version", scheduledPruneObjectVersion candidate)
        , ("scheduled.prune.receipt", scheduledPruneReceipt candidate)
        , ("scheduled.prune.receipt.version", scheduledPruneReceiptVersion candidate)
        ] `Map.union` case recovery of
          Nothing -> Map.empty
          Just (failed, failedUid, reviewDigest) -> Map.fromList
            [ ("scheduled.prune.recovery.failed.scope", scopeIdText (scopeId failed))
            , ("scheduled.prune.recovery.failed.job.uid", physicalIdentityText failedUid)
            , ("scheduled.prune.recovery.review", digestText reviewDigest)
            ]
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  pure (withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base),
    Map.singleton pruneJobId (member, bytes))
