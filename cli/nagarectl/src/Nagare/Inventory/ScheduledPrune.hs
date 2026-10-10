-- | Select exact scheduled backup versions for a reviewed retention prune
-- (EP-183 M2, ADR 28). The complete provider listing is compared with accepted
-- receipt history; only signed recovery-point times decide retention, and
-- random Job UIDs and ingestion order never stand in for completion order.
module Nagare.Inventory.ScheduledPrune
  ( ScheduledPruneCandidate (..)
  , ScheduledPruneRequest (..)
  , selectScheduledPruneCandidates
  , recoverScheduledPruneCandidate
  , compileScheduledPruneScope
  , compileScheduledPruneRecoveryScope
  , acceptedRecoveryPoint
  , isNewScheduledPrune
  , scheduledPruneRetentionAdmission
  , acceptedPastPolicy
  , StoppedPrune (..)
  , classifyStoppedPrune
  , scheduledPruneProviderMatches
  , notYetIngestedRuns
  )
where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Ord (comparing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, defaultTimeLocale, parseTimeM)
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (..), storeObjectUrl)
import Nagare.Database.Prune (PruneJobInputs (..), renderScheduledPruneJob, renderScheduledReceiptRecoveryJob)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective, recoveryPointThresholds)
import Nagare.Inventory.BackupRetention (RetentionPolicy, RetentionSplit (..), retentionPolicyText, splitByRetention)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.ScheduledStore (ListedObject (..))
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
import Text.Read (readMaybe)

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
  , scheduledPruneRetention :: !RetentionPolicy
  , scheduledPruneBackend :: !StoreBackend
  , scheduledPruneSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

-- | Refuse incomplete, unaccepted, already-pruned-but-visible, or unknown
-- provider objects. Only runs whose signed recovery point is past the policy
-- are candidates; a run accepted without a signed time (a v4 receipt) is kept.
-- Accepted restore dependencies retain their runs while unrelated older runs
-- may still become exact deletion candidates.
selectScheduledPruneCandidates ::
  ScopeId ->
  Text ->
  Text ->
  Text ->
  RetentionPolicy ->
  RecoveryPointObjective ->
  UTCTime ->
  Set Text ->
  [ScopeDeclaration] ->
  [ListedObject] ->
  Either Text [ScheduledPruneCandidate]
selectScheduledPruneCandidates source bucketAddress prefix format policy objective now protected scopes listed = do
  unless
    ( bucketAddress `T.isPrefixOf` prefix
        && not (T.null bucketAddress)
        && T.isSuffixOf "/" bucketAddress
    )
    (Left "scheduled backup prefix is outside the listed provider bucket")
  unless
    (Set.size (Set.fromList (map listedKey listed)) == length listed)
    (Left "scheduled backup provider listing repeats a key")
  let fields scope = scopeOverrides scope
      sourceName = scopeIdText source
      sameSource scope =
        Map.lookup "scheduled.backup.source.scope" (fields scope)
          == Just sourceName
      pruned =
        Set.fromList
          [ selected
          | scope <- scopes
          , Just selected <- [Map.lookup "scheduled.prune.backup.scope" (fields scope)]
          ]
      backups =
        filter
          ( \scope ->
              sameSource scope
                && Set.notMember (scopeIdText (scopeId scope)) pruned
          )
          scopes
      visible =
        Map.fromList
          [ (bucketAddress <> listedKey item, listedModified item)
          | item <- listed
          ]
  entries <- traverse (\scope -> (,) <$> accepted prefix format visible scope <*> acceptedRecoveryPoint scope) backups
  let identifiers = map (scopeIdText . scheduledPruneScope . fst) entries
  unless
    ( Set.size (Set.fromList identifiers) == length entries
        && Set.size (Set.fromList (map (scheduledPruneId . fst) entries)) == length entries
    )
    (Left "scheduled backup accepted history repeats a run")
  let expected =
        Set.fromList
          ( concat
              [ [scheduledPruneObject entry, scheduledPruneReceipt entry]
              | (entry, _) <- entries
              ]
          )
  keyPrefix <- maybe (Left "scheduled backup prefix is outside the listed provider bucket") Right (T.stripPrefix bucketAddress prefix)
  _ <-
    notYetIngestedRuns
      keyPrefix
      format
      (Set.fromList [run | scope <- scopes, sameSource scope, Just run <- [Map.lookup "scheduled.backup.id" (fields scope)]])
      (Set.fromList (mapMaybe (T.stripPrefix bucketAddress) (Set.toList expected)))
      listed
  split <- splitByRetention policy objective now [(entry, time) | (entry, Just time) <- entries]
  let eligible = pastPolicy split
  pure
    ( sortOn
        scheduledPruneCompleted
        ( filter
            ( \entry ->
                Set.notMember
                  (scopeIdText (scheduledPruneScope entry))
                  protected
            )
            eligible
        )
    )

