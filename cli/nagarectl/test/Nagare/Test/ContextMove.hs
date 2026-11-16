-- | EP-243 D3 and D5 on the interpreter: the move engine against a modelled world, checked after
-- every effect that each way a visitor can reach a site still works (ADR 25).
module Nagare.Test.ContextMove
  ( contextMoveTests
  )
where

import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Nagare.Context.Move
import Nagare.Dsl.Prelude
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

data NameServers = CloudDns | Cloudflare
  deriving stock (Eq, Show)

data Records = ToVm | ToTunnel
  deriving stock (Eq, Show)

-- | What the internet sees of one context. Stale flags are resolver caches that outlive a change
-- until their TTL passes, which only 'tick' does.
data World = World
  { registrar :: !NameServers
  , authoritative :: !NameServers
  , staleCloudDnsNs :: !Bool
  , staleCloudflareNs :: !Bool
  , mirror :: !Bool
  , records :: !Records
  , staleVmAnswers :: !Bool
  , staleTunnelAnswers :: !Bool
  , dnssec :: !Bool
  , dsAtParent :: !Bool
  , connector :: !Bool
  , carried :: !Bool
  , firewallOpen :: !Bool
  , kourierLb :: !Bool
  , committed :: !Bool
  }
  deriving stock (Eq, Show)

initialWorld :: World
initialWorld =
  World
    { registrar = CloudDns
    , authoritative = CloudDns
    , staleCloudDnsNs = False
    , staleCloudflareNs = False
    , mirror = False
    , records = ToVm
    , staleVmAnswers = False
    , staleTunnelAnswers = False
    , dnssec = False
    , dsAtParent = False
    , connector = False
    , carried = False
    , firewallOpen = True
    , kourierLb = True
    , committed = False
    }

directWorks, tunnelWorks :: World -> Bool
directWorks w = firewallOpen w && kourierLb w
tunnelWorks w = connector w && carried w

-- | Every path a visitor may take right now, and why it fails if it does.
servingProblems :: World -> [Text]
servingProblems w =
  [ "a resolver still asking Cloud DNS reaches a closed VM"
  | (authoritative w == CloudDns || staleCloudDnsNs w) && not (directWorks w)
  ]
    <> [ "the zone answers with nothing"
       | (authoritative w == Cloudflare || staleCloudflareNs w) && not (mirror w)
       ]
    <> [ "the zone sends visitors to a closed VM"
       | (authoritative w == Cloudflare || staleCloudflareNs w) && mirror w && records w == ToVm && not (directWorks w)
       ]
    <> [ "the zone sends visitors to a tunnel that does not serve"
       | (authoritative w == Cloudflare || staleCloudflareNs w) && mirror w && records w == ToTunnel && not (tunnelWorks w)
       ]
    <> ["a cached VM answer reaches a closed VM" | staleVmAnswers w && not (directWorks w)]
    <> ["a cached edge answer reaches a tunnel that does not serve" | staleTunnelAnswers w && not (tunnelWorks w)]
    <> ["a DS record at the parent does not validate" | dsAtParent w && (authoritative w == CloudDns || not (dnssec w))]

-- | Time passes: every cache expires and the registrar's change becomes authoritative.
tick :: World -> World
tick w =
  w
    { staleCloudDnsNs = False
    , staleCloudflareNs = False
    , staleVmAnswers = False
    , staleTunnelAnswers = False
    }

