-- | EP-173/EP-179: the recovery model's search for a supported exit from a
-- stopped transaction. The search is independent of how a probe reaches the
-- state it starts from: the model restores a snapshot of the stop, and its
-- reference strategy replays the scenario up to the stop.
module Nagare.Test.Model.Search
  ( ExitSearch (..)
  , Probe (..)
  , searchExit
  )
where

import Data.Text qualified as T
import Nagare.Dsl.Prelude

data ExitSearch move node
  = -- | An exit path and the state it reached.
    ExitFound ![move] !node
  | NoExit ![Text]
  | ExitViolated !Text
  deriving stock (Functor)

-- | What a probe found after its path's last move.
data Probe move
  = -- | The head is idle: the path is an exit.
    ProbeIdle
  | -- | The head changed and the transaction is still active; the candidate
    -- moves from here.
    ProbeProgressed ![move]
  | ProbeRefused !Text
  | ProbeViolated !Text

-- | Depth-first search, at most four moves deep, over the supported exit moves.
-- @probe origin path move@ applies @move@, the last of @path@, to @origin@, the
-- state the rest of the path reached, and returns what it found and the state it reached.
-- So exploring one path never disturbs another. A move the driver refuses ends
-- its path; a move that changes the transaction's state without ending it is
-- extended.
searchExit :: (Show move) => (node -> [move] -> move -> IO (Probe move, node)) -> node -> [move] -> IO (ExitSearch move node)
searchExit probe root initial = do
  result <- explore (1 :: Int) root [] initial []
  pure $ case result of
    Left violation -> ExitViolated violation
    Right (Right (path, reached)) -> ExitFound path reached
    Right (Left tried) -> NoExit (reverse tried)
  where
    explore depth origin path candidates tried = case candidates of
      [] -> pure (Right (Left tried))
      move : more -> do
        let attempt = path <> [move]
            note text = T.pack (show attempt) <> ": " <> text
        (found, reached) <- probe origin attempt move
        case found of
          ProbeIdle -> pure (Right (Right (attempt, reached)))
          ProbeProgressed next
            | depth < 4 -> do
                deeper <- explore (depth + 1) reached attempt next (note "head changed, still active" : tried)
                case deeper of
                  Right (Left tried') -> explore depth origin path more tried'
                  done -> pure done
            | otherwise -> explore depth origin path more (note "head changed at the depth limit" : tried)
          ProbeRefused reason -> explore depth origin path more (note ("refused: " <> reason) : tried)
          ProbeViolated violation -> pure (Left violation)
