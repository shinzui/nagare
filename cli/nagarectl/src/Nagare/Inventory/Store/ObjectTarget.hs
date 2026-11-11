-- | A local context's inventory store in its in-cluster object store
-- (EP-251 D4, D5). The context names the endpoint, bucket and prefix in
-- @NAGARE_INVENTORY_STORE_URL@; credentials come from one private source;
-- the operator's workstation reaches an in-cluster Service through a
-- port-forward this process opens, reopens and closes itself.
module Nagare.Inventory.Store.ObjectTarget
  ( objectStoreEndpoint
  , objectInventoryStoreUrl
  , Reach (..)
  , reachFor
  , CredentialSources (..)
  , CredentialChoice (..)
  , chooseCredentials
  , readCredentialFile
  , objectStoreOps
  , ForwardSpec (..)
  , forwardedReach
  , withObjectStoreForwards
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (IOException, SomeException, bracket, catch, try)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeStrict, withObject, (.:))
import Data.Aeson.KeyMap qualified as KM
import Data.Bits ((.&.))
import Data.ByteArray.Encoding (Base (Base64), convertFromBase)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.ClusterSession (kubectlConnectionArguments)
import Nagare.Inventory.Store.ObjectOps (ObjectOps)
import Nagare.Inventory.Store.S3
import Nagare.Target
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hGetLine)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files (fileMode, getFileStatus)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, getProcessExitCode, proc, readProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)

