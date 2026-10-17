-- | @nagare-api-server@: serve one context's recorded inventory state.
--
-- > nagare-api-server --context local-dev --project my-project --store-dir ~/.local/state/nagare/local-dev/inventory --port 8085
--
-- It binds loopback by default; the deployed image binds its pod interface
-- explicitly. The store is opened read-only and never initialized.
module Main (main) where

import Data.String (fromString)
import Data.Text qualified as Text
import Nagare.Api.Server.App (AppConfig (..), adminApplication)
import Nagare.Api.Server.Serve (newEnv)
import Nagare.Contract.Prelude
import Nagare.Contract.Project (versionInfo)
import Nagare.Inventory.Recorded (defaultRecordedReaderConfig, newRecordedReader)
import Nagare.Inventory.Store (openFilesystemStoreReadOnly, readHead)
import Nagare.Resource.Types (ContextBinding (..), mkContextId, mkName)
import Nagare.Version (BuildVersion (..), currentBuildVersion)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Applicative
import System.Exit (die)

data Options = Options
  { context :: !Text
  , project :: !Text
  , storeDir :: !FilePath
  , host :: !String
  , port :: !Int
  }

options :: Parser Options
options =
  Options
    <$> strOption (long "context" <> metavar "NAME" <> help "The context whose store is served")
    <*> strOption (long "project" <> metavar "PROJECT" <> help "The context's project, as its inventory head records it")
    <*> strOption (long "store-dir" <> metavar "DIR" <> help "The context's existing inventory store, opened read-only")
    <*> strOption (long "host" <> metavar "ADDRESS" <> value "127.0.0.1" <> showDefault <> help "The address to bind")
    <*> option auto (long "port" <> metavar "PORT" <> value 8085 <> showDefault <> help "The port to bind")

main :: IO ()
main = do
  Options contextName projectName directory address portNumber <-
    execParser (info (options <**> helper) (fullDesc <> progDesc "Serve one context's recorded inventory state, read-only."))
  binding <- either (die . Text.unpack) pure (ContextBinding <$> mkContextId contextName <*> mkName projectName)
  store <- openFilesystemStoreReadOnly directory >>= either (die . show) pure
  recordedReader <- newRecordedReader defaultRecordedReaderConfig store binding (readHead store)
  let BuildVersion buildVersion buildRevision = currentBuildVersion
  env <- newEnv recordedReader (buildVersion <> maybe "" ("+" <>) buildRevision)
  application <- adminApplication (AppConfig contextName (versionInfo currentBuildVersion Nothing) 32) env
  runSettings (setHost (fromString address) (setPort portNumber defaultSettings)) application
