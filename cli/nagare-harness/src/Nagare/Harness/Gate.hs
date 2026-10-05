-- | The local gate (EP-174). The fast gate runs on every push through
-- @.githooks/pre-push@: both Haskell suites, the style check and the
-- architecture check, serially, stopping at the first failure.
module Nagare.Harness.Gate
  ( GateRun (..)
  , fastSteps
  , formatResult
  , newLogDir
  , repositoryRoot
  , runFastGate
  , runFullGate
  , verifyRevision
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Vector qualified as Vector
import Nagare.Harness.Prelude
import Nagare.Harness.Realise (remainingPaths)
import Nagare.Harness.Record
import Nagare.Harness.Step
import Nagare.Harness.Verify (VerifyTarget (..), verifyRecord)
import System.Directory (XdgDirectory (XdgState), createDirectoryIfMissing, getXdgDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode, readProcess)
import System.Random.Stateful (globalStdGen, uniformM)
import Text.Printf (printf)

-- | Where a gate run executes and logs.
data GateRun = GateRun
  { root :: !FilePath
  , logDir :: !FilePath
  }
  deriving stock (Eq, Show, Generic)

-- | The fast gate, in order. The config-loader tests compile fixture configs
-- against the @.ghc.environment.*@ file cabal writes, which two things can
-- leave missing in a fresh checkout: @--project-dir@ from the root writes it
-- into the root, and @cabal test@ writes it only after the tests have run. So
-- each suite is built, then tested, from its package directory. The suites run
-- serially because those tests also fail during a concurrent cabal rebuild.
-- The last step is the flake's @managed-command-audit@ check: the CLI and
-- Haskell architecture checks and their tests, and the managed-command audit
-- (every just recipe and mutating command registered, catalogue current).
fastSteps :: [Step]
fastSteps =
  [ Step "nagarectl-build" "cli/nagarectl" "cabal" ["build", "nagarectl-test"]
  , Step "nagarectl-test" "cli/nagarectl" "cabal" ["test", "nagarectl-test"]
  , Step "nagare-dsl-build" "cli/nagare-dsl" "cabal" ["build", "nagare-dsl-test"]
  , Step "nagare-dsl-test" "cli/nagare-dsl" "cabal" ["test", "nagare-dsl-test"]
  , Step "haskell-style-check" "." "just" ["haskell-style-check"]
  , Step "architecture-and-command-audit" "." "bash" ["scripts/test-managed-command-audit.sh"]
  ]

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

-- | Report one result; for a failure, also show the end of its log.
reportResult :: StepResult -> IO ()
reportResult result = do
  putStrLn (formatResult result)
  unless (stepSucceeded result) $ do
    output <- TIO.readFile (result ^. #logPath)
    let tailLines = reverse (take 60 (reverse (T.lines output)))
    putStrLn ("gate: last lines of " <> result ^. #logPath <> ":")
    mapM_ (TIO.putStrLn . ("  " <>)) tailLines

-- | Run the fast gate. Returns the results, ending at the first failure.
runFastGate :: GateRun -> IO [StepResult]
runFastGate run = do
  results <- runSteps reportResult (run ^. #root) (run ^. #logDir) fastSteps
  putStrLn $
    if all stepSucceeded results && length results == length fastSteps
      then "gate: fast gate green"
      else "gate: fast gate RED"
  pure results

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

flakeCheckStep :: Step
flakeCheckStep = Step "nix-flake-check" "." "nix" ["flake", "check", "--all-systems", "--print-build-logs"]

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

-- | The full gate: clean tree, fast gate, builder probe for every remote
-- system, @nix flake check --all-systems@, a realisation proof per system, and
-- a record. Returns the record (green or red) when one was written.
runFullGate :: GateRun -> IO (Either Text GateRecord)
runFullGate run = do
  let workdir = run ^. #root
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
          fast <- runSteps reportResult workdir (run ^. #logDir) fastSteps
          let fastGreen = length fast == length fastSteps && all stepSucceeded fast
          probes <-
            if fastGreen
              then runSteps reportResult workdir (run ^. #logDir) [probeStep system salt | system <- remoteSystems]
              else pure []
          let probesGreen = fastGreen && length probes == length remoteSystems && all stepSucceeded probes
          when (fastGreen && not probesGreen) $
            putStrLn ("gate: builder unreachable for " <> T.unpack (T.intercalate ", " remoteSystems) <> " (the builder probe failed)")
          flake <-
            if probesGreen
              then runSteps reportResult workdir (run ^. #logDir) [flakeCheckStep]
              else pure []
          let flakeGreen = probesGreen && all stepSucceeded flake && not (null flake)
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
                  , steps = fast <> probes <> flake
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
          putStrLn ("gate: record " <> path <> (if final ^. #green then " (green)" else " (RED)"))
          pure (Right final)

-- | Refuse a revision without a green, clean, fully realised gate record for
-- its exact tree.
verifyRevision :: FilePath -> Text -> IO (Either Text Text)
verifyRevision workdir revision = do
  (code, out, err) <- capture workdir "git" ["rev-parse", "--verify", T.unpack revision <> "^{commit}"]
  case code of
    ExitFailure _ -> pure (Left ("unknown revision " <> revision <> ": " <> T.strip err))
    ExitSuccess -> do
      let commitId = T.strip out
      treeId <- captureLine workdir "git" ["rev-parse", T.unpack commitId <> "^{tree}"]
      supported <- supportedSystemsAt workdir commitId
      stored <- readRecord commitId
      pure $ do
        systems <- supported
        record <- stored
        verifyRecord VerifyTarget {commit = commitId, tree = treeId, supportedSystems = systems} record
        pure (commitId <> " green, tree " <> treeId <> ", systems " <> T.unwords systems)
