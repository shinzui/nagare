-- | HTTP responses for access decisions.
module Nagare.Access.Response
  ( challengeResponse
  , forbiddenResponse
  , missingBackendResponse
  , requestShapeFromWai
  )
where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Nagare.Access.Challenge
import Network.HTTP.Types
  ( Status
  , status302
  , status401
  , status403
  , status502
  )
import Network.Wai
  ( Request
  , Response
  , rawPathInfo
  , rawQueryString
  , responseLBS
  )
import Network.Wai qualified as Wai

challengeResponse :: ChallengeMode -> Response
challengeResponse (RedirectDocument loginPath) =
  responseLBS status302 [("Location", TE.encodeUtf8 loginPath)] ""
challengeResponse (JsonApi loginPath) =
  jsonResponse status401 (object ["error" .= ("unauthenticated" :: Text), "login" .= loginPath])

forbiddenResponse :: RequestShape -> Response
forbiddenResponse req =
  case classifyChallenge req of
    RedirectDocument _ ->
      htmlResponse status403 "Forbidden"
    JsonApi _ ->
      jsonResponse status403 (object ["error" .= ("forbidden" :: Text)])

missingBackendResponse :: Text -> Response
missingBackendResponse host =
  responseLBS
    status502
    [("Content-Type", "text/plain; charset=utf-8")]
    ("no backend configured for host " <> textBody host)

requestShapeFromWai :: Request -> RequestShape
requestShapeFromWai req =
  RequestShape
    { requestPath = TE.decodeUtf8 (rawPathInfo req <> rawQueryString req)
    , requestHeaders = Wai.requestHeaders req
    }

jsonResponse :: Status -> Value -> Response
jsonResponse status body =
  responseLBS status [("Content-Type", "application/json; charset=utf-8")] (encode body)

htmlResponse :: Status -> Text -> Response
htmlResponse status body =
  responseLBS status [("Content-Type", "text/html; charset=utf-8")] (textBody body)

textBody :: Text -> LBS.ByteString
textBody =
  LBS.fromStrict . TE.encodeUtf8
