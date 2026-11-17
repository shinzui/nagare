{-# LANGUAGE OverloadedStrings #-}

-- | Backup lifecycle events (EP-233): the normalized identity a verified
-- backup keeps whichever route finds it, and the pure construction of its
-- @database.backup.completed@ candidate.
--
-- A backup's identity is its origin, the scope that owns its schedule, its
-- run and its exact archive and receipt versions. It holds no collection
-- time, display name, schedule revision or discovery route, so the
-- collector, a manual backup's executor fact and a later acceptance all
-- name the same backup, and a manual run can never collide with a
-- scheduled one.
module Nagare.Events.Backup
  ( backupIdFor
  , completionKey
  , acceptanceKey
  , ScheduleKind (..)
  , SigningRef (..)
  , BackupSchedule (..)
  , VerifiedRun (..)
  , scheduledCompletion
  , backupProducer
  , acceptedBackups
  )
where

import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Envelope (eventIdFor, eventIdText)
import Nagare.Events.Source
import Nagare.Inventory.Backup (ScheduledBackupReceipt (..), ScheduledReceiptExpectation)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | @bk-@ and 32 lowercase hexadecimal digits of the identity's digest.
backupIdFor :: BackupOrigin -> ScopeId -> Text -> StoredVersion -> StoredVersion -> Text
backupIdFor origin owner run archive receipt =
  "bk-"
    <> T.take
      32
      ( digestText
          ( contentDigest
              ( either (error . T.unpack) id $
                  canonicalValue
                    ( object
                        [ "version" .= (1 :: Int)
                        , "origin" .= origin
                        , "scope" .= scopeIdText owner
                        , "run" .= run
                        , "archive" .= archive
                        , "receipt" .= receipt
                        ]
                    )
              )
          )
      )

-- | The source keys of a backup's completion and acceptance.
completionKey, acceptanceKey :: Text -> SourceKey
completionKey backup = either (error . T.unpack) id (mkSourceKey ("database.backup.completed:" <> backup))
acceptanceKey backup = either (error . T.unpack) id (mkSourceKey ("database.backup.accepted:" <> backup))

data ScheduleKind = DatabaseSchedule | AppDatabaseSchedule
  deriving stock (Eq, Ord, Show, Generic)

-- | The accepted signing Secret whose HMAC key authenticates a schedule's
-- receipts, and the incarnation recorded for it.
data SigningRef = SigningRef
  { namespace :: !Text
  , secret :: !Text
  , resource :: !ResourceId
  , incarnation :: !PhysicalIdentity
  }
  deriving stock (Eq, Show, Generic)

-- | One accepted backup schedule the collector reads: where its runs live,
-- the expectations its accepted revisions derive (the current one first),
-- and the recorded source it names.
data BackupSchedule = BackupSchedule
  { kind :: !ScheduleKind
  , label :: !Text
  -- ^ @namespace/database@ or @namespace/appdb@
  , owner :: !ScopeId
  -- ^ the scope that owns the CronJob
  , schedule :: !ResourceId
  , keyPrefix :: !Text
  -- ^ the bucket-relative prefix its runs are uploaded under
  , objectPrefix :: !Text
  -- ^ the same prefix as a full object address
  , expectations :: ![ScheduledReceiptExpectation]
  , signing :: !SigningRef
  , source :: !ResourceRef
  }
  deriving stock (Eq, Show, Generic)

-- | A run the real verifier accepted at exact versions, and the provider's
-- time for its receipt version.
data VerifiedRun = VerifiedRun
  { evidence :: !ScheduledReceiptEvidence
  , receiptTime :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

-- | The completion candidate of one verified scheduled run.
scheduledCompletion :: BackupSchedule -> VerifiedRun -> EventCandidate
scheduledCompletion schedule' verified =
  EventCandidate
    { key = completionKey backup
    , resource = schedule' ^. #source
    , occurredAt = completed
    , evidence = [Evidence "receipt" (scheduledReceiptDigest checked)]
    , payload =
        BackupCompletedPayload
          BackupCompletion
            { backup
            , origin = ScheduledBackup
            , run
            , archive
            , receipt
            , sha256 = scheduledSha256 signed
            , archiveBytes = scheduledObjectLength checked
            , scheduleRevision = Just (scheduledScheduleRevision signed)
            , recoveryPoint = stamp <$> scheduledRecoveryPoint signed
            , completedAt = completed
            }
    }
  where
    checked = verified ^. #evidence
    signed = scheduledReceipt checked
    run = physicalIdentityText (scheduledJobUid signed)
    archive = StoredVersion (scheduledObjectAddress signed) (scheduledObjectVersion checked)
    receipt = StoredVersion (scheduledObjectAddress signed <> ".receipt.json") (scheduledReceiptVersion checked)
    backup = backupIdFor ScheduledBackup (schedule' ^. #owner) run archive receipt
    completed = stamp <$> verified ^. #receiptTime
    stamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | @database.backup.accepted@ (EP-233 M3), and the completion it rests on:
-- a converged transaction that newly records a backup as a recovery point.
-- A scheduled run is accepted by its reviewed ingestion scope; a manual
-- backup by its durable, Job-free receipt record, whose transaction is also
-- where its exact versions are first verified, so that record announces its
-- completion too. Each acceptance carries the completion under the same
-- source key the collector uses, so whichever route the feed sees first
-- publishes it, and the other is the same event. A later revision of the
-- scope that keeps the backup's pins, a save-plan or an admission announces
-- nothing; application-volume runs are not database backups.
backupProducer :: SourceProducer
backupProducer = SourceProducer (const False) ["scheduled.backup.id", "backup.record"] (concatMap pair . acceptedBackups)
  where
    pair (completion, acceptance) = [PublicCandidate completion, PublicCandidate acceptance]

-- | Each newly accepted backup's completion and acceptance candidates.
acceptedBackups :: SourceInput -> [(EventCandidate, EventCandidate)]
acceptedBackups input =
  [ found
  | (receiptScope, view') <- Map.toAscList (input ^. #scopes)
  , Just found <- [scheduledAcceptance input receiptScope view' <|> manualAcceptance input receiptScope view']
  ]

scheduledAcceptance :: SourceInput -> ScopeId -> ScopeView -> Maybe (EventCandidate, EventCandidate)
scheduledAcceptance input receiptScope view' = do
  let fields = view' ^. #desired
      field key = Map.lookup key fields
  run <- field "scheduled.backup.id"
  guard (field "scheduled.backup.source.kind" /= Just "volume")
  guard (newlyPinned view' ["scheduled.backup.id", "scheduled.backup.object.version", "scheduled.backup.receipt.version"])
  owner <- field "scheduled.backup.source.scope" >>= parseScope
  archive <- StoredVersion <$> field "scheduled.backup.object" <*> field "scheduled.backup.object.version"
  receipt <- StoredVersion <$> field "scheduled.backup.receipt" <*> field "scheduled.backup.receipt.version"
  sha <- field "scheduled.backup.object.sha256"
  size <- field "scheduled.backup.object.length" >>= readInteger
  receiptDigest <- field "scheduled.backup.receipt.digest" >>= either (const Nothing) Just . mkContentDigest
  revision <- traverse (either (const Nothing) Just . mkContentDigest) (field "scheduled.backup.schedule.revision")
  let source = sourceRef owner fields "scheduled.backup.source.statefulset"
  pure (pairFor input receiptScope view' ScheduledBackup owner run archive receipt sha size revision (field "scheduled.backup.recovery.point") receiptDigest source)

manualAcceptance :: SourceInput -> ScopeId -> ScopeView -> Maybe (EventCandidate, EventCandidate)
manualAcceptance input receiptScope view' = do
  let fields = view' ^. #desired
      field key = Map.lookup key fields
  guard (field "backup.record" == Just "verified-v1")
  guard ((view' ^. #previous >>= Map.lookup "backup.record") /= Just "verified-v1")
  run <- field "backup.id"
  owner <- field "backup.source.scope" >>= parseScope
  archive <- StoredVersion <$> field "backup.object" <*> field "backup.object.version"
  receipt <- StoredVersion <$> field "backup.receipt" <*> field "backup.receipt.version"
  sha <- field "backup.object.sha256"
  size <- field "backup.object.length" >>= readInteger
  receiptDigest <- field "backup.receipt.digest" >>= either (const Nothing) Just . mkContentDigest
  let source = sourceRef owner fields "backup.source.statefulset"
  pure (pairFor input receiptScope view' ManualBackup owner run archive receipt sha size Nothing Nothing receiptDigest source)

pairFor :: SourceInput -> ScopeId -> ScopeView -> BackupOrigin -> ScopeId -> Text -> StoredVersion -> StoredVersion -> Text -> Integer -> Maybe ContentDigest -> Maybe Text -> ContentDigest -> ResourceRef -> (EventCandidate, EventCandidate)
pairFor input receiptScope view' origin owner run archive receipt sha size revision point receiptDigest source =
  ( EventCandidate
      { key = completionKey backup
      , resource = source
      , occurredAt = Nothing
      , evidence = [Evidence "receipt" receiptDigest]
      , payload = BackupCompletedPayload (BackupCompletion backup origin run archive receipt sha size revision point Nothing)
      }
  , EventCandidate
      { key = acceptanceKey backup
      , resource = source
      , occurredAt = Nothing
      , evidence = [Evidence "review" (input ^. #review), Evidence "receipt" receiptDigest]
      , payload =
          BackupAcceptedPayload
            BackupAcceptance
              { backup
              , completion = eventIdText (eventIdFor (input ^. #context) (completionKey backup))
              , receiptScope
              , receiptRevision = view' ^. #revision
              , transaction = input ^. #transaction
              , review = input ^. #review
              , recoveryPoint = point
              }
      }
  )
  where
    backup = backupIdFor origin owner run archive receipt

-- | The backup's source: its owner scope and, when recorded, its StatefulSet
-- and that StatefulSet's incarnation.
sourceRef :: ScopeId -> Map Text Text -> Text -> ResourceRef
sourceRef owner fields key =
  ResourceRef
    owner
    (Map.lookup key fields >>= either (const Nothing) Just . mkResourceId)
    Nothing
    (Map.lookup (key <> ".uid") fields >>= either (const Nothing) Just . mkPhysicalIdentity)

-- | Whether the scope's desired pins differ from those converged before.
newlyPinned :: ScopeView -> [Text] -> Bool
newlyPinned view' keys = case view' ^. #previous of
  Nothing -> True
  Just previous -> any (\key -> Map.lookup key previous /= Map.lookup key (view' ^. #desired)) keys

parseScope :: Text -> Maybe ScopeId
parseScope text = case T.breakOn ":" text of
  (kind, rest)
    | Just name <- T.stripPrefix ":" rest
    , Just scopeKind <- lookup kind [("platform", Platform), ("application", Application), ("standalone", Standalone), ("publication", Publication)] ->
        either (const Nothing) Just (mkScopeId scopeKind name)
  _ -> Nothing

readInteger :: Text -> Maybe Integer
readInteger text = case reads (T.unpack text) of
  [(n, "")] | n >= 0 -> Just n
  _ -> Nothing
