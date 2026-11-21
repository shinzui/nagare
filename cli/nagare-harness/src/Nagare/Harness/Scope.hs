-- | The Haskell suites the fast gate runs for a change (operator,
-- 2026-11-17: landing a small change must not cost a 12-minute gate). The
-- change is the difference between the commit and its nearest ancestor with a
-- green record of its own, which ran the suites this one leaves out on the
-- same code. The full gate after landing still runs every suite.
--
-- A path under @cli/<package>/@ reaches the suites whose package closure
-- holds that package. Any other path reaches nagarectl's, nagare-dsl's and
-- the API server's suites, which read the repository's payload, fixtures and
-- scripts, unless it is inert documentation ("Nagare.Harness.CarryForward").
-- The harness suite, which the fast gate never ran before, runs only for a
-- change to the harness or a package it builds on.
module Nagare.Harness.Scope
  ( Suite (..)
  , everySuite
  , payloadSuites
  , suitesReached
  )
where

import Data.Containers.ListUtils (nubOrd)
import Data.List (partition, sort)
import Data.Text qualified as T
import Nagare.Harness.Prelude

-- | A test suite the fast gate can run.
data Suite = NagarectlSuite | NagareDslSuite | ApiServerSuite | HarnessSuite
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

everySuite :: [Suite]
everySuite = [minBound .. maxBound]

-- | The suites the fast gate always ran, and still runs for a change it
-- cannot place.
payloadSuites :: [Suite]
payloadSuites = [NagarectlSuite, NagareDslSuite, ApiServerSuite]

-- | The suites whose package closure holds a package under @cli/@. The
-- platform payload copies @cli/nagare-access@ and @cli/nagare-dsl@, which
-- nagarectl's suite reads.
reaching :: Text -> Maybe [Suite]
reaching = \case
  "nagare-contract" -> Just [NagarectlSuite, ApiServerSuite, HarnessSuite]
  "nagare-dsl" -> Just [NagarectlSuite, NagareDslSuite, ApiServerSuite]
  "nagarectl" -> Just [NagarectlSuite, ApiServerSuite]
  "nagare-core" -> Just [NagarectlSuite, ApiServerSuite]
  "nagare-access" -> Just [NagarectlSuite, ApiServerSuite]
  "nagare-api" -> Just [ApiServerSuite]
  "nagare-api-server" -> Just [ApiServerSuite]
  "nagare-harness" -> Just [HarnessSuite]
  _ -> Nothing

-- | The suites a change reaches, in order. @inert@ says whether paths
-- outside @cli/@ are all inert documentation.
suitesReached :: ([Text] -> Bool) -> [Text] -> [Suite]
suitesReached inert changed = sort (nubOrd (outsideSuites <> concat owned))
  where
    (inside, outside) = partition ("cli/" `T.isPrefixOf`) changed
    owners = map (reaching . T.takeWhile (/= '/') . T.drop (T.length "cli/")) inside
    owned = [suites | Just suites <- owners]
    placed = length owned == length owners
    outsideSuites
      | not placed = payloadSuites
      | null outside || inert outside = []
      | otherwise = payloadSuites
