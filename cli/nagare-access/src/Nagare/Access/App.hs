-- | WAI application shell for nagare-access.
module Nagare.Access.App
  ( app
  , appWithBackends
  , textResponse
  )
where

import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Nagare.Access.BackendMap
import Nagare.Access.Challenge (classifyChallenge)
import Nagare.Access.Response (challengeResponse, missingBackendResponse, requestShapeFromWai)
import Network.HTTP.Types
  ( Status
  , hHost
  , status200
  , status404
  )
import Network.Wai
  ( Application
  , Request
  , Response
  , pathInfo
  , requestHeaders
  , requestMethod
  , responseLBS
  )

app :: Application
app = appWithBackends emptyBackendMap

appWithBackends :: BackendMap -> Application
appWithBackends backends req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", ["_nagare", "healthz"]) ->
      respond (textResponse status200 "ok")
    _ ->
      case lookupHost req >>= (`lookupBackend` backends) of
        Nothing ->
          respond (maybe (textResponse status404 "not found") missingBackendResponse (lookupHost req))
        Just _target ->
          respond (challengeResponse (classifyChallenge (requestShapeFromWai req)))

lookupHost :: Request -> Maybe Text
lookupHost req =
  TE.decodeUtf8 <$> lookup hHost (requestHeaders req)

{- TODO: after token verification and en authorization land, the protected-host
branch above will proxy to the selected BackendTarget instead of always
returning an unauthenticated challenge. -}

textResponse :: Status -> Text -> Response
textResponse status msg =
  responseLBS status [("Content-Type", "text/plain; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 (msg <> "\n")))
