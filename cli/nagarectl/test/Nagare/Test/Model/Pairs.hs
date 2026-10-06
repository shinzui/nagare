-- | EP-179: which ordered fault pairs the recovery model's deep tier runs.
--
-- A pair's faults are placed at boundaries of a fault-free run. The tier runs
-- every placement alone, keeping its 'Trace', and runs a pair only when its
-- second fault can see the first one's effect (M4's interaction rule). A
-- dropped pair is either never reached (its second boundary does not occur
-- once the first fault has fired, so it runs as the first fault alone) or is
-- independent, and a fixed sample of the independent pairs is checked
-- against the second fault alone.
module Nagare.Test.Model.Pairs
  ( Trace (..)
  , Pairing (..)
  , stepOf
  , pairing
  , correspondingSingle
  , sameOutcome
  , Tally (..)
  , Runner
  , deepScenario
  )
where

import Control.Monad (foldM)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Nagare.Dsl.Prelude
import Nagare.Test.World.Adversary

-- | Where a run's steps began, which steps stopped and the exit each took,
-- and the run's final call counts.
data Trace = Trace
  { starts :: ![Map.Map Call Int]
  -- ^ The call counts as each step began, in step order.
  , heads :: ![Text]
  -- ^ The head's accepted and converged revisions and active transaction as
  -- each step began, then at the end.
  , stops :: !(Map.Map Int Text)
  -- ^ The exit path each stopped step took, by step index.
  , totals :: !(Map.Map Call Int)
  }
  deriving stock (Eq, Generic, Show)

