-- | WAI application shell for nagare-access.
module Nagare.Access.App
  ( app
  , appWithBackends
  , appWithRuntime
  , textResponse
  )
where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.Challenge (classifyChallenge)
import Nagare.Access.Cookie (clearSessionCookieHeader)
import Nagare.Access.Credential (extractCredential)
import Nagare.Access.DecisionCache
import Nagare.Access.Response (challengeResponse, forbiddenResponse, missingBackendResponse, requestShapeFromWai)
import Network.HTTP.Types
  ( Status
  , hHost
  , hLocation
  , status200
  , status302
  , status401
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
appWithBackends backends =
  appWithRuntime backends defaultAccessServices

appWithRuntime :: BackendMap -> AccessServices -> Application
appWithRuntime backends services req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", ["_nagare", "healthz"]) ->
      respond (textResponse status200 "ok")
    ("GET", ["_nagare", "userinfo"]) ->
      respond =<< userInfoResponse services req
    ("GET", ["_nagare", "logout"]) ->
      respond (logoutResponse services)
    _ ->
      case lookupHost req >>= (`lookupBackendWithHost` backends) of
        Nothing ->
          respond (maybe (textResponse status404 "not found") missingBackendResponse (lookupHost req))
        Just (host, target) ->
          respond =<< handleProtected services host req target

handleProtected :: AccessServices -> Text -> Request -> BackendTarget -> IO Response
handleProtected services host req target =
  case extractCredential (requestHeaders req) of
    Nothing ->
      pure (challengeResponse challenge)
    Just credential -> do
      verified <- verifyCredential services credential
      case verified of
        Left _ ->
          pure (challengeResponse challenge)
        Right user -> do
          decision <-
            cacheLookupOrLoad
              (decisionCache services)
              DecisionKey {subject = userSubject user, host = host}
              (authorizeUser services user host)
          case decision of
            AccessAllowed ->
              forwardAuthorized services user host target req
            AccessDenied ->
              pure (forbiddenResponse requestShape)
            AccessConditional ->
              pure (forbiddenResponse requestShape)
  where
    requestShape = requestShapeFromWai req
    challenge = classifyChallenge requestShape

lookupHost :: Request -> Maybe Text
lookupHost req =
  TE.decodeUtf8 <$> lookup hHost (requestHeaders req)

defaultAccessServices :: AccessServices
defaultAccessServices =
  AccessServices
    { verifyCredential = \_ -> pure (Left InvalidCredential)
    , authorizeUser = \_ _ -> pure AccessDenied
    , forwardAuthorized = \_ _ _ _ -> pure (textResponse status404 "not found")
    , decisionCache = disabledDecisionCache
    , cookieSettings = Nothing
    }

textResponse :: Status -> Text -> Response
textResponse status msg =
  responseLBS status [("Content-Type", "text/plain; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 (msg <> "\n")))

userInfoResponse :: AccessServices -> Request -> IO Response
userInfoResponse services req =
  case extractCredential (requestHeaders req) of
    Nothing ->
      pure unauthenticatedUserInfoResponse
    Just credential -> do
      verified <- verifyCredential services credential
      pure $ case verified of
        Left _ ->
          unauthenticatedUserInfoResponse
        Right user ->
          jsonResponse status200 (object ["authenticated" .= True, "user" .= userSubject user])

unauthenticatedUserInfoResponse :: Response
unauthenticatedUserInfoResponse =
  jsonResponse status401 (object ["authenticated" .= False])

logoutResponse :: AccessServices -> Response
logoutResponse services =
  responseLBS
    status302
    headers
    ""
  where
    headers =
      [(hLocation, "/_nagare/login")]
        <> case cookieSettings services >>= either (const Nothing) Just . clearSessionCookieHeader of
          Nothing -> []
          Just header -> [header]

jsonResponse :: Status -> Value -> Response
jsonResponse status body =
  responseLBS status [("Content-Type", "application/json; charset=utf-8")] (encode body)