accepted ::
  Text ->
  Text ->
  Map.Map Text UTCTime ->
  ScopeDeclaration ->
  Either Text ScheduledPruneCandidate
accepted prefix format visible scope = do
  let fields = scopeOverrides scope
      required key =
        maybe
          (Left ("scheduled prune lacks " <> key))
          Right
          (Map.lookup key fields)
      positive key = do
        raw <- required key
        value <-
          maybe
            (Left ("scheduled prune has invalid " <> key))
            Right
            (readMaybe (T.unpack raw) :: Maybe Integer)
        unless (value > 0) (Left ("scheduled prune has empty " <> key))
        pure value
      digest key = do
        raw <- required key
        unless
          (T.length raw == 64 && T.all lowerHex raw)
          (Left ("scheduled prune has invalid " <> key))
        pure raw
  backupId <- required "scheduled.backup.id"
  unless
    (validUid backupId)
    (Left "scheduled prune backup ID is not a Job UID")
  objectAddress <- required "scheduled.backup.object"
  receipt <- required "scheduled.backup.receipt"
  unless
    ( objectAddress == prefix <> backupId <> "." <> format
        && receipt == objectAddress <> ".receipt.json"
    )
    (Left "scheduled prune backup addresses another key space")
  objectTime <-
    maybe
      (Left "scheduled backup object is missing")
      Right
      (Map.lookup objectAddress visible)
  receiptTime <-
    maybe
      (Left "scheduled backup receipt is missing")
      Right
      (Map.lookup receipt visible)
  unless
    (receiptTime >= objectTime)
    (Left "scheduled backup receipt predates its object")
  objectVersion <- required "scheduled.backup.object.version"
  receiptVersion <- required "scheduled.backup.receipt.version"
  unless
    (not (T.null objectVersion) && not (T.null receiptVersion))
    (Left "scheduled prune lacks exact provider versions")
  objectLength <- positive "scheduled.backup.object.length"
  receiptLength <- positive "scheduled.backup.receipt.length"
  objectSha <- digest "scheduled.backup.object.sha256"
  receiptDigest <- digest "scheduled.backup.receipt.digest"
  pure
    ScheduledPruneCandidate
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

-- | What a failed scheduled prune Job left at its two exact keys, read from
-- the provider's versions under the archive key (MinIO: every version; GCS:
-- every live generation). The recovery Job finishes either state.
data StoppedPrune
  = -- | The Job deleted nothing: both reviewed versions are still live.
    BothRemain
  | -- | The archive is gone and its reviewed receipt is still live.
    ReceiptRemains
  deriving stock (Eq, Show)

-- | EP-183 M2: accept only the states the prune Job's order can leave. Any
-- other version at either key, a receipt gone while its archive is live, or
-- nothing left at all (the run is already pruned) refuses.
classifyStoppedPrune :: (Text, Text) -> (Text, Text) -> [(Text, Text)] -> Either Text StoppedPrune
classifyStoppedPrune archive receipt versions
  | any (`notElem` [archive, receipt]) versions || Set.size (Set.fromList versions) /= length versions =
      Left "stopped prune provider state differs from the reviewed versions"
  | otherwise = case (archive `elem` versions, receipt `elem` versions) of
      (True, True) -> Right BothRemain
      (False, True) -> Right ReceiptRemains
      (False, False) -> Left "nothing of the stopped prune remains; the run is already pruned"
      (True, False) -> Left "the receipt is gone while its archive is live; the bucket changed outside Nagare"

