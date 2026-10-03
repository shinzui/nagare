-- | The recovery-point objective includes dump and upload time.
-- Only authenticated, freshly verified receipt times may enter this check.
module Nagare.Inventory.BackupFreshness
  ( BackupFreshness (..)
  , RecoveryPointObjective (..)
  , RecoveryPointGrade (..)
  , backupFreshness
  , renderBackupFreshness
  , recoveryPointDetail
  , parseRecoveryPointObjective
  , recoveryPointObjectiveText
  , recoveryPointSchedule
  , recoveryPointThresholds
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime)
import Nagare.Dsl.Prelude

data BackupFreshness
  = Fresh !Integer
  | Deteriorating !Integer
  | Breached !Integer
  | NoRecoveryPoint
  | FutureRecoveryPoint
  deriving stock (Eq, Show)

-- | A context selects one of two proven presets. The selected preset is
-- written into the signed schedule metadata, so freshness is graded against
-- the accepted CronJob rather than an editable environment value.
data RecoveryPointObjective
  = HourlyRecoveryPoint
  | DailyRecoveryPoint
  deriving stock (Eq, Ord, Show, Bounded, Enum)

parseRecoveryPointObjective :: Text -> Either Text RecoveryPointObjective
parseRecoveryPointObjective = \case
  "hourly" -> Right HourlyRecoveryPoint
  "daily" -> Right DailyRecoveryPoint
  other -> Left ("unknown backup recovery-point objective " <> other <> "; expected hourly or daily")

recoveryPointObjectiveText :: RecoveryPointObjective -> Text
recoveryPointObjectiveText = \case
  HourlyRecoveryPoint -> "hourly"
  DailyRecoveryPoint -> "daily"

-- | Producer cadence for each preset. Hourly runs every 15 minutes to leave
-- retry margin; daily runs once, and its breach threshold leaves two hours for
-- dump, upload and verification.
recoveryPointSchedule :: RecoveryPointObjective -> Text
recoveryPointSchedule = \case
  HourlyRecoveryPoint -> "*/15 * * * *"
  DailyRecoveryPoint -> "17 3 * * *"

-- | Warning and breach ages in seconds.
recoveryPointThresholds :: RecoveryPointObjective -> (Integer, Integer)
recoveryPointThresholds = \case
  HourlyRecoveryPoint -> (1800, 3600)
  DailyRecoveryPoint -> (25 * 3600, 26 * 3600)

backupFreshness :: RecoveryPointObjective -> UTCTime -> [UTCTime] -> BackupFreshness
backupFreshness _ _ [] = NoRecoveryPoint
backupFreshness selected now (point : points)
  | any (> now) (point : points) = FutureRecoveryPoint
  | age >= breach = Breached age
  | age >= warning = Deteriorating age
  | otherwise = Fresh age
  where
    (warning, breach) = recoveryPointThresholds selected
    age = floor (diffUTCTime now (foldr max point points))

-- | One source's graded recovery point. 'latestPending' is set when the newest
-- point comes from a verified upload that still awaits reviewed ingestion; it
-- counts toward freshness but does not authorize restore.
data RecoveryPointGrade = RecoveryPointGrade
  { objective :: !RecoveryPointObjective
  , freshness :: !BackupFreshness
  , latestPending :: !Bool
  }
  deriving stock (Eq, Show, Generic)

renderBackupFreshness :: RecoveryPointGrade -> Text
renderBackupFreshness grade = "Recovery-point freshness: " <> recoveryPointDetail grade

recoveryPointDetail :: RecoveryPointGrade -> Text
recoveryPointDetail (RecoveryPointGrade selected value pending) =
  case value of
    Fresh age -> "healthy; age=" <> seconds age <> "; objective=" <> name <> pendingNote
    Deteriorating age -> "warning; age=" <> seconds age <> "; " <> name <> " objective at risk" <> pendingNote
    Breached age -> "unhealthy; age=" <> seconds age <> "; " <> name <> " objective breached" <> pendingNote
    NoRecoveryPoint -> "unhealthy; no verified timestamped recovery point; objective=" <> name
    FutureRecoveryPoint -> "unhealthy; recovery point is in the future; verify clock agreement"
  where
    name = recoveryPointObjectiveText selected
    pendingNote = if pending then "; newest point is verified and awaits reviewed ingestion" else ""
    seconds age = T.pack (show age) <> "s"
