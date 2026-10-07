-- | EP-177/EP-179: the recovery model's tiers, over any scenario type. The fast
-- tier checks a list of schedules per scenario; the deep tier runs one shard of
-- the fault pairs that can interact ('deepScenario'). Both report progress on
-- stderr, prefixed @recovery-model:@, write each violation there the moment it
-- is found and each scenario's summary when it ends, so an interrupted run
-- leaves behind everything it found, and fail with every violation found.
module Nagare.Test.Model.Tier
  ( checkTier
  , checkTierWith
  , deepTier
  , parseShard
  , placements
  )
where

import Control.Exception (try)
import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Nagare.Dsl.Prelude
import Nagare.Test.Model.Pairs
import Nagare.Test.World.Adversary
import System.IO (hFlush, hPutStrLn, stderr)
import Test.Tasty.HUnit (Assertion, HUnitFailure (..), assertFailure)

-- | Every fault at every boundary of the call it is scheduled on.
placements :: Map.Map Call Int -> [(Boundary, Fault)]
placements calls =
  [ (Boundary (faultCall fault) n, fault)
  | fault <- [minBound .. maxBound]
  , n <- [1 .. Map.findWithDefault 0 (faultCall fault) calls]
  ]

-- | Check every schedule of every scenario, given its fault-free run,
-- collecting what each check finds. With progress, each scenario reports its
-- schedule count, a heartbeat every 500 schedules, and its time and findings.
checkTier :: Bool -> (s -> Text) -> (s -> IO (Either Text a)) -> [s] -> (s -> a -> [schedule]) -> (s -> schedule -> IO [Text]) -> Assertion
checkTier = checkTierWith id

-- | 'checkTier', with the violations found passed through a filter before
-- the tier fails on what remains (EP-182: the two-sided known-defect ledger).
checkTierWith :: ([Text] -> [Text]) -> Bool -> (s -> Text) -> (s -> IO (Either Text a)) -> [s] -> (s -> a -> [schedule]) -> (s -> schedule -> IO [Text]) -> Assertion
checkTierWith judge progress label clean selected schedulesFor check = do
  violations <- fmap concat . forM (zip [1 :: Int ..] selected) $ \(position, scenario) -> do
    let report line = when progress (announce (length selected) position (label scenario) line)
        note violation = when progress (announceViolation (length selected) position (label scenario) violation)
    started <- getMonotonicTime
    found <-
      clean scenario >>= \case
        Left violation -> let found = "the fault-free scenario violates the model:\n" <> violation in [found] <$ note found
        Right finished -> do
          let schedules = schedulesFor scenario finished
              count = T.pack (show (length schedules))
          report (count <> " schedules")
          fmap concat . forM (zip [1 :: Int ..] schedules) $ \(done, schedule) -> do
            when (done `mod` 500 == 0) (report (T.pack (show done) <> "/" <> count))
            check scenario schedule >>= \found -> found <$ mapM_ note found
    ended <- getMonotonicTime
    report ("done in " <> T.pack (show (round (ended - started) :: Int)) <> "s, " <> T.pack (show (length found)) <> " violation(s)")
    pure found
  failOn (judge violations)

-- | Shard @shard@ of the deep tier (M4) over every scenario: each placement it
-- heads alone, then each pair it heads that can interact, with every 50th
-- independent pair checked against its second fault alone. With @prune@ off,
-- every pair runs.
deepTier :: Bool -> (Int, Int) -> (s -> Text) -> (s -> Runner checkpoint) -> [s] -> Assertion
deepTier prune shard label run' selected = do
  tallies <- forM (zip [0 :: Int ..] selected) $ \(offset, scenario) -> do
    let report = announce (length selected) (offset + 1) (label scenario)
        note = announceViolation (length selected) (offset + 1) (label scenario)
    started <- getMonotonicTime
    tally <-
      run scenario Nothing [] >>= \case
        (Left violation, _) -> let found = "the fault-free scenario violates the model:\n" <> violation in Tally [found] Map.empty 0 0 0 <$ note found
        (Right clean, saved) -> deepScenario shard offset prune 50 report note (run scenario) (clean, saved) (placements (clean ^. #totals))
    ended <- getMonotonicTime
    report $
      "done in "
        <> T.pack (show (round (ended - started) :: Int))
        <> "s, "
        <> T.pack (show (tally ^. #singles))
        <> " singles, pairs "
        <> T.pack (show (Map.toList (tally ^. #pairings)))
        <> ", "
        <> T.pack (show (tally ^. #checked))
        <> " independent and "
        <> T.pack (show (tally ^. #restarted))
        <> " resumed pairs checked, "
        <> T.pack (show (length (tally ^. #violations)))
        <> " violation(s)"
    pure tally
  failOn (concatMap (^. #violations) tallies)
  where
    -- A model assertion inside one run is that run's violation; it does not
    -- end the shard.
    run scenario resumed schedule = either (\(HUnitFailure _ reason) -> (Left ("the model failed under " <> T.pack (show schedule) <> ": " <> T.pack reason), Map.empty)) id <$> try (run' scenario resumed schedule)

-- | The deep tier's shard @i/n@ (0-based). Every shard runs every scenario and
-- heads every n-th placement of each, so the heaviest scenario spreads across
-- shards too (EP-179).
parseShard :: Maybe String -> Either String (Int, Int)
parseShard = \case
  Nothing -> Right (0, 1)
  Just spec -> case break (== '/') spec of
    (shard, '/' : count)
      | [(i, "")] <- reads shard
      , [(n, "")] <- reads count
      , n > 0
      , i >= 0
      , i < n ->
          Right (i, n)
    _ -> Left ("NAGARE_RECOVERY_MODEL_SHARD must be i/n with 0 <= i < n, not " <> spec)

announce :: Int -> Int -> Text -> Text -> IO ()
announce total position name line =
  hPutStrLn stderr ("recovery-model: [" <> show position <> "/" <> show total <> "] " <> T.unpack name <> ": " <> T.unpack line) >> hFlush stderr

-- | Each line of a violation, greppable as @recovery-model: violation:@.
announceViolation :: Int -> Int -> Text -> Text -> IO ()
announceViolation total position name violation =
  mapM_ (\line -> hPutStrLn stderr ("recovery-model: violation: [" <> show position <> "/" <> show total <> "] " <> T.unpack name <> " | " <> T.unpack line)) (T.lines violation) >> hFlush stderr

failOn :: [Text] -> Assertion
failOn = \case
  [] -> pure ()
  violations -> assertFailure (T.unpack (T.intercalate "\n\n" (take 400 violations)) <> "\n\n" <> show (length violations) <> " violation(s)")
