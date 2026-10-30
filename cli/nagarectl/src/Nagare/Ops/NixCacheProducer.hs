-- | EP-230: the workstation producer path to the context's Attic cache.
--
-- A token is a file, never a value. 'mintToken' writes what @atticadm
-- make-token@ prints inside the cluster to a new mode-0600 file and nowhere
-- else; 'pushPaths' mints its own short-lived token into a private directory
-- that is removed on every exit. No argument, environment variable, log line
-- or trace carries a token: the Attic client reads it through @token-file@ in
-- a private configuration.
--
-- The forward binds 127.0.0.1:18080, the only loopback host the server's
-- @allowed-hosts@ admits (@cluster/bootstrap/nix-cache/server.toml.tmpl@), so
-- a busy port is refused rather than replaced. The port-forward runs in its
-- own process group and the whole group is killed on every exit, so an exec
-- credential plugin kubectl started cannot outlive the command.
module Nagare.Ops.NixCacheProducer
  ( ProducerOps (..)
  , Child (..)
  , ProducerError (..)
  , TokenRequest (..)
  , Forwarded (..)
  , PushTarget (..)
  , Pushed (..)
  , defaultProducerOps
  , requireCloudContext
  , cacheName
  , forwardEndpoint
  , defaultTokenRequest
  , pushTokenRequest
  , validityLimitSeconds
  , validitySeconds
  , validateTokenRequest
  , makeTokenArguments
  , portForwardArguments
  , pushArguments
  , cacheConfigUrl
  , renderClientConfig
  , normalizeEndpoint
  , mintToken
  , withForward
  , pushPaths
  , renderProducerError
  )
