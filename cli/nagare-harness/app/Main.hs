module Main (main) where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Harness.FixtureSmoke (runFixtureSmoke)
import Nagare.Harness.Gate (GateRun (..), newLogDir, repositoryRoot, runFastGate, runFullGate, verifyRevision)
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
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "gate" (info gateParser (progDesc "Run or check the local gate (EP-174)"))
        <> command "fixture-smoke" (info smokeParser (progDesc "Run every fixture application locally with its declared bindings"))
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
    FixtureSmoke manifest allowShared -> do
      green <- runFixtureSmoke (fromMaybe (root </> "fixtures/inventory-release/local/fixture-smoke.json") manifest) allowShared
      unless green exitFailure
  where
    refuse message = TIO.hPutStrLn stderr message >> exitFailure