-- | EP-183 M2: the apply-time preflight of a saved scheduled prune, for both
-- backends. Every accepted unpruned receipt's objects are still listed, any
-- other run is one 'notYetIngestedRuns' tolerates, and the archive key's
-- versions are exactly the two reviewed ones. A run the producer uploaded
-- after planning therefore does not refuse the prune.
scheduledPruneProviderMatches :: Text -> Text -> Set Text -> [Text] -> [ListedObject] -> (Text, Text) -> (Text, Text) -> [(Text, Text)] -> Either Text ()
scheduledPruneProviderMatches keyPrefix format known expected listed archive receipt versions = do
  _ <- notYetIngestedRuns keyPrefix format known (Set.fromList expected) listed
  unless
    ( Set.fromList versions == Set.fromList [archive, receipt]
        && length versions == 2
    )
    (Left "scheduled prune provider listing or exact versions changed after review")

-- | EP-183 M2 (decided 2026-10-10): listed runs that no accepted scope names,
-- which a prune tolerates instead of refusing. Each must be strictly newer, by
-- every one of its listed keys, than every listed key of the accepted
-- unpruned runs: the producer keeps uploading while an operator ingests and
-- prunes, and such a run can never be a candidate. An un-ingested run that is
-- not newer still refuses, as does a key that is not a run of this schedule,
-- an accepted run's key reappearing, or an accepted key gone missing. The
-- result is the runs to report as not yet ingested.
notYetIngestedRuns :: Text -> Text -> Set Text -> Set Text -> [ListedObject] -> Either Text [Text]
notYetIngestedRuns keyPrefix format known expected listed = do
  let byKey = Map.fromList [(listedKey entry, listedModified entry) | entry <- listed]
  unless
    (Map.size byKey == length listed)
    (Left "scheduled backup provider listing repeats a key")
  unless
    (all (`Map.member` byKey) (Set.toList expected))
    (Left "scheduled backup listing lacks an accepted unpruned archive or receipt")
  let acceptedTimes = [time | (key, time) <- Map.toList byKey, Set.member key expected]
  runs <- forM [(key, time) | (key, time) <- Map.toList byKey, Set.notMember key expected] $ \(key, time) -> do
    run <- maybe (Left ("unresolved provider key under the schedule: " <> key)) Right (scheduledRunOf key)
    when (Set.member run known) (Left ("an accepted run's object is listed again: " <> key))
    unless
      (all (< time) acceptedTimes)
      (Left ("run " <> run <> " is not ingested and not newer than the newest accepted run; ingest it first (db backup-receipts --all)"))
    pure run
  pure (Set.toAscList (Set.fromList runs))
  where
    scheduledRunOf key = do
      leaf <- T.stripPrefix keyPrefix key
      let objectSuffix = "." <> format
      run <- maybe (T.stripSuffix objectSuffix leaf) Just (T.stripSuffix (objectSuffix <> ".receipt.json") leaf)
      if validUid run then Just run else Nothing

-- | The signed recovery point an accepted receipt scope recorded at ingestion,
-- if its receipt carried one (v5). A malformed value refuses.
acceptedRecoveryPoint :: ScopeDeclaration -> Either Text (Maybe UTCTime)
acceptedRecoveryPoint scope = case Map.lookup "scheduled.backup.recovery.point" (scopeOverrides scope) of
  Nothing -> Right Nothing
  Just raw ->
    maybe
      (Left "accepted scheduled receipt has an invalid recovery point")
      (Right . Just)
      (parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack raw))

-- | A reviewed scope that prunes a scheduled run, as opposed to the receipt
-- recovery of an already admitted partial prune.
isNewScheduledPrune :: ScopeDeclaration -> Bool
isNewScheduledPrune scope =
  Map.member "scheduled.prune.backup.scope" fields
    && Map.notMember "scheduled.prune.recovery.review" fields
  where
    fields = scopeOverrides scope

-- | The accepted, unpruned scheduled runs of one source that the policy,
-- evaluated now, places past policy, for @server status@. Runs accepted without
-- a signed recovery point are kept and not counted. The breach window of the
-- widest objective preset applies, as at admission.
acceptedPastPolicy :: RetentionPolicy -> UTCTime -> ScopeId -> [ScopeDeclaration] -> Either Text [ScopeId]
acceptedPastPolicy policy now source current = do
  let pruned =
        Set.fromList
          [ selected
          | scope <- current
          , Just selected <- [Map.lookup "scheduled.prune.backup.scope" (scopeOverrides scope)]
          ]
      runs =
        [ scope
        | scope <- current
        , Map.lookup "scheduled.backup.source.scope" (scopeOverrides scope) == Just (scopeIdText source)
        , Set.notMember (scopeIdText (scopeId scope)) pruned
        ]
  points <- traverse (\scope -> (scopeId scope,) <$> acceptedRecoveryPoint scope) runs
  pastPolicy <$> splitByRetention policy widestObjective now [(name, time) | (name, Just time) <- points]

