module Main (main) where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Harness.FixtureSmoke (runFixtureSmoke)
import Nagare.Harness.Gate (GateRun (..), newLogDir, repositoryRoot, runFastGate, runFullGate, verifyRevision)
import Nagare.Harness.Mutation (Outcome (..), checkPatterns, checkRecords, loadRecords, proveRecords, selectRecords)
import Nagare.Harness.Prelude
import Nagare.Harness.Step (stepSucceeded)
import Options.Applicative
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)

data Command
  = GateFast
  | GateFull
  | GateVerify !Text
  | FixtureSmoke !(Maybe FilePath) !Bool
  | MutationsCheck
  | MutationsPatterns
  | MutationsProve !Text !(Maybe Text) !Int
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "gate" (info gateParser (progDesc "Run or check the local gate (EP-174)"))
        <> command "fixture-smoke" (info smokeParser (progDesc "Run every fixture application locally with its declared bindings"))
        <> command "mutations" (info mutationsParser (progDesc "Check and prove the mutation records (EP-180 M8)"))
    )

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
              )
              (progDesc "Prove on the remote builder that each record still fails its tests")
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
    )
    <|> flag' GateFast (long "fast" <> help "Both Haskell suites, style and architecture checks")
    <|> flag' GateFull (long "full" <> help "Clean tree, fast gate, builder probe, nix flake check --all-systems, realisation proof, record")

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  parsed <- execParser (info (commandParser <**> helper) (fullDesc <> progDesc "Nagare release and gate harness"))
  root <- repositoryRoot
  case parsed of
    GateFast -> do
      logDir <- newLogDir
      results <- runFastGate GateRun {root, logDir}
      unless (all stepSucceeded results && not (null results)) exitFailure
    GateFull -> do
      logDir <- newLogDir
      outcome <- runFullGate GateRun {root, logDir}
      case outcome of
        Left err -> refuse ("gate: " <> err)
        Right record -> unless (record ^. #green) exitFailure
    GateVerify revision -> do
      outcome <- verifyRevision root revision
      case outcome of
        Left err -> refuse ("gate verify: " <> revision <> " refused: " <> err)
        Right summary -> TIO.putStrLn ("gate verify: " <> summary)
    MutationsCheck -> report "mutations check" =<< checkRecords root
    MutationsPatterns -> report "mutations patterns" =<< checkPatterns root
    MutationsProve revision base width -> do
      loaded <- loadRecords root
      entries <- either (refuse . ("mutations prove: " <>)) pure loaded
      selected <- selectRecords root ((,revision) <$> base) entries
      TIO.putStrLn ("mutations prove: " <> T.pack (show (length selected)) <> " of " <> T.pack (show (length entries)) <> " records at " <> revision)
      results <- proveRecords root width revision selected
      forM_ results $ \result ->
        TIO.putStrLn ("mutations prove: " <> T.pack (show (result ^. #outcome)) <> " " <> result ^. #record <> (if T.null (result ^. #detail) then "" else " (" <> result ^. #detail <> ")"))
      let failed = [result | result <- results, result ^. #outcome /= Killed]
      TIO.putStrLn ("mutations prove: " <> T.pack (show (length results - length failed)) <> " killed, " <> T.pack (show (length failed)) <> " not")
      unless (null failed) exitFailure
    FixtureSmoke manifest allowShared -> do
      green <- runFixtureSmoke (fromMaybe (root </> "fixtures/inventory-release/local/fixture-smoke.json") manifest) allowShared
      unless green exitFailure
  where
    refuse message = TIO.hPutStrLn stderr message >> exitFailure
    report label problems = do
      mapM_ (TIO.putStrLn . ((label <> ": ") <>)) problems
      if null problems then TIO.putStrLn (label <> ": ok") else exitFailure
