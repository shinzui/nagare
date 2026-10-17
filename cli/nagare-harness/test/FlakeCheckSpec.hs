{-# OPTIONS_GHC -Werror=unused-imports #-}

-- | EP-184 M2: the full gate runs the flake check alongside the suites, keeps
-- it going after a failure, and reports each failing check as it appears.
module FlakeCheckSpec (flakeCheckTests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, withAsync)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Nagare.Harness.FlakeCheck
import Nagare.Harness.Gate (CheckPlan (..), fullCheckPlan, probeUntilUp, runCheckPlan)
import Nagare.Harness.Prelude
import Nagare.Harness.Step
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

flakeCheckTests :: TestTree
flakeCheckTests =
  testGroup
    "full gate checks (EP-184 M2)"
    [ testCase "the flake check keeps going and runs on every system" $
        (fullCheckPlan "nagare-harness" ^. #flake . #arguments) @?= ["flake", "check", "--all-systems", "--keep-going", "--print-build-logs"]
    , testCase "a flake log names each failed derivation once, and the summary names each failed check" $ do
        let running =
              "broken-one> make: *** [all] Error 1\n\
              \error: builder for '/nix/store/aaa111-broken-one.drv' failed with exit code 1;\n\
              \\ESC[31;1merror:\ESC[0m Cannot build '/nix/store/bbb222-broken-two.drv'.\n\
              \error: Cannot build '/nix/store/aaa111-broken-one.drv'.\n"
            summary = "  \x2705 checks.aarch64-darwin.fine\n  \x274C checks.aarch64-darwin.broken-one\n  \x2753 checks.x86_64-linux.other (cancelled)\n"
        flakeFailures running @?= [FailedDerivation "broken-one", FailedDerivation "broken-two"]
        summaryFailures (flakeFailures running) @?= [FailedDerivation "broken-one", FailedDerivation "broken-two"]
        summaryFailures (flakeFailures (running <> summary)) @?= [FailedCheck "checks.aarch64-darwin.broken-one"]
        flakeFailures "error: 1 dependencies of derivation '/nix/store/ccc-dependent.drv' failed to build\n" @?= []
        flakeFailures "error: build of '/nix/store/ddd-remote.drv' on 'ssh://builder@host' failed: Cannot build '/nix/store/ddd-remote.drv'.\n"
          @?= [FailedDerivation "remote"]
    , testCase "a log follower reports each new failure once, across a line split between reads" $
        withSystemTempDirectory "flake" $ \dir -> do
          let path = dir </> "flake.log"
          follower <- newLogFollower path
          (@?= []) =<< followLog follower
          writeFile path "error: builder for '/nix/store/aaa-split"
          (@?= []) =<< followLog follower
          appendFile path "-check.drv' failed\nerror: Cannot build '/nix/store/aaa-split-check.drv'.\n"
          (@?= [FailedDerivation "split-check"]) =<< followLog follower
          (@?= []) =<< followLog follower
    , testCase "the suite and the flake check run at the same time" $
        -- Each waits up to 20 s to see the other start; run one after the
        -- other, the first never sees it. No wall-clock bound, so a loaded
        -- machine does not fail it (2026-10-14: 4.5 s under a full gate).
        withPlan (plan [ok "static"] [meeting "suite" "nix-flake-check"] (meeting "nix-flake-check" "suite")) $ \(fast, flake, _, _) -> do
          map (^. #name) fast @?= ["static", "suite"]
          map (^. #exit) flake @?= [0]
    , testCase "a static failure stops the gate before the suite and the flake check" $
        withSystemTempDirectory "gate" $ \dir -> do
          let say _ = pure ()
          let flake = Step "nix-flake-check" "." "sh" ["-c", "touch " <> (dir </> "flake-ran")]
          (fast, results) <- runCheckPlan say dir dir (plan [broken "static"] [ok "suite"] flake)
          map (^. #name) fast @?= ["static"]
          results @?= []
          (@?= False) =<< doesFileExist (dir </> "flake-ran")
    , testCase "a suite failure does not stop the flake check" $
        withPlan (plan [ok "static"] [broken "suite", ok "after"] (Step "nix-flake-check" "." "sh" ["-c", "sleep 1; echo finished"])) $ \(fast, flake, said, _) -> do
          map (^. #name) fast @?= ["static", "suite"]
          map (^. #exit) flake @?= [0]
          assertBool "the gate did not say it keeps going" (any (("keeps going to report every failing check" `isInfixOf`) . snd) said)
    , testCase "a failing check is reported while the flake check still runs, and listed at its end" $
        withPlan (plan [ok "static"] [ok "suite"] brokenFlake) $ \(_, flake, said, _) -> do
          map (^. #exit) flake @?= [1]
          -- The fake flake check names its failure at once and runs 5 s more;
          -- the report must come before it ends, not within a fixed time.
          case ([elapsed | (elapsed, line) <- said, "nix-flake-check: FAILED derivation broken" `isInfixOf` line], [elapsed | (elapsed, line) <- said, "nix-flake-check " `isInfixOf` line, "FAIL" `isInfixOf` line]) of
            (reported : _, ended : _) -> assertBool ("reported at " <> show reported <> " s, the check ended at " <> show ended <> " s") (reported < ended - 2)
            _ -> assertFailure ("never reported: " <> show said)
          assertBool "the end does not list the failed check" (any (("gate:   derivation broken" `isInfixOf`) . snd) said)
    , testCase "only a lost builder with no failed build counts as a lost builder" $ do
        builderLostOnly (lost <> "error: Cannot build '/nix/store/aaa-nagare.drv'.\n       Reason: platform mismatch\n") @?= True
        builderLostOnly "cannot build on 'ssh://builder@b': error: failed to start SSH connection to 'b': Connection to UNKNOWN port 65535 timed out\n" @?= True
        builderLostOnly (lost <> "error: Cannot build '/nix/store/bbb-tests.drv'.\n       Reason: builder failed with exit code 1.\n") @?= False
        builderLostOnly "error: builder for '/nix/store/aaa-broken.drv' failed with exit code 1;\n" @?= False
        builderLostOnly "error: attribute 'missing' not found\n" @?= False
    , testCase "a flake check that lost the builder runs once more after the probe, and the second run decides" $
        withPlan (retrying [ok "probe"] lostOnce) $ \(_, flake, said, _) -> do
          map (^. #name) flake @?= ["nix-flake-check", "probe", "nix-flake-check-retry"]
          map (^. #exit) flake @?= [1, 0, 0]
          assertBool "the gate did not say it runs the flake check again" (any (("running it once more" `isInfixOf`) . snd) said)
    , testCase "a lost builder is not retried when a build also failed" $
        withPlan (retrying [ok "probe"] (flakeSaying (lost <> "Reason: builder failed with exit code 1.") 1)) $ \(_, flake, _, _) ->
          map (^. #name) flake @?= ["nix-flake-check"]
    , testCase "a flake check is run at most twice, and not again when the probe fails" $ do
        withPlan (retrying [ok "probe"] (flakeSaying lost 1)) $ \(_, flake, _, _) ->
          map (^. #exit) flake @?= [1, 0, 1]
        withPlan (retrying [broken "probe"] lostOnce) $ \(_, flake, _, _) ->
          map (^. #name) flake @?= ["nix-flake-check", "probe"]
    , testCase "a probe that fails while the builder wakes is tried again, at most three times" $ do
        -- Fails twice (the woken VM is still booting), then passes.
        let waking = Step "probe" "." "sh" ["-c", "n=$(cat tries 2>/dev/null || echo 0); n=$((n+1)); echo $n > tries; [ $n -ge 3 ]"]
        withPlan (retrying [waking] lostOnce) $ \(_, flake, _, _) -> do
          map (^. #name) flake @?= ["nix-flake-check", "probe", "nix-flake-check-retry"]
          map (^. #exit) flake @?= [1, 0, 0]
        let asleep = Step "probe" "." "sh" ["-c", "echo x >> tries; exit 1"]
        withSystemTempDirectory "gate" $ \dir -> do
          results <- probeUntilUp 0 (const (pure ())) dir dir [asleep]
          map (^. #exit) results @?= [1]
          (@?= 3) . length . lines =<< readFile (dir </> "tries")
    , testCase "a cancelled step's process is terminated" $
        withSystemTempDirectory "gate" $ \dir -> do
          let pidFile = dir </> "pid"
          withAsync (runStep dir dir (Step "long" "." "sh" ["-c", "echo $$ > " <> pidFile <> "; exec sleep 30"])) $ \running -> do
            waitFor (doesFileExist pidFile)
            threadDelay 200000
            pid <- filter (/= '\n') <$> readFile pidFile
            cancel running
            threadDelay 200000
            (code, _, _) <- readProcessWithExitCode "sh" ["-c", "kill -0 " <> pid] ""
            assertBool ("process " <> pid <> " still runs") (code /= ExitSuccess)
    ]
  where
    ok name = Step name "." "sh" ["-c", "exit 0"]
    broken name = Step name "." "sh" ["-c", "echo broken; exit 3"]
    meeting name other =
      let mine = T.unpack name <> ".started"
          theirs = T.unpack other <> ".started"
       in Step name "." "sh" ["-c", "touch " <> mine <> "; i=0; while [ ! -f " <> theirs <> " ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done; [ -f " <> theirs <> " ]"]
    brokenFlake = Step "nix-flake-check" "." "sh" ["-c", "echo \"error: builder for '/nix/store/aaa-broken.drv' failed with exit code 1;\"; sleep 5; exit 1"]
    plan static suite flake = CheckPlan {static, suite, flake, pollMicroseconds = 100000, beforeRetry = [], probePauseMicroseconds = 0}
    retrying probes flake = (plan [ok "static"] [ok "suite"] flake) {beforeRetry = probes}
    lost = "Failed to find a machine for remote build!\n"
    flakeSaying text code = Step "nix-flake-check" "." "sh" ["-c", "printf '%s\\n' " <> show (T.unpack text) <> "; exit " <> show (code :: Int)]
    -- Loses the builder on its first run (no marker file yet), passes on the next.
    lostOnce = Step "nix-flake-check" "." "sh" ["-c", "if [ -f lost-once ]; then exit 0; fi; touch lost-once; echo 'Failed to find a machine for remote build!'; exit 1"]
    withPlan checkPlan check =
      withSystemTempDirectory "gate" $ \dir -> do
        said <- newIORef []
        started <- getCurrentTime
        let say lines' = do
              elapsed <- realToFrac . (`diffUTCTime` started) <$> getCurrentTime
              atomicModifyIORef' said (\previous -> (previous <> map (elapsed :: Double,) lines', ()))
        (fast, flake) <- runCheckPlan say dir dir checkPlan
        finished <- getCurrentTime
        lines' <- readIORef said
        check (fast, flake, lines', realToFrac (diffUTCTime finished started) :: Double)
    waitFor condition = do
      done <- condition
      unless done (threadDelay 50000 >> waitFor condition)