-- | The objective preset with the widest breach window.
widestObjective :: RecoveryPointObjective
widestObjective = List.maximumBy (comparing (snd . recoveryPointThresholds)) [minBound .. maxBound]

-- | Admission's retention check (EP-183 M2, ADR 28). Re-read the accepted
-- receipts of each pruned run's source and refuse unless every pruned run has
-- a signed recovery point that the policy, evaluated now, places past policy.
-- The newest point, every point inside the policy's keep-all window or any
-- objective's breach window, and the newest point of each retained day are
-- therefore never removable, whatever the review selected.
scheduledPruneRetentionAdmission ::
  RetentionPolicy ->
  UTCTime ->
  Map.Map ScopeId (ScopeRevision, ScopeDeclaration) ->
  [ScopeDeclaration] ->
  Either Text ()
scheduledPruneRetentionAdmission policy now acceptedScopes reviewed = do
  let current = map snd (Map.elems acceptedScopes)
      byName = Map.fromList [(scopeIdText (scopeId scope), scope) | scope <- current]
      alreadyPruned =
        Set.fromList
          [ selected
          | scope <- current
          , Just selected <- [Map.lookup "scheduled.prune.backup.scope" (scopeOverrides scope)]
          ]
  forM_ (filter isNewScheduledPrune reviewed) $ \prune -> do
    let fields = scopeOverrides prune
        required key = maybe (Left ("scheduled prune lacks " <> key)) Right (Map.lookup key fields)
    recorded <- required "scheduled.prune.policy.retention"
    unless
      (recorded == retentionPolicyText policy)
      (Left ("scheduled prune review records another retention policy: " <> recorded))
    backupName <- required "scheduled.prune.backup.scope"
    policySource <- required "scheduled.prune.policy.scope"
    backup <- maybe (Left "pruned scheduled receipt is not accepted") Right (Map.lookup backupName byName)
    unless
      (Set.notMember backupName alreadyPruned)
      (Left "pruned scheduled receipt was already pruned")
    unless
      (Map.lookup "scheduled.backup.source.scope" (scopeOverrides backup) == Just policySource)
      (Left "pruned scheduled receipt belongs to another source")
    let siblings =
          [ scope
          | scope <- current
          , Map.lookup "scheduled.backup.source.scope" (scopeOverrides scope) == Just policySource
          , Set.notMember (scopeIdText (scopeId scope)) alreadyPruned
          ]
    points <- traverse (\scope -> (scopeIdText (scopeId scope),) <$> acceptedRecoveryPoint scope) siblings
    unless
      (lookup backupName points /= Just Nothing)
      (Left "pruned scheduled receipt has no signed recovery point")
    split <- splitByRetention policy widestObjective now [(name, time) | (name, Just time) <- points]
    unless
      (backupName `elem` pastPolicy split)
      (Left "scheduled prune would remove a recovery point the retention policy keeps (the newest, one inside the keep-all window, or the newest of its day)")

lowerHex :: Char -> Bool
lowerHex character =
  character >= '0' && character <= '9'
    || character >= 'a' && character <= 'f'

validUid :: Text -> Bool
validUid uid =
  T.length uid == 36
    && and
      [ if position `elem` [8, 13, 18, 23]
          then character == '-'
          else lowerHex character
      | (position, character) <- zip [0 :: Int ..] (T.unpack uid)
      ]

-- | Reconstruct only the candidate already named by an immutable failed
-- review. The data version may now be absent, so ordinary retention selection
-- cannot authorize recovery from the current-key listing.
recoverScheduledPruneCandidate ::
  ScopeDeclaration ->
  ScopeDeclaration ->
  UTCTime ->
  Either Text ScheduledPruneCandidate
