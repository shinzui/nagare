-- | HTTP responses for access decisions.
--
-- An API request ('JsonApi') is answered with the shared RFC 9457 problem
-- document of @nagare-contract@; a document request keeps its redirect or
-- plain page. Every gateway error is @Cache-Control: no-store@.
module Nagare.Access.Response
  ( UpstreamFailure (..)
  , challengeResponse
  , forbiddenResponse
  , authorizationUnavailableResponse
  , upstreamFailureResponse
  , missingBackendResponse
  , requestShapeFromWai
  , requestShapeFor
  )
where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Nagare.Access.BackendMap (BackendTarget, isApiPath)
import Nagare.Access.Challenge
import Nagare.Access.Prelude
import Nagare.Contract.Problem (ProblemDetails, ProblemSpec, authorizationUnavailable, forbidden, problemFor, unauthenticated, upstreamTimeout, upstreamUnavailable)
import Network.HTTP.Types
  ( Header
  , Status
  , mkStatus
  , status302
  , status403
  , status502
  , status503
  )
import Network.Wai
  ( Request
  , Response
  , rawPathInfo
  , rawQueryString
  , responseLBS
  )
import Network.Wai qualified as Wai

-- | Why a forwarded request got no upstream response.
data UpstreamFailure
  = -- | The upstream could not be reached, or its URL is not usable.
    UpstreamUnreachable
  | -- | The upstream did not send its response headers in time.
    UpstreamTimedOut
  deriving stock (Generic, Eq, Show)

challengeResponse :: ChallengeMode -> Response
challengeResponse (RedirectDocument loginPath) =
  responseLBS status302 [("Location", TE.encodeUtf8 loginPath)] ""
challengeResponse (JsonApi loginPath) =
  problemResponse
    [("WWW-Authenticate", "Bearer")]
    ( problemFor unauthenticated "Sign in, or present a bearer token, for this host."
        & #gatewayError
        ?~ "unauthenticated"
        & #login
        ?~ loginPath
    )

forbiddenResponse :: RequestShape -> Response
forbiddenResponse req =
  case classifyChallenge req of
    RedirectDocument _ ->
      htmlResponse status403 "Forbidden"
    JsonApi _ ->
      problemResponse
        []
        ( problemFor forbidden "The signed-in identity has no grant on this host."
            & #gatewayError
            ?~ "forbidden"
        )

-- | The authorizer could not answer: not a denial, so nothing was cached.
authorizationUnavailableResponse :: RequestShape -> Response
authorizationUnavailableResponse req =
  case classifyChallenge req of
    RedirectDocument _ -> plainResponse status503 "authorization service unavailable\n"
    JsonApi _ -> problemResponse [] (problemFor authorizationUnavailable "The authorization service did not answer; retry later.")

-- | The details never carry the HTTP client's exception text, which can name
-- internal addresses; the caller logs that separately.
upstreamFailureResponse :: RequestShape -> UpstreamFailure -> Response
upstreamFailureResponse req failure =
  case classifyChallenge req of
    RedirectDocument _ -> plainResponse (specStatus spec) (LBS.fromStrict (TE.encodeUtf8 (message <> "\n")))
    JsonApi _ -> problemResponse [] (problemFor spec message)
  where
    (spec, message) = case failure of
      UpstreamUnreachable -> (upstreamUnavailable, "The upstream service is unavailable.")
      UpstreamTimedOut -> (upstreamTimeout, "The upstream service did not answer in time.")

missingBackendResponse :: Text -> Response
missingBackendResponse host =
  responseLBS
    status502
    [("Content-Type", "text/plain; charset=utf-8")]
    ("no backend configured for host " <> textBody host)

-- | A request's shape outside any backend: never an API path.
requestShapeFromWai :: Request -> RequestShape
requestShapeFromWai req =
  RequestShape
    { path = TE.decodeUtf8 (rawPathInfo req <> rawQueryString req)
    , headers = Wai.requestHeaders req
    , api = False
    }

-- | A request's shape for the backend it is routed to.
requestShapeFor :: BackendTarget -> Request -> RequestShape
requestShapeFor target req =
  requestShapeFromWai req
    & #api
    .~ either (const False) (isApiPath target) (TE.decodeUtf8' (rawPathInfo req))

problemResponse :: [Header] -> ProblemDetails -> Response
problemResponse extra problem =
  responseLBS
    (mkStatus (problem ^. #status) (TE.encodeUtf8 (problem ^. #title)))
    ([("Content-Type", "application/problem+json"), ("Cache-Control", "no-store")] <> extra)
    (encode problem)

specStatus :: ProblemSpec -> Status
specStatus spec =
  mkStatus (spec ^. #status) (TE.encodeUtf8 (spec ^. #title))

plainResponse :: Status -> LBS.ByteString -> Response
plainResponse status =
  responseLBS status [("Content-Type", "text/plain; charset=utf-8"), ("Cache-Control", "no-store")]

htmlResponse :: Status -> Text -> Response
htmlResponse status body =
  responseLBS status [("Content-Type", "text/html; charset=utf-8")] (textBody body)

textBody :: Text -> LBS.ByteString
textBody =
  LBS.fromStrict . TE.encodeUtf8