where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (IOException, bracket, finally, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAlpha, isAsciiLower, isAsciiUpper, isControl, isDigit, isSpace)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.Counters (traceProcess)
import Nagare.Target (Mode (Cloud, Local))
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types.Status (statusCode)
import System.Directory (createDirectory, doesPathExist, getTemporaryDirectory, makeAbsolute, removeDirectoryRecursive)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, hGetLine, hIsEOF, stderr)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files (ownerModes, ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Posix.IO (OpenMode (WriteOnly), creat, defaultFileFlags, exclusive, fdToHandle, openFd)
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Process
  ( CreateProcess (..)
  , StdStream (CreatePipe, Inherit, UseHandle)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , readCreateProcessWithExitCode
  , waitForProcess
  , withCreateProcess
  )

-- | The effects of the producer path; tests inject every one.
data ProducerOps = ProducerOps
  { connection :: !(IO (Either Text [String]))
  -- ^ The kubectl connection arguments of the command's admitted session.
  , kubectl :: !([String] -> IO (Either Text ByteString))
  -- ^ Run kubectl to completion, capturing stdout; a failure names its stderr.
  , spawn :: !([String] -> IO (Either Text Child))
  -- ^ Start a long-lived kubectl in its own process group.
  , listening :: !(IO Bool)
  -- ^ Whether something already answers on 127.0.0.1:18080.
  , fetch :: !(String -> IO (Either Text ByteString))
  -- ^ GET a URL; a 2xx body or the reason there is none.
  , attic :: !(FilePath -> [String] -> IO ExitCode)
  -- ^ Run the Attic client with @XDG_CONFIG_HOME@ set to the given directory.
  , storePath :: !(FilePath -> IO (Either Text ()))
  -- ^ Whether the path is valid in the local Nix store, and why not.
  , pause :: !(IO ())
  , scratch :: !(IO FilePath)
  -- ^ Where private directories are created.
  }
  deriving stock (Generic)

-- | A running child: poll, wait, its last stderr line, and a group kill.
data Child = Child
  { exited :: !(IO (Maybe ExitCode))
  , waitExit :: !(IO ExitCode)
  , lastError :: !(IO Text)
  , stop :: !(IO ())
  }
  deriving stock (Generic)

data ProducerError
  = InvalidSubject !Text
  | InvalidValidity !Text !Text
  | TokenDestinationExists !FilePath
  | SessionRefused !Text
  | TokenMintFailed !Text
  | TokenWriteFailed !FilePath !Text
  | PortBusy
  | ForwardFailed !Text
  | ForwardDied !Text
  | ForwardNotReady !Text
  | CacheConfigUnreadable !Text
  | NotAStorePath !FilePath
  | MissingStorePath !FilePath !Text
  | InvalidEndpoint !Text
  | InvalidCacheName !Text
  | TokenFileMissing !FilePath
  | PrivateDirectoryFailed !Text
  | LocalContext
  deriving stock (Eq, Show)

-- | Who a token is for and how long it lives, in Attic's duration syntax.
data TokenRequest = TokenRequest
  { subject :: !Text
  , validity :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | The cache this forward serves: its endpoint, name and public signing key.
data Forwarded = Forwarded
  { endpoint :: !Text
  , cache :: !Text
  , publicKey :: !Text
  , child :: !Child
  }
  deriving stock (Generic)

-- | The context's cache through the forward, or any Attic by URL with an
-- operator-held token file.
data PushTarget
  = ContextCache
  | ExternalCache !Text !FilePath !Text
  deriving stock (Eq, Show)

data Pushed = Pushed
  { endpoint :: !Text
  , cache :: !Text
  , paths :: ![FilePath]
  , exit :: !ExitCode
  }
  deriving stock (Eq, Show, Generic)

-- | The cache is a cloud-only component (ADR 21).
requireCloudContext :: Mode -> Either ProducerError ()
requireCloudContext = \case
  Local -> Left LocalContext
  Cloud -> Right ()

-- | The one cache every Nagare context serves.
cacheName :: Text
cacheName = "nagare-cache"

-- | The only loopback endpoint the server admits.
forwardEndpoint :: Text
forwardEndpoint = "http://127.0.0.1:18080/"

defaultTokenRequest :: TokenRequest
defaultTokenRequest = TokenRequest "operator-push" "1h"

-- | The token 'pushPaths' mints for itself.
pushTokenRequest :: TokenRequest
pushTokenRequest = TokenRequest "operator-push" "15m"

validityLimitSeconds :: Integer
validityLimitSeconds = 24 * 60 * 60

-- | Seconds in an Attic duration such as @15m@, @1h@ or @1h 30m@.
validitySeconds :: Text -> Either Text Integer
validitySeconds raw
  | T.null (T.strip raw) = Left "empty duration"
  | otherwise = go (T.strip raw)
  where
    go remaining
      | T.null remaining = Right 0
      | otherwise = do
          let (digits, afterDigits) = T.span isDigit remaining
              (unit, rest) = T.span isAlpha afterDigits
          when (T.null digits) (Left ("expected a number at '" <> remaining <> "'"))
          factor <- unitSeconds unit
          (read (T.unpack digits) * factor +) <$> go (T.stripStart rest)
    unitSeconds unit
      | unit `elem` ["s", "sec", "secs", "second", "seconds"] = Right 1
      | unit `elem` ["m", "min", "mins", "minute", "minutes"] = Right 60
      | unit `elem` ["h", "hr", "hrs", "hour", "hours"] = Right 3600
      | unit `elem` ["d", "day", "days"] = Right 86400
      | otherwise = Left ("unknown unit '" <> unit <> "'; use s, m, h or d")

validateTokenRequest :: TokenRequest -> Either ProducerError ()
validateTokenRequest request = do
  let name = request ^. #subject
  when (T.null name || not (T.all subjectChar name)) (Left (InvalidSubject name))
  seconds <- first (InvalidValidity (request ^. #validity)) (validitySeconds (request ^. #validity))
  when (seconds <= 0) (Left (InvalidValidity (request ^. #validity) "must be positive"))
  when (seconds > validityLimitSeconds) (Left (InvalidValidity (request ^. #validity) "exceeds 24h"))
  where
    subjectChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("._-" :: String)

-- | @atticadm make-token@ inside the server Pod, through the session.
makeTokenArguments :: [String] -> TokenRequest -> [String]
makeTokenArguments session request =
  session
    <> ["--request-timeout=10s", "-n", "nagare-system", "exec", "deployment/nix-cache", "--"]
    <> ["atticadm", "-f", "/config/server.toml", "make-token"]
    <> ["--sub", T.unpack (request ^. #subject), "--validity", T.unpack (request ^. #validity)]
    <> ["--pull", T.unpack cacheName, "--push", T.unpack cacheName]

portForwardArguments :: [String] -> [String]
portForwardArguments session =
  session <> ["-n", "nagare-system", "port-forward", "--address", "127.0.0.1", "service/nix-cache", "18080:80"]

-- | The client names its server @nagare@ in the private configuration.
pushArguments :: Text -> [FilePath] -> [String]
pushArguments name storePaths = ["push", "nagare:" <> T.unpack name] <> storePaths

cacheConfigUrl :: Text -> Text -> String
cacheConfigUrl base name = T.unpack (base <> "_api/v1/cache-config/" <> name)

-- | The Attic client configuration: one server, read through a token file.
renderClientConfig :: Text -> FilePath -> Text
renderClientConfig base tokenFile =
  T.unlines
    [ "default-server = \"nagare\""
    , ""
    , "[servers.nagare]"
    , "endpoint = " <> tomlString base
    , "token-file = " <> tomlString (T.pack tokenFile)
    ]
  where
    tomlString value = "\"" <> T.concatMap escape value <> "\""
    escape = \case
      '"' -> "\\\""
      '\\' -> "\\\\"
      c -> T.singleton c

-- | An http(s) URL ending in @/@, so the client joins API paths beneath it.
normalizeEndpoint :: Text -> Either ProducerError Text
normalizeEndpoint raw
  | not (any (`T.isPrefixOf` raw) ["http://", "https://"]) = Left (InvalidEndpoint raw)
  | T.any (\c -> isSpace c || isControl c || c `elem` ("\"\\" :: String)) raw = Left (InvalidEndpoint raw)
  | T.isSuffixOf "/" raw = Right raw
  | otherwise = Right (raw <> "/")

validateCacheName :: Text -> Either ProducerError ()
validateCacheName name = case T.uncons name of
  Just (initial, _)
    | alphaNumeric initial && T.all (\c -> alphaNumeric c || c `elem` ("._-" :: String)) name -> Right ()
  _ -> Left (InvalidCacheName name)
  where
    alphaNumeric c = isAsciiLower c || isAsciiUpper c || isDigit c

-- | Mint a pull-and-push token for @nagare-cache@ into a new mode-0600 file.
-- An existing destination is refused before anything is minted.
mintToken :: ProducerOps -> TokenRequest -> FilePath -> IO (Either ProducerError ())
mintToken ops request destination = case validateTokenRequest request of
  Left failure -> pure (Left failure)
  Right () -> do
    exists <- doesPathExist destination
    if exists
      then pure (Left (TokenDestinationExists destination))
      else
        ops ^. #connection >>= \case
          Left reason -> pure (Left (SessionRefused reason))
          Right session ->
            (ops ^. #kubectl) (makeTokenArguments session request) >>= \case
              Left reason -> pure (Left (TokenMintFailed reason))
              Right output -> do
                let token = BC.strip output
                if BS.null token
                  then pure (Left (TokenMintFailed "atticadm printed no token"))
                  else first (TokenWriteFailed destination . T.pack . show) <$> try @IOException (writeNewPrivate destination token)

-- | Write a file that must not exist yet, readable only by its owner.
writeNewPrivate :: FilePath -> ByteString -> IO ()
writeNewPrivate path bytes = do
  handle <- openFd path WriteOnly (defaultFileFlags {creat = Just 0o600, exclusive = True}) >>= fdToHandle
  BS.hPut handle bytes `finally` hClose handle
  setFileMode path (ownerReadMode `unionFileModes` ownerWriteMode)

-- | Forward 127.0.0.1:18080 to the cache, wait until Attic answers, read the
-- public key, and run @action@. The forward is killed however this ends.
withForward :: ProducerOps -> (Forwarded -> IO a) -> IO (Either ProducerError a)
withForward ops action =
  ops ^. #listening >>= \case
    True -> pure (Left PortBusy)
    False ->
      ops ^. #connection >>= \case
        Left reason -> pure (Left (SessionRefused reason))
        Right session ->
          bracket ((ops ^. #spawn) (portForwardArguments session)) (traverse_ (^. #stop)) $ \case
            Left reason -> pure (Left (ForwardFailed reason))
            Right child ->
              awaitReady ops child >>= \case
                Left failure -> pure (Left failure)
                Right key -> Right <$> action (Forwarded forwardEndpoint cacheName key child)

-- | Attic's root page answers at most 30 times one second apart, then the
-- cache configuration names the public key.
awaitReady :: ProducerOps -> Child -> IO (Either ProducerError Text)
awaitReady ops child = go (30 :: Int)
  where
    go attempts =
      child ^. #exited >>= \case
        Just _ -> Left . ForwardDied <$> child ^. #lastError
        Nothing
          | attempts <= 0 -> Left . ForwardNotReady <$> child ^. #lastError
          | otherwise ->
              (ops ^. #fetch) (T.unpack forwardEndpoint) >>= \case
                Right body | "Attic Binary Cache" `BS.isInfixOf` body -> readKey
                _ -> ops ^. #pause >> go (attempts - 1)
    readKey =
      (ops ^. #fetch) (cacheConfigUrl forwardEndpoint cacheName) <&> \case
        Left reason -> Left (CacheConfigUnreadable reason)
        Right bytes -> maybe (Left (CacheConfigUnreadable "the cache configuration has no public_key")) Right (publicKeyOf bytes)
    publicKeyOf bytes = do
      value <- Aeson.decodeStrict bytes
      key <- Aeson.parseMaybe (Aeson.withObject "cache-config" (Aeson..: "public_key")) value
      guard (not (T.null key))
      pure key

-- | Push store paths. Every path is checked against the local store before
-- anything else; the private directory with the client configuration, and
-- in context mode the minted token, is removed however the push ends.
pushPaths :: ProducerOps -> PushTarget -> NonEmpty FilePath -> IO (Either ProducerError Pushed)
pushPaths ops target storePaths =
  checkPaths (NE.toList storePaths) >>= \case
    Left failure -> pure (Left failure)
    Right () -> case target of
      ContextCache ->
        inPrivateDirectory $ \directory -> do
          let tokenFile = directory </> "token"
          mintToken ops pushTokenRequest tokenFile >>= \case
            Left failure -> pure (Left failure)
            Right () -> withForward ops (\forwarded -> push directory (forwarded ^. #endpoint) tokenFile (forwarded ^. #cache))
      ExternalCache rawEndpoint tokenFile name ->
        case (,) <$> normalizeEndpoint rawEndpoint <*> validateCacheName name of
          Left failure -> pure (Left failure)
          Right (base, ()) -> do
            absolute <- makeAbsolute tokenFile
            exists <- doesPathExist absolute
            if not exists
              then pure (Left (TokenFileMissing absolute))
              else inPrivateDirectory (\directory -> Right <$> push directory base absolute name)
  where
    checkPaths = \case
      [] -> pure (Right ())
      path : rest
        | not (storeShaped path) -> pure (Left (NotAStorePath path))
        | otherwise -> checkPaths rest >>= either (pure . Left) (const (present path))
    present path = first (MissingStorePath path) <$> (ops ^. #storePath) path
    storeShaped path = case stripStore path of
      Just name -> not (null name) && '/' `notElem` name && name `notElem` [".", ".."]
      Nothing -> False
    stripStore path = if "/nix/store/" `isPrefixOf` path then Just (drop (length ("/nix/store/" :: String)) path) else Nothing
    push directory base tokenFile name = do
      let home = directory </> "config"
      createDirectory home
      createDirectory (home </> "attic")
      writeNewPrivate (home </> "attic" </> "config.toml") (TE.encodeUtf8 (renderClientConfig base tokenFile))
      code <- (ops ^. #attic) home (pushArguments name (NE.toList storePaths))
      pure (Pushed base name (NE.toList storePaths) code)
    inPrivateDirectory body = do
      root <- ops ^. #scratch
      created <- try @IOException (createTempDirectory root "nagare-attic-push" >>= \path -> path <$ setFileMode path ownerModes)
      case created of
        Left failure -> pure (Left (PrivateDirectoryFailed (T.pack (show failure))))
        Right directory -> body directory `finally` void (try @IOException (removeDirectoryRecursive directory))

renderProducerError :: ProducerError -> Text
renderProducerError = \case
  InvalidSubject name -> "token subject '" <> name <> "' must be non-empty and use only letters, digits, '.', '_' and '-'"
  InvalidValidity value reason -> "token validity '" <> value <> "' is invalid: " <> reason <> " (at most 24h, e.g. 15m or 1h)"
  TokenDestinationExists path -> "refusing to overwrite " <> T.pack path <> "; name a new token file"
  SessionRefused reason -> reason
  TokenMintFailed reason -> "could not mint a token in deployment/nix-cache: " <> reason
  TokenWriteFailed path reason -> "could not write the token file " <> T.pack path <> ": " <> reason
  PortBusy ->
    "127.0.0.1:18080 is already in use; the cache admits only that loopback host, so stop its other user first "
      <> "(another 'nagarectl nix-cache forward', 'nagare nix-cache-status', or the reviewed cache transport)"
  ForwardFailed reason -> "could not start the port-forward to service/nix-cache: " <> reason
  ForwardDied reason -> "the port-forward to service/nix-cache exited: " <> lastLine reason
  ForwardNotReady reason -> "Attic did not answer through the port-forward after 30 attempts: " <> lastLine reason
  CacheConfigUnreadable reason -> "could not read the public key of " <> cacheName <> ": " <> reason
  NotAStorePath path -> T.pack path <> " is not a store path; give absolute /nix/store/HASH-NAME paths"
  MissingStorePath path reason -> T.pack path <> " is not valid in the local Nix store: " <> reason
  InvalidEndpoint value -> "endpoint '" <> value <> "' must be an http:// or https:// URL without spaces or quotes"
  InvalidCacheName name -> "cache name '" <> name <> "' must start with a letter or digit and use only letters, digits, '.', '_' and '-'"
  TokenFileMissing path -> "token file " <> T.pack path <> " does not exist"
  PrivateDirectoryFailed reason -> "could not create a private directory: " <> reason
  LocalContext -> "the Nix cache is a cloud-only component and is unavailable for local contexts"
  where
    lastLine reason = if T.null reason then "(kubectl printed nothing on stderr)" else reason

-- * The real programs

-- | The real kubectl, Attic client, Nix and HTTP, with @connection@ from the
-- command's admitted session.
defaultProducerOps :: IO (Either Text [String]) -> ProducerOps
defaultProducerOps session =
  ProducerOps
    { connection = session
    , kubectl = capture "kubectl"
    , spawn = spawnGroup "kubectl"
    , listening = loopbackAnswers
    , fetch = httpGet
    , attic = runAttic
    , storePath = localStorePath
    , pause = threadDelay 1000000
    , scratch = getTemporaryDirectory
    }

capture :: String -> [String] -> IO (Either Text ByteString)
capture program arguments = do
  result <- traceProcess (T.pack program) (try @IOException (readCreateProcessWithExitCode (proc program arguments) ""))
  pure $ case result of
    Left failure -> Left ("could not start " <> T.pack program <> ": " <> T.pack (show failure))
    Right (ExitSuccess, output, _) -> Right (BC.pack output)
    Right (ExitFailure code, _, errors) -> Left (T.pack program <> " exited " <> T.pack (show code) <> diagnostic errors)
  where
    diagnostic errors = case filter (not . T.null) (map T.strip (T.lines (T.pack errors))) of
      [] -> ""
      lines' -> ": " <> last lines'

-- | Start a child in its own process group, draining its output and keeping
-- its last non-empty stderr line. 'stop' kills the whole group with SIGKILL,
-- as "Nagare.Dsl.Load.Process" does, and reaps the child.
spawnGroup :: String -> [String] -> IO (Either Text Child)
spawnGroup program arguments = do
  started <-
    try @IOException
      (createProcess (proc program arguments) {std_in = Inherit, std_out = CreatePipe, std_err = CreatePipe, create_group = True})
  case started of
    Left failure -> pure (Left (T.pack (show failure)))
    Right (_, Just output, Just errors, process) -> do
      latest <- newIORef ""
      readers <- traverse forkIO [drain output (const (pure ())), drain errors (\line -> unless (T.null line) (writeIORef latest line))]
      pure . Right $
        Child
          { exited = getProcessExitCode process
          , waitExit = waitForProcess process
          , lastError = readIORef latest
          , stop = do
              getPid process >>= traverse_ (void . try @IOException . signalProcessGroup sigKILL)
              void (waitForProcess process)
              traverse_ killThread readers
          }
    Right _ -> pure (Left (T.pack program <> " started without its pipes"))
  where
    drain handle keep = void . try @IOException $ do
      let loop =
            hIsEOF handle >>= \case
              True -> pure ()
              False -> hGetLine handle >>= keep . T.strip . T.pack >> loop
      loop

-- | Something answers a TCP connection on 127.0.0.1:18080.
loopbackAnswers :: IO Bool
loopbackAnswers = do
  manager <- Http.newManager Http.defaultManagerSettings {Http.managerResponseTimeout = Http.responseTimeoutMicro 2000000}
  request <- Http.parseRequest (T.unpack forwardEndpoint)
  result <- try @Http.HttpException (Http.httpNoBody request manager)
  pure $ case result of
    Left (Http.HttpExceptionRequest _ (Http.ConnectionFailure _)) -> False
    _ -> True

httpGet :: String -> IO (Either Text ByteString)
httpGet url = do
  manager <- Http.newManager Http.defaultManagerSettings {Http.managerResponseTimeout = Http.responseTimeoutMicro 5000000}
  result <- try @Http.HttpException $ do
    request <- Http.parseRequest url
    Http.httpLbs request manager
  pure $ case result of
    Left failure -> Left (T.pack (takeWhile (/= '\n') (show failure)))
    Right response
      | statusCode (Http.responseStatus response) `div` 100 == 2 -> Right (LBS.toStrict (Http.responseBody response))
      | otherwise -> Left ("HTTP " <> T.pack (show (statusCode (Http.responseStatus response))) <> " from " <> T.pack url)

-- | The Attic client, its stdout and stderr on our stderr, so stdout stays
-- free for a contract document.
runAttic :: FilePath -> [String] -> IO ExitCode
runAttic home arguments = do
  environment <- getEnvironment
  let command =
        (proc "attic" arguments)
          { env = Just (("XDG_CONFIG_HOME", home) : filter ((/= "XDG_CONFIG_HOME") . fst) environment)
          , std_out = UseHandle stderr
          , std_err = Inherit
          }
  started <- traceProcess "attic" (try @IOException (withCreateProcess command (\_ _ _ process -> waitForProcess process)))
  case started of
    Left failure -> BC.hPutStrLn stderr (BC.pack ("nagarectl: could not run attic: " <> show failure)) >> pure (ExitFailure 127)
    Right code -> pure code

localStorePath :: FilePath -> IO (Either Text ())
localStorePath path =
  void <$> capture "nix" ["--extra-experimental-features", "nix-command", "path-info", path]
