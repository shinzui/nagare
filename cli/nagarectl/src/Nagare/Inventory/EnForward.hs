-- | A private port-forward to the context's en Service and one request
-- through it. The access runtime keeps one forward for a whole command
-- ("Nagare.Inventory.AccessRuntime"); the En tenant proof opens one for its
-- read and closes it ("Nagare.Inventory.Adapters.EnTenants").
module Nagare.Inventory.EnForward
  ( EnForward
  , startEnForward
  , closeEnForward
  , enForwardRunning
  , enRequest
  , withEnForward
  , parseEnForwardPort
  , enMetricsRequest
  , enMetricsAnswer
  )
where

import Control.Concurrent (forkIO)
import Control.Exception (IOException, bracket, catch, onException, try)
import Control.Monad (join)
import Data.Aeson (Value (Null), encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.ClusterSession (sessionKubeconfigArguments)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import System.IO (Handle, hClose, hGetLine)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, getProcessExitCode, proc, terminateProcess, waitForProcess)
import System.Timeout (timeout)

-- | kubectl's port-forward process and the pipe it reports on.
type EnForward = (Handle, ProcessHandle)

-- | Start kubectl's port-forward to @svc/en@ in @nagare-system@ and return its
-- base URL. After its first line names the local port, the rest of its output
-- is drained, so a long command's per-connection lines never fill the pipe.
startEnForward :: Text -> IO (Either Text (EnForward, Text))
startEnForward kubectlContext = do
  forward@(output, _) <- openEnForward kubectlContext
  ready <- timeout 15000000 (hGetLine output) `onException` closeEnForward forward
  case ready >>= parseEnForwardPort . T.pack of
    Nothing -> closeEnForward forward >> pure (Left "en port-forward did not become ready")
    Just port -> do
      _ <- forkIO (drain output)
      pure (Right (forward, "http://127.0.0.1:" <> port))
  where
    drain output = (hGetLine output >> drain output) `catch` \(_ :: IOException) -> pure ()

enForwardRunning :: EnForward -> IO Bool
enForwardRunning (_, process) = isNothing <$> getProcessExitCode process

-- | Run one action against a fresh forward, closed however the action ends.
withEnForward :: Text -> (Text -> IO a) -> IO (Either Text a)
withEnForward kubectlContext action = do
  started <- try (startEnForward kubectlContext)
  case started of
    Left (failure :: IOException) -> pure (Left ("en port-forward failed: " <> T.pack (show failure)))
    Right (Left reason) -> pure (Left reason)
    Right (Right (forward, base)) -> Right <$> bracket (pure forward) closeEnForward (const (action base))

openEnForward :: Text -> IO EnForward
openEnForward kubectlContext = do
  connection <- sessionKubeconfigArguments kubectlContext >>= either (fail . T.unpack) pure
  (_, output, _, process) <-
    createProcess
      ( proc
          "kubectl"
          (connection <> ["--context", T.unpack kubectlContext, "-n", "nagare-system", "port-forward", "svc/en", ":80", "--address", "127.0.0.1"])
      )
        { std_out = CreatePipe
        , std_err = NoStream
        }
  maybe (fail "kubectl port-forward has no output pipe") (\handle -> pure (handle, process)) output

closeEnForward :: EnForward -> IO ()
closeEnForward (output, process) = do
  terminateProcess process `catch` \(_ :: IOException) -> pure ()
  _ <- waitForProcess process
  hClose output `catch` \(_ :: IOException) -> pure ()

-- | One request with a bearer key: en's status and body, or a transport
-- failure that withholds the key and the body.
enRequest :: String -> Text -> ByteString -> Text -> Value -> IO (Either Text (Int, ByteString))
enRequest key base verb suffix body = do
  response <- try @HttpException $ do
    manager <- newTlsManager
    initial <- parseRequest (T.unpack (base <> suffix))
    httpLbs
      initial
        { method = verb
        , requestHeaders = [("Authorization", "Bearer " <> TE.encodeUtf8 (T.pack key)), ("Content-Type", "application/json")]
        , requestBody = RequestBodyLBS (if verb == "GET" then "" else encode body)
        , responseTimeout = responseTimeoutMicro 10000000
        , redirectCount = 0
        , checkResponse = \_ _ -> pure ()
        }
      manager
  pure $ case response of
    Left _ -> Left "access transport failed; credentials and response body withheld"
    Right result -> Right (statusCode (responseStatus result), LBS.toStrict (responseBody result))

-- | The local port from kubectl's first @Forwarding from 127.0.0.1:PORT -> N@ line.
parseEnForwardPort :: Text -> Maybe Text
parseEnForwardPort line = do
  rest <- T.stripPrefix "Forwarding from 127.0.0.1:" (T.strip line)
  let (port, target) = T.breakOn " -> " rest
  unless (not (T.null port) && T.all (`elem` ['0' .. '9']) port && not (T.null (T.drop 4 target))) Nothing
  pure port

-- | EP-262: a scrape of En's @GET /metrics@, sent as a kubectl request so an
-- interpreter can answer it. The input carries the scrape key; the answer is
-- En's status on the first line and its body after it.
enMetricsRequest :: [String]
enMetricsRequest = ["port-forward", "-n", "nagare-system", "svc/en", ":80", "--", "GET", "/metrics"]

-- | The live answer to 'enMetricsRequest', through a private forward.
enMetricsAnswer :: Text -> String -> IO (Either Text String)
enMetricsAnswer kubectlContext key = do
  fetched <- withEnForward kubectlContext (\base -> enRequest key base "GET" "/metrics" Null)
  pure $ case join fetched of
    Left reason -> Left reason
    Right (code, body) -> Right (show code <> "\n" <> T.unpack (TE.decodeUtf8With (\_ _ -> Just '?') body))