perform :: MoveDirection -> MoveStep -> World -> (StepOutcome, World)
perform MovingForward step w = case step of
  CheckPreconditions
    | dsAtParent w -> (StepRefused "the parent publishes a DS record", w)
    | otherwise -> (StepCompleted, w)
  MirrorZone -> (StepCompleted, w {mirror = True, records = if mirror w then records w else ToVm})
  AwaitNameServers
    | registrar w == Cloudflare && authoritative w == CloudDns ->
        (StepCompleted, w {authoritative = Cloudflare, staleCloudDnsNs = True})
    | authoritative w == Cloudflare -> (StepCompleted, w)
    | otherwise -> (StepWaiting "change the name servers at the registrar", w)
  EnableDnssec -> (StepCompleted, w {dnssec = True})
  ConfirmDirect
    | directWorks w -> (StepCompleted, w)
    | otherwise -> (StepRefused "direct ingress does not answer", w)
  StartConnector -> (StepCompleted, w {connector = True})
  CarryHostnames -> (StepCompleted, w {carried = True})
  SwitchRecords
    | not (tunnelWorks w) -> (StepRefused "the tunnel does not serve yet", w)
    | records w == ToTunnel -> (StepCompleted, w)
    | otherwise -> (StepCompleted, w {records = ToTunnel, staleVmAnswers = True})
  VerifyTunnel
    | records w == ToTunnel && tunnelWorks w -> (StepCompleted, w)
    | otherwise -> (StepRefused "a hostname does not answer through the edge", w)
  AwaitOldTtl
    | staleVmAnswers w || staleCloudDnsNs w -> (StepWaiting "old answers are still cached", w)
    | otherwise -> (StepCompleted, w)
  CloseFirewall
    | records w /= ToTunnel || staleVmAnswers w || staleCloudDnsNs w || authoritative w == CloudDns ->
        (StepRefused "visitors may still arrive directly", w)
    | otherwise -> (StepCompleted, w {firewallOpen = False})
  CloseKourier -> (StepCompleted, w {kourierLb = False})
  CommitMove -> (StepCompleted, w {committed = True})
perform RollingBack step w = case step of
  CloseKourier -> (StepCompleted, w {kourierLb = True})
  CloseFirewall -> (StepCompleted, w {firewallOpen = True})
  SwitchRecords
    | not (directWorks w) -> (StepRefused "direct ingress does not answer", w)
    | records w == ToVm -> (StepCompleted, w)
    | otherwise -> (StepCompleted, w {records = ToVm, staleTunnelAnswers = True})
  CarryHostnames
    | records w == ToTunnel || staleTunnelAnswers w -> (StepWaiting "cached edge answers still use the carried names", w)
    | otherwise -> (StepCompleted, w {carried = False})
  StartConnector
    | records w == ToTunnel || staleTunnelAnswers w -> (StepWaiting "cached edge answers still use the tunnel", w)
    | otherwise -> (StepCompleted, w {connector = False})
  EnableDnssec
    | dsAtParent w -> (StepWaiting "remove the DS record at the registrar", w)
    | otherwise -> (StepCompleted, w {dnssec = False})
  MirrorZone
    | registrar w == Cloudflare -> (StepWaiting "point the name servers back at Cloud DNS", w)
    | authoritative w == Cloudflare -> (StepWaiting "resolvers still ask Cloudflare", w {authoritative = CloudDns, staleCloudflareNs = True})
    | staleCloudflareNs w -> (StepWaiting "resolvers still ask Cloudflare", w)
    | otherwise -> (StepCompleted, w {mirror = False})
  _ -> (StepRefused ("no inverse for " <> T.pack (show step)), w)

-- | The interpreter's state: the world, the saved record, and every serving problem seen.
data Harness = Harness
  { world :: !(IORef World)
  , saved :: !(IORef MoveRecord)
  , problems :: !(IORef [Text])
  , crashAt :: !(IORef (Maybe (MoveDirection, MoveStep)))
  , waits :: !(IORef [Text])
  }

newHarness :: IO Harness
newHarness = Harness <$> newIORef initialWorld <*> newIORef (newMove sameDomainSteps) <*> newIORef [] <*> newIORef Nothing <*> newIORef []

-- | Each effect is checked as it lands. A crash takes effect and then loses the acknowledgement.
harnessOps :: Harness -> MoveOps IO
harnessOps h =
  MoveOps
    { performStep = \direction step -> do
        before <- readIORef (world h)
        let (outcome, after) = perform direction step before
        writeIORef (world h) after
        observe h (show direction <> " " <> show step)
        crash <- readIORef (crashAt h)
        if crash == Just (direction, step)
          then writeIORef (crashAt h) Nothing >> pure (StepWaiting "crashed after the effect")
          else pure outcome
    , saveMove = writeIORef (saved h)
    }

