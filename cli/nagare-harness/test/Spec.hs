{-# OPTIONS_GHC -Werror=unused-imports #-}

module Main (main) where

import Control.Exception (finally)
import Data.Aeson (eitherDecode, eitherDecodeFileStrict)
import Data.Either (isLeft, isRight)
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Harness.CarryForward
import Nagare.Harness.FixtureSmoke
import Nagare.Harness.Gate (fastSteps, verifyRevision)
import Nagare.Harness.Mutation (Expectation (..), MutationRecord (..), Outcome (..), Suite (..), classifyProof, readSweepResults)
import Nagare.Harness.Prelude
import Nagare.Harness.Realise (remainingPaths)
import Nagare.Harness.Record
import Nagare.Harness.RouteCheck
import Nagare.Harness.Step
import Nagare.Harness.Verify
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess, readProcess)
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
    , testGroup
        "documentation carry-forward (EP-170, operator 2026-10-09)"
        [ testCase "needles are the path and each directory below its inert prefix" $
            referenceNeedles "docs/audits/run/c2/chain.sh"
              @?= ["docs/audits/run", "docs/audits/run/c2", "docs/audits/run/c2/chain.sh"]
        , testCase "plans, MasterPlans, ADRs and audits nobody names are inert" $
            carryForwardVerdict (const Nothing) ["docs/plans/1-x.md", "docs/masterplans/2-y.md", "docs/adr/0001-z.md", "docs/audits/a/b.json"]
              @?= Right 4
        , testCase "an empty difference carries forward" $
            carryForwardVerdict (const Nothing) [] @?= Right 0
        , testCase "code, user guides, runbooks and release notes are not inert" $
            map
              (classifyPath (const Nothing))
              ["cli/nagarectl/src/X.hs", "docs/user/reference.md", "docs/runbooks/a.md", "docs/releases/v0.4.0.md", "release.json"]
              @?= replicate 5 OutsideInertDocumentation
        , testCase "plans the payload ships are not inert" $
            map (classifyPath (const Nothing)) shippedDocuments @?= replicate 2 ShippedInPayload
        , testCase "a fixture named by a test, or in a directory a test names, is not inert" $ do
            let namedBy needle = if needle == "docs/audits/k8s" then Just "cli/nagarectl/test/KSpec.hs" else Nothing
            classifyPath namedBy "docs/audits/k8s/experiments/e6e.out" @?= NamedByCode "cli/nagarectl/test/KSpec.hs"
            classifyPath namedBy "docs/audits/other/notes.md" @?= Inert
        , testCase "one blocking path refuses the whole difference" $
            assertBool "mixed difference accepted" (isLeft (carryForwardVerdict (const Nothing) ["docs/plans/1-x.md", "justfile"]))
        , testCase "gate verify carries a green record forward over inert documentation only" carryForwardRoundTrip
        ]
    , testGroup
        "route check (EP-183 M1)"
        [ testCase "a protected route that redirects, logs in, serves and enforces a revoke passes" $
            routeOutcome enforcing >>= (@?= Right ())
        , testCase "a wrong trust anchor that is accepted fails: verification is not enforced" $
            routeOutcome (enforcing {acceptsWrongCa = True}) >>= (@?= Left VerificationNotEnforced)
        , testCase "a route whose certificate the context's CA does not verify fails with a named reason" $
            routeOutcome (enforcing {verified = False}) >>= (@?= Left (CertificateNotTrusted "60: SSL certificate problem"))
        , testCase "an unprotected route fails: no redirect to the login page" $
            routeOutcome (enforcing {protected = False}) >>= (@?= Left (NotRedirectedToLogin 200 Nothing))
        , testCase "a revoke the enforcer ignores fails" $
            routeOutcome (enforcing {honoursRevoke = False}) >>= (@?= Left (RevokeNotEnforced 200))
        , testCase "a wrong password is a rejected login" $
            routeOutcome (enforcing {acceptsPassword = False}) >>= (@?= Left (LoginRejected 401))
        , testCase "a redirect to an operator portal is named, not driven" $
            loginTarget "a.example" (HttpResponse 302 [("location", "https://auth.example/login?return_to=x")] "")
              @?= Left (PortalLoginUnsupported "https://auth.example/login?return_to=x")
        , testCase "curl's last header block, its exit codes and shomei-admin's user id are read" $ do
            parseHeaders "HTTP/1.1 100 Continue\r\n\r\nHTTP/2 302\r\nLocation: /_nagare/login?rd=%2F\r\nSet-Cookie: a=b; Path=/\r\n\r\n"
              @?= [("location", "/_nagare/login?rd=%2F"), ("set-cookie", "a=b; Path=/")]
            curlFailure 60 "x" @?= TlsRejected "60: x"
            curlFailure 77 "x" @?= TlsRejected "77: x"
            curlFailure 7 "x" @?= Unreachable "7: x"
            parseCreatedUser "created user user_01k2abc <rc@example.test> (email verified)\n" @?= Right "user_01k2abc"
            assertBool "garbage read as a user" (isLeft (parseCreatedUser "error"))
        ]
    ]

-- | A scripted protected route: the enforcer's built-in login, grants and the
-- certificate, as switches the failure tests turn off one at a time.
data Route = Route
  { acceptsWrongCa :: !Bool
  , verified :: !Bool
  , protected :: !Bool
  , honoursRevoke :: !Bool
  , acceptsPassword :: !Bool
  }
  deriving stock (Generic)

