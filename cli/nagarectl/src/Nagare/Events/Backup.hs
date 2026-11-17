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
  )
where

import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Nagare.Dsl.Prelude hiding ((.=))
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