observe :: Harness -> String -> IO ()
observe h label = do
  w <- readIORef (world h)
  forM_ (servingProblems w) $ \problem -> modifyIORef' (problems h) (<> [T.pack label <> ": " <> problem])

-- | The operator's part of a wait: change the name servers, remove a DS record, or let time pass.
operator :: Harness -> MoveDirection -> Text -> IO ()
operator h direction reason = do
  modifyIORef' (world h) answer
  modifyIORef' (waits h) (<> [reason])
  observe h ("operator after " <> T.unpack reason)
  where
    answer w
      | "registrar" `T.isInfixOf` reason && direction == MovingForward = w {registrar = Cloudflare}
      | "back at Cloud DNS" `T.isInfixOf` reason = w {registrar = CloudDns}
      | "DS record" `T.isInfixOf` reason = w {dsAtParent = False}
      | otherwise = tick w

-- | Run in one direction until it finishes, answering every wait the way an operator would.
drive :: Harness -> MoveDirection -> IO MoveResult
drive h direction = go (40 :: Int)
  where
    go 0 = assertFailure "the move did not settle" >> pure (MoveRefused "loop")
    go n = do
      record <- readIORef (saved h)
      (result, _) <- (if direction == MovingForward then runMove else rollbackMove) (harnessOps h) record
      case result of
        MoveStopped _ (StepWaiting reason) -> operator h direction reason >> go (n - 1)
        _ -> pure result

assertServedThroughout :: Harness -> IO ()
assertServedThroughout h = readIORef (problems h) >>= \seen -> assertBool (T.unpack (T.unlines seen)) (null seen)

