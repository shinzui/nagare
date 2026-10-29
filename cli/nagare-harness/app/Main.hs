module Main (main) where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Harness.FixtureSmoke (runFixtureSmoke)
import Nagare.Harness.Gate (coveredRevision, fastGateAt, fullGateAt, landableRevision, newLogDir, postLandGate, repositoryRoot, verifyRevision)
import Nagare.Harness.Mutation (Outcome (..), checkPatterns, checkRecords, loadRecords, proveRecords, selectRecords, sweepRecords)
import Nagare.Harness.Prelude
import Nagare.Harness.Release.Candidate (CandidateOptions (..), releaseCandidate)
import Nagare.Harness.Release.Intranet (IntranetOptions (..), transitionPinTag, transitionRun)
import Nagare.Harness.Release.Process (realRuntime, refusing)
import Nagare.Harness.Release.Rehearse (RehearseOptions (..), transitionRehearse)
import Nagare.Harness.Release.TransitionDrill (transitionDrill)
import Nagare.Harness.RouteCheck (RouteCheckOptions (..), routeCheckMain)
import Nagare.Harness.Step (stepSucceeded)
import Options.Applicative
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)

data Command
  = GateFast !Text
  | GateFull !Text
  | GatePostLand !Text
  | GateVerify !Text
  | GateCovered !Text
  | GateLandable !Text !Text
  | FixtureSmoke !(Maybe FilePath) !Bool
  | MutationsCheck
  | MutationsPatterns
  | MutationsProve !Text !(Maybe Text) !Int ![Text]
  | MutationsSweep !Text !(Maybe Text) !Int
  | RouteCheck !RouteCheckOptions
  | ReleaseCandidate !CandidateOptions
  | TransitionRun !IntranetOptions !Bool
  | TransitionPinTag !IntranetOptions
  | TransitionRehearse !RehearseOptions
  | TransitionDrillCommand
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "gate" (info gateParser (progDesc "Run or check the local gate (EP-174)"))
        <> command "fixture-smoke" (info smokeParser (progDesc "Run every fixture application locally with its declared bindings"))
        <> command "mutations" (info mutationsParser (progDesc "Check and prove the mutation records (EP-180 M8)"))
        <> command "route-check" (info routeCheckParser (progDesc "Check a protected route over verified HTTPS: login, grant and revoke (EP-183 M1)"))
        <> command "release" (info releaseParser (progDesc "Prepare a release candidate up to the tag (EP-229)"))
        <> command "transition" (info transitionParser (progDesc "Move the intranet, pin its tag, or rehearse a release transition (EP-229)"))
    )

releaseParser :: Parser Command
releaseParser =
  hsubparser
    ( command
        "candidate"
        ( info
            ( fmap ReleaseCandidate $
                CandidateOptions
                  <$> versionArgument
                  <*> (T.pack <$> strOption (long "revision" <> metavar "REV" <> value "HEAD" <> showDefault <> help "The candidate revision, on origin/master"))
                  <*> switch (long "rehearsal" <> help "Run every step but land nothing and leave the intranet untouched")
            )
            (progDesc "Everything up to the tag, unattended: gate, transition rehearsal, attachments, assembly, the intranet, the rehearsal record (scripts/release-candidate.sh)")
        )
    )