enforcing :: Route
enforcing = Route False True True True True

routeOutcome :: Route -> IO (Either RouteFailure ())
routeOutcome route = do
  granted <- newIORef False
  password <- newIORef ""
  let handshake trust'
        | trust' == CaFile "wrong.pem" = if route ^. #acceptsWrongCa then Right () else Left (TlsRejected "60: SSL certificate problem")
        | not (route ^. #verified) = Left (TlsRejected "60: SSL certificate problem")
        | otherwise = Right ()
      http' trust' req = do
        isGranted <- readIORef granted
        expected <- readIORef password
        pure (handshake trust' >> Right (answer isGranted expected req))
      answer isGranted expected req = case (req ^. #method, req ^. #url) of
        ("GET", "https://a.example/")
          | not (route ^. #protected) -> HttpResponse 200 [] "rows: 3\n"
          | lookup "nagare_session" (req ^. #cookies) /= Just "s1" -> HttpResponse 302 [("location", "/_nagare/login?rd=%2F")] ""
          | isGranted -> HttpResponse 200 [] "rows: 3\n"
          | otherwise -> HttpResponse 403 [] "forbidden"
        ("GET", "https://a.example/_nagare/login?rd=%2F") -> HttpResponse 200 [("set-cookie", "__Host-nagare_csrf=tok; Secure; Path=/")] "<input type=\"hidden\" name=\"csrf\" value=\"tok\">"
        ("POST", "https://a.example/_nagare/login")
          | lookup "csrf" (req ^. #form) == Just "tok"
          , lookup "__Host-nagare_csrf" (req ^. #cookies) == Just "tok"
          , route ^. #acceptsPassword
          , lookup "password" (req ^. #form) == Just expected ->
              HttpResponse 302 [("location", "/"), ("set-cookie", "nagare_session=s1; HttpOnly"), ("set-cookie", "nagare_refresh=r1; HttpOnly")] ""
          | otherwise -> HttpResponse 401 [] "invalid login"
        _ -> HttpResponse 404 [] ""
      ops =
        RouteOps
          { http = http'
          , createUser = \_ secret -> writeIORef password secret >> pure (Right "user_01route")
          , grant = \_ -> writeIORef granted True >> pure (Right ())
          , revoke = \_ -> when (route ^. #honoursRevoke) (writeIORef granted False) >> pure (Right ())
          , newSecret = pure "0123456789abcdef"
          , pause = pure ()
          , progress = const (pure ())
          }
  runRouteCheck ops (RouteCheck "a.example" (CaFile "local-ca.pem") (CaFile "wrong.pem") "rows: " 3 3)

-- | A throwaway repository and gate-record directory: a gated base commit,
-- then documentation, fixture, code and red-record commits on top.
carryForwardRoundTrip :: Assertion
carryForwardRoundTrip =
  withSystemTempDirectory "carry" $ \dir -> do
    let repo = dir </> "repo"
        state = dir </> "state"
        git arguments = callProcess "git" (["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] <> arguments)
        write path content = createDirectoryIfMissing True (takeDirectory (repo </> path)) >> writeFile (repo </> path) content
        commitAll message = git ["add", "-A"] >> git ["commit", "-q", "-m", message] >> headOf
        headOf = T.strip . T.pack <$> readProcess "git" ["-C", repo, "rev-parse", "HEAD"] ""
        treeOf commitId = T.strip . T.pack <$> readProcess "git" ["-C", repo, "rev-parse", T.unpack commitId <> "^{tree}"] ""
        recordFor commitId isGreen = do
          treeId <- treeOf commitId
          _ <- writeRecord (greenRecord & #commit .~ commitId & #tree .~ treeId & #green .~ isGreen)
          pure ()
    createDirectoryIfMissing True repo
    git ["init", "-q"]
    write "release.json" "{\"supportedSystems\":[\"x86_64-linux\",\"aarch64-darwin\"]}"
    write "src/Spec.hs" "-- reads docs/audits/fixtures/known.json"
    write "docs/audits/fixtures/known.json" "{}"
    write "docs/plans/1-plan.md" "one"
    write "agents/skills/x/SKILL.md" "See docs/plans/1-plan.md and docs/audits/new-run."
    previous <- lookupEnv "XDG_STATE_HOME"
    flip finally (maybe (unsetEnv "XDG_STATE_HOME") (setEnv "XDG_STATE_HOME") previous) $ do
      setEnv "XDG_STATE_HOME" state
      base <- commitAll "base"
      recordFor base True
      write "docs/plans/1-plan.md" "two"
      write "docs/audits/new-run/README.md" "evidence"
      docsOnly <- commitAll "docs"
      verdict <- verifyRevision repo docsOnly
      assertBool ("documentation-only commit refused: " <> show verdict) (isRight verdict)
      write "docs/audits/fixtures/known.json" "{\"changed\":true}"
      fixture <- commitAll "fixture"
      assertBool "a fixture a test names carried forward" . isLeft =<< verifyRevision repo fixture
      git ["reset", "-q", "--hard", T.unpack docsOnly]
      write "src/Spec.hs" "-- changed"
      code <- commitAll "code"
      assertBool "a code change carried forward" . isLeft =<< verifyRevision repo code
      git ["reset", "-q", "--hard", T.unpack docsOnly]
      write "docs/plans/1-plan.md" "three"
      redOwn <- commitAll "red"
      recordFor redOwn False
      assertBool "a commit with its own red record carried forward" . isLeft =<< verifyRevision repo redOwn

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