-- | The step a boundary falls in, or 'Nothing' when the run never reaches it.
stepOf :: Trace -> Boundary -> Maybe Int
stepOf trace (Boundary call' n)
  | n > Map.findWithDefault 0 call' (trace ^. #totals) = Nothing
  | otherwise = case [k | (k, start) <- zip [0 ..] (trace ^. #starts), Map.findWithDefault 0 call' start < n] of
      [] -> Nothing
      began -> Just (last began)

-- | Why a pair runs or is dropped.
data Pairing
  = -- | Both boundaries fall in one step of the fault-free run.
    SameStep
  | -- | The first fault leaves the world changed for the rest of the run.
    PersistentFirst
  | -- | The first fault's run violates the model on its own, so it has no
    -- trace to judge the pair by.
    FirstViolates
  | -- | The second boundary falls in the first fault's step, in a step the
    -- first fault made stop differently, or in the step after that.
    Interacting
  | -- | Once the first fault fires, the run never reaches the second
    -- boundary: the pair runs exactly as the first fault alone.
    Unreached
  | -- | The first fault's effect was resolved before the second boundary's
    -- step began: from the first fault's step on, every step stopped and
    -- ended as in the fault-free run.
    Independent
  deriving stock (Eq, Ord, Show)

-- | M4's rule for a pair whose first fault, at step @s1@ of the fault-free
-- run, is transient: the second boundary is judged in the run of the first
-- fault alone.
pairing :: Trace -> Trace -> Int -> Boundary -> Pairing
pairing clean alone s1 second = case stepOf alone second of
  Nothing -> Unreached
  Just s2
    | s2 <= max s1 (lastAffected + 1) -> Interacting
    | otherwise -> Independent
  where
    -- A step the first fault made stop differently, or end in another state.
    affected = [k | k <- [s1 .. length (alone ^. #starts) - 1], Map.lookup k (clean ^. #stops) /= Map.lookup k (alone ^. #stops) || ended clean k /= ended alone k]
    ended trace k = take 1 (drop (k + 1) (trace ^. #heads))
    lastAffected = maximum (s1 - 1 : affected)

-- | The boundary in the fault-free run at the same place in step @s2@ as
-- @second@ is in the first fault's run: the single fault an independent
-- pair is checked against.
correspondingSingle :: Trace -> Trace -> Boundary -> Maybe Boundary
correspondingSingle clean alone second@(Boundary call' n) = do
  s2 <- stepOf alone second
  let offset trace = Map.findWithDefault 0 call' ((trace ^. #starts) !! s2)
  pure (Boundary call' (n - offset alone + offset clean))

-- | Two runs agree from step @s2@ on: both pass with the same exits from that
-- step, or both report the same violation.
sameOutcome :: Int -> Either Text Trace -> Either Text Trace -> Bool
sameOutcome s2 left right = case (left, right) of
  (Right one, Right other) -> later one == later other
  (Left one, Left other) -> violation one == violation other
  _ -> False
  where
    later trace = Map.filterWithKey (\k _ -> k >= s2) (trace ^. #stops)
    violation = filter ("violation:" `T.isPrefixOf`) . T.lines

-- | What one shard found in one scenario.
data Tally = Tally
  { violations :: ![Text]
  , pairings :: !(Map.Map Pairing Int)
  -- ^ Pairs considered, by why they ran or were dropped.
  , singles :: !Int
  , checked :: !Int
  -- ^ Independent pairs checked against their second fault alone.
  , restarted :: !Int
  -- ^ Resumed pairs checked against the same pair run from the start.
  }
  deriving stock (Generic, Show)

-- | Runs a schedule, from a checkpoint or from the start, and returns what it
-- found and a checkpoint for each step it began.
type Runner checkpoint = Maybe checkpoint -> [(Boundary, Fault)] -> IO (Either Text Trace, Map.Map Int checkpoint)

-- | Shard @i@ of @n@ of the deep tier over one scenario: every placement whose
-- index, offset by the scenario's, is @i@ modulo @n@, alone and as the first
-- fault of each pair it heads. A pair is headed by its fault in the earlier
-- step, or by the earlier boundary when both share a step, so each pair of
-- distinct boundaries is considered once. With @prune@ off every pair runs.
--
-- A run starts from the latest checkpoint whose prefix it shares: a single
-- fault or a same-step pair from the fault-free run's checkpoint at its step,
-- any other pair from its first fault's checkpoint at the second boundary's
-- step. Every @every@-th independent pair is checked against its second fault
-- alone, and every @every@-th pair run from a checkpoint against the same pair
-- from the start; a disagreement is a violation.
deepScenario :: (Int, Int) -> Int -> Bool -> Int -> (Text -> IO ()) -> (Text -> IO ()) -> Runner checkpoint -> (Trace, Map.Map Int checkpoint) -> [(Boundary, Fault)] -> IO Tally
deepScenario (shard, shards) offset prune every report note run (clean, cleanSaved) placements = do
  started <- getMonotonicTime
  let headed = [first' | (k, first') <- zip [0 :: Int ..] placements, (k + offset) `mod` shards == shard]
      progress position tally = do
        now <- getMonotonicTime
        when (position `mod` 25 == 0) . report $
          T.pack (show position) <> "/" <> T.pack (show (length headed)) <> " heads, " <> T.pack (show (sum (tally ^. #pairings))) <> " pairs, " <> T.pack (show (round (now - started) :: Int)) <> "s"
  foldM (\tally (position, first') -> heads first' tally <* progress position tally) (Tally [] Map.empty 0 0 0) (zip [1 :: Int ..] headed)
  where
    stepIn trace (boundary, _) = stepOf trace boundary
    at step' = step' >>= (`Map.lookup` cleanSaved)
    -- A violation is noted the moment it is found, so an interrupted shard
    -- leaves behind everything it found.
    violated tally violation = (tally & #violations %~ (<> [violation])) <$ note violation
    found tally = either (violated tally) (const (pure tally))
    heads first'@(b1, f1) tally = do
      let s1 = stepIn clean first'
      (alone, saved) <- run (at s1) [first']
      let judged =
            [ (second', why)
            | second'@(b2, _) <- placements
            , b2 /= b1
            , let s2 = stepIn clean second'
            , s2 > s1 || (s2 == s1 && b1 < b2)
            , let why
                    | s2 == s1 = SameStep
                    | faultPersistence f1 == Persistent = PersistentFirst
                    | otherwise = either (const FirstViolates) (\trace -> maybe FirstViolates (\s -> pairing clean trace s b2) s1) alone
            ]
          -- The checkpoint a pair starts from.
          resume (b2, _) why = case alone of
            Right trace | why /= SameStep, Just cp <- stepOf trace b2 >>= (`Map.lookup` saved) -> Just cp
            _ -> at s1
      counted <- found (tally & #singles %~ (+ 1)) alone
      foldM (pair first' alone resume) counted judged
    pair first' alone resume tally (second', why) = do
      let counted = tally & #pairings %~ Map.insertWith (+) why 1
          ran = sum (Map.filterWithKey (\why' _ -> why' `notElem` [Unreached, Independent]) (counted ^. #pairings))
          independent = Map.findWithDefault 0 Independent (counted ^. #pairings)
      case alone of
        _ | not prune || why `notElem` [Unreached, Independent] -> do
          (outcome, _) <- run (resume second' why) [first', second']
          checked' <- found counted outcome
          if ran `mod` every /= 0
            then pure checked'
            else do
              (fromStart, _) <- run Nothing [first', second']
              let disagreement = "the pair " <> T.pack (show [first', second']) <> " resumed from a checkpoint ends unlike from the start:\n" <> T.pack (show outcome) <> "\n" <> T.pack (show fromStart)
              (if outcome == fromStart then pure else (`violated` disagreement)) (checked' & #restarted %~ (+ 1))
        Right trace | why == Independent && independent `mod` every == 0 -> check first' trace resume counted second'
        _ -> pure counted
    -- M4's sampled check: an independent pair must end as its second fault
    -- does alone, from the second fault's step on.
    check first' trace resume tally second'@(b2, f2) = case (stepOf trace b2, correspondingSingle clean trace b2) of
      (Just s2, Just single) -> do
        (both, _) <- run (resume second' Independent) [first', second']
        (alone, _) <- run (at (Just s2)) [(single, f2)]
        let disagreement = "M4: the independent pair " <> T.pack (show [first', second']) <> " ends unlike " <> T.pack (show (single, f2)) <> " alone:\n" <> T.pack (show both) <> "\n" <> T.pack (show alone)
        (if sameOutcome s2 both alone then pure else (`violated` disagreement)) (tally & #checked %~ (+ 1))
      _ -> pure tally
