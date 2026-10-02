-- | The one-hour recovery-point objective includes dump and upload time.
-- Only authenticated, freshly verified receipt times may enter this check.
module Nagare.Inventory.BackupFreshness
  ( BackupFreshness (..)
  , backupFreshness
  , renderBackupFreshness
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

backupFreshness :: UTCTime -> [UTCTime] -> BackupFreshness
backupFreshness _ [] = NoRecoveryPoint
backupFreshness now (point : points)
  | any (> now) (point : points) = FutureRecoveryPoint
  | age >= 3600 = Breached age
  | age >= 1800 = Deteriorating age
  | otherwise = Fresh age
  where
    age = floor (diffUTCTime now (foldr max point points))

renderBackupFreshness :: BackupFreshness -> Text
renderBackupFreshness value =
  "Recovery-point freshness: " <> case value of
    Fresh age -> "healthy; age=" <> seconds age
    Deteriorating age -> "warning; age=" <> seconds age <> "; one-hour objective at risk"
    Breached age -> "unhealthy; age=" <> seconds age <> "; one-hour objective breached"
    NoRecoveryPoint -> "unhealthy; no verified timestamped recovery point"
    FutureRecoveryPoint -> "unhealthy; recovery point is in the future; verify clock agreement"
  where
    seconds age = T.pack (show age) <> "s"
