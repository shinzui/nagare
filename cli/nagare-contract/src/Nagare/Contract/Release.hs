-- | Documents nagarectl writes for the release runner (EP-229). They are not
-- part of the public @--contract 1@ surface: nagare-harness decodes them with
-- these types instead of re-reading a review, and never links nagarectl.
module Nagare.Contract.Release
  ( TransitionPlanSummary (..)
  , transitionPlanSummaryVersion
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Nagare.Contract.Prelude

-- | @platform transition plan --summary FILE@: what the saved review would
-- do. @operations@ counts the review's operations by action;
-- @reaccepted@ names each scope other than the bootstrap stamp whose desired
-- revision differs from its base. A review with no operation that re-accepts
-- no scope is the converged state.
data TransitionPlanSummary = TransitionPlanSummary
  { schemaVersion :: !Int
  , review :: !Text
  , operations :: !(Map Text Int)
  , operationCount :: !Int
  , reaccepted :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

transitionPlanSummaryVersion :: Int
transitionPlanSummaryVersion = 1
