-- | Process setup and typed command dispatch for nagarectl.
module Main (main) where

import Control.Exception (IOException, try)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import GHC.IO.Encoding (setLocaleEncoding)
import Nagare.Cli.Dispatch (dispatchTraced)
import Nagare.Cli.Parser (opts)
import Nagare.Dsl.Prelude
import Nagare.Inventory.DelegatedPlanning (profileActor)
import Nagare.Inventory.DeployerCommands (contextArgument, guardDeployerCommand)
import Nagare.Target (ActiveTarget, resolveActiveTarget)
import Options.Applicative (execParser)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hSetEncoding, stderr, stdout, utf8)

main :: IO ()
main = do
  setLocaleEncoding utf8
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  getArgs >>= guardDeployer . map T.pack
  execParser opts >>= dispatchTraced

-- | EP-247 D3: a deployer context runs only the commands its delegation
-- covers, refused before any option parsing or store read. A context that
-- does not resolve is left to the command, which reports it.
guardDeployer :: [Text] -> IO ()
guardDeployer arguments = do
  resolved <- try (resolveActiveTarget (contextArgument arguments)) :: IO (Either IOException ActiveTarget)
  case resolved >>= first (userError . T.unpack) . profileActor . (^. #profile) of
    Left _ -> pure ()
    Right actor -> either (\message -> TIO.hPutStrLn stderr message >> exitFailure) pure (guardDeployerCommand actor arguments)