contextMoveTests :: [TestTree]
contextMoveTests =
  [ testCase "a move runs every step in order and ends with no inbound web port, serving throughout" $ do
      h <- newHarness
      drive h MovingForward >>= (@?= MoveFinished)
      w <- readIORef (world h)
      (firewallOpen w, kourierLb w, records w, authoritative w, committed w) @?= (False, False, ToTunnel, Cloudflare, True)
      assertServedThroughout h
  , testCase "stopped after any step's effect, resume finishes the move and rollback restores direct ingress, serving throughout" $
      forM_ (filter (/= CommitMove) sameDomainSteps) $ \step -> do
        resumed <- newHarness
        writeIORef (crashAt resumed) (Just (MovingForward, step))
        drive resumed MovingForward >>= (@?= MoveFinished)
        assertServedThroughout resumed
        rolled <- newHarness
        writeIORef (crashAt rolled) (Just (MovingForward, step))
        record <- readIORef (saved rolled)
        (first', _) <- runMove (harnessOps rolled) record
        waitThenStop rolled first' step
        drive rolled RollingBack >>= (@?= MoveRolledBack)
        w <- readIORef (world rolled)
        assertBool ("after a stop at " <> show step <> " rollback left " <> show w) (directWorks w && authoritative w == CloudDns && not (mirror w) && not (connector w))
        assertServedThroughout rolled
  , testCase "a rollback that itself stops after an inverse's effect resumes to the same end, serving throughout" $
      forM_ (filter hasInverse sameDomainSteps) $ \step -> do
        h <- newHarness
        drive h MovingForward >>= \_ -> pure ()
        -- Reset the commit so rollback is allowed: a move stopped just before committing.
        modifyIORef' (saved h) (\r -> r & #completed .~ (length sameDomainSteps - 1))
        writeIORef (crashAt h) (Just (RollingBack, step))
        drive h RollingBack >>= (@?= MoveRolledBack)
        w <- readIORef (world h)
        assertBool ("rollback crashing at " <> show step <> " left " <> show w) (directWorks w && authoritative w == CloudDns && not (mirror w))
        assertServedThroughout h
  , testCase "a DS record the operator added after DNSSEC holds rollback until it is removed" $ do
      h <- newHarness
      -- Forward until the old answers are cached, then the operator registers the DS record.
      record <- readIORef (saved h)
      _ <- runMove (harnessOps h) record
      operator h MovingForward "change the name servers at the registrar"
      _ <- readIORef (saved h) >>= runMove (harnessOps h)
      modifyIORef' (world h) (\w -> w {dsAtParent = True})
      observe h "operator registers the DS record"
      writeIORef (waits h) []
      drive h RollingBack >>= (@?= MoveRolledBack)
      seen <- readIORef (waits h)
      assertBool ("rollback never waited for the DS record: " <> show seen) (any ("DS record" `T.isInfixOf`) seen)
      w <- readIORef (world h)
      dnssec w @?= False
      assertServedThroughout h
  , testCase "a parent DS record refuses the move before anything changes" $ do
      h <- newHarness
      modifyIORef' (world h) (\w -> w {dsAtParent = True, authoritative = CloudDns})
      record <- readIORef (saved h)
      (result, after) <- runMove (harnessOps h) record
      result @?= MoveStopped CheckPreconditions (StepRefused "the parent publishes a DS record")
      after ^. #completed @?= 0
  , testCase "a committed move refuses rollback, and a move rolling back refuses to go forward" $ do
      h <- newHarness
      drive h MovingForward >>= (@?= MoveFinished)
      committedRecord <- readIORef (saved h)
      fst <$> rollbackMove (harnessOps h) committedRecord >>= (@?= MoveRefused "the move is committed; moving back is a new move")
      fresh <- newHarness
      let rolling = newMove sameDomainSteps & #completed .~ 6 & #direction .~ RollingBack
      fst <$> runMove (harnessOps fresh) rolling >>= (@?= MoveRefused "this move is rolling back; continue with rollback")
  , testCase "the checker reports each broken world, and a list without the TTL wait stops at the firewall" $ do
      let moved = initialWorld {registrar = Cloudflare, authoritative = Cloudflare, mirror = True, records = ToTunnel, connector = True, carried = True}
      length (servingProblems initialWorld) @?= 0
      length (servingProblems moved) @?= 0
      length (servingProblems (initialWorld {firewallOpen = False})) @?= 1
      length (servingProblems (moved {connector = False})) @?= 1
      length (servingProblems (moved {firewallOpen = False, staleVmAnswers = True})) @?= 1
      length (servingProblems (moved {mirror = False})) @?= 1
      length (servingProblems (moved {dsAtParent = True})) @?= 1
      length (servingProblems (initialWorld {dsAtParent = True})) @?= 1
      h <- newHarness
      writeIORef (saved h) (newMove (filter (/= AwaitOldTtl) sameDomainSteps))
      record <- readIORef (saved h)
      (first', _) <- runMove (harnessOps h) record
      operator h MovingForward (case first' of MoveStopped _ (StepWaiting reason) -> reason; _ -> "")
      (result, _) <- readIORef (saved h) >>= runMove (harnessOps h)
      result @?= MoveStopped CloseFirewall (StepRefused "visitors may still arrive directly")
      assertServedThroughout h
  , testCase "the remaining steps name what is left in each direction" $ do
      let record = newMove sameDomainSteps & #completed .~ 8
      take 1 (remainingSteps record) @?= [VerifyTunnel]
      remainingSteps (record & #direction .~ RollingBack) @?= [SwitchRecords, CarryHostnames, StartConnector, EnableDnssec, MirrorZone]
  ]
  where
    -- Answer the operator's waits until the crashed step, then stop there with its effect in place.
    waitThenStop h result step = case result of
      MoveStopped stopped (StepWaiting reason)
        | stopped /= step -> do
            operator h MovingForward reason
            record <- readIORef (saved h)
            (next, _) <- runMove (harnessOps h) record
            waitThenStop h next step
      _ -> pure ()
