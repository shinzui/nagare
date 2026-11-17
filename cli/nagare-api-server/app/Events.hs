-- | @nagare-events@: one context's lifecycle event worker (EP-235).
--
-- > nagare-events --context local-dev --project my-project --store-dir /var/lib/nagare/inventory \
-- >   --backup-minio http://minio.nagare-system.svc.cluster.local:9000 --backup-bucket nagare-backups \
-- >   --backup-credentials /var/run/nagare/minio.json --delivery on --activate
--
-- It materializes committed sources into the feed, collects verified
-- backups and delivers subscriptions, each in its own bounded loop. Its
-- inventory store is opened read-only; it writes only the lifecycle state
-- beside it. With @--delivery off@, the default, it sends nothing, which is how a candidate
-- or rehearsal context runs it. @/health/live@, @/health/ready@ and
-- @/metrics@ report the last iteration of each loop and never read a store.
module Main (main) where

import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (newEmptyMVar, readMVar, tryPutMVar)
import Crypto.Random (getRandomBytes)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Nagare.Api.Events.Worker
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..))
import Nagare.Contract.Prelude
import Nagare.Events.Backup (SigningRef (..))
import Nagare.Events.Delivery (DeliveryEnv (..), defaultDeliveryBudget)
import Nagare.Events.Delivery.Transport (adapterRegistry)
import Nagare.Events.SigningKeys (inClusterSecrets)
import Nagare.Events.Store (FeedStore, filesystemObjectOps, newFeedStore)
import Nagare.Events.Target (feedLocation)
import Nagare.Events.Webhook.Subscription (webhookTransport)
import Nagare.Events.Webhook.Transport (httpSend, productionAddressPolicy, webhookFactory)
import Nagare.Inventory.Store (InventoryStore, openFilesystemStoreReadOnly)
import Nagare.Inventory.Store.Gogol (StorageEnv, gogolObjectOpsWithEnv, gogolVersionedReader, inventoryManagerSettings)
import Nagare.Inventory.Store.ObjectTarget (readCredentialFile)
import Nagare.Inventory.Store.S3 (S3Credentials (..), s3HttpTransport, s3VersionedReader)
import Nagare.Inventory.Store.Service (ServiceStore (..), ServiceStoreConfig (..), openServiceStore, serviceWriterEnv)
import Nagare.Resource.Types (ContextBinding (..), PhysicalIdentity, mkContextId, mkName, mkPhysicalIdentity, nameText)
import Network.HTTP.Types (status200, status404, status503)
import Network.Wai (Application, pathInfo, responseLBS)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit (die)
import System.IO (BufferMode (..), hSetBuffering, stdout)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)
import System.Timeout (timeout)

data Store
  = LocalStore !FilePath
  | CloudStore !Text !Text !FilePath !(Maybe FilePath)

data Backups
  = NoBackups
  | GcsBackups !Text
  | MinioBackups !Text !Text !(Maybe FilePath)

data Options = Options
  { context :: !Text
  , project :: !Text
  , store :: !Store
  , backups :: !Backups
  , deliver :: !Bool
  , activateAtStart :: !Bool
  , intervals :: !Intervals
  , host :: !String
  , port :: !Int
  }
  deriving stock (Generic)

