-- | EP-172: the release transition in the recovery model: the identity its
-- stage reviews carry, its planning, and the commit that pins and closes it.
module Nagare.Test.Model.Transition
  ( commitTransition
  , planTransition
  , transitionIdentity
  )
where

import Data.Aeson (eitherDecodeStrict')
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store
import Nagare.Platform.Transition (checkTransition, renderTransitionRefusal, transitionCommitRefusal)
import Nagare.Platform.Workspace (PayloadManifest)
import Nagare.Test.Model.Fixtures (appScope)
import Nagare.Test.Model.Run (Run, asOperator, inspectHead, orFail, orTrouble)

-- | EP-172: the transition's review identity, and its commit. The head must
-- be idle with the marker still open, which is the marker's durability under
-- the faults and exits of the stage before; the marker is then cleared, as
-- `platform transition commit` does after writing the pin.
transitionIdentity :: Text
transitionIdentity = transitionReviewIdentity "0.4.0" (transitionPayload ^. #payloadId)

-- | The payload the model's transition plans from: release 0.5.0, which
-- accepts transitions from 0.4.0 only.
transitionPayload :: PayloadManifest
transitionPayload =
  either error id $
    eitherDecodeStrict'
      "{\"assetSchemaVersion\":1,\"payloadId\":\"payload-t\",\"platformVersion\":\"0.5.0\",\"sourceRevision\":null,\"transitionsFrom\":[\"0.4.0\"]}"

-- | Plan a transition from a context pinned to @source@, as `platform
-- transition plan` does before any write: the payload's check against the
-- head, held to the model's own reading of the table, in which only 0.4.0 is
-- a source. The check is pure, so a refusal comes before any write.
planTransition :: Run -> Text -> IO (Either Text ())
planTransition run source = do
  current <- inspectHead run >>= orFail "read head"
  case current of
    Nothing -> pure (Left "I10: the head is missing at the transition's planning")
    Just headValue -> do
      let listed = source == "0.4.0"
      pure $ case checkTransition transitionPayload (Just source) (headSchemaVersion headValue) of
        Right _
          | not listed -> Left ("I10: planning accepted a transition from " <> source <> ", which the payload does not list")
        Left refusal
          | listed -> Left ("I1: planning refused the listed transition from " <> source <> " (" <> renderTransitionRefusal refusal <> ")")
        _ -> Right ()

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
      -- `platform transition commit`'s own refusal, over every scope: a stage
      -- that stopped and was closed without converging is reviewed again first.
      | Just reason <- transitionCommitRefusal (transitionPayload ^. #payloadId) (const True) headValue -> pure (Right (Just reason))
      -- The pin is the transition's last write: it never lands before the
      -- stage's scope update converged.
      | Map.lookup appScope (headAccepted headValue) /= Map.lookup appScope (headConverged headValue) ->
          pure (Left "I10: the pin was committed before the transition stage converged")
      | otherwise -> asOperator run $ \store -> do
          observed <- observeHead store >>= orTrouble "observe head"
          case observedHeadManifest observed of
            Just latest
              | isJust (headTransition latest) ->
                  fmap (const Nothing) . first (T.pack . show) <$> replaceObservedHead observed latest {headGeneration = headGeneration latest + 1, headTransition = Nothing}
            _ -> pure (Right Nothing)