recoverScheduledPruneCandidate backup failed receiptTime = do
  let backupFields = scopeOverrides backup
      failedFields = scopeOverrides failed
      required fields key =
        maybe
          (Left ("scheduled recovery lacks " <> key))
          Right
          (Map.lookup key fields)
  backupId <- required backupFields "scheduled.backup.id"
  objectAddress <- required backupFields "scheduled.backup.object"
  receiptAddress <- required backupFields "scheduled.backup.receipt"
  let (prefix, leaf) = T.breakOnEnd "/" objectAddress
  format <-
    maybe
      (Left "scheduled recovery object has another run key")
      Right
      (T.stripPrefix (backupId <> ".") leaf)
  unless
    (not (T.null prefix) && not (T.null format))
    (Left "scheduled recovery object has no accepted prefix or format")
  candidate <-
    accepted
      prefix
      format
      ( Map.fromList
          [(objectAddress, receiptTime), (receiptAddress, receiptTime)]
      )
      backup
  let exact =
        [ ("scheduled.prune.backup.scope", scopeIdText (scopeId backup))
        , ("scheduled.prune.object", objectAddress)
        , ("scheduled.prune.object.version", scheduledPruneObjectVersion candidate)
        , ("scheduled.prune.receipt", receiptAddress)
        , ("scheduled.prune.receipt.version", scheduledPruneReceiptVersion candidate)
        ]
  forM_ exact $ \(key, expected) -> do
    actual <- required failedFields key
    unless
      (actual == expected)
      (Left ("scheduled recovery changes reviewed " <> key))
  pure candidate

-- | One selected run becomes one independent, reviewed Job. The existing
-- prune adapter checks the accepted ingestion Job's UID/native bytes at apply;
-- the Job itself checks both reviewed provider versions and hashes before the
-- first deletion. A partial failure is OperatorRecovery, never an auto retry.
compileScheduledPruneScope ::
  ScheduledPruneRequest ->
  ScopeDeclaration ->
  Map.Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileScheduledPruneScope request backup native =
  compileScheduledPruneScopeWith Nothing request backup native

compileScheduledPruneRecoveryScope ::
  ScheduledPruneRequest ->
  ScopeDeclaration ->
  Map.Map ResourceId (ManagedResource, ByteString) ->
  ScopeDeclaration ->
  PhysicalIdentity ->
  ContentDigest ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileScheduledPruneRecoveryScope request backup native failed failedUid reviewDigest =
  compileScheduledPruneScopeWith
    (Just (failed, failedUid, reviewDigest))
    request
    backup
    native

