-- | Reverse-proxy forwarding for authorized nagare-access requests.
module Nagare.Access.Proxy
  ( buildProxyRequest
  , hardenRequestHeaders
  , hardenWebSocketRequestHeaders
  , newProxyManager
  , portalForwarder
  , portalPageFetcher
  , proxyForwarder
  , proxyResponseToWai
  , stripEnforcerCookies
  )
where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, catch, finally, try)
import Control.Monad (unless, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Access.Auth (AuthenticatedUser (..))
import Nagare.Access.Auth (PortalIdentity (..), PortalPageRequest (..), PortalUpstreamResult (..))
import Nagare.Access.BackendMap (BackendTarget (..), Portal (..), publicHostText)
import Nagare.Access.Portal (AccessToken (..), CapturedResponse (..), PortalPage (..), PortalPageKind (..), ReturnTarget (..), decodeSessionHandoff, renderReturnTarget, safePathText)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Client.Internal qualified as HCI
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types (Header, HeaderName, HttpVersion (..), Status (..), hHost, status200, status502, statusCode, statusMessage)
import Network.Wai qualified as Wai

newProxyManager :: IO HC.Manager
newProxyManager = newTlsManager

proxyForwarder :: HC.Manager -> AuthenticatedUser -> Text -> BackendTarget -> Wai.Request -> IO Wai.Response
proxyForwarder manager user publicHost target waiReq = do
  let upgrade = isWebSocketUpgrade waiReq
  built <-
    if upgrade
      then buildWebSocketProxyRequest user publicHost target waiReq
      else buildProxyRequest user publicHost target waiReq
  case built of
    Left err ->
      pure (badGatewayResponse err)
    Right proxyReq
      | upgrade ->
          pure (webSocketProxyResponse manager proxyReq)
      | otherwise -> do
          upstream <- try (HC.responseOpen proxyReq manager)
          pure $ case upstream of
            Left (err :: HC.HttpException) ->
              badGatewayResponse ("upstream request failed: " <> Text.pack (show err))
            Right response ->
              proxyResponseToWai response

-- | Forward a request to the configured portal, intercepting its two trusted
-- session-control response headers before they can reach the browser.
portalForwarder :: HC.Manager -> Portal -> PortalIdentity -> Wai.Request -> IO PortalUpstreamResult
portalForwarder manager portal identity waiReq = do
  let upgrade = isWebSocketUpgrade waiReq
  built <-
    if upgrade
      then buildPortalWebSocketRequest portal identity waiReq
      else buildPortalRequest portal identity waiReq
  case built of
    Left err -> pure (PortalPassThrough (badGatewayResponse err))
    Right proxyReq
      | upgrade -> pure (PortalPassThrough (webSocketProxyResponse manager proxyReq))
      | otherwise -> do
          opened <- try (HC.responseOpen proxyReq manager)
          case opened of
            Left (err :: HC.HttpException) ->
              pure (PortalPassThrough (badGatewayResponse ("upstream request failed: " <> Text.pack (show err))))
            Right response -> interceptPortalResponse response

portalPageFetcher :: HC.Manager -> Portal -> PortalPageRequest -> IO (Maybe PortalPage)
portalPageFetcher manager portal pageRequest = do
  result <- try (fetchPortalPageUnsafe manager portal pageRequest)
  pure (either (const Nothing) id (result :: Either HC.HttpException (Maybe PortalPage)))

fetchPortalPageUnsafe :: HC.Manager -> Portal -> PortalPageRequest -> IO (Maybe PortalPage)
fetchPortalPageUnsafe manager portal pageRequest = do
  baseReq <- HC.parseRequest (Text.unpack (upstreamUrl (portalTarget portal)))
  let request =
        baseReq
          { HC.method = "GET"
          , HC.path = appendPaths (HC.path baseReq) (portalErrorPath (pageKind pageRequest))
          , HC.queryString = ""
          , HC.requestBody = HC.RequestBodyBS BS.empty
          , HC.requestHeaders = portalPageHeaders pageRequest
          , HC.responseTimeout = HC.responseTimeoutMicro 2000000
          , HC.decompress = const False
          , HC.redirectCount = 0
          }
  HC.withResponse request manager $ \response ->
    if HC.responseStatus response /= status200 || not (isHtmlResponse response)
      then pure Nothing
      else do
        body <- readBodyCapped (256 * 1024) (HC.responseBody response)
        pure (PortalPage <$> body)

portalErrorPath :: PortalPageKind -> BS.ByteString
portalErrorPath ForbiddenPage = "/errors/403"
portalErrorPath UnavailablePage = "/errors/503"

portalPageHeaders :: PortalPageRequest -> [Header]
portalPageHeaders pageRequest =
  [ ("Accept", "text/html")
  , ("X-Nagare-Error-Host", TE.encodeUtf8 host)
  , ("X-Nagare-Error-Path", TE.encodeUtf8 path)
  , ("X-Nagare-Return-To", TE.encodeUtf8 (renderReturnTarget target))
  ]
    <> maybe [] (\user -> [("X-Forwarded-User", TE.encodeUtf8 (userSubject user))]) (pageUser pageRequest)
  where
    target = pageTarget pageRequest
    host = publicHostText (targetHost target)
    path = safePathText (targetPath target)

isHtmlResponse :: HC.Response body -> Bool
isHtmlResponse response =
  maybe False (BS.isPrefixOf "text/html" . asciiLower) (lookup "Content-Type" (HC.responseHeaders response))

readBodyCapped :: Int -> HC.BodyReader -> IO (Maybe LBS.ByteString)
readBodyCapped limit reader = go 0 []
  where
    go total chunks = do
      chunk <- HC.brRead reader
      if BS.null chunk
        then pure (Just (LBS.fromChunks (reverse chunks)))
        else
          let newTotal = total + BS.length chunk
           in if newTotal > limit
                then pure Nothing
                else go newTotal (chunk : chunks)

buildProxyRequest :: AuthenticatedUser -> Text -> BackendTarget -> Wai.Request -> IO (Either Text HC.Request)
buildProxyRequest user publicHost target waiReq = do
  parsed <- try (HC.parseRequest (Text.unpack (upstreamUrl target)))
  pure $ case parsed of
    Left (err :: HC.HttpException) ->
      Left ("invalid upstream URL: " <> Text.pack (show err))
    Right baseReq ->
      Right $
        baseReq
          { HC.method = Wai.requestMethod waiReq
          , HC.path = appendPaths (HC.path baseReq) (Wai.rawPathInfo waiReq)
          , HC.queryString = Wai.rawQueryString waiReq
          , HC.requestBody = HC.RequestBodyStreamChunked ($ Wai.getRequestBodyChunk waiReq)
          , HC.requestHeaders =
              hardenRequestHeaders publicHost user (Wai.requestHeaders waiReq)
          , HC.decompress = const False
          , HC.redirectCount = 0
          }

buildPortalRequest :: Portal -> PortalIdentity -> Wai.Request -> IO (Either Text HC.Request)
buildPortalRequest portal identity waiReq = do
  parsed <- try (HC.parseRequest (Text.unpack (upstreamUrl (portalTarget portal))))
  pure $ case parsed of
    Left (err :: HC.HttpException) ->
      Left ("invalid upstream URL: " <> Text.pack (show err))
    Right baseReq ->
      Right $
        baseReq
          { HC.method = Wai.requestMethod waiReq
          , HC.path = appendPaths (HC.path baseReq) (Wai.rawPathInfo waiReq)
          , HC.queryString = Wai.rawQueryString waiReq
          , HC.requestBody = HC.RequestBodyStreamChunked ($ Wai.getRequestBodyChunk waiReq)
          , HC.requestHeaders = portalRequestHeaders portal identity (Wai.requestHeaders waiReq)
          , HC.decompress = const False
          , HC.redirectCount = 0
          }

buildWebSocketProxyRequest :: AuthenticatedUser -> Text -> BackendTarget -> Wai.Request -> IO (Either Text HC.Request)
buildWebSocketProxyRequest user publicHost target waiReq = do
  parsed <- try (HC.parseRequest (Text.unpack (upstreamUrl target)))
  pure $ case parsed of
    Left (err :: HC.HttpException) ->
      Left ("invalid upstream URL: " <> Text.pack (show err))
    Right baseReq ->
      Right $
        baseReq
          { HC.method = Wai.requestMethod waiReq
          , HC.path = appendPaths (HC.path baseReq) (Wai.rawPathInfo waiReq)
          , HC.queryString = Wai.rawQueryString waiReq
          , HC.requestBody = HC.RequestBodyBS BS.empty
          , HC.requestHeaders =
              hardenWebSocketRequestHeaders publicHost user (Wai.requestHeaders waiReq)
          , HC.decompress = const False
          , HC.redirectCount = 0
          }

buildPortalWebSocketRequest :: Portal -> PortalIdentity -> Wai.Request -> IO (Either Text HC.Request)
buildPortalWebSocketRequest portal identity waiReq = do
  parsed <- try (HC.parseRequest (Text.unpack (upstreamUrl (portalTarget portal))))
  pure $ case parsed of
    Left (err :: HC.HttpException) ->
      Left ("invalid upstream URL: " <> Text.pack (show err))
    Right baseReq ->
      Right $
        baseReq
          { HC.method = Wai.requestMethod waiReq
          , HC.path = appendPaths (HC.path baseReq) (Wai.rawPathInfo waiReq)
          , HC.queryString = Wai.rawQueryString waiReq
          , HC.requestBody = HC.RequestBodyBS BS.empty
          , HC.requestHeaders = portalWebSocketRequestHeaders portal identity (Wai.requestHeaders waiReq)
          , HC.decompress = const False
          , HC.redirectCount = 0
          }

proxyResponseToWai :: HC.Response HC.BodyReader -> Wai.Response
proxyResponseToWai response =
  Wai.responseStream
    (HC.responseStatus response)
    (filterResponseHeaders (HC.responseHeaders response))
    ( \write flush ->
        streamResponseBody (HC.responseBody response) write flush
          `finally` HC.responseClose response
    )

interceptPortalResponse :: HC.Response HC.BodyReader -> IO PortalUpstreamResult
interceptPortalResponse response =
  case lookup "Nagare-Session-Establish" (HC.responseHeaders response) of
    Just value -> do
      HC.responseClose response
      pure $
        case decodeSessionHandoff value of
          Left err -> PortalHandoffMalformed err
          Right handoff -> PortalSessionEstablish handoff
    Nothing ->
      case lookup "Nagare-Session-Clear" (HC.responseHeaders response) of
        Just _ -> do
          body <- readBodyAtMost (64 * 1024) (HC.responseBody response)
          HC.responseClose response
          pure
            ( PortalSessionClear
                CapturedResponse
                  { capturedStatus = HC.responseStatus response
                  , capturedHeaders = filterResponseHeaders (HC.responseHeaders response)
                  , capturedBody = LBS.fromStrict body
                  }
            )
        Nothing -> pure (PortalPassThrough (proxyResponseToWai response))

readBodyAtMost :: Int -> HC.BodyReader -> IO BS.ByteString
readBodyAtMost limit reader = go limit []
  where
    go remaining chunks
      | remaining <= 0 = pure (BS.concat (reverse chunks))
      | otherwise = do
          chunk <- HC.brRead reader
          if BS.null chunk
            then pure (BS.concat (reverse chunks))
            else
              let kept = BS.take remaining chunk
               in go (remaining - BS.length kept) (kept : chunks)

streamResponseBody :: HC.BodyReader -> (Builder.Builder -> IO ()) -> IO () -> IO ()
streamResponseBody reader write flush = do
  chunk <- HC.brRead reader
  unless (BS.null chunk) $ do
    write (Builder.byteString chunk)
    flush
    streamResponseBody reader write flush

webSocketProxyResponse :: HC.Manager -> HC.Request -> Wai.Response
webSocketProxyResponse manager proxyReq =
  Wai.responseRaw
    (runWebSocketTunnel manager proxyReq)
    (badGatewayResponse "raw upgrade responses are not supported by this WAI handler")

runWebSocketTunnel :: HC.Manager -> HC.Request -> IO BS.ByteString -> (BS.ByteString -> IO ()) -> IO ()
runWebSocketTunnel manager proxyReq clientRead clientWrite =
  HC.withConnection proxyReq manager (runWithConnection clientRead clientWrite)
    `catch` \(err :: SomeException) ->
      clientWrite (rawBadGateway ("websocket upstream failed: " <> B8.pack (show err)))
  where
    runWithConnection clientRead' clientWrite' conn = do
      sendLater <- HCI.requestBuilder proxyReq conn
      maybe (pure ()) id sendLater
      HCI.StatusHeaders status version earlyHeaders responseHeaders <-
        HCI.parseStatusHeaders Nothing Nothing conn Nothing (\_ -> pure ()) Nothing
      clientWrite' (renderRawResponse version status (earlyHeaders <> responseHeaders))
      when (statusCode status == 101) $
        relayBidirectional conn clientRead' clientWrite'

relayBidirectional :: HCI.Connection -> IO BS.ByteString -> (BS.ByteString -> IO ()) -> IO ()
relayBidirectional conn clientRead clientWrite = do
  done <- newEmptyMVar
  upstreamThread <- forkIO (pump (HCI.connectionRead conn) clientWrite done)
  downstreamThread <- forkIO (pump clientRead (HCI.connectionWrite conn) done)
  takeMVar done
  killThread upstreamThread
  killThread downstreamThread
  where
    pump readChunk writeChunk done =
      let loop = do
            chunk <- readChunk
            unless (BS.null chunk) $ do
              void (writeChunk chunk)
              loop
       in loop `finally` void (tryPutMVar done ())

renderRawResponse :: HttpVersion -> Status -> [Header] -> BS.ByteString
renderRawResponse (HttpVersion major minor) status headers =
  BS.concat
    [ B8.pack ("HTTP/" <> show major <> "." <> show minor <> " " <> show (statusCode status) <> " ")
    , statusMessage status
    , "\r\n"
    , BS.concat (map renderHeader headers)
    , "\r\n"
    ]
  where
    renderHeader (name, value) =
      CI.original name <> ": " <> value <> "\r\n"

rawBadGateway :: BS.ByteString -> BS.ByteString
rawBadGateway msg =
  BS.concat
    [ "HTTP/1.1 502 Bad Gateway\r\n"
    , "Content-Type: text/plain; charset=utf-8\r\n"
    , "Content-Length: "
    , B8.pack (show (BS.length msg))
    , "\r\n\r\n"
    , msg
    ]

hardenRequestHeaders :: Text -> AuthenticatedUser -> [Header] -> [Header]
hardenRequestHeaders publicHost user headers =
  ensureAcceptEncodingHeader (stripEnforcerCookies (filterRequestHeaders headers))
    <> [ ("X-Forwarded-User", TE.encodeUtf8 (userSubject user))
       , ("X-Forwarded-Host", TE.encodeUtf8 publicHost)
       , ("X-Forwarded-Proto", "https")
       ]

hardenWebSocketRequestHeaders :: Text -> AuthenticatedUser -> [Header] -> [Header]
hardenWebSocketRequestHeaders publicHost user headers =
  ensureAcceptEncodingHeader (stripEnforcerCookies (filterWebSocketRequestHeaders headers))
    <> [ ("X-Forwarded-User", TE.encodeUtf8 (userSubject user))
       , ("X-Forwarded-Host", TE.encodeUtf8 publicHost)
       , ("X-Forwarded-Proto", "https")
       ]

portalRequestHeaders :: Portal -> PortalIdentity -> [Header] -> [Header]
portalRequestHeaders portal identity headers =
  ensureAcceptEncodingHeader (stripEnforcerCookies (filter portalHeaderAllowed (filterRequestHeaders headers)))
    <> portalIdentityHeaders identity
    <> [ ("X-Forwarded-Host", TE.encodeUtf8 (publicHostText (portalHost portal)))
       , ("X-Forwarded-Proto", "https")
       ]

portalWebSocketRequestHeaders :: Portal -> PortalIdentity -> [Header] -> [Header]
portalWebSocketRequestHeaders portal identity headers =
  ensureAcceptEncodingHeader (stripEnforcerCookies (filter portalHeaderAllowed (filterWebSocketRequestHeaders headers)))
    <> portalIdentityHeaders identity
    <> [ ("X-Forwarded-Host", TE.encodeUtf8 (publicHostText (portalHost portal)))
       , ("X-Forwarded-Proto", "https")
       ]

portalHeaderAllowed :: Header -> Bool
portalHeaderAllowed (name, _) =
  name `notElem` ["Authorization", "Nagare-Session-Establish", "Nagare-Session-Clear"]

portalIdentityHeaders :: PortalIdentity -> [Header]
portalIdentityHeaders PortalAnonymous = []
portalIdentityHeaders (PortalAuthenticated user (AccessToken token)) =
  [ ("X-Forwarded-User", TE.encodeUtf8 (userSubject user))
  , ("Authorization", "Bearer " <> TE.encodeUtf8 token)
  ]

ensureAcceptEncodingHeader :: [Header] -> [Header]
ensureAcceptEncodingHeader headers
  | any ((== "Accept-Encoding") . fst) headers = headers
  | otherwise = ("Accept-Encoding", "") : headers

isWebSocketUpgrade :: Wai.Request -> Bool
isWebSocketUpgrade waiReq =
  hasHeaderToken "Connection" "upgrade" (Wai.requestHeaders waiReq)
    && hasHeaderToken "Upgrade" "websocket" (Wai.requestHeaders waiReq)

hasHeaderToken :: HeaderName -> BS.ByteString -> [Header] -> Bool
hasHeaderToken name expected headers =
  any (tokenMatches expected) [value | (headerName, value) <- headers, headerName == name]

tokenMatches :: BS.ByteString -> BS.ByteString -> Bool
tokenMatches expected value =
  let expectedLower = asciiLower expected
   in expectedLower `elem` map (B8.dropWhile (== ' ') . B8.dropWhileEnd (== ' ') . asciiLower) (B8.split ',' value)

asciiLower :: BS.ByteString -> BS.ByteString
asciiLower =
  B8.map toLower

filterRequestHeaders :: [Header] -> [Header]
filterRequestHeaders =
  filter (not . shouldStripRequestHeader . fst)

filterWebSocketRequestHeaders :: [Header] -> [Header]
filterWebSocketRequestHeaders =
  filter (not . shouldStripWebSocketRequestHeader . fst)

filterResponseHeaders :: [Header] -> [Header]
filterResponseHeaders =
  filter (not . shouldStripResponseHeader . fst)

-- | Remove cookies owned by nagare-access before a request reaches any app.
-- Unrelated application cookies retain their order and are normalized to the
-- conventional @name=value; name=value@ form.
stripEnforcerCookies :: [Header] -> [Header]
stripEnforcerCookies = foldr stripOne []
  where
    stripOne (name, value) kept
      | name /= "Cookie" = (name, value) : kept
      | otherwise =
          case filter (not . isEnforcerCookie) (cookiePairs value) of
            [] -> kept
            pairs -> (name, B8.intercalate "; " pairs) : kept

    cookiePairs = filter (not . BS.null) . map trim . B8.split ';'
    trim = B8.dropWhile (== ' ') . B8.dropWhileEnd (== ' ')
    isEnforcerCookie pair =
      let cookieName = trim (fst (B8.break (== '=') pair))
       in cookieName `elem` ["nagare_session", "nagare_refresh", "__Host-nagare_csrf"]

shouldStripRequestHeader :: HeaderName -> Bool
shouldStripRequestHeader name =
  name
    `elem` [ hHost
           , "Content-Length"
           , "Transfer-Encoding"
           , "Connection"
           , "Keep-Alive"
           , "Proxy-Authenticate"
           , "Proxy-Authorization"
           , "TE"
           , "Trailer"
           , "Upgrade"
           , "X-Forwarded-User"
           , "X-Forwarded-Host"
           , "X-Forwarded-Proto"
           ]

shouldStripWebSocketRequestHeader :: HeaderName -> Bool
shouldStripWebSocketRequestHeader name =
  name
    `elem` [ hHost
           , "Content-Length"
           , "Transfer-Encoding"
           , "Proxy-Authenticate"
           , "Proxy-Authorization"
           , "TE"
           , "Trailer"
           , "X-Forwarded-User"
           , "X-Forwarded-Host"
           , "X-Forwarded-Proto"
           ]

shouldStripResponseHeader :: HeaderName -> Bool
shouldStripResponseHeader name =
  name
    `elem` [ "Transfer-Encoding"
           , "Connection"
           , "Keep-Alive"
           , "Proxy-Authenticate"
           , "Proxy-Authorization"
           , "TE"
           , "Trailer"
           , "Upgrade"
           , "Nagare-Session-Establish"
           , "Nagare-Session-Clear"
           ]

appendPaths :: BS.ByteString -> BS.ByteString -> BS.ByteString
appendPaths base incoming
  | BS.null base || base == "/" = normalizedIncoming
  | normalizedIncoming == "/" = base
  | "/" `BS.isSuffixOf` base = base <> BS.dropWhile (== slash) normalizedIncoming
  | otherwise = base <> normalizedIncoming
  where
    normalizedIncoming
      | BS.null incoming = "/"
      | "/" `BS.isPrefixOf` incoming = incoming
      | otherwise = "/" <> incoming
    slash = 47

badGatewayResponse :: Text -> Wai.Response
badGatewayResponse msg =
  Wai.responseLBS
    status502
    [("Content-Type", "text/plain; charset=utf-8")]
    (LBS.fromStrict (TE.encodeUtf8 msg))