-- | The object endpoint of a local context: a loopback address, or an
-- in-cluster Service (@NAME.NAMESPACE.svc[.cluster.local]:PORT@). A cloud
-- context never selects it, so the GCS path and its guardrail are untouched.
objectStoreEndpoint :: TargetProfile -> Either Text S3Endpoint
objectStoreEndpoint profile = do
  unless (profile ^. #mode == Local) (Left "an object inventory store is only for a local context; a cloud context uses GCS")
  when (T.null (profile ^. #inventoryStoreUrl)) (Left "NAGARE_INVENTORY_STORE=object requires NAGARE_INVENTORY_STORE_URL=http://HOST:PORT/BUCKET/PREFIX")
  endpoint <- parseS3Endpoint (profile ^. #inventoryStoreUrl)
  _ <- reachFor False endpoint
  pure endpoint

-- | EP-251: a local context's object inventory URL. The stored
-- @NAGARE_INVENTORY_STORE_URL@ wins; without one, the context's prefix in a
-- @nagare-inventory@ bucket on its local object store
-- (@NAGARE_LOCAL_OBJECT_STORE@), so a bootstrapped context can migrate without
-- a profile edit its accepted history forbids.
objectInventoryStoreUrl :: Text -> TargetProfile -> Maybe Text
objectInventoryStoreUrl ctx tp
  | not (T.null (tp ^. #inventoryStoreUrl)) = Just (tp ^. #inventoryStoreUrl)
  | otherwise = case T.breakOn "://" (tp ^. #localObjectStore) of
      (scheme, rest)
        | scheme `elem` ["http", "https"]
        , authority <- T.takeWhile (/= '/') (T.drop 3 rest)
        , not (T.null authority) ->
            Just (scheme <> "://" <> authority <> "/nagare-inventory/" <> ctx)
      _ -> Nothing

-- | How a client reaches the endpoint: directly, or through a forward to a
-- Service from the workstation.
data Reach = Direct | ForwardTo !Text !Text !Text
  deriving stock (Eq, Show)

reachFor :: Bool -> S3Endpoint -> Either Text Reach
reachFor inCluster endpoint = case T.splitOn ":" (endpoint ^. #host) of
  [hostName, port]
    | hostName `elem` ["127.0.0.1", "localhost"], validPort port -> Right Direct
    | serviceName : namespace : "svc" : suffix <- T.splitOn "." hostName
    , suffix `elem` [[], ["cluster", "local"]]
    , validPort port ->
        Right (if inCluster then Direct else ForwardTo namespace serviceName port)
  _ -> Left "the object inventory endpoint must be loopback or an in-cluster Service with a port"
  where
    validPort port = not (T.null port) && T.all (`elem` ['0' .. '9']) port

data CredentialSources = CredentialSources
  { credentialsFile :: !(Maybe FilePath)
  , environmentKey :: !(Maybe Text)
  , environmentSecret :: !(Maybe Text)
  , deployer :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data CredentialChoice = FromFile !FilePath | FromEnvironment !S3Credentials | FromAdministratorSecret
  deriving stock (Eq, Show)

-- | One private source. A deployer must bring scoped credentials and never
-- falls back to the store's administrator Secret.
chooseCredentials :: CredentialSources -> Either Text CredentialChoice
chooseCredentials sources = case (sources ^. #credentialsFile, sources ^. #environmentKey, sources ^. #environmentSecret) of
  (Just _, Just _, _) -> both
  (Just _, _, Just _) -> both
  (Just path, Nothing, Nothing) -> Right (FromFile path)
  (Nothing, Just key, Just secret) -> Right (FromEnvironment (S3Credentials key secret))
  (Nothing, Nothing, Nothing)
    | sources ^. #deployer -> Left "a deployer's object inventory store needs NAGARE_INVENTORY_STORE_CREDENTIALS_FILE or AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    | otherwise -> Right FromAdministratorSecret
  _ -> Left "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set together"
  where
    both = Left "set NAGARE_INVENTORY_STORE_CREDENTIALS_FILE or the AWS_* variables, not both"

newtype CredentialFile = CredentialFile S3Credentials

instance FromJSON CredentialFile where
  parseJSON = withObject "object store credentials" $ \o -> do
    unless (all (`elem` ["accessKeyId", "secretAccessKey"]) (KM.keys o)) (fail "the credential file has an unknown field")
    fmap CredentialFile (S3Credentials <$> o .: "accessKeyId" <*> o .: "secretAccessKey")

-- | A JSON file readable by its owner only. Its bytes never reach an error.
readCredentialFile :: FilePath -> IO (Either Text S3Credentials)
readCredentialFile path = do
  loaded <- try $ do
    status <- getFileStatus path
    bytes <- BS.readFile path
    pure (fileMode status .&. 0o077, bytes)
  pure $ case loaded of
    Left (_ :: IOException) -> Left "the object store credential file cannot be read"
    Right (open, _) | open /= 0 -> Left "the object store credential file must be private (mode 0600 or 0400)"
    Right (_, bytes) -> case eitherDecodeStrict bytes of
      Right (CredentialFile credentials) -> Right credentials
      Left _ -> Left "the object store credential file is not {\"accessKeyId\", \"secretAccessKey\"}"

-- | The administrator Secret of the local object store, read once for an
-- operator through the context's kubectl connection.
readAdministratorSecret :: Text -> IO (Either Text S3Credentials)
readAdministratorSecret kubectlContext = do
  connection <- kubectlConnectionArguments kubectlContext
  case connection of
    Left reason -> pure (Left reason)
    Right arguments -> do
      result <- try (readProcessWithExitCode "kubectl" (arguments <> ["-n", "nagare-system", "get", "secret", T.unpack minioCredentialsSecret, "-o", "json"]) "")
      pure $ case result of
        Left (_ :: IOException) -> Left "kubectl could not read the object store credentials"
        Right (ExitSuccess, output, _) -> do
          value <- first (const "the object store credential Secret is not JSON") (eitherDecodeStrict (BC.pack output))
          let field name = case value of
                Object root
                  | Just (Object fields) <- KM.lookup "data" root
                  , Just (String encoded) <- KM.lookup name fields ->
                      first (const "the object store credential Secret is not base64") (convertFromBase Base64 (TE.encodeUtf8 encoded))
                _ -> Left "the object store credential Secret lacks its keys"
          key <- field "AWS_ACCESS_KEY_ID"
          secret <- field "AWS_SECRET_ACCESS_KEY"
          pure (S3Credentials (TE.decodeUtf8 key) (TE.decodeUtf8 secret))
        Right _ -> Left "kubectl could not read the object store credentials"

-- | The object store operations for a local context, and whether the bucket
-- was ensured. Only an opening that may initialize creates the bucket.
objectStoreOps :: Bool -> ActiveTarget -> IO (Either Text ObjectOps)
objectStoreOps mayInitialize target = do
  let profile = target ^. #profile
      kubectlContext = contextNameText (target ^. #contextName)
  file <- lookupEnv "NAGARE_INVENTORY_STORE_CREDENTIALS_FILE"
  key <- fmap T.pack <$> lookupEnv "AWS_ACCESS_KEY_ID"
  secret <- fmap T.pack <$> lookupEnv "AWS_SECRET_ACCESS_KEY"
  inCluster <- isJust <$> lookupEnv "KUBERNETES_SERVICE_HOST"
  let nonEmpty = mfilter' (not . null)
      nonEmptyText = mfilter' (not . T.null)
      mfilter' keep = (>>= \value -> if keep value then Just value else Nothing)
      sources = CredentialSources (nonEmpty file) (nonEmptyText key) (nonEmptyText secret) (isJust (profile ^. #deployer))
  case (,,) <$> objectStoreEndpoint profile <*> chooseCredentials sources <*> pure () of
    Left reason -> pure (Left reason)
    Right (endpoint, choice, ()) -> do
      credentials <- case choice of
        FromFile path -> readCredentialFile path
        FromEnvironment given -> pure (Right given)
        FromAdministratorSecret -> readAdministratorSecret kubectlContext
      case (credentials, reachFor inCluster endpoint) of
        (Left reason, _) -> pure (Left reason)
        (_, Left reason) -> pure (Left reason)
        (Right given, Right reach) -> do
          reachAction <- case reach of
            Direct -> pure (pure (Right (endpoint ^. #base, endpoint ^. #host)))
            ForwardTo namespace service port -> forwardedReach (kubectlForward kubectlContext namespace service port)
          transport <- s3HttpTransport reachAction given
          ensured <- if mayInitialize then ensureBucket transport endpoint else pure (Right ())
          pure (s3ObjectOpsWith transport endpoint <$ ensured)

-- | A forward's command and the parser of its first output line.
data ForwardSpec = ForwardSpec
  { command :: !(IO (Either Text (FilePath, [String])))
  , readyPort :: !(Text -> Maybe Text)
  }

kubectlForward :: Text -> Text -> Text -> Text -> ForwardSpec
kubectlForward kubectlContext namespace service port =
  ForwardSpec
    { command =
        fmap
          (\arguments -> ("kubectl", arguments <> ["-n", T.unpack namespace, "port-forward", "svc/" <> T.unpack service, ":" <> T.unpack port, "--address", "127.0.0.1"]))
          <$> kubectlConnectionArguments kubectlContext
    , readyPort = forwardPort
    }

forwardPort :: Text -> Maybe Text
forwardPort line = do
  rest <- T.stripPrefix "Forwarding from 127.0.0.1:" (T.strip line)
  let (port, target) = T.breakOn " -> " rest
  unless (not (T.null port) && T.all (`elem` ['0' .. '9']) port && not (T.null (T.drop 4 target))) Nothing
  pure port

-- | The reach of a workstation client: the forward opens on first use, is
-- reopened if its process exited (a forward that dies mid-transaction leaves
-- the next request a fresh one; the store's own uncertainty rules keep the
-- transaction resumable), and is registered so the command closes it.
forwardedReach :: ForwardSpec -> IO (IO (Either Text (Text, Text)))
forwardedReach spec = do
  current <- newMVar Nothing
  pure (modifyMVar current reuseOrOpen)
  where
    reuseOrOpen :: Maybe ((Handle, ProcessHandle), Text) -> IO (Maybe ((Handle, ProcessHandle), Text), Either Text (Text, Text))
    reuseOrOpen open = do
      alive <- case open of
        Just (forward@(_, process), port) ->
          getProcessExitCode process >>= \case
            Nothing -> pure (Just port)
            Just _ -> Nothing <$ closeForward forward
        Nothing -> pure Nothing
      case alive of
        Just port -> pure (open, Right (local port))
        Nothing -> do
          started <- startForward
          pure $ case started of
            Left reason -> (Nothing, Left reason)
            Right (forward, port) -> (Just (forward, port), Right (local port))
    local port = ("http://127.0.0.1:" <> port, "127.0.0.1:" <> port)
    startForward = do
      selected <- command spec
      case selected of
        Left reason -> pure (Left reason)
        Right (program, arguments) -> do
          spawned <- try (createProcess (proc program arguments) {std_out = CreatePipe, std_err = NoStream})
          case spawned of
            Left (_ :: IOException) -> pure (Left "the object store port-forward could not start")
            Right (_, Nothing, _, process) -> Left "the object store port-forward has no output" <$ terminateProcess process
            Right (_, Just output, _, process) -> do
              registerForward (output, process)
              ready <- timeout 15000000 (try (hGetLine output) :: IO (Either IOException String))
              case ready of
                Just (Right line) | Just port <- readyPort spec (T.pack line) -> do
                  _ <- forkIO (drain output)
                  pure (Right ((output, process), port))
                _ -> Left "the object store port-forward did not become ready" <$ closeForward (output, process)
    drain output = (hGetLine output >> drain output) `catch` \(_ :: IOException) -> pure ()

forwards :: IORef [(Handle, ProcessHandle)]
forwards = unsafePerformIO (newIORef [])
{-# NOINLINE forwards #-}

registerForward :: (Handle, ProcessHandle) -> IO ()
registerForward forward = atomicModifyIORef' forwards (\open -> (forward : open, ()))

closeForward :: (Handle, ProcessHandle) -> IO ()
closeForward (output, process) = do
  terminateProcess process `catch` \(_ :: SomeException) -> pure ()
  _ <- try (waitForProcess process) :: IO (Either SomeException ExitCode)
  hClose output `catch` \(_ :: IOException) -> pure ()

-- | Run a command and close every forward it opened, however it ends.
withObjectStoreForwards :: IO a -> IO a
withObjectStoreForwards action = bracket (pure ()) (const closeAll) (const action)
  where
    closeAll = atomicModifyIORef' forwards ([],) >>= mapM_ closeForward
