-- | EP-246 D6 on the interpreter (ADR 25): a move to a new base domain over a modelled world, stopped
-- after every step's effect. Resume reaches the end state, rollback reaches a context serving on its
-- old base with its old grants and passkeys, and nobody is locked out or unserved outside the stated
-- outage between the flip and the sites' verification.
module Nagare.Test.ContextBaseMoveRun
  ( contextBaseMoveRunTests
  )
where

import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Nagare.Context.Move
import Nagare.Dsl.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

data Base = Old | New
  deriving stock (Eq, Show)

data World = World
  { zone :: !Bool
  , dnssec :: !Bool
  , connector :: !Bool
  , profile :: !Base
  , platform :: !Base
  , passkeys :: ![Text]
  -- ^ Rows in Shomei's table.
  , export :: !(Maybe [Text])
  , redeployed :: !Bool
  -- ^ The operator redeployed every site from its config on the new base.
  , carried :: !Bool
  -- ^ New routes and grants accepted, old ones kept.
  , firewallOpen :: !Bool
  , kourierLb :: !Bool
  , committed :: !Bool
  , verified :: !Bool
  }
  deriving stock (Eq, Show, Generic)

original :: [Text]
original = ["alice-laptop", "carol-phone"]

initialWorld :: World
initialWorld = World False False False Old Old original Nothing False False True True False False

oldServes, newServes :: World -> Bool
oldServes w = firewallOpen w && kourierLb w && platform w == Old && profile w == Old
newServes w = zone w && connector w && platform w == New && profile w == New && carried w && passkeys w `notElem'` original
  where
    notElem' rows old = not (any (`elem` old) rows)

-- | What a visitor or a signing-in user meets now. The flip starts a stated outage that ends when the
-- sites are verified; outside it either the old names serve or the new ones do.
problems :: World -> [Text]
problems w =
  [ "neither the old nor the new names serve outside the outage"
  | not inOutage
  , not (oldServes w)
  , not (newServes w)
  ]
    <> ["the firewall closed before the new names served" | not (firewallOpen w), not (newServes w)]
    <> ["a passkey bound to the old domain blocks sign-in on the new one" | platform w == New, verified w, any (`elem` original) (passkeys w)]
    <> ["the old domain lost its passkeys" | platform w == Old, passkeys w /= original]
  where
    inOutage = profile w == New || platform w == New

perform :: MoveDirection -> MoveStep -> World -> (StepOutcome, World)
perform MovingForward step w = case step of
  CheckPreconditions -> (StepCompleted, w)
  CreateZone -> (StepCompleted, w {zone = True})
  EnableDnssec
    | dnssec w -> (StepCompleted, w)
    | otherwise -> (StepWaiting "turn DNSSEC on for the zone in Cloudflare", w)
  StartConnector -> (StepCompleted, w {connector = True})
  FlipBase
    | profile w == Old -> (StepWaiting "reload the shell's environment", w {profile = New})
    | otherwise -> (StepCompleted, w {platform = New})
  RemovePasskeys ->
    let saved = fromMaybe (passkeys w) (export w)
     in (StepCompleted, w {export = Just saved, passkeys = filter (`notElem` saved) (passkeys w)})
  CarrySites
    | not (redeployed w) -> (StepWaiting "redeploy every site from its config", w)
    | otherwise -> (StepCompleted, w {carried = True})
  VerifySites
    | newServes w -> (StepCompleted, w {verified = True})
    | otherwise -> (StepRefused "a new name does not answer", w)
  CloseFirewall
    | not (newServes w) -> (StepRefused "the new names do not serve", w)
    | otherwise -> (StepCompleted, w {firewallOpen = False})
  CloseKourier -> (StepCompleted, w {kourierLb = False})
  CommitMove -> (StepCompleted, w {committed = True})
  _ -> (StepRefused ("not a base-domain step: " <> T.pack (show step)), w)
perform RollingBack step w = case step of
  CloseKourier -> (StepCompleted, w {kourierLb = True})
  CloseFirewall -> (StepCompleted, w {firewallOpen = True})
  CarrySites -> (StepCompleted, w {verified = False})
  RemovePasskeys -> (StepCompleted, w {passkeys = fromMaybe (passkeys w) (export w)})
  FlipBase
    | profile w == New -> (StepWaiting "reload the shell's environment", w {profile = Old})
    | otherwise -> (StepCompleted, w {platform = Old, redeployed = False, carried = False})
  StartConnector -> (StepCompleted, w)
  EnableDnssec -> (StepCompleted, w)
  CreateZone -> (StepCompleted, w)
  _ -> (StepRefused ("no inverse for " <> T.pack (show step)), w)

data Harness = Harness
  { world :: !(IORef World)
  , saved :: !(IORef MoveRecord)
  , seen :: !(IORef [Text])
  , crashAt :: !(IORef (Maybe (MoveDirection, MoveStep)))
  }

newHarness :: IO Harness
newHarness = Harness <$> newIORef initialWorld <*> newIORef (newMove baseDomainSteps) <*> newIORef [] <*> newIORef Nothing