-- | The scripts' own grammars, so each wrapper is a bare @exec … "$\@"@.
transitionParser :: Parser Command
transitionParser =
  hsubparser
    ( command
        "run"
        ( info
            (TransitionRun <$> intranetOptions <*> switch (long "pin-tag" <> help "Pin the published tag instead, as transition pin-tag"))
            (progDesc "Move the intranet to a candidate run (scripts/release-intranet.sh)")
        )
        <> command
          "pin-tag"
          ( info
              (TransitionPinTag <$> intranetOptions)
              (progDesc "Pin the intranet's operator repository to the published tag; the rollout is not repeated")
          )
        <> command
          "rehearse"
          ( info
              ( fmap TransitionRehearse $
                  RehearseOptions
                    <$> (T.pack <$> strArgument (metavar "REV" <> help "The candidate revision"))
                    <*> (T.pack <$> strArgument (metavar "PREV_VERSION" <> help "The published release it moves from"))
                    <*> optional (strOption (long "run" <> metavar "DIR" <> help "Work directory (default: a fresh /private/tmp/nagare-release-rehearse.XXXXXX)"))
              )
              (progDesc "Rehearse the transition from a published release to a candidate on nagare-mp23 (scripts/release-rehearse.sh)")
          )
        <> command
          "drill"
          ( info
              (pure TransitionDrillCommand)
              (progDesc "The transition drill on a disposable Docker daemon, configured by NAGARE_REHEARSAL_* (scripts/transition-rehearsal.sh)")
          )
    )
  where
    intranetOptions =
      IntranetOptions
        <$> versionArgument
        <*> optional (strOption (long "run" <> metavar "DIR" <> help "The candidate run (default: the version's latest run)"))
        <*> optional (T.pack <$> strOption (long "context" <> metavar "NAME" <> help "Default: NAGARE_RELEASE_CONTEXT, else intranet"))
        <*> optional (T.pack <$> strOption (long "revision" <> metavar "REV" <> help "Refuse unless the run is for this revision"))

versionArgument :: Parser Text
versionArgument = T.pack <$> strArgument (metavar "VERSION" <> help "major.minor.patch")

routeCheckParser :: Parser Command
routeCheckParser =
  fmap RouteCheck $
    RouteCheckOptions
      <$> (T.pack <$> strOption (long "context" <> metavar "NAME" <> help "Nagare context for the reviewed grant and revoke"))
      <*> (T.pack <$> strOption (long "kube-context" <> metavar "NAME" <> value "k3d-nagare-local" <> showDefault <> help "kubectl context of the same cluster"))
      <*> (T.pack <$> strOption (long "host" <> metavar "HOST" <> value "scenario-a.127-0-0-1.sslip.io" <> showDefault <> help "The protected route"))
      <*> optional (strOption (long "ca" <> metavar "FILE" <> help "Trust only this PEM bundle (default: the local CA Secret)"))
      <*> switch (long "system-trust" <> help "Trust the system store (a cloud context's public certificate)")
      <*> optional (option auto (long "ingress-port-forward" <> metavar "PORT" <> help "Connect through a Kourier port-forward on this local port"))
      <*> (T.pack <$> strOption (long "expect-body" <> metavar "TEXT" <> value "rows: " <> showDefault <> help "Text the app's page contains"))
      <*> strOption (long "nagarectl" <> metavar "PATH" <> value "nagarectl" <> showDefault <> help "The nagarectl binary for reviewed commands")
      <*> strOption (long "reviews" <> metavar "DIR" <> help "Directory for the saved grant and revoke reviews")
      <*> optional (T.pack <$> strOption (long "team" <> metavar "KEY" <> help "Grant the host to this team and check through a reviewed membership (EP-188 M3)"))
      <*> (T.pack <$> strOption (long "other-team" <> metavar "KEY" <> value "route-check-strangers" <> showDefault <> help "A team the host is never granted to; its member must be refused"))

mutationsParser :: Parser Command
mutationsParser =
  hsubparser
    ( command "check" (info (pure MutationsCheck) (progDesc "Every record has a manifest entry and applies to the working tree"))
        <> command "patterns" (info (pure MutationsPatterns) (progDesc "Every record's pattern selects a test of its built suite"))
        <> command
          "prove"
          ( info
              ( MutationsProve
                  <$> (T.pack <$> strOption (long "rev" <> metavar "REV" <> help "Committed revision to prove the records against"))
                  <*> optional (T.pack <$> strOption (long "base" <> metavar "BASE" <> help "Prove only records the range BASE..REV could affect; default: every record"))
                  <*> option auto (long "width" <> metavar "N" <> value 4 <> showDefault <> help "Records proved at once on the remote builder")
                  <*> many (T.pack <$> strOption (long "record" <> metavar "NAME" <> help "Prove only this record (repeatable)"))
              )
              (progDesc "Prove on the remote builder that each record still fails its tests")
          )
        <> command
          "sweep"
          ( info
              ( MutationsSweep
                  <$> (T.pack <$> strOption (long "rev" <> metavar "REV" <> help "Committed revision to sweep"))
                  <*> optional (T.pack <$> strOption (long "base" <> metavar "BASE" <> help "Sweep only records the range BASE..REV could affect; default: every record"))
                  <*> option auto (long "width" <> metavar "N" <> value 4 <> showDefault <> help "Workers in the remote build")
              )
              (progDesc "Prove every record in one remote build that compiles the revision once per worker")
          )
    )

