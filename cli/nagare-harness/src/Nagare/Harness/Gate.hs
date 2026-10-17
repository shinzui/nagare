-- | The local gate (EP-174). The fast gate is the style check, the
-- architecture check, the mutation records and both Haskell suites, built
-- incrementally and run serially, stopping at the first failure. On a tree
-- with no uncommitted changes it writes a fast record, which is what
-- @just land@ needs; the full gate then runs on the landed commit in the
-- background, and a release needs a full record.
module Nagare.Harness.Gate
  ( CheckPlan (..)
  , GateRun (..)
  , fastSteps
  , formatResult
  , fullCheckPlan
  , coveredRevision
  , coveringFastRecord
  , fastGateAt
  , fullGateAt
  , landableRevision
  , newLogDir
  , newSay
  , postLandGate
  , repositoryRoot
  , probeUntilUp
  , reuseFastRecord
  , runCheckPlan
  , runFastGate
  , runFullGate
  , verifyRevision
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently, withAsync)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Monad (forever, join)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Containers.ListUtils (nubOrd)
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Vector qualified as Vector
import Nagare.Harness.CarryForward (carryForwardVerdict, referenceNeedles)
import Nagare.Harness.FlakeCheck
import Nagare.Harness.Prelude
import Nagare.Harness.Realise (remainingPaths)
import Nagare.Harness.Record
import Nagare.Harness.Slot (Slot (..), runningRevisions, withRunMarker, withSlot)
import Nagare.Harness.Step
import Nagare.Harness.Verify (VerifyTarget (..), landedGateBlock, verifyFastRecord, verifyRecord)
import System.Directory (XdgDirectory (XdgState), createDirectoryIfMissing, getXdgDirectory)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hFlush, stdout)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode, readProcess)
import System.Random.Stateful (globalStdGen, uniformM)
import Text.Printf (printf)

-- | Where a gate run executes and logs, and the harness its harness steps
-- run: the running executable, never a @cabal run@ in a shared checkout.
data GateRun = GateRun
  { root :: !FilePath
  , logDir :: !FilePath
  , harness :: !FilePath
  }
  deriving stock (Eq, Show, Generic)

-- | The fast gate, in order. The static checks take seconds, so they run
-- first: a style, architecture or mutation-record failure stops the gate
-- before minutes of builds and tests. @haskell-style-check@ is fourmolu, cabal-gild and the
-- style rules. The architecture step is the flake's @managed-command-audit@
-- check: the CLI and Haskell architecture checks and their tests, and the
-- managed-command audit (every just recipe and mutating command registered,
-- catalogue current). The config-loader tests compile fixture configs
-- against the @.ghc.environment.*@ file cabal writes, which two things can
-- leave missing in a fresh checkout: @--project-dir@ from the root writes it
-- into the root, and @cabal test@ writes it only after the tests have run. So
-- each suite is built, then tested, from its package directory. The suites run
-- serially because those tests also fail during a concurrent cabal rebuild.
--
-- The mutation records (EP-180 M8) are checked twice: that each still applies
-- and has a manifest entry, with the static checks, and that each one's test
-- pattern selects a test of its built suite, once both suites are built and
-- before they run. A record that applies to nothing or names no test proves
-- nothing (F76).
fastSteps :: FilePath -> [Step]
fastSteps self = staticSteps self <> suiteSteps self

-- | The static checks: seconds each.
staticSteps :: FilePath -> [Step]
staticSteps self =
  [ Step "haskell-style-check" "." "just" ["haskell-style-check"]
  , Step "architecture-and-command-audit" "." "bash" ["scripts/test-managed-command-audit.sh"]
  , -- F31: the rendered registry-refresh timer against a recording API.
    Step "registry-credential-delegation" "." "python3" ["scripts/test-registry-credential-delegation.py"]
  , harnessStep self "mutation-records" ["mutations", "check"]
  ]

-- | The suite builds, the record patterns, and the suites: minutes.
suiteSteps :: FilePath -> [Step]
suiteSteps self = buildSteps self <> testSteps

-- | The suite builds and the record patterns, which need the built suites.
buildSteps :: FilePath -> [Step]
buildSteps self =
  [ Step "nagarectl-build" "cli/nagarectl" "cabal" ["build", "nagarectl-test"]
  , Step "nagare-dsl-build" "cli/nagare-dsl" "cabal" ["build", "nagare-dsl-test"]
  , Step "nagare-api-server-build" "cli/nagarectl" "cabal" ["build", "nagare-api-server-test"]
  , harnessStep self "mutation-patterns" ["mutations", "patterns"]
  ]

