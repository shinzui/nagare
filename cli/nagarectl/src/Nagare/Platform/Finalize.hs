-- | EP-228 M1: closing a release transition. The context pin is a local file
-- and the transition marker lives in the remote head, so no lock makes their
-- writes one; closing is a recoverable protocol instead (ADR 6: the pin moves
-- last).
--
-- 1. Intent. Under the store lock, the head is judged again (this payload's
--    marker, no unresolved transaction, every moved scope converged) and the
--    marker records the release the pin moves to, by a conditional head
--    replacement. From then on admission refuses every review, and an older
--    CLI refuses the head, so nothing can change under the pin write.
-- 2. Pin. The context pin is written to the target, unless it already names
--    it. A pin naming neither the source nor the target is foreign: refuse.
-- 3. Close. Under the lock, a head still carrying exactly that marker, still
--    idle, has its marker cleared by a conditional replacement.
--
-- A stop anywhere is finished by running the commit again: the intent is
-- kept and a pin already written is not written twice.
module Nagare.Platform.Finalize
  ( PinOps (..)
  , FinalizeStep (..)
  , finalizeTransition
  )
where

import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store
  ( HeadManifest (headActiveTransaction, headExecutorClaim, headGeneration, headTransition)
  , InventoryStore
  , TransitionMarker (..)
  , observeHead
  , observedHeadManifest
  , replaceObservedHead
  , withProcessLock
  )
import Nagare.Platform.Transition (transitionCommitRefusal, transitionOwnerRefusal)
import Nagare.Resource.Types (ScopeId)

-- | How the context pin is read and written; tests inject both.
data PinOps = PinOps
  { readPin :: !(IO (Either Text (Maybe Text)))
  , writePin :: !(Text -> IO (Either Text ()))
  }

-- | Where a commit stopped or finished; a test stops between steps with it.
data FinalizeStep = AfterIntent | AfterPin
  deriving stock (Eq, Show)

-- | Finish the transition this payload owns, moving the pin to @target@.
-- @moved@ selects the scopes the transition moves. @pause@ runs after each
-- step (a no-op in production; a test throws there to model a crash).
finalizeTransition :: InventoryStore -> PinOps -> (FinalizeStep -> IO ()) -> Text -> (ScopeId -> Bool) -> Text -> IO (Either Text TransitionMarker)
finalizeTransition store pins pause payload moved target = do
  intended <- underLock $ \current -> case headTransition current of
    Just marker
      | Just pin <- transitionFinalizing marker ->
          -- A stopped commit resumes; its intent stays.
          case transitionOwnerRefusal marker payload of
            Just reason -> Left reason
            Nothing
              | pin == target -> Right (Left marker)
              | otherwise -> Left ("the transition is finalizing the pin to " <> pin <> ", not " <> target)
    _ -> case transitionCommitRefusal payload moved current of
      Just reason -> Left reason
      Nothing -> case headTransition current of
        Nothing -> Left "no release transition is open; review one with platform transition plan"
        Just marker ->
          let finalizing = marker {transitionFinalizing = Just target}
           in Right (Right (finalizing, current {headGeneration = headGeneration current + 1, headTransition = Just finalizing}))
  case intended of
    Left reason -> pure (Left reason)
    Right marker -> do
      pause AfterIntent
      pinned <- readPin pins
      written <- case pinned of
        Left reason -> pure (Left reason)
        Right (Just pin)
          | pin == target -> pure (Right ())
          | pin == transitionSource marker -> writePin pins target
          | otherwise -> pure (Left ("the context pin names " <> pin <> ", neither the transition's source " <> transitionSource marker <> " nor its target " <> target <> "; refusing to move it"))
        Right Nothing -> pure (Left "the context has no platform pin; refusing to write one")
      case written of
        Left reason -> pure (Left reason)
        Right () -> do
          pause AfterPin
          closed <- underLock $ \current ->
            if headTransition current /= Just marker
              then Left "the transition marker changed while the pin moved; inspect the head before committing again"
              else
                if isJust (headActiveTransaction current) || isJust (headExecutorClaim current)
                  then Left "a transaction was admitted while the pin moved; resolve it before committing again"
                  else Right (Right ((), current {headGeneration = headGeneration current + 1, headTransition = Nothing}))
          pure (marker <$ closed)
  where
    -- Judge the observed head under the lock: refuse, keep it ('Left'
    -- value), or replace it conditionally ('Right' (value, head)).
    underLock :: (HeadManifest -> Either Text (Either a (a, HeadManifest))) -> IO (Either Text a)
    underLock judge = do
      result <- withProcessLock store $ \_ -> do
        observed <- observeHead store
        case observed of
          Left failure -> pure (Left (T.pack (show failure)))
          Right observed' -> case observedHeadManifest observed' of
            Nothing -> pure (Left "inventory store is not initialized")
            Just current -> case judge current of
              Left reason -> pure (Left reason)
              Right (Left kept) -> pure (Right kept)
              Right (Right (value, replacement)) -> (value <$) . first (T.pack . show) <$> replaceObservedHead observed' replacement
      pure (either (Left . T.pack . show) id result)
