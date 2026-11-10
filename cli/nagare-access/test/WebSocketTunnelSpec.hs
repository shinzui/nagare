-- | The raw WebSocket path, over real sockets: bytes tunnel after the upstream's
-- 101, and the rotated cookies reach the handshake (EP-239, IR-41 AC-3).
module WebSocketTunnelSpec (webSocketTunnelTests) where

import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import GHC.Stack (HasCallStack)
import Nagare.Access.App (appWithRuntime)
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.Cookie (decodeRefreshCookieValue, refreshCookieHeader, signedCookieSettings)
import Nagare.Access.Credential (Credential (..))
import Nagare.Access.Prelude
import Nagare.Access.Proxy (portalForwarder, proxyForwarder)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (status400, status403)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import Network.Wai (requestHeaders)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import TestServices (testServices)

webSocketTunnelTests :: TestTree
webSocketTunnelTests =
  testGroup
    "websocket tunnel"
    [ testCase "tunnels websocket upgrade bytes after upstream 101" $
        testWithApplication (pure websocketUpstreamApp) $ \upstreamPort ->
          testWithApplication (pure (websocketProxyApp upstreamPort)) $ \proxyPort ->
            withTcpConnection proxyPort $ \socket -> do
              SocketBS.sendAll socket websocketUpgradeRequest
              response <- readUntil socket "\r\n\r\n"
              assertBool "expected 101 response" ("HTTP/1.1 101 Switching Protocols" `BS.isPrefixOf` response)
              assertBool "expected websocket accept header" ("Sec-WebSocket-Accept: test-accept" `BS.isInfixOf` response)
              SocketBS.sendAll socket "hello"
              echoed <- assertSocketRead socket
              echoed @?= "upstream:hello"
    , testGroup
        "rotated cookies on the raw websocket handshake"
        [ handshakeCookieTests "protected backend" "app.example.test"
        , handshakeCookieTests "portal backend" "auth.example.test"
        ]
    ]

websocketProxyApp :: Int -> Wai.Application
websocketProxyApp upstreamPort req respond = do
  manager <- HC.newManager HC.defaultManagerSettings
  let user = AuthenticatedUser {subject = "user:alice"}
      target = BackendTarget (Text.pack ("http://127.0.0.1:" <> show upstreamPort)) ProtectedBackend Nothing Nothing
  proxyForwarder manager user "tools.example.com" target [] req >>= respond

websocketUpstreamApp :: Wai.Application
websocketUpstreamApp _req respond =
  respond $
    Wai.responseRaw
      ( \src sink -> do
          sink $
            BS.concat
              [ "HTTP/1.1 101 Switching Protocols\r\n"
              , "Upgrade: websocket\r\n"
              , "Connection: Upgrade\r\n"
              , "Sec-WebSocket-Accept: test-accept\r\n"
              , "\r\n"
              ]
          chunk <- src
          sink ("upstream:" <> chunk)
      )
      (Wai.responseLBS status400 [] "raw unsupported")

-- | Upgrades carrying an expired session and a live refresh cookie, through
-- the whole application and the real forwarders over real sockets. A fake
-- response cannot show this: 'Wai.mapResponseHeaders' leaves a raw response
-- alone, so only the bytes on the wire prove the cookies were delivered.
handshakeCookieTests :: TestName -> ByteString -> TestTree
handshakeCookieTests name host =
  testGroup
    name
    [ testCase "an upstream 101 carries each replacement cookie once and tunnels" $ do
        upstreamCookies <- newIORef []
        refreshes <- newIORef (0 :: Int)
        testWithApplication (pure (recordingCookies upstreamCookies websocketUpstreamApp)) $ \upstreamPort ->
          withHandshake host refreshes upstreamPort $ \socket response -> do
            assertBool ("expected 101, got " <> show response) ("HTTP/1.1 101 " `BS.isPrefixOf` response)
            assertBool "the upgrade must not be redirected" (not ("Location:" `BS.isInfixOf` response))
            assertRotatedCookies response
            readIORef refreshes >>= (@?= 1)
            SocketBS.sendAll socket "hello"
            assertSocketRead socket >>= (@?= "upstream:hello")
            readIORef upstreamCookies >>= (@?= [Just "theme=dark"])
    , testCase "an upstream refusal still carries each replacement cookie once" $ do
        upstreamCookies <- newIORef []
        refreshes <- newIORef (0 :: Int)
        let refusing _ respond = respond (Wai.responseLBS status403 [] "")
        testWithApplication (pure (recordingCookies upstreamCookies refusing)) $ \upstreamPort ->
          withHandshake host refreshes upstreamPort $ \_ response -> do
            assertBool ("expected 403, got " <> show response) ("HTTP/1.1 403 " `BS.isPrefixOf` response)
            assertRotatedCookies response
            readIORef refreshes >>= (@?= 1)
            readIORef upstreamCookies >>= (@?= [Just "theme=dark"])
    , testCase "a connection failure before the handshake is a 502 with each replacement cookie once" $ do
        refreshes <- newIORef (0 :: Int)
        withHandshake host refreshes 1 $ \_ response -> do
          assertBool ("expected 502, got " <> show response) ("HTTP/1.1 502 " `BS.isPrefixOf` response)
          assertRotatedCookies response
          readIORef refreshes >>= (@?= 1)
    ]

