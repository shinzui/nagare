-- | One review step of a context move (EP-243), over the operations that plan, save and apply a stage
-- review. A run applies the review the last run saved, then plans the next one and stops for the
-- operator to read it; the step completes when a plan changes nothing. A review that does not apply is
-- discarded, so the next run plans afresh from what is now true.
module Nagare.Context.MoveReview
  ( ReviewPlan (..)
  , ReviewOps (..)
  , reviewStep
  , notApplied
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Nagare.Context.Move (StepOutcome (..))
import Nagare.Context.MoveChecks (reviewSettled)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (OperationAction)
import Nagare.Inventory.Store.Manifest (ScopeRevision)
import Nagare.Resource.Types (ScopeId)

-- | What a saved plan holds, and the accepted revisions it was planned against.
data ReviewPlan = ReviewPlan
  { actions :: ![OperationAction]
  , desired :: !(Map ScopeId ScopeRevision)
  , accepted :: !(Map ScopeId ScopeRevision)
  , location :: !Text
  }
  deriving stock (Eq, Show, Generic)

data ReviewOps m = ReviewOps
  { savedReview :: !(m Bool)
  -- ^ A review the last run saved is waiting.
  , planReview :: !(m ReviewPlan)
  -- ^ Plan the step's next stage and save it.
  , applyReview :: !(m Bool)
  -- ^ Apply the saved review and discard it; 'False' when it did not apply.
  , discardReview :: !(m ())
  }

reviewStep :: (Monad m) => ReviewOps m -> m StepOutcome
reviewStep ops = do
  saved <- savedReview ops
  if saved
    then applyReview ops >>= \applied -> if applied then fresh else pure (StepRefused notApplied)
    else fresh
  where
    fresh = do
      plan <- planReview ops
      if reviewSettled (plan ^. #actions) (plan ^. #desired) (plan ^. #accepted)
        then discardReview ops >> pure StepCompleted
        else
          pure
            ( StepWaiting
                ("read the review saved in " <> plan ^. #location <> " above; run the same command again to apply it")
            )

notApplied :: Text
notApplied =
  "the saved review did not apply (see above). If `nagarectl inventory status` shows an active transaction, settle it with `nagarectl inventory resume`; then run the same command again to plan afresh"
