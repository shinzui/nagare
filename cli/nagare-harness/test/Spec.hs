{-# OPTIONS_GHC -Werror=unused-imports #-}

module Main (main) where

import Data.Aeson (eitherDecode, eitherDecodeFileStrict)
import Data.Either (isLeft, isRight)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Nagare.Harness.FixtureSmoke
import Nagare.Harness.Gate (fastSteps)
import Nagare.Harness.Mutation (Expectation (..), MutationRecord (..), Outcome (..), Suite (..), classifyProof, readSweepResults)
import Nagare.Harness.Prelude
import Nagare.Harness.Realise (remainingPaths)
import Nagare.Harness.Record
import Nagare.Harness.Step
import Nagare.Harness.Verify
import System.Directory (listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "nagare-harness"
    [ testGroup
        "steps"
        [ testCase "stops at the first failure and keeps its exit code" $
            withSystemTempDirectory "gate" $ \dir -> do
              results <-
                runSteps
                  (const (pure ()))
                  dir
                  dir
                  [ Step "first" "." "sh" ["-c", "exit 0"]
                  , Step "second" "." "sh" ["-c", "echo broken; exit 3"]
                  , Step "third" "." "sh" ["-c", "exit 0"]
                  ]
              map (^. #name) results @?= ["first", "second"]
              map (^. #exit) results @?= [0, 3]
              logged <- readFile (last results ^. #logPath)
              logged @?= "broken\n"
        , testCase "a program that cannot start fails the step instead of the gate" $
            withSystemTempDirectory "gate" $ \dir -> do
              results <- runSteps (const (pure ())) dir dir [Step "missing" "." "nagare-harness-no-such-program" []]
              map (^. #exit) results @?= [127]
        ]
    , testCase "a mutation proof counts only when its record fails at the stage it names (EP-180 M8)" $ do
        classifyProof TestFails (ExitFailure 1) True @?= Killed
        classifyProof TestFails ExitSuccess True @?= Survived
        classifyProof TestFails (ExitFailure 1) False @?= WrongStage
        classifyProof BuildFails (ExitFailure 1) False @?= Killed
        classifyProof BuildFails (ExitFailure 1) True @?= WrongStage
        classifyProof BuildFails ExitSuccess True @?= WrongStage
    , testCase "a sweep's results classify each record, and a record it never reached is not run (EP-180 M8)" $ do
        let entries =
              [ MutationRecord "killed" Nagarectl "/a/" TestFails
              , MutationRecord "survived" Nagarectl "/b/" TestFails
              , MutationRecord "stale" Nagarectl "/c/" TestFails
              , MutationRecord "compiles-not" Nagarectl "/d/" BuildFails
              , MutationRecord "unreached" NagareDsl "/e/" TestFails
              ]
            rows = "killed\tbuilt\t1\t40\nsurvived\tbuilt\t0\t38\nstale\tstale\t\t0\ncompiles-not\tbuild-failed\t\t12\n"
        map (^. #outcome) (readSweepResults entries rows) @?= [Killed, Survived, Stale, Killed, NotRun]
    , testCase "a mutation manifest entry names its suite, pattern and expectation (EP-180 M8)" $ do
        let entry = "[{\"record\":\"G7-x\",\"suite\":\"nagare-dsl\",\"pattern\":\"/a || b/\",\"expect\":\"test-fails\"}]"
        eitherDecode entry @?= Right [MutationRecord "G7-x" NagareDsl "/a || b/" TestFails]
        assertBool "an unknown suite decoded" (isLeft (eitherDecode "[{\"record\":\"x\",\"suite\":\"other\",\"pattern\":\"/x/\",\"expect\":\"test-fails\"}]" :: Either String [MutationRecord]))
    , testCase "the fast gate runs the static checks, which take seconds, then both builds and the record patterns, before both suites" $
        map (^. #name) fastSteps
          @?= ["haskell-style-check", "architecture-and-command-audit", "registry-credential-delegation", "mutation-records", "nagarectl-build", "nagare-dsl-build", "mutation-patterns", "nagarectl-test", "nagare-dsl-test"]
    , testGroup
        "dry-run realisation"
        [ testCase "nothing to build or fetch leaves nothing remaining" $
            remainingPaths "warning: Git tree is dirty\nUsing saved setting for 'extra-substituters'\n" @?= []
        , testCase "derivations to build and paths to fetch both remain" $
            remainingPaths
              ( "these 2 derivations will be built:\n\
                \  /nix/store/aaa-check-one.drv\n\
                \  /nix/store/bbb-check-two.drv\n\
                \this path will be fetched (1.0 MiB download, 4.0 MiB unpacked):\n\
                \  /nix/store/ccc-dep\n\
                \warning: unrelated /nix/store/ddd-mentioned\n"
              )
              @?= ["/nix/store/aaa-check-one.drv", "/nix/store/bbb-check-two.drv", "/nix/store/ccc-dep"]
        , testCase "a single derivation header is read" $
            remainingPaths "this derivation will be built:\n  /nix/store/eee-probe.drv\n" @?= ["/nix/store/eee-probe.drv"]
        ]
    , testGroup
        "fixture smoke manifest"
        [ testCase "accounts for every fixture application and keeps the scenario-b negative" $ do
            let fixtures = "../../fixtures/inventory-release/local"
            manifest <- either fail pure =<< eitherDecodeFileStrict @Manifest (fixtures </> "fixture-smoke.json")
            apps <- listDirectory (fixtures </> "apps")
            sort (map (^. #directory) (manifest ^. #entries)) @?= sort (map ("apps" </>) apps)
            map (^. #directory) (manifest ^. #negative) @?= ["apps/scenario-b"]
        , testCase "a binding becomes its service URL on the smoke network" $
            bindingEnvironment ("svc-" <>) [Binding {env = "REDIS_URL", service = "redis"}]
              @?= Right [("REDIS_URL", "redis://svc-redis:6379/0")]
        , testCase "an unknown service is refused" $
            assertBool "unknown service accepted" (isLeft (bindingEnvironment id [Binding {env = "X", service = "mongo"}]))
        ]
    , testGroup
        "gate verify"
        [ testCase "a green, clean, fully realised record for the exact tree passes" $
            assertBool "green record refused" (isRight (verifyRecord target (Just greenRecord)))
        , testCase "a missing record is refused" $
            assertBool "missing record accepted" (isLeft (verifyRecord target Nothing))
        , testCase "a red record is refused" $
            assertBool "red record accepted" (isLeft (verifyRecord target (Just (greenRecord & #green .~ False))))
        , testCase "a dirty-tree record is refused" $
            assertBool "dirty record accepted" (isLeft (verifyRecord target (Just (greenRecord & #clean .~ False))))
        , testCase "a record for another tree is refused" $
            assertBool "tree mismatch accepted" (isLeft (verifyRecord target (Just (greenRecord & #tree .~ "other-tree"))))
        , testCase "a supported system without a realised record is refused" $
            assertBool "missing system accepted" (isLeft (verifyRecord target (Just (greenRecord & #systems %~ Map.delete "x86_64-linux"))))
        , testCase "a system with checks still missing is refused" $
            assertBool
              "partial realisation accepted"
              ( isLeft
                  ( verifyRecord
                      target
                      (Just (greenRecord & #systems %~ Map.insert "x86_64-linux" (SystemRealisation 35 0 ["/nix/store/x.drv"])))
                  )
              )
        , testCase "a failed builder probe is refused" $
            assertBool "failed probe accepted" (isLeft (verifyRecord target (Just (greenRecord & #builderProbe . #ok .~ False))))
        ]
    ]

target :: VerifyTarget
target = VerifyTarget {commit = "c0ffee", tree = "7ree", supportedSystems = ["x86_64-linux", "aarch64-darwin"]}

greenRecord :: GateRecord
greenRecord =
  GateRecord
    { version = 1
    , commit = "c0ffee"
    , tree = "7ree"
    , clean = True
    , steps = []
    , systems =
        Map.fromList
          [ ("aarch64-darwin", SystemRealisation 36 36 [])
          , ("x86_64-linux", SystemRealisation 35 35 [])
          ]
    , builderProbe = BuilderProbe {system = "x86_64-linux", ok = True}
    , tools = Map.empty
    , green = True
    }
