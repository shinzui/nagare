-- | EP-224 M2: the cost record a release run's index and traces produce, its
-- verdict, and the history that keeps profiles apart.
module TransitionCostSpec (transitionCostTests) where

import Data.Aeson (Value, eitherDecodeFileStrict, object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Contract.Trace
import Nagare.Harness.Prelude hiding ((.=))
import Nagare.Harness.Release.Records (writeSortedAtomically)
import Nagare.Harness.TransitionCost
import System.Directory (createDirectoryIfMissing, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

transitionCostTests :: TestTree
transitionCostTests =
  testGroup
    "TransitionCost (EP-224 M2)"
    [ testCase "a fixture run collects every trace and passes its budgets" $
        withFixture $ \run record -> do
          (record ^. #missing, length (record ^. #stages), record ^. #profile) @?= ([], 2, "local-rehearsal")
          case record ^. #stages of
            first' : _ -> do
              (first' ^. #planned, first' ^. #executed) @?= (Map.fromList [("UpdateResource", 1), ("ValidateResource", 205)], Map.fromList [("UpdateResource", 1), ("ValidateResource", 205)])
              (first' ^. #planSeconds, first' ^. #applySeconds, first' ^. #kubernetesRequests) @?= (Just 12, 30, 8)
            [] -> assertFailure "no stage"
          record ^. #activationSeconds @?= 50
          fst (judge record) @?= VerdictPassed
          -- The written record reads back as the same record.
          collectTo run (run </> "cost.json") >>= either (assertFailure . T.unpack) (const (pure ()))
          eitherDecodeFileStrict (run </> "cost.json") >>= (@?= Right record)
    , testCase "a missing or unreadable trace makes the run incomplete, never passing" $
        withFixture $ \run _ -> do
          removeFile (run </> "run" </> "reviews" </> "transition-2.plan.trace.json")
          writeFile (run </> "run" </> "reviews" </> "transition-1.apply.trace.json") "{\"schemaVersion\":2}"
          record <- collectRun run >>= either (\reason -> assertFailure (T.unpack reason) >> fail "collect") pure
          record ^. #missing @?= ["reviews/transition-1.apply.trace.json", "reviews/transition-2.plan.trace.json"]
          fst (judge record) @?= VerdictIncomplete
    , testCase "a failed run, a failed command or a slow plan fails the record" $
        withFixture $ \_ record -> do
          fst (judge (record & #runStatus .~ "failed")) @?= VerdictFailed
          fst (judge (record & #stages . ix 0 . #outcomes .~ ["completed", "cancelled"])) @?= VerdictFailed
          let slow = record & #stages . ix 1 . #planSeconds ?~ 61
          fst (judge slow) @?= VerdictFailed
          [entry ^. #budget | entry <- snd (judge slow), not (entry ^. #holds)] @?= ["plan transition-2"]
          -- Artifact preparation is reported apart from planning, never from activation.
          let prepared = slow & #stages . ix 1 . #preparationSeconds ?~ 2
          fst (judge prepared) @?= VerdictPassed
          fst (judge (prepared & #stages . ix 1 . #preparationSeconds ?~ 1)) @?= VerdictFailed
          fst (judge (record & #activationSeconds .~ 301)) @?= VerdictFailed
          fst (judge (record & #runStatus .~ "running")) @?= VerdictIncomplete
          -- A failed run is failed even when traces are missing.
          fst (judge (record & #runStatus .~ "failed" & #missing .~ ["reviews/transition-1.plan.trace.json"])) @?= VerdictFailed
    , testCase "history lists records by profile and refuses an unknown schema" $
        withSystemTempDirectory "cost-history" $ \root -> do
          mapM_ (createDirectoryIfMissing True . (root </>)) ["rev-a", "rev-b", "rev-c"]
          withFixture $ \_ record -> do
            writeSortedAtomically (root </> "rev-b" </> "intranet-cost.json") (toJSON (record & #profile .~ "intranet"))
            writeSortedAtomically (root </> "rev-a" </> "transition-cost.json") (toJSON record)
          listed <- historyLines root >>= either (\reason -> assertFailure (T.unpack reason) >> fail "history") pure
          map (T.takeWhile (/= ' ')) listed @?= ["intranet", "local-rehearsal"]
          writeSortedAtomically (root </> "rev-c" </> "transition-cost.json") (object ["schemaVersion" .= (9 :: Int)] :: Value)
          historyLines root >>= assertBool "an unknown record schema was listed" . isLeft
    , testCase "the trace codec the collector reads refuses another schema version" $
        decodeTraceDocument "{\"schemaVersion\":2,\"command\":\"x\"}" @?= Left "Error in $: unsupported trace schema version 2"
    ]

withFixture :: (FilePath -> CostRecord -> IO a) -> IO a
withFixture body = withSystemTempDirectory "cost-fixture" $ \directory -> do
  let run = directory </> "run"
  writeFixture run (UTCTime (fromGregorian 2026 10 29) 0) >>= either (assertFailure . T.unpack) pure
  record <- collectRun run >>= either (\reason -> assertFailure (T.unpack reason) >> fail "collect") pure
  body run record
