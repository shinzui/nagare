-- | EP-183 M2, ADR 28: which scheduled recovery points a context keeps.
-- Retention is a graded target plus a reviewed prune; nothing deletes in the
-- background. Only signed recovery-point times may enter this policy.
module Nagare.Inventory.BackupRetention
  ( RetentionPolicy (..)
  , standardRetention
  , retentionPolicyText
  , RetentionSplit (..)
  , splitByRetention
  , retentionDetail
  )
where

import Data.List (partition, sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day, NominalDiffTime, UTCTime (utctDay), diffUTCTime)
import Nagare.Dsl.Prelude
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective, recoveryPointThresholds)

-- | Every point younger than 'keepAllFor' is kept, then the newest point of
-- each UTC day younger than 'keepDailyFor', and always the newest point.
data RetentionPolicy = RetentionPolicy
  { keepAllFor :: !NominalDiffTime
  , keepDailyFor :: !NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)

-- | The operator's targets (ADR 28): every point for 48 hours, the newest of
-- each day for 30 days. The release fixes the policy, as decision D6 fixed
-- the objective presets; no context or environment value selects another.
standardRetention :: RetentionPolicy
standardRetention = RetentionPolicy {keepAllFor = 48 * hour, keepDailyFor = 30 * 24 * hour}
  where
    hour = 3600

-- | The policy as a reviewed prune records it, so its recovery can refuse a
-- different policy.
retentionPolicyText :: RetentionPolicy -> Text
retentionPolicyText policy =
  "all-" <> seconds (keepAllFor policy) <> "s,daily-" <> seconds (keepDailyFor policy) <> "s,newest"
  where
    seconds value = T.pack (show (floor value :: Integer))

data RetentionSplit key = RetentionSplit
  { kept :: ![key]
  , pastPolicy :: ![key]
  -- ^ Oldest first.
  }
  deriving stock (Eq, Show, Generic)

-- | Split verified points by the policy. Points tied for the newest time of
-- their day, or for the newest overall, are all kept: a tie has no provable
-- newest member. A point inside the objective's breach window is always kept
-- even if a policy shorter than that window is ever passed. A point in the
-- future refuses, as freshness does, because the clocks disagree.
splitByRetention ::
  RetentionPolicy ->
  RecoveryPointObjective ->
  UTCTime ->
  [(key, UTCTime)] ->
  Either Text (RetentionSplit key)
splitByRetention _ _ _ [] = Right (RetentionSplit [] [])
splitByRetention policy objective now points
  | any ((> now) . snd) points = Left "a scheduled recovery point is in the future; verify clock agreement"
  | otherwise =
      let newest = maximum (map snd points)
          (_, breach) = recoveryPointThresholds objective
          window = max (keepAllFor policy) (fromInteger breach)
          age time = diffUTCTime now time
          dailyNewest :: Map.Map Day UTCTime
          dailyNewest =
            Map.fromListWith
              max
              [(utctDay time, time) | (_, time) <- points, age time < keepDailyFor policy]
          keeps time =
            time == newest
              || age time < window
              || Map.lookup (utctDay time) dailyNewest == Just time
          (keep, past) = partition (keeps . snd) points
       in Right
            RetentionSplit
              { kept = map fst (sortOn (Down . snd) keep)
              , pastPolicy = map fst (sortOn snd past)
              }

-- | The @server status@ detail for one source.
retentionDetail :: RetentionPolicy -> Int -> Text
retentionDetail policy past =
  T.pack (show past)
    <> " accepted scheduled recovery point(s) past policy ("
    <> retentionPolicyText policy
    <> ")"
    <> if past > 0 then "; review them with db prune-scheduled-backups" else ""
