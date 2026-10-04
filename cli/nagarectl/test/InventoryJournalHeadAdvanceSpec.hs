module InventoryJournalHeadAdvanceSpec (inventoryJournalHeadAdvanceTests) where

import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryObjectOpsSpec (fakeObjectOps)
import InventoryTransactionSpec (fixtureBinding, preparedFixtureWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types (ContentDigest)
import Test.Tasty
import Test.Tasty.HUnit

-- | F38: a head write that fails after its journal event was published.
inventoryJournalHeadAdvanceTests :: TestTree
inventoryJournalHeadAdvanceTests =
  testGroup
    "journal head advance (F38)"
    [ testCase "a refused head write after a published completion is retried and converges" $ do
        (applied, effects, events) <- runWithHeadFailures Refused 1 Nothing
        assertConverged applied
        effects @?= 1
        assertOneCompletionPerOperation events
    , testCase "a head write whose acknowledgement was lost is read back and converges" $ do
        (applied, effects, events) <- runWithHeadFailures LandedButUnknown 1 Nothing
        assertConverged applied
        effects @?= 1
        assertOneCompletionPerOperation events
    , testCase "a persistent head failure stops, and resume adopts the orphan despite a different recovery proof" $ do
        let recoveryProof = contentDigest "independent recovery proof"
        (resumed, effects, events) <- runWithHeadFailures Refused 4 (Just recoveryProof)
        assertConverged resumed
        effects @?= 1
        assertOneCompletionPerOperation events
        let completions = [digest | event <- events, Completed digest <- [eventState event]]
        assertBool "the orphan's original receipt is kept, not the recovery proof" (recoveryProof `notElem` completions)
    ]

data HeadFailure = Refused | LandedButUnknown

-- | Execute the fixture review on a fake object store whose head writes fail
-- right after a completion event is published. With a recovery proof, the
-- first apply must stop and a resume with that proof must finish the job.
runWithHeadFailures :: HeadFailure -> Int -> Maybe ContentDigest -> IO (Either String TransactionResult, Int, [JournalEvent])
runWithHeadFailures mode failures recoveryProof = do
  base <- fakeObjectOps
  pending <- newIORef False
  remaining <- newIORef failures
  let ops =
        base
          { putObject = \condition name@(ObjectName key) bytes -> do
              armed <- readIORef pending
              left <- readIORef remaining
              if key == "head.json" && armed && left > 0
                then do
                  writeIORef remaining (left - 1)
                  case mode of
                    Refused -> pure (PutUnknown "injected head write failure")
                    LandedButUnknown -> putObject base condition name bytes >> writeIORef pending False >> pure (PutUnknown "injected lost acknowledgement")
                else do
                  result <- putObject base condition name bytes
                  case result of
                    PutWritten _
                      | "journal/" `T.isPrefixOf` key && "\"Completed\"" `T.isInfixOf` TE.decodeUtf8 bytes -> writeIORef pending True
                      | key == "head.json" -> writeIORef pending False
                    _ -> pure ()
                  pure result
          }
  store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
  effects <- newIORef (0 :: Int)
  (reviewed, registry) <-
    preparedFixtureWith
      store
      (\_ _ -> modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted)
      (\_ _ -> pure (maybe RecoverySafeToRetry RecoveryProvedComplete recoveryProof))
  applied <- applyReviewed store registry reviewed >>= either (assertFailure . show) pure
  result <- case recoveryProof of
    Nothing -> pure (Right applied)
    Just _ -> case applied of
      StoppedAmbiguous transaction _ -> do
        replay <- newObjectStore base fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
        Right <$> (resumeTransaction replay registry transaction >>= either (assertFailure . show) pure)
      other -> pure (Left ("expected the persistent head failure to stop ambiguous, got " <> show other))
  journal <- getObjects base (ObjectName "journal") >>= either (assertFailure . show) pure
  events <- traverse (either (assertFailure . T.unpack) pure . decodeJournalEvent) (Map.elems journal)
  count <- readIORef effects
  pure (result, count, events)

assertConverged :: Either String TransactionResult -> Assertion
assertConverged result = case result of
  Right (Converged _) -> pure ()
  Right other -> assertFailure ("expected convergence, got " <> show other)
  Left reason -> assertFailure reason

assertOneCompletionPerOperation :: [JournalEvent] -> Assertion
assertOneCompletionPerOperation events = do
  let completed = [operation | event <- events, Just operation <- [eventOperation event], Completed _ <- [eventState event]]
  assertBool "a completion was recorded" (not (null completed))
  Map.filter (> (1 :: Int)) (Map.fromListWith (+) [(operation, 1) | operation <- completed]) @?= Map.empty