smokeParser :: Parser Command
smokeParser =
  FixtureSmoke
    <$> optional (strOption (long "manifest" <> metavar "PATH" <> help "Default: fixtures/inventory-release/local/fixture-smoke.json"))
    <*> switch (long "allow-shared-daemon" <> help "Run even when the Docker daemon hosts a k3d cluster")

gateParser :: Parser Command
gateParser =
  hsubparser
    ( command
        "verify"
        ( info
            (GateVerify . T.pack <$> strOption (long "revision" <> metavar "REV" <> help "Revision that native work will use"))
            (progDesc "Refuse a revision without a green, clean, fully realised gate record")
        )
        <> command
          "covered"
          ( info
              (GateCovered . T.pack <$> strOption (long "revision" <> metavar "REV" <> help "Landed revision"))
              (progDesc "Succeed when a landed revision needs no full gate of its own: a record verifies, or a running ancestor gate will carry forward over inert documentation")
          )
        <> command
          "post-land"
          ( info
              (GatePostLand . T.pack <$> strOption (long "revision" <> metavar "REV" <> help "Landed revision"))
              (progDesc "The post-land check: nothing when the revision is covered, otherwise its full gate in a gate slot")
          )
        <> command
          "landable"
          ( info
              ( GateLandable
                  <$> (T.pack <$> strOption (long "revision" <> metavar "REV" <> help "Revision to land"))
                  <*> (T.pack <$> strOption (long "base" <> metavar "REF" <> value "origin/master" <> showDefault <> help "The branch it lands on"))
              )
              (progDesc "Refuse to land a revision without a green fast or full record, or while a landed commit's full gate is red")
          )
    )
    <|> (GateFast <$ flag' () (long "fast" <> help "Style and architecture checks and both Haskell suites, incremental, in a gate slot; writes the fast record land needs") <*> revisionOption)
    <|> (GateFull <$ flag' () (long "full" <> help "In a gate slot: builder probe, static checks, then the suite builds alongside nix flake check --all-systems (each suite once), realisation proof, record") <*> revisionOption)
  where
    revisionOption = T.pack <$> strOption (long "revision" <> metavar "REV" <> value "HEAD" <> showDefault <> help "Committed revision to gate; uncommitted changes are never gated")

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  parsed <- execParser (info (commandParser <**> helper) (fullDesc <> failureCode 2 <> progDesc "Nagare release and gate harness"))
  case parsed of
    ReleaseCandidate options -> realRuntime >>= \runtime -> refusing "release-candidate" (releaseCandidate runtime options)
    TransitionRun options pinTag -> realRuntime >>= \runtime -> refusing "release-intranet" ((if pinTag then transitionPinTag else transitionRun) runtime options)
    TransitionPinTag options -> realRuntime >>= \runtime -> refusing "release-intranet" (transitionPinTag runtime options)
    TransitionRehearse options -> realRuntime >>= \runtime -> refusing "release-rehearse" (transitionRehearse runtime options)
    TransitionDrillCommand -> realRuntime >>= \runtime -> refusing "rehearsal" (transitionDrill runtime)
    _ -> repositoryRoot >>= \root -> harnessMain root parsed

harnessMain :: FilePath -> Command -> IO ()
harnessMain root parsed =
  case parsed of
    GateFast revision -> do
      outcome <- fastGateAt root revision
      case outcome of
        Left err -> refuse ("gate: " <> err)
        Right results -> unless (all stepSucceeded results && not (null results)) exitFailure
    GateFull revision -> do
      outcome <- fullGateAt root revision
      case outcome of
        Left err -> refuse ("gate: " <> err)
        Right record -> unless (record ^. #green) exitFailure
    GatePostLand revision -> do
      outcome <- postLandGate root revision
      case outcome of
        Left err -> refuse ("gate post-land: " <> err)
        Right Nothing -> pure ()
        Right (Just record) -> unless (record ^. #green) exitFailure
    GateVerify revision -> do
      outcome <- verifyRevision root revision
      case outcome of
        Left err -> refuse ("gate verify: " <> revision <> " refused: " <> err)
        Right summary -> TIO.putStrLn ("gate verify: " <> summary)
    GateCovered revision -> do
      outcome <- coveredRevision root revision
      case outcome of
        Left err -> refuse ("gate covered: " <> revision <> " not covered: " <> err)
        Right summary -> TIO.putStrLn ("gate covered: " <> summary)
    GateLandable revision base -> do
      outcome <- landableRevision root base revision
      case outcome of
        Left err -> refuse ("gate landable: " <> revision <> " refused: " <> err)
        Right summary -> TIO.putStrLn ("gate landable: " <> summary)
    MutationsCheck -> report "mutations check" =<< checkRecords root
    MutationsPatterns -> report "mutations patterns" =<< checkPatterns root
    MutationsProve revision base width chosen -> do
      loaded <- loadRecords root
      entries <- either (refuse . ("mutations prove: " <>)) pure loaded
      selected <- filter (\entry -> null chosen || entry ^. #record `elem` chosen) <$> selectRecords root ((,revision) <$> base) entries
      TIO.putStrLn ("mutations prove: " <> T.pack (show (length selected)) <> " of " <> T.pack (show (length entries)) <> " records at " <> revision)
      results <- proveRecords root width revision selected
      forM_ results $ \result ->
        TIO.putStrLn ("mutations prove: " <> T.pack (show (result ^. #outcome)) <> " " <> result ^. #record <> (if T.null (result ^. #detail) then "" else " (" <> result ^. #detail <> ")"))
      let failed = [result | result <- results, result ^. #outcome /= Killed]
      TIO.putStrLn ("mutations prove: " <> T.pack (show (length results - length failed)) <> " killed, " <> T.pack (show (length failed)) <> " not")
      unless (null failed) exitFailure
    MutationsSweep revision base width -> do
      loaded <- loadRecords root
      everything <- either (refuse . ("mutations sweep: " <>)) pure loaded
      entries <- selectRecords root ((,revision) <$> base) everything
      logDir <- newLogDir
      TIO.putStrLn ("mutations sweep: " <> T.pack (show (length entries)) <> " of " <> T.pack (show (length everything)) <> " records at " <> revision <> ", logs in " <> T.pack logDir)
      swept <- if null entries then pure (Right []) else sweepRecords root logDir revision width entries
      results <- either (refuse . ("mutations sweep: " <>)) pure swept
      forM_ [result | result <- results, result ^. #outcome /= Killed] $ \result ->
        TIO.putStrLn ("mutations sweep: " <> T.pack (show (result ^. #outcome)) <> " " <> result ^. #record <> " (" <> result ^. #detail <> ")")
      let failed = [result | result <- results, result ^. #outcome /= Killed]
      TIO.putStrLn ("mutations sweep: " <> T.pack (show (length results - length failed)) <> " killed, " <> T.pack (show (length failed)) <> " not")
      unless (null failed) exitFailure
    RouteCheck options -> do
      green <- routeCheckMain options
      unless green exitFailure
    FixtureSmoke manifest allowShared -> do
      green <- runFixtureSmoke (fromMaybe (root </> "fixtures/inventory-release/local/fixture-smoke.json") manifest) allowShared
      unless green exitFailure
    -- The release commands run before the repository root is read.
    ReleaseCandidate _ -> pure ()
    TransitionRun _ _ -> pure ()
    TransitionPinTag _ -> pure ()
    TransitionRehearse _ -> pure ()
    TransitionDrillCommand -> pure ()
  where
    refuse message = TIO.hPutStrLn stderr message >> exitFailure
    report label problems = do
      mapM_ (TIO.putStrLn . ((label <> ": ") <>)) problems
      if null problems then TIO.putStrLn (label <> ": ok") else exitFailure
