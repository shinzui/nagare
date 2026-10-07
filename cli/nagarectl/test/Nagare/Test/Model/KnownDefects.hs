-- | EP-182: the known-defect ledger. A violation the recovery model finds on
-- the validated world, whose defect is known and owned by a plan but not yet
-- fixed, is listed here with the exact number of times it occurs. The ledger
-- is two-sided: a violation no entry matches fails the tier, and so does an
-- entry whose count changed, so a fix forces the entry's removal and a new
-- failure cannot hide inside an old entry. The model's invariants are never
-- relaxed for a listed defect.
module Nagare.Test.Model.KnownDefects
  ( KnownViolation (..)
  , knownViolations
  , judgeViolations
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Test.World.Adversary (Fault (..))

data KnownViolation = KnownViolation
  { gap :: !Text
  -- ^ The finding or RES-4 gap, for example @G3@ or @F76@.
  , owner :: !Text
  -- ^ The plan that fixes it.
  , scenario :: !Text
  -- ^ The scenario label, exactly.
  , fault :: !Fault
  -- ^ The single fault the fast tier placed.
  , violation :: !Text
  -- ^ The start of the violation line, after @violation: @.
  , count :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | Known defects the fast tier finds on the validated world. Only the fast
-- tier reads this ledger; the deep tier reports every violation.
knownViolations :: [KnownViolation]
knownViolations =
  -- F77: a mounted database claim deleted outside review stays Terminating
  -- while its pod runs, and planning waits for it to go. A documented limit
  -- for MP-23 (docs/audits/mp23-findings.md#f77); the reviewed exit is the
  -- next MasterPlan's.
  [ KnownViolation
      "F77"
      deferral
      "create a database, then retire it"
      Deleted
      "I1: planning refused (PlanError {planErrorCode = \"invalid-retirement\""
      1
  , KnownViolation
      "F77"
      deferral
      "create a database, update its resources, then update it again"
      Deleted
      "I1: planning refused (PlanError {planErrorCode = \"observation-unavailable\""
      2
  ]
  where
    deferral = "deferral ledger (operator, 2026-10-07)"

-- | The violations that fail the tier: every one no entry matches, and one
-- line per entry whose count differs from what was found.
judgeViolations :: [KnownViolation] -> [Text] -> [Text]
judgeViolations ledger found =
  [v | v <- found, not (any (`matches` v) ledger)]
    <> [ "known-defect ledger: fixed or changed, update or remove this entry: "
           <> T.pack (show entry)
           <> " (found "
           <> T.pack (show seen)
           <> ")"
       | entry <- ledger
       , let seen = length (filter (matches entry) found)
       , seen /= entry ^. #count
       ]
  where
    matches entry v =
      fieldIs "scenario: " (== entry ^. #scenario) v
        && fieldIs "faults: " (\faults -> T.pack (show (entry ^. #fault)) `T.isInfixOf` faults && T.count "Boundary" faults == 1) v
        && fieldIs "violation: " ((entry ^. #violation) `T.isPrefixOf`) v
    fieldIs prefix predicate v = any predicate [rest | line <- T.lines v, Just rest <- [T.stripPrefix prefix (T.strip line)]]
