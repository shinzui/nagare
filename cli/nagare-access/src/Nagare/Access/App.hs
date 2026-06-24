-- | WAI application shell for nagare-access.
module Nagare.Access.App
  ( app
  , appWithBackends
  , appWithRuntime
  , textResponse
  )
where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Function ((&))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.Challenge (classifyChallenge, safeReturnDestination)
import Nagare.Access.Cookie (clearSessionCookieHeader, csrfCookieHeader, sessionCookieHeader)
import Nagare.Access.Credential (extractCredential)
import Nagare.Access.DecisionCache
import Nagare.Access.Response (challengeResponse, forbiddenResponse, missingBackendResponse, requestShapeFromWai)
import Network.HTTP.Types
  ( HeaderName
  , Status
  , hHost
  , hLocation
  , parseQuery
  , status200
  , status302
  , status400
  , status401
  , status403
  , status404
  , status500
  )
import Network.Wai
  ( Application
  , Request
  , Response
  , pathInfo
  , rawQueryString
  , requestHeaders
  , requestMethod
  , responseLBS
  , strictRequestBody
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
    ("GET", ["_nagare", "login"]) ->
      respond =<< loginFormResponse services req
    ("POST", ["_nagare", "login"]) ->
      respond =<< loginSubmitResponse services req
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
    , loginUser = \_ -> pure (LoginFailed "login is not configured")
    , newCsrfToken = pure "csrf-token"
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

loginFormResponse :: AccessServices -> Request -> IO Response
loginFormResponse services req = do
  csrf <- newCsrfToken services
  pure $
    case csrfCookieHeader csrf 600 of
      Left err ->
        textResponse status500 err
      Right csrfHeader ->
        responseLBS
          status200
          [("Content-Type", "text/html; charset=utf-8"), csrfHeader]
          (LBS.fromStrict (TE.encodeUtf8 (loginFormHtml csrf returnDestination)))
  where
    returnDestination =
      safeReturnDestination (maybe "/" id (queryTextValue "rd" (rawQueryString req)))
        & maybe "/" id

loginSubmitResponse :: AccessServices -> Request -> IO Response
loginSubmitResponse services req = do
  body <- strictRequestBody req
  let form = parseQuery (LBS.toStrict body)
      csrfFromForm = formTextValue "csrf" form
      csrfFromCookie = cookieTextValue "__Host-nagare_csrf" (requestHeaders req)
  case (csrfFromForm, csrfFromCookie) of
    (Just submitted, Just stored)
      | submitted == stored ->
          submitLogin services form
    _ ->
      pure (textResponse status403 "csrf validation failed")

submitLogin :: AccessServices -> [(BS.ByteString, Maybe BS.ByteString)] -> IO Response
submitLogin services form =
  case loginCredentialsFromForm form of
    Nothing ->
      pure (textResponse status400 "missing login credentials")
    Just credentials -> do
      outcome <- loginUser services credentials
      pure $ case outcome of
        LoginSucceeded tokens ->
          loginSuccessResponse services tokens returnDestination
        LoginMfaRequired ->
          textResponse status401 "mfa required"
        LoginFailed _ ->
          textResponse status401 "invalid login"
  where
    returnDestination =
      safeReturnDestination (maybe "/" id (formTextValue "rd" form))
        & maybe "/" id

loginSuccessResponse :: AccessServices -> SessionTokens -> Text -> Response
loginSuccessResponse services tokens returnDestination =
  case cookieSettings services of
    Nothing ->
      textResponse status500 "login is not configured"
    Just settings ->
      case sessionCookieHeader settings (accessToken tokens) (expiresIn tokens) of
        Left err ->
          textResponse status500 err
        Right sessionHeader ->
          responseLBS status302 [(hLocation, TE.encodeUtf8 returnDestination), sessionHeader] ""

loginCredentialsFromForm :: [(BS.ByteString, Maybe BS.ByteString)] -> Maybe LoginCredentials
loginCredentialsFromForm form = do
  password <- nonEmpty =<< formTextValue "password" form
  let loginIdValue = nonEmpty =<< formTextValue "loginId" form
      emailValue = nonEmpty =<< formTextValue "email" form
  if loginIdValue == Nothing && emailValue == Nothing
    then Nothing
    else
      Just
        LoginCredentials
          { loginCredentialId = loginIdValue
          , loginCredentialEmail = emailValue
          , loginCredentialPassword = password
          }

queryTextValue :: BS.ByteString -> BS.ByteString -> Maybe Text
queryTextValue name query =
  formTextValue name (parseQuery query)

formTextValue :: BS.ByteString -> [(BS.ByteString, Maybe BS.ByteString)] -> Maybe Text
formTextValue name form =
  lookup name form >>= (>>= decodeUtf8Maybe)

cookieTextValue :: BS.ByteString -> [(HeaderName, BS.ByteString)] -> Maybe Text
cookieTextValue name headers =
  lookup "Cookie" headers >>= lookupCookie name >>= decodeUtf8Maybe

lookupCookie :: BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
lookupCookie name cookieHeader =
  lookup name (parseCookieHeader cookieHeader)

parseCookieHeader :: BS.ByteString -> [(BS.ByteString, BS.ByteString)]
parseCookieHeader =
  map parsePair . BC.split ';'
  where
    parsePair chunk =
      let (key, valueWithEquals) = BS.break (== 61) (trim chunk)
       in (key, BS.drop 1 valueWithEquals)

trim :: BS.ByteString -> BS.ByteString
trim =
  BC.dropWhile (== ' ') . fst . BC.spanEnd (== ' ')

decodeUtf8Maybe :: BS.ByteString -> Maybe Text
decodeUtf8Maybe =
  either (const Nothing) Just . TE.decodeUtf8'

nonEmpty :: Text -> Maybe Text
nonEmpty value
  | Text.null (Text.strip value) = Nothing
  | otherwise = Just value

loginFormHtml :: Text -> Text -> Text
loginFormHtml csrf returnDestination =
  Text.concat
    [ "<!doctype html><html><head><meta charset=\"utf-8\"><title>Sign in</title>"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    , "</head><body><main><h1>Sign in</h1>"
    , "<form method=\"post\" action=\"/_nagare/login\">"
    , "<input type=\"hidden\" name=\"csrf\" value=\""
    , htmlEscape csrf
    , "\">"
    , "<input type=\"hidden\" name=\"rd\" value=\""
    , htmlEscape returnDestination
    , "\">"
    , "<label>Login <input name=\"loginId\" autocomplete=\"username\"></label>"
    , "<label>Password <input name=\"password\" type=\"password\" autocomplete=\"current-password\"></label>"
    , "<button type=\"submit\">Sign in</button>"
    , "</form></main></body></html>"
    ]

htmlEscape :: Text -> Text
htmlEscape =
  Text.concatMap escapeChar
  where
    escapeChar '&' = "&amp;"
    escapeChar '<' = "&lt;"
    escapeChar '>' = "&gt;"
    escapeChar '"' = "&quot;"
    escapeChar '\'' = "&#39;"
    escapeChar c = Text.singleton c