ops :: Harness -> MoveOps IO
ops h =
  MoveOps
    { performStep = \direction step -> do
        (outcome, after) <- perform direction step <$> readIORef (world h)
        writeIORef (world h) after
        check h (show direction <> " " <> show step)
        crash <- readIORef (crashAt h)
        if crash == Just (direction, step)
          then writeIORef (crashAt h) Nothing >> pure (StepWaiting "crashed after the effect")
          else pure outcome
    , saveMove = writeIORef (saved h)
    }

check :: Harness -> String -> IO ()
check h label = readIORef (world h) >>= \w -> forM_ (problems w) (\p -> modifyIORef' (seen h) (<> [T.pack label <> ": " <> p]))

-- | The operator's part of a wait.
answer :: Harness -> Text -> IO ()
answer h reason = do
  modifyIORef' (world h) respond
  check h ("operator: " <> T.unpack reason)
  where
    respond w
      | "DNSSEC" `T.isInfixOf` reason = w {dnssec = True}
      | "redeploy" `T.isInfixOf` reason = w {redeployed = True}
      | otherwise = w

-- | Go forward, answering waits, until the injected crash has happened.
untilCrash :: Harness -> IO ()
untilCrash h = go (60 :: Int)
  where
    go 0 = assertFailure "the crash never happened"
    go n = do
      (result, _) <- readIORef (saved h) >>= runMove (ops h)
      pending <- readIORef (crashAt h)
      case (pending, result) of
        (Nothing, _) -> pure ()
        (Just _, MoveStopped _ (StepWaiting reason)) -> answer h reason >> go (n - 1)
        (Just _, other) -> assertFailure ("stopped before the crash: " <> show other)

drive :: Harness -> MoveDirection -> IO MoveResult
drive h direction = go (60 :: Int)
  where
    go 0 = assertFailure "the move did not settle" >> pure (MoveRefused "loop")
    go n = do
      record <- readIORef (saved h)
      (result, _) <- (if direction == MovingForward then runMove else rollbackMove) (ops h) record
      case result of
        MoveStopped _ (StepWaiting reason) -> answer h reason >> go (n - 1)
        _ -> pure result

clean :: Harness -> IO ()
clean h = readIORef (seen h) >>= \found -> assertBool (T.unpack (T.unlines found)) (null found)

endState, oldState :: World -> Bool
endState w = newServes w && not (firewallOpen w) && not (kourierLb w) && committed w
oldState w = oldServes w && passkeys w == original

contextBaseMoveRunTests :: TestTree
contextBaseMoveRunTests =
  testGroup
    "a move to a new base domain on the interpreter (EP-246 D6)"
    [ testCase "the whole move ends on the new base with no inbound web port, and nobody is locked out" $ do
        h <- newHarness
        drive h MovingForward >>= (@?= MoveFinished)
        readIORef (world h) >>= assertBool "not at the end state" . endState
        clean h
    , testCase "stopped after any step's effect, resume finishes and rollback restores the old base with its passkeys" $
        forM_ (filter (/= CommitMove) baseDomainSteps) $ \step -> do
          resumed <- newHarness
          writeIORef (crashAt resumed) (Just (MovingForward, step))
          drive resumed MovingForward >>= (@?= MoveFinished)
          readIORef (world resumed) >>= assertBool ("resume after " <> show step) . endState
          clean resumed
          rolled <- newHarness
          writeIORef (crashAt rolled) (Just (MovingForward, step))
          untilCrash rolled
          drive rolled RollingBack >>= (@?= MoveRolledBack)
          w <- readIORef (world rolled)
          assertBool ("after a stop at " <> show step <> " rollback left " <> show w) (oldState w)
          clean rolled
    , testCase "a rollback that itself stops after an inverse's effect resumes to the old base" $
        forM_ (filter hasInverse baseDomainSteps) $ \step -> do
          h <- newHarness
          _ <- drive h MovingForward
          modifyIORef' (saved h) (\r -> r & #completed .~ (length baseDomainSteps - 1))
          writeIORef (crashAt h) (Just (RollingBack, step))
          drive h RollingBack >>= (@?= MoveRolledBack)
          readIORef (world h) >>= \w -> assertBool ("rollback crashing at " <> show step <> " left " <> show w) (oldState w)
          clean h
    , testCase "a stop after the export removes exactly the exported passkeys on the next run" $ do
        h <- newHarness
        writeIORef (crashAt h) (Just (MovingForward, RemovePasskeys))
        _ <- drive h MovingForward
        w <- readIORef (world h)
        (export w, filter (`elem` original) (passkeys w)) @?= (Just original, [])
    , testCase "the checker reports each broken world" $ do
        problems initialWorld @?= []
        length (problems (initialWorld {firewallOpen = False})) @?= 2
        let moved = initialWorld {zone = True, connector = True, profile = New, platform = New, passkeys = [], export = Just original, redeployed = True, carried = True, verified = True}
        problems moved @?= []
        length (problems (moved {passkeys = original})) @?= 1
    ]
