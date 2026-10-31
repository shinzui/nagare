-- | @nagare-api-server@: serve one context's recorded inventory state.
--
-- > nagare-api-server --context local-dev --project my-project --store-dir ~/.local/state/nagare/local-dev/inventory
-- > nagare-api-server --context intranet --project my-project --store-url gs://my-project-nagare-pulumi-state/nagare/intranet/inventory \
-- >   --project-number 123456789012 --credentials /var/run/nagare/reader.json --cache-dir /var/cache/nagare
--
-- It binds loopback by default; the deployed image binds its pod interface
-- explicitly. The store is opened read-only and never initialized: a local
-- directory as it is, or a GCS prefix through the dedicated reader service
-- account (EP-196), with bucket ownership rechecked on every head read.
module Main (main) where

import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.String (fromString)
import Data.Text qualified as Text
import Nagare.Api.Server.App (AppConfig (..), adminApplication)
import Nagare.Api.Server.Serve (newEnv)
import Nagare.Contract.Prelude
import Nagare.Contract.Project (versionInfo)
import Nagare.Inventory.Recorded (defaultRecordedReaderConfig, newRecordedReader)
import Nagare.Inventory.Store (openFilesystemStoreReadOnly, readHead, readObject)
import Nagare.Inventory.Store.Gogol (inventoryManagerSettings)
import Nagare.Inventory.Store.Service (ServiceStore (..), ServiceStoreConfig (..), openServiceStore)
import Nagare.Platform.Versions.Store (versionSnapshotKey)
import Nagare.Resource.Types (ContextBinding (..), mkContextId, mkName)
import Nagare.Version (BuildVersion (..), currentBuildVersion)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Applicative
import System.Exit (die)
import System.IO (BufferMode (..), hSetBuffering, stdout)

data Source
  = LocalStore !FilePath
  | CloudStore !Text !Text !FilePath !(Maybe FilePath)

data Options = Options
  { context :: !Text
  , project :: !Text
  , source :: !Source
  , host :: !String
  , port :: !Int
  }

options :: Parser Options
options =
  Options
    <$> strOption (long "context" <> metavar "NAME" <> help "The context whose store is served")
    <*> strOption (long "project" <> metavar "PROJECT" <> help "The context's project, as its inventory head records it")
    <*> (local <|> cloud)
    <*> strOption (long "host" <> metavar "ADDRESS" <> value "127.0.0.1" <> showDefault <> help "The address to bind")
    <*> option auto (long "port" <> metavar "PORT" <> value 8085 <> showDefault <> help "The port to bind")
  where
    local = LocalStore <$> strOption (long "store-dir" <> metavar "DIR" <> help "The context's existing local inventory store")
    cloud =
      CloudStore
        <$> strOption (long "store-url" <> metavar "URL" <> help "The context's gs:// inventory prefix")
        <*> strOption (long "project-number" <> metavar "NUMBER" <> help "The numeric number of the context's project")
        <*> strOption (long "credentials" <> metavar "FILE" <> help "The reader service account's key file")
        <*> optional (strOption (long "cache-dir" <> metavar "DIR" <> help "A private writable directory for verified immutable objects"))

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  Options contextName projectName storeSource address portNumber <-
    execParser (info (options <**> helper) (fullDesc <> progDesc "Serve one context's recorded inventory state, read-only."))
  binding <- either (die . Text.unpack) pure (ContextBinding <$> mkContextId contextName <*> mkName projectName)
  (store, headAction, objectAction) <- case storeSource of
    LocalStore directory -> do
      opened <- openFilesystemStoreReadOnly directory >>= either (die . show) pure
      pure (opened, readHead opened, readObject opened)
    CloudStore url number credentials cache -> do
      service <-
        openServiceStore
          ServiceStoreConfig
            { binding = binding
            , projectNumber = number
            , storeUrl = url
            , credentialsFile = credentials
            , cacheDirectory = cache
            , managerSettings = inventoryManagerSettings
            , configureEnv = id
            }
          >>= either (die . show) pure
      pure (service ^. #store, service ^. #freshHead, service ^. #freshObject)
  recordedReader <- newRecordedReader defaultRecordedReaderConfig store binding headAction
  let BuildVersion buildVersion buildRevision = currentBuildVersion
  -- The platform-versions snapshot, through the same session; in the cloud
  -- every read rechecks the bucket's owner like a head read (EP-236).
  let snapshotRead = first (Text.pack . show) <$> objectAction versionSnapshotKey
  env <- newEnv recordedReader (buildVersion <> maybe "" ("+" <>) buildRevision) binding snapshotRead
  application <- adminApplication (AppConfig contextName (versionInfo currentBuildVersion Nothing) 32 (BS.hPutStr stdout)) env
  runSettings (setHost (fromString address) (setPort portNumber defaultSettings)) application
