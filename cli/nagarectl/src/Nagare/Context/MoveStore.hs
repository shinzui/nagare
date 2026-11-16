-- | The open context move in the inventory head (EP-243): opening it, saving each step's intent
-- and completion, closing it, and the admission rule that keeps every other change out while it is
-- open. Each write is a conditional replacement of the observed head under the store lock, as the
-- release transition's commit is ('Nagare.Platform.Finalize').
module Nagare.Context.MoveStore
  ( openMove
  , saveMoveProgress
  , closeMove
  , openMoveOf
  , moveAdmissionRefusal
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Context.Move
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Manifest (MoveMarker (..), parseMoveReviewIdentity)

-- | Open a move on an idle head, or return the one already open when it is the same kind, so a
-- second @move apply@ resumes it.
openMove :: InventoryStore -> Text -> Text -> Text -> Text -> Bool -> [MoveStep] -> IO (Either Text MoveMarker)
openMove store kind startedAt retained target originTls list = underLock store $ \current -> case headMove current of
  Just marker
    | moveKind marker == kind -> Right (Left marker)
    | otherwise -> Left ("a " <> moveKind marker <> " move is already open; finish or roll it back first")
  Nothing -> case busy current of
    Just reason -> Left reason
    Nothing ->
      let marker = MoveMarker {moveKind = kind, moveStartedAt = startedAt, moveRetainedDnsName = retained, moveTargetBase = target, moveOriginTls = originTls, moveProgress = newMove list}
       in Right (Right (marker, bumped current {headMove = Just marker}))

-- | Record a step's intent or completion. Steps run their reviews between two of these writes, so
-- the head is idle whenever one happens; anything else in flight refuses.
saveMoveProgress :: InventoryStore -> MoveRecord -> IO (Either Text ())
saveMoveProgress store record = underLock store $ \current -> case headMove current of
  Nothing -> Left "no context move is open"
  Just marker
    | moveProgress marker == record -> Right (Left ())
    | Just reason <- busy current -> Left reason
    | moveProgress marker ^. #steps /= record ^. #steps -> Left "the open move has a different step list"
    | otherwise -> Right (Right ((), bumped current {headMove = Just marker {moveProgress = record}}))

-- | Close a move that finished every step or rolled every completed step back.
closeMove :: InventoryStore -> IO (Either Text MoveMarker)
closeMove store = underLock store $ \current -> case headMove current of
  Nothing -> Left "no context move is open"
  Just marker
    | Just reason <- busy current -> Left reason
    | not (settled (moveProgress marker)) ->
        Left ("the move has steps left: " <> T.intercalate ", " (map moveStepToken (remainingSteps (moveProgress marker))))
    | otherwise -> Right (Right (marker, bumped current {headMove = Nothing}))
  where
    settled record =
      isNothing (record ^. #inProgress)
        && ( (record ^. #direction == MovingForward && record ^. #completed == length (record ^. #steps))
               || (record ^. #direction == RollingBack && record ^. #completed == 0)
           )

openMoveOf :: InventoryStore -> IO (Either Text (Maybe MoveMarker))
openMoveOf store = do
  observed <- readHead store
  pure (either (Left . T.pack . show) (Right . (>>= headMove)) observed)

-- | While a move is open, a review is admitted only when it is that move's step in progress.
moveAdmissionRefusal :: Maybe MoveMarker -> Text -> Maybe Text
moveAdmissionRefusal Nothing identity = case parseMoveReviewIdentity identity of
  Just _ -> Just "this review belongs to a context move that is not open"
  Nothing -> Nothing
moveAdmissionRefusal (Just marker) identity = case parseMoveReviewIdentity identity of
  Just (kind, step, _)
    | kind == moveKind marker && Just step == moveProgress marker ^. #inProgress -> Nothing
    | otherwise -> Just ("this review is for step " <> moveStepToken step <> ", but the open move " <> current)
  Nothing -> Just ("a " <> moveKind marker <> " context move is open (" <> current <> "); continue it with context move apply or roll it back")
  where
    current = maybe "has no step in progress" (("is at " <>) . moveStepToken) (moveProgress marker ^. #inProgress)

busy :: HeadManifest -> Maybe Text
busy current
  | Just transaction <- headActiveTransaction current = Just ("transaction " <> transaction <> " is active; resume or close it first")
  | isJust (headExecutorClaim current) = Just "an executor holds the store; wait for it or recover it first"
  | isJust (headTransition current) = Just "a release transition is open; commit or close it first"
  | isJust (headDataFence current) = Just "a data fence is held; release it first"
  | isJust (headMigration current) = Just "the inventory store has migrated; reload the context shell"
  | otherwise = Nothing

bumped :: HeadManifest -> HeadManifest
bumped current = current {headGeneration = headGeneration current + 1}

-- | Judge the observed head under the lock: refuse, keep it ('Left' value), or replace it
-- conditionally ('Right' (value, head)).
underLock :: InventoryStore -> (HeadManifest -> Either Text (Either a (a, HeadManifest))) -> IO (Either Text a)
underLock store judge = do
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
