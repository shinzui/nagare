-- | EP-243 on the interpreter (ADR 25): a move's review step against a fake platform with pending
-- changes, stale reviews and a lost acknowledgement, alone and driving the whole move. Every stop is a
-- wait or a refusal the next run of the same command gets past.
module Nagare.Test.ContextMoveReview
  ( contextMoveReviewTests
  )
where

import Control.Monad (forM_, replicateM_)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Context.Move
import Nagare.Context.MoveReview
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (OperationAction (..))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store.Manifest (ScopeRevision (..))
import Nagare.Resource.Types (ScopeKind (Platform), mkScopeGeneration, mkScopeId)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | One stage's truth: how many changes are left, the review a run saved, and the faults to inject.
data Stage = Stage
  { pending :: !Int
  , generation :: !Integer
  , saved :: !(Maybe Int)
  , staleNext :: !Bool
  , loseNextAcknowledgement :: !Bool
  , applied :: !Int
  , plans :: !Int
  }
  deriving stock (Eq, Show, Generic)

platform :: Int -> Stage
platform n = Stage n 1 Nothing False False 0 0

ops :: IORef Stage -> ReviewOps IO
ops world =
  ReviewOps
    { savedReview = isJust . saved <$> readIORef world
    , planReview = do
        modifyIORef' world (\p -> p {plans = plans p + 1, saved = Just (pending p)})
        p <- readIORef world
        let scope = either (error . show) id (mkScopeId Platform "upstream")
            revision g n = ScopeRevision (either (error . show) id (mkScopeGeneration g)) (contentDigest (TE.encodeUtf8 (tshow n)))
            -- An unchanged plan still bumps the generation, as composition does.
            desired = Map.singleton scope (revision (generation p + 1) (pending p))
            accepted = Map.singleton scope (revision (generation p) (if pending p == 0 then 0 else pending p + 100))
        pure (ReviewPlan [if pending p == 0 then VerifyResource else UpdateResource] desired accepted "fake")
    , applyReview = do
        p <- readIORef world
        let effect q = q {pending = max 0 (pending q - 1), generation = generation q + 1, applied = applied q + 1}
        case () of
          _
            | staleNext p -> modifyIORef' world (\q -> q {staleNext = False, saved = Nothing}) >> pure False
            | loseNextAcknowledgement p -> modifyIORef' world (\q -> (effect q) {loseNextAcknowledgement = False, saved = Nothing}) >> pure False
            | otherwise -> modifyIORef' world (\q -> (effect q) {saved = Nothing}) >> pure True
    , discardReview = modifyIORef' world (\p -> p {saved = Nothing})
    }

-- | The operator: run the same command until the step completes, at most @limit@ times.
untilDone :: Int -> IO StepOutcome -> IO [StepOutcome]
untilDone limit run
  | limit <= 0 = pure []
  | otherwise =
      run >>= \case
        StepCompleted -> pure [StepCompleted]
        other -> (other :) <$> untilDone (limit - 1) run

contextMoveReviewTests :: TestTree
contextMoveReviewTests =
  testGroup
    "context move review step (EP-243)"
    [ testCase "a step plans, waits for the operator, applies on the next run, and completes when nothing is left" $ do
        world <- newIORef (platform 3)
        outcomes <- untilDone 10 (reviewStep (ops world))
        map isWait (init outcomes) @?= [True, True, True]
        last outcomes @?= StepCompleted
        final <- readIORef world
        (pending final, applied final, saved final) @?= (0, 3, Nothing)
    , testCase "a plan with only verifications and a bumped generation completes at once" $ do
        world <- newIORef (platform 0)
        reviewStep (ops world) >>= (@?= StepCompleted)
        final <- readIORef world
        (applied final, saved final) @?= (0, Nothing)
    , testCase "a stale review is refused and discarded, and the next run plans afresh" $ do
        world <- newIORef (platform 1)
        reviewStep (ops world) >>= assertBool "waits" . isWait
        modifyIORef' world (\p -> p {staleNext = True})
        reviewStep (ops world) >>= (@?= StepRefused notApplied)
        readIORef world >>= (@?= Nothing) . saved
        rest <- untilDone 5 (reviewStep (ops world))
        last rest @?= StepCompleted
        readIORef world >>= (@?= 1) . applied
    , testCase "a lost acknowledgement is refused, and the next run plans from what landed without applying it twice" $ do
        world <- newIORef (platform 2)
        reviewStep (ops world) >>= assertBool "waits" . isWait
        modifyIORef' world (\p -> p {loseNextAcknowledgement = True})
        reviewStep (ops world) >>= (@?= StepRefused notApplied)
        rest <- untilDone 5 (reviewStep (ops world))
        last rest @?= StepCompleted
        final <- readIORef world
        (pending final, applied final) @?= (0, 2)
    , testCase "a whole move through review steps finishes by rerunning apply, whatever faults each step meets" $
        forM_ [(stale, lost) | stale <- [False, True], lost <- [False, True]] $ \(stale, lost) -> do
          worlds <- traverse (const (newIORef ((platform 2) {staleNext = stale, loseNextAcknowledgement = lost}))) sameDomainSteps
          record <- newIORef (newMove sameDomainSteps)
          let stepOps = Map.fromList (zip sameDomainSteps worlds)
              moveOps =
                MoveOps
                  { performStep = \_ step -> maybe (pure (StepRefused "no world")) (reviewStep . ops) (Map.lookup step stepOps)
                  , saveMove = \r -> modifyIORef' record (const r)
                  }
              operator limit
                | limit <= (0 :: Int) = assertFailure "the move did not finish"
                | otherwise = do
                    (result, _) <- readIORef record >>= runMove moveOps
                    case result of
                      MoveFinished -> pure ()
                      MoveStopped _ (StepWaiting _) -> operator (limit - 1)
                      MoveStopped _ (StepRefused reason) | reason == notApplied -> operator (limit - 1)
                      other -> assertFailure ("an unexpected stop: " <> show other)
          operator 200
          forM_ worlds $ \world -> readIORef world >>= \p -> (pending p, saved p) @?= (0, Nothing)
    , testCase "rolling back through review steps undoes each by rerunning rollback" $ do
        worlds <- traverse (const (newIORef (platform 1))) sameDomainSteps
        let stepOps = Map.fromList (zip sameDomainSteps worlds)
            moveOps =
              MoveOps
                { performStep = \_ step -> maybe (pure (StepRefused "no world")) (reviewStep . ops) (Map.lookup step stepOps)
                , saveMove = \_ -> pure ()
                }
        record <- newIORef (newMove sameDomainSteps & #completed .~ 6)
        replicateM_ 40 $ do
          current <- readIORef record
          unless (current ^. #completed == 0 && isNothing (current ^. #inProgress)) $ do
            (result, next) <- rollbackMove moveOps current
            modifyIORef' record (const next)
            case result of
              MoveRolledBack -> pure ()
              MoveStopped _ (StepWaiting _) -> pure ()
              other -> assertFailure ("an unexpected stop: " <> show other)
        final <- readIORef record
        (final ^. #completed, final ^. #inProgress) @?= (0, Nothing)
    ]

isWait :: StepOutcome -> Bool
isWait = \case
  StepWaiting _ -> True
  _ -> False

tshow :: (Show a) => a -> Text
tshow = T.pack . show
