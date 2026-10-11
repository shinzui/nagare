-- | EP-172: the release transition in the recovery model: the identity its
-- stage reviews carry, and the commit that pins and closes it.
module Nagare.Test.Model.Transition
  ( commitTransition
  , transitionIdentity
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store
import Nagare.Test.Model.Fixtures (appScope)
import Nagare.Test.Model.Run (Run, asOperator, inspectHead, orFail, orTrouble)

-- | EP-172: the transition's review identity, and its commit. The head must
-- be idle with the marker still open, which is the marker's durability under
-- the faults and exits of the stage before; the marker is then cleared, as
-- `platform transition commit` does after writing the pin.
transitionIdentity :: Text
transitionIdentity = transitionReviewIdentity "0.4.0" "payload-t"

commitTransition :: Run -> IO (Either Text (Maybe Text))
commitTransition run = do
  -- The marker's durability is judged on a fault-free read before the write:
  -- a retried write may find its own earlier attempt landed.
  current <- inspectHead run >>= orFail "read head"
  case current of
    Nothing -> pure (Left "I10: the head is missing at the transition's commit")
    Just headValue
      | isJust (headActiveTransaction headValue) || isJust (headExecutorClaim headValue) ->
          pure (Left "I10: the transition's commit found an active transaction or executor claim")
      | isNothing (headTransition headValue) -> pure (Left "I10: the transition marker was lost before the commit")
      -- As `platform transition commit` refuses while the cluster does not
      -- report the target: the stage must have converged.
      | Map.lookup appScope (headAccepted headValue) /= Map.lookup appScope (headConverged headValue) ->
          pure (Right (Just "the transition stage has not converged; review it again before committing"))
      | otherwise -> asOperator run $ \store -> do
          observed <- observeHead store >>= orTrouble "observe head"
          case observedHeadManifest observed of
            Just latest
              | isJust (headTransition latest) ->
                  fmap (const Nothing) . first (T.pack . show) <$> replaceObservedHead observed latest {headGeneration = headGeneration latest + 1, headTransition = Nothing}
            _ -> pure (Right Nothing)
