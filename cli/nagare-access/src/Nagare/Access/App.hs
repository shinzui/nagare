-- | WAI application shell for nagare-access.
module Nagare.Access.App
  ( app
  , textResponse
  )
where

import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types
  ( Status
  , status200
  , status404
  )
import Network.Wai
  ( Application
  , Response
  , pathInfo
  , requestMethod
  , responseLBS
  )

app :: Application
app req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", ["_nagare", "healthz"]) ->
      respond (textResponse status200 "ok")
    _ ->
      respond (textResponse status404 "not found")

textResponse :: Status -> Text -> Response
textResponse status msg =
  responseLBS status [("Content-Type", "text/plain; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 (msg <> "\n")))