options :: Parser Options
options =
  Options
    <$> strOption (long "context" <> metavar "NAME" <> help "The context whose lifecycle events this worker runs")
    <*> strOption (long "project" <> metavar "PROJECT" <> help "The context's project, as its inventory head records it")
    <*> (local <|> cloud)
    <*> (gcsBackups <|> minioBackups <|> pure NoBackups)
    <*> option onOff (long "delivery" <> metavar "on|off" <> value False <> help "Send subscriptions' deliveries; off (the default) sends nothing, as a candidate or rehearsal context runs")
    <*> switch (long "activate" <> help "Enable the feed, backup collection and delivery if they are not yet")
    <*> ( Intervals
            <$> option auto (long "source-interval" <> metavar "SECONDS" <> value 30 <> showDefault <> help "Seconds between source materialization cycles")
            <*> option auto (long "receipt-interval" <> metavar "SECONDS" <> value 300 <> showDefault <> help "Seconds between backup receipt cycles, at least 30")
            <*> option auto (long "delivery-interval" <> metavar "SECONDS" <> value 10 <> showDefault <> help "Seconds between delivery cycles")
        )
    <*> strOption (long "host" <> metavar "ADDRESS" <> value "127.0.0.1" <> showDefault <> help "The address of the probe and metrics endpoints")
    <*> option auto (long "port" <> metavar "PORT" <> value 8086 <> showDefault <> help "The port of the probe and metrics endpoints")
  where
    local = LocalStore <$> strOption (long "store-dir" <> metavar "DIR" <> help "The context's existing local inventory store; its lifecycle state is beside it")
    cloud =
      CloudStore
        <$> strOption (long "store-url" <> metavar "URL" <> help "The context's gs:// inventory prefix; its lifecycle state is beside it")
        <*> strOption (long "project-number" <> metavar "NUMBER" <> help "The numeric number of the context's project")
        <*> strOption (long "credentials" <> metavar "FILE" <> help "The worker service account's key file")
        <*> optional (strOption (long "cache-dir" <> metavar "DIR" <> help "A private writable directory for verified immutable objects"))
    gcsBackups = GcsBackups <$> strOption (long "backup-gcs" <> metavar "BUCKET" <> help "The context's GCS backup bucket")
    minioBackups =
      MinioBackups
        <$> strOption (long "backup-minio" <> metavar "URL" <> help "The in-cluster object store's endpoint")
        <*> strOption (long "backup-bucket" <> metavar "BUCKET" <> help "The backup bucket in it")
        <*> optional (strOption (long "backup-credentials" <> metavar "FILE" <> help "A private JSON file with accessKeyId and secretAccessKey, read-only to the bucket; without it, AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"))

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  opts <- execParser (info (options <**> helper) (fullDesc <> progDesc "Run one context's lifecycle event worker: sources, backup receipts and deliveries."))
  when (opts ^. #intervals . #receipts < 30) (die "--receipt-interval is at least 30 seconds")
  binding <- either (die . Text.unpack) pure (ContextBinding <$> mkContextId (opts ^. #context) <*> mkName (opts ^. #project))
  (inventory, feed, gcsEnv) <- openStores binding (opts ^. #store)
  secrets <- if needsSecrets opts then either (die . Text.unpack) (pure . Just) =<< inClusterSecrets else pure Nothing
  let secretValue namespace name field = maybe (pure (Left "the worker reads no Secrets outside a cluster")) (\r -> r namespace name field) secrets
      signing ref = do
        found <- secretValue (ref ^. #namespace) (ref ^. #secret) "HMAC_KEY"
        pure (found >>= \(value, uid) -> (,) (TE.decodeUtf8 value) <$> mkPhysicalIdentity uid)
  access <- backupAccess (opts ^. #backups) gcsEnv signing
  stopping <- newEmptyMVar
  let pause seconds = void (timeout (seconds * 1000000) (readMVar stopping))
      deliveryEnv =
        DeliveryEnv
          { inventory
          , feed
          , binding
          , registry = adapterRegistry [(webhookTransport, webhookFactory (\ref -> fmap fst <$> secretValue (ref ^. #namespace) (ref ^. #secret) (ref ^. #key)) (httpSend productionAddressPolicy) getCurrentTime)]
          , clock = getCurrentTime
          , random = (\bytes -> fromIntegral (BS.foldl' (\acc b -> acc * 256 + fromIntegral b) (0 :: Integer) bytes) / 4294967296) <$> (getRandomBytes 4 :: IO ByteString)
          , token = TE.decodeUtf8 . convertToBase Base16 <$> (getRandomBytes 16 :: IO ByteString)
          , budget = defaultDeliveryBudget
          }
      config = WorkerConfig binding inventory feed access (if opts ^. #deliver then Just deliveryEnv else Nothing) (opts ^. #intervals) getCurrentTime pause stopping
  when (opts ^. #activateAtStart) (activate config >>= either (die . Text.unpack . ("nagare-events: activation failed: " <>)) pure)
  status <- newWorkerStatus
  let stop = void (tryPutMVar stopping ())
  _ <- installHandler sigTERM (Catch stop) Nothing
  _ <- installHandler sigINT (Catch stop) Nothing
  withAsync (runSettings (setHost (fromString (opts ^. #host)) (setPort (opts ^. #port) defaultSettings)) (probes status)) $ \_ ->
    runWorker config status
  putStrLn "nagare-events: stopped"
  where
    needsSecrets opts = case opts ^. #backups of
      NoBackups -> opts ^. #deliver
      _ -> True

openStores :: ContextBinding -> Store -> IO (InventoryStore, FeedStore, Maybe StorageEnv)
openStores binding = \case
  LocalStore directory -> do
    inventory <- openFilesystemStoreReadOnly directory >>= either (die . show) pure
    lifecycle <- filesystemObjectOps (Text.unpack (feedLocation (Text.pack directory)))
    feed <- newFeedStore lifecycle
    pure (inventory, feed, Nothing)
  CloudStore url number credentials cache -> do
    service <- openServiceStore (ServiceStoreConfig binding number url credentials cache inventoryManagerSettings id) >>= either (die . show) pure
    writer <- serviceWriterEnv credentials inventoryManagerSettings >>= either (die . show) pure
    lifecycle <- either (die . Text.unpack) pure (gogolObjectOpsWithEnv writer (nameText (binding ^. #project)) (feedLocation url))
    feed <- newFeedStore lifecycle
    pure (service ^. #store, feed, Just writer)

backupAccess :: Backups -> Maybe StorageEnv -> (SigningRef -> IO (Either Text (Text, PhysicalIdentity))) -> IO (Maybe BackupAccess)
backupAccess choice gcsEnv signing = case choice of
  NoBackups -> pure Nothing
  GcsBackups bucket -> case gcsEnv of
    Nothing -> die "--backup-gcs needs a cloud store's --credentials"
    Just env -> pure (Just (BackupAccess (GcsBackend "" bucket) (gogolVersionedReader (pure env) bucket Nothing) ("gs://" <> bucket <> "/") signing))
  MinioBackups endpoint bucket credentials -> do
    given <- case credentials of
      Just file -> readCredentialFile file >>= either (die . Text.unpack . ("--backup-credentials: " <>)) pure
      Nothing -> do
        key <- lookupEnv "AWS_ACCESS_KEY_ID"
        secret <- lookupEnv "AWS_SECRET_ACCESS_KEY"
        case (,) <$> key <*> secret of
          Just (k, v) | not (null k) && not (null v) -> pure (S3Credentials (Text.pack k) (Text.pack v))
          _ -> die "--backup-minio needs --backup-credentials or AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    transport <- s3HttpTransport (pure (Right (endpoint, Text.drop 7 endpoint))) given
    pure (Just (BackupAccess (MinioBackend (MinioRef endpoint bucket "")) (s3VersionedReader transport bucket) ("s3://" <> bucket <> "/") signing))

onOff :: ReadM Bool
onOff = eitherReader $ \case
  "on" -> Right True
  "off" -> Right False
  _ -> Left "on or off"

probes :: WorkerStatus -> Application
probes status request respond = case pathInfo request of
  ["health", "live"] -> respond (responseLBS status200 [] "live")
  ["health", "ready"] -> do
    verdict <- ready status
    respond (either (\why -> responseLBS status503 [] (LBS.fromStrict (TE.encodeUtf8 why))) (const (responseLBS status200 [] "ready")) verdict)
  ["metrics"] -> renderMetrics status >>= respond . responseLBS status200 [("Content-Type", "text/plain; version=0.0.4")]
  _ -> respond (responseLBS status404 [] "")