-- | The suites; nagarectl's runs one process per core ("Nagare.Test.Shards").
testSteps :: [Step]
testSteps =
  [ Step "nagarectl-test" "cli/nagarectl" "cabal" ["test", "nagarectl-test"]
  , Step "nagare-dsl-test" "cli/nagare-dsl" "cabal" ["test", "nagare-dsl-test"]
  , Step "nagare-api-server-test" "cli/nagarectl" "cabal" ["test", "nagare-api-server-test"]
  ]

harnessStep :: FilePath -> Text -> [String] -> Step
harnessStep self name = Step name "." self

repositoryRoot :: IO FilePath
repositoryRoot = filter (/= '\n') <$> readProcess "git" ["rev-parse", "--show-toplevel"] ""

-- | A fresh log directory under @$XDG_STATE_HOME/nagare/gates/logs@.
newLogDir :: IO FilePath
newLogDir = do
  base <- getXdgDirectory XdgState "nagare/gates/logs"
  stamp <- formatTime defaultTimeLocale "%Y%m%dT%H%M%S%QZ" <$> getCurrentTime
  let directory = base </> stamp
  createDirectoryIfMissing True directory
  pure directory

formatResult :: StepResult -> String
formatResult result =
  printf
    "gate: %-32s %-4s (%.1f s)"
    (T.unpack (result ^. #name))
    (if stepSucceeded result then "ok" else "FAIL" :: String)
    (result ^. #seconds)

-- | Print lines as one block. The full gate reports from concurrent steps, so
-- a step's failure report is never interleaved with another's line.
newSay :: IO ([String] -> IO ())
newSay = do
  lock <- newMVar ()
  pure $ \linesOut -> withMVar lock $ \() -> mapM_ putStrLn linesOut >> hFlush stdout

-- | Report one result; for a failure, also show the end of its log.
reportResult :: ([String] -> IO ()) -> StepResult -> IO ()
reportResult say result
  | stepSucceeded result = say [formatResult result]
  | otherwise = do
      output <- TE.decodeUtf8Lenient <$> BS.readFile (result ^. #logPath)
      let tailLines = reverse (take 60 (reverse (T.lines output)))
      say ([formatResult result, "gate: last lines of " <> result ^. #logPath <> ":"] <> map (T.unpack . ("  " <>)) tailLines)

-- | Run the fast gate. Returns the results, ending at the first failure. When
-- the tracked files match HEAD before and after the run, it writes HEAD's fast
-- record, green or red. Untracked files are ignored: the operator's checkout
-- often holds some, and they are not part of the commit.
runFastGate :: GateRun -> IO [StepResult]
runFastGate run = do
  let workdir = run ^. #root
  say <- newSay
  before <- trackedChanges workdir
  let steps = fastSteps (run ^. #harness)
  results <- runSteps (reportResult say) workdir (run ^. #logDir) steps
  let green = all stepSucceeded results && length results == length steps
  putStrLn (if green then "gate: fast gate green" else "gate: fast gate RED")
  after <- trackedChanges workdir
  if T.null before && T.null after
    then do
      commitId <- captureLine workdir "git" ["rev-parse", "HEAD"]
      treeId <- captureLine workdir "git" ["rev-parse", "HEAD^{tree}"]
      path <- writeFastRecord FastRecord {version = 1, commit = commitId, tree = treeId, steps = results, green}
      putStrLn ("gate: fast record " <> path <> (if green then " (green)" else " (RED)"))
    else putStrLn "gate: uncommitted changes, so no fast record; commit them and rerun to land"
  pure results
  where
    trackedChanges workdir = captureLine workdir "git" ["status", "--porcelain", "--untracked-files=no"]

-- | Run a command in @workdir@ and capture its output.
capture :: FilePath -> FilePath -> [String] -> IO (ExitCode, Text, Text)
capture workdir program arguments = do
  (code, out, err) <- readCreateProcessWithExitCode (proc program arguments) {cwd = Just workdir} ""
  pure (code, T.pack out, T.pack err)

captureLine :: FilePath -> FilePath -> [String] -> IO Text
captureLine workdir program arguments = do
  (_, out, _) <- capture workdir program arguments
  pure (T.strip out)

-- | The systems a revision's @release.json@ supports.
supportedSystemsAt :: FilePath -> Text -> IO (Either Text [Text])
supportedSystemsAt workdir revision = do
  (code, out, err) <- capture workdir "git" ["show", T.unpack revision <> ":release.json"]
  pure $ case code of
    ExitFailure _ -> Left ("cannot read release.json at " <> revision <> ": " <> T.strip err)
    ExitSuccess -> case eitherDecodeStrict (TE.encodeUtf8 out) of
      Right (Object fields)
        | Just (Array values) <- KeyMap.lookup "supportedSystems" fields
        , let systems = [value | String value <- Vector.toList values]
        , not (null systems) ->
            Right systems
      Right _ -> Left "release.json has no supportedSystems list"
      Left err' -> Left ("release.json: " <> T.pack err')

-- | The builder probe: a salted trivial derivation for @system@, so neither a
-- cache nor an earlier build can stand in for a working builder.
probeStep :: Text -> Text -> Step
probeStep system salt =
  Step
    { name = "builder-probe-" <> system
    , directory = "."
    , program = "nix"
    , arguments =
        [ "build"
        , "--no-link"
        , "--impure"
        , "--expr"
        , T.unpack $
            "derivation { name = \"nagare-builder-probe\"; system = \""
              <> system
              <> "\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo "
              <> salt
              <> " > $out\" ]; }"
        ]
    }

-- | The full gate's checks after the builder probe (EP-184 M2).
data CheckPlan = CheckPlan
  { static :: ![Step]
  -- ^ Seconds each; run first, and a failure stops everything else.
  , suite :: ![Step]
  -- ^ Run in order, stopping at the first failure, alongside @flake@.
  , flake :: !Step
  -- ^ Started with @suite@ and always run to its end (it keeps going).
  , pollMicroseconds :: !Int
  -- ^ How often @flake@'s log is read for new failures.
  , beforeRetry :: ![Step]
  -- ^ Run, all green, before @flake@ runs a second time because it lost the
  -- remote builder and nothing else failed ('builderLostOnly'): the builder
  -- probes, tried as 'probeUntilUp' tries them.
  , probePauseMicroseconds :: !Int
  -- ^ The pause between two tries of @beforeRetry@.
  }
  deriving stock (Eq, Show, Generic)

-- | The full gate runs each suite once: the flake check's @aarch64-darwin@
-- and @x86_64-linux@ derivations run both suites, built hermetically, so the
-- local @cabal test@ steps are not repeated here. The local builds stay for
-- the record patterns, and are already built when the fast gate ran.
fullCheckPlan :: FilePath -> CheckPlan
fullCheckPlan self =
  CheckPlan
    { static = staticSteps self
    , suite = buildSteps self
    , flake = flakeCheckStep
    , pollMicroseconds = 10000000
    , beforeRetry = []
    , probePauseMicroseconds = probePause
    }

-- | The full gate's check plan, and the step results that stand in for the
-- steps it leaves out (EP-200 M2). A green fast record that covers the tree
-- ('coveringFastRecord') already ran the static checks, the suite builds and
-- the record patterns on the same input, so the full gate runs only the flake
-- check; without one, the plan is unchanged.
reuseFastRecord :: Maybe FastRecord -> CheckPlan -> (CheckPlan, Maybe [StepResult])
reuseFastRecord covering plan = case covering of
  Just recorded
    | recorded ^. #green ->
        (plan & #static .~ [] & #suite .~ [], Just (recorded ^. #steps))
  _ -> (plan, Nothing)

-- | The green fast record that covers a commit's tree, as landing accepts it:
-- the commit's own, or one carried forward from a fast-gated commit over
-- inert documentation.
coveringFastRecord :: FilePath -> Text -> IO (Maybe FastRecord)
coveringFastRecord workdir commitId = do
  own <- verifyOwnFastRecord workdir commitId
  case own of
    Right (Just _) -> either (const Nothing) id <$> readFastRecord commitId
    Left _ -> pure Nothing
    Right Nothing -> do
      carried <- carryForwardWith workdir (verifyOwnFastRecord workdir) (pure []) commitId
      case carried of
        Right (ancestor, _, _) -> either (const Nothing) id <$> readFastRecord ancestor
        Left _ -> pure Nothing

-- | @Right (Just [])@ when the commit's own fast record is green for its
-- tree, @Right Nothing@ when it has none, @Left@ when it is unusable.
verifyOwnFastRecord :: FilePath -> Text -> IO (Either Text (Maybe [Text]))
verifyOwnFastRecord workdir commitId = do
  treeId <- captureLine workdir "git" ["rev-parse", T.unpack commitId <> "^{tree}"]
  stored <- readFastRecord commitId
  pure $ case stored of
    Left err -> Left err
    Right Nothing -> Right Nothing
    Right present -> Just [] <$ verifyFastRecord commitId treeId present

-- | Run the builder probes until they all pass, at most three times,
-- @pause@ microseconds apart, and return the last try. The builder VM stops
-- itself when an idle check finds no SSH connection and no build (the
-- watchdog in scripts/nix-builder-startup.sh.tpl), even in the middle of a
-- gate. Started again, it needs about 30 s before SSH answers, longer than
-- Nix's 10 s connect timeout, so the probe that wakes it fails and a later
-- one passes (2026-10-14: guestTerminate at 18:29Z, start at 18:45:09Z, first
-- connection at 18:45:38Z).
probeUntilUp :: Int -> (StepResult -> IO ()) -> FilePath -> FilePath -> [Step] -> IO [StepResult]
probeUntilUp pause report workdir logDir steps = go (3 :: Int)
  where
    go tries = do
      results <- runSteps report workdir logDir steps
      if tries <= 1 || (length results == length steps && all stepSucceeded results)
        then pure results
        else threadDelay pause >> go (tries - 1)

-- | 45 s between probe tries: a woken builder answers SSH within about 30 s.
probePause :: Int
probePause = 45000000

-- | Every step 'runCheckPlan' runs for a check plan, in order.
planSteps :: CheckPlan -> [Step]
planSteps plan = plan ^. #static <> plan ^. #suite

-- | Run the static checks; when they pass, run the suite and the flake check
-- at the same time. Each flake failure is reported as soon as its log shows
-- it, and the flake check runs to its end even after a suite step fails, so
-- one gate run reports every failing check. A flake check that lost the
-- remote builder, with no build or test failing, runs once more after the
-- @beforeRetry@ steps pass; everything it already built is cached, so the
-- second run costs about a minute. Returns the static and suite results (the
-- fast gate's steps, in order) and the flake results: the first run, then any
-- @beforeRetry@ steps and the second run. The last one decides.
runCheckPlan :: ([String] -> IO ()) -> FilePath -> FilePath -> CheckPlan -> IO ([StepResult], [StepResult])
runCheckPlan say workdir logDir plan = do
  static <- runSteps (reportResult say) workdir logDir (plan ^. #static)
  if length static /= length (plan ^. #static) || not (all stepSucceeded static)
    then pure (static, [])
    else do
      (suite, flake) <- concurrently (runSteps reportSuite workdir logDir (plan ^. #suite)) runFlakeOnceMore
      pure (static <> suite, flake)
  where
    flakeName = T.unpack (plan ^. #flake . #name)
    reportSuite result = do
      reportResult say result
      unless (stepSucceeded result) $
        say ["gate: RED; " <> flakeName <> " keeps going to report every failing check (interrupt the gate to stop it)"]
    reportFailures = mapM_ (\failure -> say ["gate: " <> flakeName <> ": FAILED " <> T.unpack (renderFailure failure) <> " (the other checks keep going)"])
    runFlakeOnceMore = do
      first <- runFlake (plan ^. #flake)
      output <- TE.decodeUtf8Lenient <$> BS.readFile (first ^. #logPath)
      if stepSucceeded first || not (builderLostOnly output)
        then pure [first]
        else do
          say ["gate: " <> flakeName <> " lost the remote builder and no build failed; probing the builder and running it once more"]
          probes <- probeUntilUp (plan ^. #probePauseMicroseconds) (reportResult say) workdir logDir (plan ^. #beforeRetry)
          if length probes /= length (plan ^. #beforeRetry) || not (all stepSucceeded probes)
            then pure (first : probes)
            else do
              second <- runFlake (plan ^. #flake & #name %~ (<> "-retry"))
              pure (first : probes <> [second])
    runFlake step = do
      let name = T.unpack (step ^. #name)
          logPath = logDir </> (name <> ".log")
      follower <- newLogFollower logPath
      result <- withAsync (forever (threadDelay (plan ^. #pollMicroseconds) >> followLog follower >>= reportFailures)) $ \_ ->
        runStep workdir logDir step
      followLog follower >>= reportFailures
      reportResult say result
      unless (stepSucceeded result) $ do
        failures <- summaryFailures . flakeFailures . TE.decodeUtf8Lenient <$> BS.readFile logPath
        say (("gate: " <> name <> " failed checks (" <> show (length failures) <> "):") : ["gate:   " <> T.unpack (renderFailure failure) | failure <- failures])
      pure result

-- | Dry-run every check attribute of @system@; anything left to build or
-- fetch means the flake check did not realise it.
realise :: FilePath -> Text -> IO (Either Text SystemRealisation)
realise workdir system = do
  (code, out, err) <- capture workdir "nix" ["eval", ".#checks." <> T.unpack system, "--apply", "builtins.attrNames", "--json"]
  case (code, eitherDecodeStrict (TE.encodeUtf8 out)) of
    (ExitSuccess, Right names) | not (null names) -> do
      let installables = [".#checks." <> T.unpack system <> "." <> T.unpack attr | attr <- names :: [Text]]
      (dryCode, dryOut, dryErr) <- capture workdir "nix" (["build", "--no-link", "--dry-run"] <> installables)
      let remaining = remainingPaths (dryOut <> "\n" <> dryErr)
          total = length names
      pure $ case dryCode of
        ExitFailure _ -> Left ("dry run failed for " <> system <> ": " <> lastLines dryErr)
        ExitSuccess ->
          Right
            SystemRealisation
              { checks = total
              , realised = if null remaining then total else 0
              , remaining
              }
    (ExitSuccess, _) -> pure (Left ("no checks listed for " <> system))
    (ExitFailure _, _) -> pure (Left ("cannot list checks for " <> system <> ": " <> lastLines err))
  where
    lastLines = T.unlines . reverse . take 5 . reverse . T.lines

-- | The full gate: clean tree, builder probe for every remote system, the
-- static checks, then the suite builds and @nix flake check --all-systems@
-- at the same time ('runCheckPlan'), a realisation proof per system, and a
-- record. Returns the record (green or red) when one was written.
runFullGate :: GateRun -> IO (Either Text GateRecord)
runFullGate run = do
  let workdir = run ^. #root
  started <- getCurrentTime
  status <- captureLine workdir "git" ["status", "--porcelain"]
  if not (T.null status)
    then pure (Left "the full gate needs a clean tree (git status --porcelain is not empty)")
    else do
      commitId <- captureLine workdir "git" ["rev-parse", "HEAD"]
      treeId <- captureLine workdir "git" ["rev-parse", "HEAD^{tree}"]
      localSystem <- captureLine workdir "nix" ["eval", "--impure", "--raw", "--expr", "builtins.currentSystem"]
      supported <- supportedSystemsAt workdir commitId
      case supported of
        Left err -> pure (Left err)
        Right systems -> do
          let remoteSystems = filter (/= localSystem) systems
          salt <- T.pack . show <$> uniformM @Word globalStdGen
          say <- newSay
          -- The builder probe runs first, and wakes a stopped builder VM: a
          -- gate that probed only after the fast steps found it gone
          -- (2026-10-07).
          probes <- probeUntilUp probePause (reportResult say) workdir (run ^. #logDir) [probeStep system salt | system <- remoteSystems]
          let probesGreen = length probes == length remoteSystems && all stepSucceeded probes
          unless probesGreen $
            putStrLn
              ( "gate: builder unreachable for "
                  <> T.unpack (T.intercalate ", " remoteSystems)
                  <> " after three probes; nothing else ran. Check that the builder VM starts"
                  <> " (scripts/setup-nix-builder.sh), then rerun the gate."
              )
          covering <- coveringFastRecord workdir commitId
          let (plan, reused) =
                reuseFastRecord covering $
                  fullCheckPlan (run ^. #harness) & #beforeRetry .~ [probeStep system ("retry-" <> salt) & #name %~ (<> "-retry") | system <- remoteSystems]
          forM_ reused $ \_ ->
            putStrLn ("gate: the green fast record of " <> maybe "" (T.unpack . (^. #commit)) covering <> " covers this tree's static checks and suite builds; they are not run again")
          (ran, flake) <-
            if probesGreen
              then runCheckPlan say workdir (run ^. #logDir) plan
              else pure ([], [])
          let fastGreen = probesGreen && length ran == length (planSteps plan) && all stepSucceeded ran
              fast = fromMaybe ran reused
              -- A flake check run a second time after losing the builder
              -- ('runCheckPlan') is decided by its last run.
              flakeGreen =
                fastGreen && case reverse flake of
                  latest : _ -> stepSucceeded latest
                  [] -> False
          realisations <-
            if flakeGreen
              then forM systems $ \system -> do
                result <- realise workdir system
                case result of
                  Left err -> do
                    putStrLn ("gate: realisation " <> T.unpack system <> " FAIL: " <> T.unpack err)
                    pure (system, SystemRealisation {checks = 0, realised = 0, remaining = [err]})
                  Right realisation -> do
                    printf
                      "gate: realised %s %d/%d\n"
                      (T.unpack system)
                      (realisation ^. #realised)
                      (realisation ^. #checks)
                    unless (null (realisation ^. #remaining)) $
                      mapM_ (putStrLn . ("gate:   still missing " <>) . T.unpack) (realisation ^. #remaining)
                    pure (system, realisation)
              else pure []
          ghcVersion <- captureLine workdir "ghc" ["--numeric-version"]
          cabalVersion <- captureLine workdir "cabal" ["--numeric-version"]
          nixVersion <- captureLine workdir "nix" ["--version"]
          let systemMap = Map.fromList realisations
              allRealised =
                flakeGreen
                  && all
                    ( \system -> case Map.lookup system systemMap of
                        Just realisation -> realisation ^. #checks > 0 && realisation ^. #realised == realisation ^. #checks
                        Nothing -> False
                    )
                    systems
              record =
                GateRecord
                  { version = 1
                  , commit = commitId
                  , tree = treeId
                  , clean = True
                  , steps = probes <> fast <> flake
                  , systems = systemMap
                  , builderProbe =
                      BuilderProbe
                        { system = T.intercalate "," remoteSystems
                        , ok = probesGreen
                        }
                  , tools = Map.fromList [("ghc", ghcVersion), ("cabal", cabalVersion), ("nix", nixVersion)]
                  , green = allRealised
                  }
          -- A tree changed during the run would make the record lie.
          after <- captureLine workdir "git" ["status", "--porcelain"]
          let final = if T.null after then record else record & #clean .~ False & #green .~ False
          path <- writeRecord final
          finished <- getCurrentTime
          printf "gate: wall %.0f s\n" (realToFrac (diffUTCTime finished started) :: Double)
          putStrLn ("gate: record " <> path <> (if final ^. #green then " (green)" else " (RED)"))
          pure (Right final)

-- | Refuse a revision without a green, clean, fully realised gate record for
-- its exact tree. A revision with no record of its own may carry forward the
-- record of its nearest gated ancestor, or of any recently gated commit, when
-- every path between the two trees is inert documentation
-- ("Nagare.Harness.CarryForward"). A revision whose own
-- record is red never carries forward.
verifyRevision :: FilePath -> Text -> IO (Either Text Text)
verifyRevision workdir revision = do
  (code, out, err) <- capture workdir "git" ["rev-parse", "--verify", T.unpack revision <> "^{commit}"]
  case code of
    ExitFailure _ -> pure (Left ("unknown revision " <> revision <> ": " <> T.strip err))
    ExitSuccess -> do
      let commitId = T.strip out
      own <- verifyOwnRecord workdir commitId
      case own of
        Right (Just systems) -> pure (Right (summary commitId systems))
        Left refusal -> pure (Left refusal)
        Right Nothing -> do
          carried <- carryForwardRecord workdir commitId
          pure $ case carried of
            Right (ancestor, paths, systems) ->
              Right
                ( summary commitId systems
                    <> " (carried forward from "
                    <> ancestor
                    <> ": "
                    <> T.pack (show paths)
                    <> " changed paths, all inert documentation)"
                )
            Left refusal -> Left ("no gate record for " <> commitId <> ", and no carry-forward: " <> refusal <> "; run `just gate` on a clean checkout of it")
  where
    summary commitId systems = commitId <> " green, systems " <> T.unwords systems

-- | @Right (Just systems)@ when the commit's own record verifies, @Right
-- Nothing@ when it has no record, and @Left@ when its record is unusable.
verifyOwnRecord :: FilePath -> Text -> IO (Either Text (Maybe [Text]))
verifyOwnRecord workdir commitId = do
  treeId <- captureLine workdir "git" ["rev-parse", T.unpack commitId <> "^{tree}"]
  supported <- supportedSystemsAt workdir commitId
  stored <- readRecord commitId
  pure $ do
    record <- stored
    case record of
      Nothing -> Right Nothing
      Just present -> do
        systems <- supported
        verifyRecord VerifyTarget {commit = commitId, tree = treeId, supportedSystems = systems} (Just present)
        Right (Just systems)

-- | The nearest ancestor (within 500 commits) whose own record verifies, and
-- the verdict on the paths that differ between its tree and the commit's.
-- When that ancestor's difference is blocked, any recently gated commit whose
-- tree differs from this one only by inert documentation carries forward too:
-- the gate's result depends on the tree alone, so a code commit rebased over
-- documentation keeps the record it earned before the rebase.
carryForwardRecord :: FilePath -> Text -> IO (Either Text (Text, Int, [Text]))
carryForwardRecord workdir = carryForwardWith workdir (verifyOwnRecord workdir) (recentRecordCommits 50)

-- | 'carryForwardRecord' over any kind of record: @verifyOwn@ verifies a
-- commit's own record, and @siblings@ lists recently gated commits to try
-- when the nearest gated ancestor is blocked.
carryForwardWith :: FilePath -> (Text -> IO (Either Text (Maybe [Text]))) -> IO [Text] -> Text -> IO (Either Text (Text, Int, [Text]))
carryForwardWith workdir verifyOwn siblings commitId = do
  (_, listed, _) <- capture workdir "git" ["rev-list", "--max-count=500", T.unpack commitId <> "^@"]
  ancestor <- firstGreen (T.lines listed)
  nearest <- case ancestor of
    Nothing -> pure (Left "no ancestor within 500 commits has a green gate record")
    Just (ancestorId, systems) ->
      first (\blocked -> "nearest gated ancestor " <> ancestorId <> "; blocked by " <> blocked)
        <$> verdictFrom ancestorId systems
  case nearest of
    Right carried -> pure (Right carried)
    Left refusal -> maybe (Left refusal) Right <$> (firstSibling . filter (`notElem` (commitId : T.lines listed)) =<< siblings)
  where
    verdictFrom gatedId systems = do
      changed <- changedPaths gatedId
      named <- forM (nubOrd (concatMap referenceNeedles changed)) $ \needle -> (needle,) <$> namingFile needle
      let namedBy needle = join (lookup needle named)
      pure ((gatedId,,systems) <$> carryForwardVerdict namedBy changed)
    changedPaths gatedId = do
      (_, diffed, _) <- capture workdir "git" ["diff", "-z", "--name-only", "--no-renames", T.unpack gatedId, T.unpack commitId]
      pure (filter (not . T.null) (T.splitOn "\0" diffed))
    -- A recently gated commit that is not an ancestor, such as this commit
    -- before a rebase. Paths that are not inert on their face skip the
    -- naming search.
    firstSibling = \case
      [] -> pure Nothing
      candidate : rest -> do
        (exists, _, _) <- capture workdir "git" ["cat-file", "-e", T.unpack candidate <> "^{commit}"]
        own <- if exists == ExitSuccess then verifyOwn candidate else pure (Right Nothing)
        case own of
          Right (Just systems) -> do
            changed <- changedPaths candidate
            if isRight (carryForwardVerdict (const Nothing) changed)
              then verdictFrom candidate systems >>= either (const (firstSibling rest)) (pure . Just)
              else firstSibling rest
          _ -> firstSibling rest
    firstGreen = \case
      [] -> pure Nothing
      candidate : rest -> do
        own <- verifyOwn candidate
        case own of
          Right (Just systems) -> pure (Just (candidate, systems))
          _ -> firstGreen rest
    -- The first non-Markdown file outside docs/ in the commit's tree that
    -- names the needle.
    namingFile needle = do
      (_, found, _) <- capture workdir "git" ["grep", "-l", "-I", "-F", "-e", T.unpack needle, T.unpack commitId, "--", ".", ":(exclude)docs", ":(exclude,glob)**/*.md"]
      pure $ case T.lines found of
        hit : _ -> Just (fromMaybe hit (T.stripPrefix (commitId <> ":") hit))
        [] -> Nothing

-- | Whether a landed revision needs a full gate of its own. It does not when
-- its own or a carried-forward record verifies, or when the nearest ancestor
-- that has a green record or a full gate waiting or running
-- ('runningRevisions') differs from it only by inert documentation: that
-- gate's record carries forward once it finishes.
coveredRevision :: FilePath -> Text -> IO (Either Text Text)
coveredRevision workdir revision = do
  verified <- verifyRevision workdir revision
  case verified of
    Right summary -> pure (Right summary)
    Left refusal -> do
      commitId <- captureLine workdir "git" ["rev-parse", T.unpack revision <> "^{commit}"]
      running <- runningRevisions
      let gatedOrRunning candidate = do
            own <- verifyOwnRecord workdir candidate
            case own of
              Right (Just systems) -> pure (Right (Just systems))
              _ -> pure (Right (if candidate `elem` running then Just [] else Nothing))
      carried <- carryForwardWith workdir gatedOrRunning (pure []) commitId
      pure $ case carried of
        Right (ancestor, paths, _) ->
          Right (commitId <> " covered by the full gate of " <> ancestor <> " over " <> T.pack (show paths) <> " inert paths")
        Left _ -> Left refusal

-- | Whether @just land@ may push a revision. A green full record (its own or
-- carried forward) always may: that is how a fix lands. Otherwise the newest
-- finished full gate of a commit already on @base@ must not be red, and the
-- revision needs a green fast record, its own or carried forward from a
-- fast-gated ancestor over inert documentation.
landableRevision :: FilePath -> Text -> Text -> IO (Either Text Text)
landableRevision workdir base revision = do
  full <- verifyRevision workdir revision
  case full of
    Right summary -> pure (Right ("full gate: " <> summary))
    Left _ -> do
      (code, out, err) <- capture workdir "git" ["rev-parse", "--verify", T.unpack revision <> "^{commit}"]
      case code of
        ExitFailure _ -> pure (Left ("unknown revision " <> revision <> ": " <> T.strip err))
        ExitSuccess -> do
          let commitId = T.strip out
          landed <- landedFullGates
          case landedGateBlock landed of
            Just blocked -> pure (Left blocked)
            Nothing -> do
              own <- verifyOwnFastRecord workdir commitId
              case own of
                Right (Just _) -> pure (Right ("fast gate: " <> commitId <> " green"))
                Left refusal -> pure (Left refusal)
                Right Nothing -> do
                  carried <- carryForwardWith workdir (verifyOwnFastRecord workdir) (pure []) commitId
                  pure $ case carried of
                    Right (ancestor, paths, _) ->
                      Right ("fast gate: " <> commitId <> " carried forward from " <> ancestor <> " over " <> T.pack (show paths) <> " inert paths")
                    Left refusal -> Left ("no fast gate record for " <> commitId <> ", and no carry-forward: " <> refusal <> "; run `just gate-fast` on it")
  where
    landedFullGates = do
      recent <- recentRecordCommits 50
      fmap catMaybes . forM recent $ \commitId -> do
        (onBase, _, _) <- capture workdir "git" ["merge-base", "--is-ancestor", T.unpack commitId, T.unpack base]
        stored <- readRecord commitId
        pure $ case (onBase, stored) of
          (ExitSuccess, Right (Just record)) -> Just (commitId, record ^. #green)
          _ -> Nothing

-- | Run the fast gate on @revision@ in a gate slot ("Nagare.Harness.Slot").
-- @checkout@ is the checkout the gate was asked from; its uncommitted changes
-- are not part of the commit and are not gated.
fastGateAt :: FilePath -> Text -> IO (Either Text [StepResult])
fastGateAt checkout revision = inSlot checkout revision False $ \run -> Right <$> runFastGate run

-- | Run the full gate on @revision@ in a gate slot, marked as running for
-- 'coveredRevision' while it waits and runs.
fullGateAt :: FilePath -> Text -> IO (Either Text GateRecord)
fullGateAt checkout revision = inSlot checkout revision True runFullGate

-- | The post-land check of a landed revision: nothing when 'coveredRevision'
-- covers it, otherwise its full gate in a slot.
postLandGate :: FilePath -> Text -> IO (Either Text (Maybe GateRecord))
postLandGate checkout revision = do
  covered <- coveredRevision checkout revision
  case covered of
    Right summary -> do
      putStrLn ("gate post-land: " <> T.unpack summary <> "; no full gate needed")
      pure (Right Nothing)
    Left _ -> fmap Just <$> fullGateAt checkout revision

inSlot :: FilePath -> Text -> Bool -> (GateRun -> IO (Either Text a)) -> IO (Either Text a)
inSlot checkout revision marked action = do
  (code, out, err) <- capture checkout "git" ["rev-parse", "--verify", T.unpack revision <> "^{commit}"]
  case code of
    ExitFailure _ -> pure (Left ("unknown revision " <> revision <> ": " <> T.strip err))
    ExitSuccess -> do
      let commitId = T.strip out
      dirty <- captureLine checkout "git" ["status", "--porcelain", "--untracked-files=no"]
      unless (T.null dirty) $
        putStrLn ("gate: " <> checkout <> " has uncommitted changes; they are not part of " <> T.unpack commitId <> " and are not gated")
      self <- getExecutablePath
      logDir <- newLogDir
      (if marked then withRunMarker commitId else id) $
        withSlot checkout commitId $ \slot -> do
          printf "gate: slot %d, revision %s, worktree %s\n" (slot ^. #number) (T.unpack commitId) (slot ^. #tree)
          hFlush stdout
          action GateRun {root = slot ^. #tree, logDir, harness = self}
