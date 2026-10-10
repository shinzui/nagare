{-# OPTIONS_GHC -Werror=unused-imports #-}

-- | EP-184 M2: the full gate runs the flake check alongside the suites, keeps
-- it going after a failure, and reports each failing check as it appears.
module FlakeCheckSpec (flakeCheckTests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, withAsync)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Nagare.Harness.FlakeCheck
import Nagare.Harness.Gate (CheckPlan (..), fullCheckPlan, runCheckPlan)
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
        (fullCheckPlan ^. #flake . #arguments) @?= ["flake", "check", "--all-systems", "--keep-going", "--print-build-logs"]
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
        withPlan (plan [ok "static"] [sleeping "suite" 2] (sleeping "nix-flake-check" 2)) $ \(fast, flake, _, seconds) -> do
          map (^. #name) fast @?= ["static", "suite"]
          map (^. #exit) flake @?= [0]
          assertBool ("took " <> show seconds <> " s, not about 2 s") (seconds < 3.5)
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
          -- The fake flake check names its failure at once and runs 2 s more.
          case [elapsed | (elapsed, line) <- said, "nix-flake-check: FAILED derivation broken" `isInfixOf` line] of
            elapsed : _ -> assertBool ("reported only after " <> show elapsed <> " s") (elapsed < 1.5)
            [] -> assertFailure ("never reported: " <> show said)
          assertBool "the end does not list the failed check" (any (("gate:   derivation broken" `isInfixOf`) . snd) said)
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
    sleeping name n = Step name "." "sh" ["-c", "sleep " <> show (n :: Int)]
    brokenFlake = Step "nix-flake-check" "." "sh" ["-c", "echo \"error: builder for '/nix/store/aaa-broken.drv' failed with exit code 1;\"; sleep 2; exit 1"]
    plan static suite flake = CheckPlan {static, suite, flake, pollMicroseconds = 100000}
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