recordingCookies :: IORef [Maybe ByteString] -> Wai.Application -> Wai.Application
recordingCookies seen upstream req respond = do
  modifyIORef' seen (<> [lookup "Cookie" (requestHeaders req)])
  upstream req respond

-- | Send one upgrade through the enforcer and hand over its response head.
withHandshake :: ByteString -> IORef Int -> Int -> (Socket.Socket -> ByteString -> IO a) -> IO a
withHandshake host refreshes upstreamPort check = do
  manager <- HC.newManager HC.defaultManagerSettings
  refreshCookie <- refreshCookieValue "cookie-secret" "refresh.old"
  let upstream = Text.pack ("http://127.0.0.1:" <> show upstreamPort)
  backends <-
    assertRight $
      backendMapFromTargets
        [ ("app.example.test", BackendTarget upstream ProtectedBackend Nothing Nothing)
        , ("auth.example.test", BackendTarget upstream PortalBackend Nothing Nothing)
        ]
  let services =
        testServices
          & #cookieSettings
          .~ Just (signedCookieSettings ".example.test" "cookie-secret")
          & #verifyCredential
          .~ ( \case
                 SessionCookie "access.new" -> pure (Right AuthenticatedUser {subject = "user:alice"})
                 _ -> pure (Left ExpiredCredential)
             )
          & #refreshUserSession
          .~ ( \_ -> do
                 modifyIORef' refreshes (+ 1)
                 pure (RefreshResult RefreshLed (LoginSucceeded SessionTokens {accessToken = "access.new", refreshToken = Just "refresh.new", expiresIn = 900, remembered = True}))
             )
          & #forwardAuthorized
          .~ proxyForwarder manager
          & #forwardPortal
          .~ portalForwarder manager
  testWithApplication (pure (appWithRuntime backends services)) $ \proxyPort ->
    withTcpConnection proxyPort $ \socket -> do
      SocketBS.sendAll socket $
        BS.concat
          [ "GET /socket HTTP/1.1\r\nHost: "
          , host
          , "\r\nCookie: nagare_session=access.old; theme=dark; nagare_refresh="
          , refreshCookie
          , "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: test-key\r\nSec-WebSocket-Version: 13\r\n\r\n"
          ]
      response <- readUntil socket "\r\n\r\n"
      check socket response

assertRotatedCookies :: (HasCallStack) => ByteString -> IO ()
assertRotatedCookies response = do
  let cookieLines = filter ("Set-Cookie: " `BS.isPrefixOf`) (splitHeadLines response)
      valuesOf cookieName = [BS.takeWhile (/= 59) value | line <- cookieLines, Just value <- [BS.stripPrefix ("Set-Cookie: " <> cookieName <> "=") line]]
  valuesOf "nagare_session" @?= ["access.new"]
  case valuesOf "nagare_refresh" of
    [value] -> decodeRefreshCookieValue "cookie-secret" (TE.decodeUtf8 value) @?= Just "refresh.new"
    other -> assertFailure ("expected one refresh cookie, got " <> show other)
  length cookieLines @?= 2

splitHeadLines :: ByteString -> [ByteString]
splitHeadLines bytes =
  case BS.breakSubstring "\r\n" bytes of
    (line, rest)
      | BS.null rest -> [line]
      | otherwise -> line : splitHeadLines (BS.drop 2 rest)

websocketUpgradeRequest :: ByteString
websocketUpgradeRequest =
  BS.concat
    [ "GET /socket HTTP/1.1\r\n"
    , "Host: tools.example.com\r\n"
    , "Connection: Upgrade\r\n"
    , "Upgrade: websocket\r\n"
    , "Sec-WebSocket-Key: test-key\r\n"
    , "Sec-WebSocket-Version: 13\r\n"
    , "\r\n"
    ]

withTcpConnection :: Int -> (Socket.Socket -> IO a) -> IO a
withTcpConnection port =
  bracket open Socket.close
  where
    open = do
      let hints =
            Socket.defaultHints
              { Socket.addrSocketType = Socket.Stream
              }
      addr : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just (show port))
      socket <- Socket.socket (Socket.addrFamily addr) (Socket.addrSocketType addr) (Socket.addrProtocol addr)
      Socket.connect socket (Socket.addrAddress addr)
      pure socket

readUntil :: Socket.Socket -> ByteString -> IO ByteString
readUntil socket needle =
  go BS.empty
  where
    go acc
      | needle `BS.isInfixOf` acc = pure acc
      | otherwise = do
          chunk <- assertSocketRead socket
          go (acc <> chunk)

assertSocketRead :: Socket.Socket -> IO ByteString
assertSocketRead socket = do
  result <- timeout 1000000 (SocketBS.recv socket 4096)
  case result of
    Just chunk | not (BS.null chunk) -> pure chunk
    Just _ -> assertFailure "socket closed before expected bytes"
    Nothing -> assertFailure "timed out waiting for socket bytes"

refreshCookieValue :: Text -> Text -> IO ByteString
refreshCookieValue key token = do
  header <- assertRight (refreshCookieHeader (signedCookieSettings ".example.test" key) token (Just 2592000))
  maybe (assertFailure "missing refresh cookie value") (pure . BS.takeWhile (/= 59)) (BS.stripPrefix "nagare_refresh=" (snd header))

assertRight :: (HasCallStack, Show a) => Either a b -> IO b
assertRight (Left err) = assertFailure ("expected Right, got Left " <> show err)
assertRight (Right value) = pure value
