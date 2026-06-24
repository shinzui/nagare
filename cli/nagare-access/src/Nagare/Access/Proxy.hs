-- | Reverse-proxy forwarding for authorized nagare-access requests.
module Nagare.Access.Proxy
  ( buildProxyRequest
  , newProxyManager
  , proxyForwarder
  , proxyResponseToWai
  )
where

import Control.Exception (try)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Access.Auth (AuthenticatedUser (..))
import Nagare.Access.BackendMap (BackendTarget (..))
import Network.HTTP.Client qualified as HC
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types (Header, HeaderName, hHost, status502)
import Network.Wai qualified as Wai

newProxyManager :: IO HC.Manager
newProxyManager = newTlsManager

proxyForwarder :: HC.Manager -> AuthenticatedUser -> Text -> BackendTarget -> Wai.Request -> IO Wai.Response
proxyForwarder manager user publicHost target waiReq = do
  built <- buildProxyRequest user publicHost target waiReq
  case built of
    Left err ->
      pure (badGatewayResponse err)
    Right proxyReq -> do
      upstream <- try (HC.httpLbs proxyReq manager)
      pure $ case upstream of
        Left (err :: HC.HttpException) ->
          badGatewayResponse ("upstream request failed: " <> Text.pack (show err))
        Right response ->
          proxyResponseToWai response

buildProxyRequest :: AuthenticatedUser -> Text -> BackendTarget -> Wai.Request -> IO (Either Text HC.Request)
buildProxyRequest user publicHost target waiReq = do
  body <- Wai.strictRequestBody waiReq
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
          , HC.requestBody = HC.RequestBodyLBS body
          , HC.requestHeaders =
              hardenRequestHeaders publicHost user (Wai.requestHeaders waiReq)
          , HC.redirectCount = 0
          }

proxyResponseToWai :: HC.Response LBS.ByteString -> Wai.Response
proxyResponseToWai response =
  Wai.responseLBS
    (HC.responseStatus response)
    (filterResponseHeaders (HC.responseHeaders response))
    (HC.responseBody response)

hardenRequestHeaders :: Text -> AuthenticatedUser -> [Header] -> [Header]
hardenRequestHeaders publicHost user headers =
  filterRequestHeaders headers
    <> [ ("X-Forwarded-User", TE.encodeUtf8 (userSubject user))
       , ("X-Forwarded-Host", TE.encodeUtf8 publicHost)
       , ("X-Forwarded-Proto", "https")
       ]

filterRequestHeaders :: [Header] -> [Header]
filterRequestHeaders =
  filter (not . shouldStripRequestHeader . fst)

filterResponseHeaders :: [Header] -> [Header]
filterResponseHeaders =
  filter (not . shouldStripResponseHeader . fst)

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