compileScheduledPruneScopeWith ::
  Maybe (ScopeDeclaration, PhysicalIdentity, ContentDigest) ->
  ScheduledPruneRequest ->
  ScopeDeclaration ->
  Map.Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileScheduledPruneScopeWith recovery request backup native = do
  let candidate = scheduledPruneCandidate request
      invalid message =
        inventoryError "invalid-scheduled-prune" message
          & #scopes
          .~ [scopeId backup]
          & #sources
          .~ [scheduledPruneSource request]
          & (:| [])
      fields = scopeOverrides backup
      required key =
        maybe
          (Left (invalid ("scheduled receipt lacks " <> key)))
          Right
          (Map.lookup key fields)
      db = scheduledPruneDatabase request
      ns = scheduledPruneNamespace request
      backupId = scheduledPruneId candidate
  _ <- first invalid (mkServiceName db)
  _ <- first invalid (mkServiceName ns)
  unless
    (scopeId backup == scheduledPruneScope candidate && validUid backupId)
    (Left (invalid "selected candidate differs from the accepted receipt scope"))
  unless
    ( Map.lookup "scheduled.backup.source.scope" fields
        == Just (scopeIdText (scheduledPrunePolicyScope request))
    )
    (Left (invalid "scheduled prune policy source is invalid"))
  case recovery of
    Nothing -> pure ()
    Just (failed, _, _) -> do
      checked <-
        first
          invalid
          ( recoverScheduledPruneCandidate
              backup
              failed
              (scheduledPruneCompleted candidate)
          )
      unless
        ( checked == candidate
            && Map.lookup "scheduled.prune.policy.scope" (scopeOverrides failed)
              == Just (scopeIdText (scheduledPrunePolicyScope request))
            && Map.lookup "scheduled.prune.policy.revision" (scopeOverrides failed)
              == Just
                ( digestText
                    ( revisionDigest
                        (scheduledPrunePolicyRevision request)
                    )
                )
            && Map.lookup "scheduled.prune.policy.retention" (scopeOverrides failed)
              == Just (retentionPolicyText (scheduledPruneRetention request))
        )
        (Left (invalid "scheduled recovery changes the failed retention candidate or policy"))
  let exact =
        [ ("scheduled.backup.id", backupId)
        , ("scheduled.backup.object", scheduledPruneObject candidate)
        , ("scheduled.backup.object.version", scheduledPruneObjectVersion candidate)
        ,
          ( "scheduled.backup.object.length"
          , T.pack
              ( show
                  (scheduledPruneObjectLength candidate)
              )
          )
        , ("scheduled.backup.object.sha256", scheduledPruneObjectSha256 candidate)
        , ("scheduled.backup.receipt", scheduledPruneReceipt candidate)
        , ("scheduled.backup.receipt.version", scheduledPruneReceiptVersion candidate)
        ,
          ( "scheduled.backup.receipt.length"
          , T.pack
              ( show
                  (scheduledPruneReceiptLength candidate)
              )
          )
        , ("scheduled.backup.receipt.digest", scheduledPruneReceiptDigest candidate)
        ]
  forM_ exact $ \(key, expected) -> do
    actual <- required key
    unless
      (actual == expected)
      (Left (invalid ("selected candidate changes " <> key)))
  let objectPrefix =
        storeObjectUrl
          (scheduledPruneBackend request)
          ("databases/" <> db <> "/" <> backupId <> ".")
  unless
    ( objectPrefix `T.isPrefixOf` scheduledPruneObject candidate
        && scheduledPruneReceipt candidate
          == scheduledPruneObject candidate <> ".receipt.json"
    )
    (Left (invalid "scheduled prune candidate addresses another backend or database"))
  ingestionJob <- case [ member
                       | bundle <- scopeBundles backup
                       , Managed member <- declarations bundle
                       , case member ^. #address of
                           Kubernetes _ "batch" kind (Just namespace) _ ->
                             nameText kind == "job" && nameText namespace == ns
                           _ -> False
                       ] of
    [single] -> Right single
    _ -> Left (invalid "accepted scheduled receipt lacks one ingestion Job")
  (acceptedJob, jobBytes) <-
    maybe
      (Left (invalid "accepted ingestion Job lacks private native evidence"))
      Right
      (Map.lookup (ingestionJob ^. #identity) native)
  unless
    (acceptedJob == ingestionJob)
    (Left (invalid "accepted ingestion Job native member changed"))
  jobValue <- first (invalid . T.pack) (eitherDecodeStrict jobBytes)
  jobCanonical <- first invalid (canonicalValue jobValue)
  unless
    (ingestionJob ^. #spec == NativeObject (contentDigest jobCanonical))
    (Left (invalid "accepted ingestion Job native digest changed"))
  cluster <- case ingestionJob ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "accepted ingestion Job has no Kubernetes address")
  let ownerPrefix = case recovery of
        Nothing -> "database-scheduled-prune-"
        Just _ -> "database-scheduled-prune-recovery-"
  owner <-
    first
      invalid
      ( mkScopeId
          Standalone
          (ownerPrefix <> ns <> "-" <> db <> "-" <> backupId)
      )
  key <- first invalid (mkLogicalKey backupId)
  jobRole <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "prune")
  let pruneJobId = mintResourceId owner key jobRole
      proofId = mintResourceId owner key proofRole
      jobName = case recovery of
        Nothing ->
          "nagare-schedprune-"
            <> T.take
              40
              (digestText (contentDigest (TE.encodeUtf8 (scheduledPruneObject candidate))))
        Just _ ->
          "nagare-schedprune-recover-"
            <> T.take
              35
              (digestText (contentDigest (TE.encodeUtf8 (scheduledPruneObject candidate))))
      inputs =
        PruneJobInputs
          { namespace = ns
          , jobName = jobName
          , objectUrl = scheduledPruneObject candidate
          , receiptUrl = scheduledPruneReceipt candidate
          , objectSha256 = scheduledPruneObjectSha256 candidate
          , receiptSha256 = scheduledPruneReceiptDigest candidate
          , expiryEpoch = 0
          , backend = scheduledPruneBackend request
          }
  let jobManifest = case recovery of
        Nothing ->
          renderScheduledPruneJob
            inputs
            (scheduledPruneObjectVersion candidate)
            (scheduledPruneReceiptVersion candidate)
        Just _ ->
          renderScheduledReceiptRecoveryJob
            inputs
            (scheduledPruneObjectVersion candidate)
            (scheduledPruneReceiptVersion candidate)
  rendered <-
    first
      (invalid . T.pack . show)
      (Yaml.decodeEither' jobManifest :: Either Yaml.ParseException Value)
  annotated <- case rendered of
    Object root
      | Just (Object metadata) <- KM.lookup "metadata" root ->
          let annotations =
                object $
                  [ "nagare.dev/prune-backup-scope" .= scopeIdText (scopeId backup)
                  , "nagare.dev/prune-backup-job"
                      .= resourceIdText (ingestionJob ^. #identity)
                  , "nagare.dev/prune-backup-job-uid"
                      .= physicalIdentityText (scheduledPruneBackupJobUid request)
                  , "nagare.dev/scheduled-prune-backup-id" .= backupId
                  ]
                    <> case recovery of
                      Nothing -> []
                      Just (failed, failedUid, reviewDigest) ->
                        [ "nagare.dev/scheduled-prune-failed-scope" .= scopeIdText (scopeId failed)
                        , "nagare.dev/scheduled-prune-failed-job-uid" .= physicalIdentityText failedUid
                        , "nagare.dev/scheduled-prune-failed-review" .= digestText reviewDigest
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
    _ -> Left (invalid "scheduled prune Job lacks native metadata")
  canonical <- first invalid (canonicalValue annotated)
  (bound, bytes) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = pruneJobId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = annotated
            , objectDigest = contentDigest canonical
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = scheduledPruneSource request
            }
      )
  expectedAddress <-
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
    (bound ^. #address == expectedAddress)
    (Left (invalid "scheduled prune Job has another native address"))
  let member = bound {dependencies = [OrderedAfter (ingestionJob ^. #identity)]}
  receiptDigest <-
    first
      invalid
      ( mkContentDigest
          (scheduledPruneReceiptDigest candidate)
      )
  let proof =
        DeclaredOperation
          proofId
          (pruneJobId :| [])
          [ContentInput (contentDigest bytes), ContentInput receiptDigest]
          OperatorRecovery
          PruneData
      overrides =
        Map.fromList
          [ ("scheduled.prune.backup.scope", scopeIdText (scopeId backup))
          , ("prune.backup.scope", scopeIdText (scopeId backup))
          ,
            ( "prune.backup.revision"
            , digestText
                (revisionDigest (scheduledPruneBackupRevision request))
            )
          , ("prune.backup.job", resourceIdText (ingestionJob ^. #identity))
          ,
            ( "prune.backup.job.uid"
            , physicalIdentityText
                (scheduledPruneBackupJobUid request)
            )
          ,
            ( "scheduled.prune.policy.scope"
            , scopeIdText
                (scheduledPrunePolicyScope request)
            )
          ,
            ( "scheduled.prune.policy.revision"
            , digestText
                (revisionDigest (scheduledPrunePolicyRevision request))
            )
          ,
            ( "scheduled.prune.policy.retention"
            , retentionPolicyText (scheduledPruneRetention request)
            )
          , ("scheduled.prune.object", scheduledPruneObject candidate)
          , ("scheduled.prune.object.version", scheduledPruneObjectVersion candidate)
          , ("scheduled.prune.receipt", scheduledPruneReceipt candidate)
          , ("scheduled.prune.receipt.version", scheduledPruneReceiptVersion candidate)
          ]
          `Map.union` case recovery of
            Nothing -> Map.empty
            Just (failed, failedUid, reviewDigest) ->
              Map.fromList
                [ ("scheduled.prune.recovery.failed.scope", scopeIdText (scopeId failed))
                , ("scheduled.prune.recovery.failed.job.uid", physicalIdentityText failedUid)
                , ("scheduled.prune.recovery.review", digestText reviewDigest)
                ]
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  pure
    ( withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base)
    , Map.singleton pruneJobId (member, bytes)
    )
