-- | WAI application shell for nagare-access.
module Nagare.Access.App
  ( app
  , appWithBackends
  , appWithRuntime
  , textResponse
  )
where

import Nagare.Access.Prelude hiding ((.=))
import Data.Generics.Labels ()

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.Aeson (FromJSON (parseJSON), Value, eitherDecode, encode, object, withObject, (.:), (.:?), (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Function ((&))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.Challenge (ChallengeMode (..), RequestShape, classifyChallenge, safeReturnDestination)
import Nagare.Access.Challenge qualified as Challenge
import Nagare.Access.Cookie
  ( CookieSettings (cookieKey)
  , clearRefreshCookieHeader
  , clearSessionCookieHeader
  , csrfCookieHeader
  , decodeRefreshCookieValue
  , refreshCookieHeader
  , sessionCookieHeader
  )
import Nagare.Access.Credential (Credential (SessionCookie), credentialToken, extractCredential)
import Nagare.Access.DecisionCache
import Nagare.Access.Portal
import Nagare.Access.Response (challengeResponse, forbiddenResponse, missingBackendResponse, requestShapeFromWai)
import Network.HTTP.Types
  ( Header
  , HeaderName
  , Status
  , hHost
  , hLocation
  , parseQuery
  , status200
  , status302
  , status303
  , status400
  , status401
  , status403
  , status404
  , status500
  , status503
  )
import Network.Wai
  ( Application
  , Request
  , Response
  , mapResponseHeaders
  , pathInfo
  , rawQueryString
  , requestHeaders
  , requestMethod
  , responseLBS
  , strictRequestBody
  )

defaultRefreshCookieMaxAgeSeconds :: Int
defaultRefreshCookieMaxAgeSeconds = 30 * 24 * 60 * 60

app :: Application
app = appWithBackends emptyBackendMap

appWithBackends :: BackendMap -> Application
appWithBackends backends =
  appWithRuntime backends defaultAccessServices

data LoginPage
  = BuiltinLoginPage
  | PortalLoginPage !Portal
  deriving stock (Generic, Eq, Show)

appWithRuntime :: BackendMap -> AccessServices -> Application
appWithRuntime backends services req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", ["_nagare", "healthz"]) ->
      respond (textResponse status200 "ok")
    ("GET", ["_nagare", "userinfo"]) ->
      respond =<< userInfoResponse services req
    ("GET", ["_nagare", "logout"]) ->
      respond =<< logoutResponse backends services req
    ("GET", ["_nagare", "login"]) ->
      respond =<< loginGetResponse backends services req
    ("POST", ["_nagare", "login"]) ->
      respond =<< loginSubmitResponse services req
    ("POST", ["_nagare", "mfa", "complete"]) ->
      respond =<< mfaCompleteResponse services req
    _ ->
      case lookupHost req >>= (`lookupBackendWithHost` backends) of
        Nothing ->
          respond (maybe (textResponse status404 "not found") missingBackendResponse (lookupHost req))
        Just (host, target) ->
          case target ^. #role of
            ProtectedBackend -> respond =<< handleProtected services (loginPageFor backends) host req target
            PortalBackend ->
              case findPortal backends of
                Just portal -> respond =<< handlePortal backends services portal req
                Nothing -> respond (textResponse status500 "portal backend is inconsistent")

handleProtected :: AccessServices -> LoginPage -> PublicHost -> Request -> BackendTarget -> IO Response
handleProtected services loginPage host req target = do
  authenticated <- authenticateRequest services req challenge
  case authenticated of
    Left response ->
      pure response
    Right (user, responseHeaders) -> do
      outcome <-
        cacheLookupOrLoad
          (services ^. #decisionCache)
          DecisionKey {subject = user ^. #subject, host = hostText}
          ((services ^. #authorizeUser) user hostText)
      case outcome of
        AuthorizationDecision AccessAllowed ->
          addResponseHeaders responseHeaders <$> (services ^. #forwardAuthorized) user hostText target req
        -- AccessDenied and AccessConditional are both a refusal: 403.
        AuthorizationDecision _ -> do
          denied <- portalDecisionResponse services loginPage ForbiddenPage status403 host requestShape user (forbiddenResponse requestShape)
          pure (addResponseHeaders responseHeaders denied)
        -- The authorizer is down. This is not a denial and must not be
        -- presented as one: 503 tells the caller (and any retry logic) that
        -- the answer is unknown, and nothing was written to the cache.
        AuthorizationUnavailable _ -> do
          unavailable <-
            portalDecisionResponse
              services
              loginPage
              UnavailablePage
              status503
              host
              requestShape
              user
              (textResponse status503 "authorization service unavailable")
          pure (addResponseHeaders responseHeaders unavailable)
  where
    hostText = publicHostText host
    requestShape = requestShapeFromWai req
    challenge = challengeFor loginPage host requestShape

loginPageFor :: BackendMap -> LoginPage
loginPageFor = maybe BuiltinLoginPage PortalLoginPage . findPortal

challengeFor :: LoginPage -> PublicHost -> RequestShape -> ChallengeMode
challengeFor BuiltinLoginPage _ requestShape = classifyChallenge requestShape
challengeFor (PortalLoginPage portal) host requestShape =
  case classifyChallenge requestShape of
    RedirectDocument _ -> RedirectDocument login
    JsonApi _ -> JsonApi login
  where
    target = ReturnTarget host <$> requestSafePath requestShape
    login = portalLoginUrl portal Nothing target

portalDecisionResponse :: AccessServices -> LoginPage -> PortalPageKind -> Status -> PublicHost -> RequestShape -> AuthenticatedUser -> Response -> IO Response
portalDecisionResponse services loginPage kind status host requestShape user fallback =
  case (loginPage, classifyChallenge requestShape) of
    (PortalLoginPage portal, RedirectDocument _) ->
      case requestSafePath requestShape of
        Nothing -> pure fallback
        Just path -> do
          page <-
            (services ^. #fetchPortalPage)
              portal
              PortalPageRequest
                { kind = kind
                , target = ReturnTarget host path
                , user = Just user
                }
          pure (maybe fallback (portalPageResponse status) page)
    _ -> pure fallback

requestSafePath :: RequestShape -> Maybe SafePath
requestSafePath requestShape =
  mkSafePath $
    if Text.null (requestShape ^. #path)
      then "/"
      else requestShape ^. #path

loginGetResponse :: BackendMap -> AccessServices -> Request -> IO Response
loginGetResponse backends services req =
  case loginPageFor backends of
    BuiltinLoginPage -> loginFormResponse services req
    PortalLoginPage portal
      | queryTextValue "builtin" (rawQueryString req) == Just "1" -> loginFormResponse services req
      | otherwise ->
          pure
            ( responseLBS
                status302
                [(hLocation, TE.encodeUtf8 (portalLoginUrl portal Nothing returnTarget))]
                ""
            )
      where
        returnTarget = do
          rawHost <- lookupHost req
          host <- either (const Nothing) Just (mkPublicHost rawHost)
          path <- mkSafePath (maybe "/" id (queryTextValue "rd" (rawQueryString req)))
          pure ReturnTarget {host = host, path = path}

authenticateRequest :: AccessServices -> Request -> ChallengeMode -> IO (Either Response (AuthenticatedUser, [Header]))
authenticateRequest services req challenge =
  case extractCredential (requestHeaders req) of
    Nothing ->
      refreshOrChallenge services req challenge
    Just credential -> do
      verified <- (services ^. #verifyCredential) credential
      case verified of
        Right user ->
          pure (Right (user, []))
        Left _ ->
          refreshOrChallenge services req challenge

refreshOrChallenge :: AccessServices -> Request -> ChallengeMode -> IO (Either Response (AuthenticatedUser, [Header]))
refreshOrChallenge services req challenge =
  case refreshTokenFromRequest services req of
    Nothing ->
      pure (Left (challengeResponse challenge))
    Just refreshToken -> do
      outcome <- (services ^. #refreshUserSession) refreshToken
      case outcome of
        LoginSucceeded tokens -> do
          verified <- (services ^. #verifyCredential) (SessionCookie (tokens ^. #accessToken))
          case verified of
            Right user ->
              pure (Right (user, either (const []) id (sessionHeaders services tokens)))
            Left _ ->
              pure (Left (clearAuthCookies services (challengeResponse challenge)))
        LoginMfaRequired _ ->
          pure (Left (clearAuthCookies services (challengeResponse challenge)))
        LoginFailed _ ->
          pure (Left (clearAuthCookies services (challengeResponse challenge)))

handlePortal :: BackendMap -> AccessServices -> Portal -> Request -> IO Response
handlePortal backends services portal req = do
  (identity, authenticationHeaders) <- authenticatePortal services req
  upstream <- (services ^. #forwardPortal) portal identity req
  case upstream of
    PortalPassThrough response ->
      pure (addResponseHeaders authenticationHeaders response)
    PortalSessionEstablish handoff -> do
      established <- runExceptT (establishSession services backends portal handoff)
      case established of
        Left failure -> do
          putStrLn ("auth portal session hand-off failed: " <> show failure)
          pure (handoffFailureResponse portal)
        Right (target, headers) ->
          pure (handoffSuccessResponse req target headers)
    PortalHandoffMalformed reason -> do
      putStrLn ("auth portal session hand-off failed: " <> show (HandoffMalformed reason))
      pure (handoffFailureResponse portal)
    PortalSessionClear captured -> do
      case identity of
        PortalAuthenticated _ token -> (services ^. #revokeSession) token
        PortalAnonymous -> pure ()
      pure
        ( responseLBS
            (captured ^. #status)
            (clearAuthCookieHeaders services <> captured ^. #headers)
            (captured ^. #body)
        )

authenticatePortal :: AccessServices -> Request -> IO (PortalIdentity, [Header])
authenticatePortal services req =
  case extractCredential (requestHeaders req) of
    Nothing -> refreshPortalIdentity services req
    Just credential -> do
      verified <- (services ^. #verifyCredential) credential
      case verified of
        Right user -> pure (PortalAuthenticated user (AccessToken (credentialToken credential)), [])
        Left _ -> refreshPortalIdentity services req

refreshPortalIdentity :: AccessServices -> Request -> IO (PortalIdentity, [Header])
refreshPortalIdentity services req =
  case refreshTokenFromRequest services req of
    Nothing -> pure (PortalAnonymous, [])
    Just refresh -> do
      outcome <- (services ^. #refreshUserSession) refresh
      case outcome of
        LoginSucceeded tokens -> do
          verified <- (services ^. #verifyCredential) (SessionCookie (tokens ^. #accessToken))
          case verified of
            Right user ->
              pure
                ( PortalAuthenticated user (AccessToken (tokens ^. #accessToken))
                , either (const []) id (sessionHeaders services tokens)
                )
            Left _ -> pure (PortalAnonymous, clearAuthCookieHeaders services)
        LoginMfaRequired _ -> pure (PortalAnonymous, clearAuthCookieHeaders services)
        LoginFailed _ -> pure (PortalAnonymous, clearAuthCookieHeaders services)

data HandoffFailure
  = HandoffMalformed !Text
  | HandoffAccessTokenRejected
  | HandoffRefreshFailed
  | HandoffRefreshedTokenRejected
  | HandoffCookieCreationFailed
  deriving stock (Generic, Eq, Show)

establishSession :: AccessServices -> BackendMap -> Portal -> SessionHandoff -> ExceptT HandoffFailure IO (ReturnTarget, [Header])
establishSession services backends portal handoff = do
  let AccessToken initialAccess = handoff ^. #accessToken
      RefreshToken initialRefresh = handoff ^. #refreshToken
  initialVerified <- lift ((services ^. #verifyCredential) (SessionCookie initialAccess))
  case initialVerified of
    Left _ -> throwE HandoffAccessTokenRejected
    Right _ -> pure ()
  refreshed <- lift ((services ^. #refreshUserSession) initialRefresh)
  tokens <- case refreshed of
    LoginSucceeded sessionTokens | sessionTokens ^. #refreshToken /= Nothing -> pure sessionTokens
    _ -> throwE HandoffRefreshFailed
  refreshedVerified <- lift ((services ^. #verifyCredential) (SessionCookie (tokens ^. #accessToken)))
  case refreshedVerified of
    Left _ -> throwE HandoffRefreshedTokenRejected
    Right _ -> pure ()
  headers <- either (const (throwE HandoffCookieCreationFailed)) pure (sessionHeaders services tokens)
  let target =
        fromMaybe
          (portalHome portal)
          (handoff ^. #returnTo >>= parseReturnTarget backends)
  pure (target, headers)

handoffSuccessResponse :: Request -> ReturnTarget -> [Header] -> Response
handoffSuccessResponse req target headers =
  case classifyChallenge (requestShapeFromWai req) of
    RedirectDocument _ -> responseLBS status303 ((hLocation, TE.encodeUtf8 rendered) : headers) ""
    JsonApi _ -> jsonResponseWithHeaders status200 headers (object ["redirect" .= rendered])
  where
    rendered = renderReturnTarget target

handoffFailureResponse :: Portal -> Response
handoffFailureResponse portal =
  responseLBS
    status303
    [(hLocation, TE.encodeUtf8 (portalLoginUrl portal (Just SessionFailed) Nothing))]
    ""

-- | The @Host@ header as text, or 'Nothing' when it is absent *or* not valid
-- UTF-8. A hostile client can send arbitrary bytes here; the strict
-- 'TE.decodeUtf8' throws an imprecise exception when the resulting 'Text' is
-- forced, which crashes the handler with a 500 instead of answering.
lookupHost :: Request -> Maybe Text
lookupHost req =
  lookup hHost (requestHeaders req) >>= decodeUtf8Maybe

defaultAccessServices :: AccessServices
defaultAccessServices =
  AccessServices
    { verifyCredential = \_ -> pure (Left InvalidCredential)
    , authorizeUser = \_ _ -> pure (AuthorizationDecision AccessDenied)
    , forwardAuthorized = \_ _ _ _ -> pure (textResponse status404 "not found")
    , loginUser = \_ -> pure (LoginFailed "login is not configured")
    , completeMfa = \_ -> pure (LoginFailed "mfa is not configured")
    , refreshUserSession = \_ -> pure (LoginFailed "refresh is not configured")
    , revokeSession = \_ -> pure ()
    , forwardPortal = \_ _ _ -> pure (PortalPassThrough (textResponse status404 "not found"))
    , fetchPortalPage = \_ _ -> pure Nothing
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
      verified <- (services ^. #verifyCredential) credential
      pure $ case verified of
        Left _ ->
          unauthenticatedUserInfoResponse
        Right user ->
          jsonResponse status200 (object ["authenticated" .= True, "user" .= (user ^. #subject)])

unauthenticatedUserInfoResponse :: Response
unauthenticatedUserInfoResponse =
  jsonResponse status401 (object ["authenticated" .= False])

logoutResponse :: BackendMap -> AccessServices -> Request -> IO Response
logoutResponse backends services req = do
  case extractCredential (requestHeaders req) of
    Nothing -> pure ()
    Just credential -> do
      verified <- (services ^. #verifyCredential) credential
      case verified of
        Right _ -> (services ^. #revokeSession) (AccessToken (credentialToken credential))
        Left _ -> pure ()
  pure (responseLBS status302 headers "")
  where
    destination =
      maybe
        "/_nagare/login"
        (\portal -> portalLoginUrl portal (Just LoggedOut) Nothing)
        (findPortal backends)
    headers =
      [(hLocation, TE.encodeUtf8 destination)]
        <> clearAuthCookieHeaders services

jsonResponse :: Status -> Value -> Response
jsonResponse status body =
  responseLBS status [("Content-Type", "application/json; charset=utf-8")] (encode body)

jsonResponseWithHeaders :: Status -> [Header] -> Value -> Response
jsonResponseWithHeaders status headers body =
  responseLBS status (("Content-Type", "application/json; charset=utf-8") : headers) (encode body)

loginFormResponse :: AccessServices -> Request -> IO Response
loginFormResponse services req = do
  csrf <- services ^. #newCsrfToken
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
      outcome <- (services ^. #loginUser) credentials
      pure $ case outcome of
        LoginSucceeded tokens ->
          loginSuccessResponse services tokens returnDestination
        LoginMfaRequired challenge ->
          loginMfaResponse challenge (maybe "" id (formTextValue "csrf" form)) returnDestination
        LoginFailed _ ->
          textResponse status401 "invalid login"
  where
    returnDestination =
      safeReturnDestination (maybe "/" id (formTextValue "rd" form))
        & maybe "/" id

loginSuccessResponse :: AccessServices -> SessionTokens -> Text -> Response
loginSuccessResponse services tokens returnDestination =
  case sessionHeaders services tokens of
    Left err ->
      textResponse status500 err
    Right headers ->
      responseLBS status302 ((hLocation, TE.encodeUtf8 returnDestination) : headers) ""

mfaCompleteResponse :: AccessServices -> Request -> IO Response
mfaCompleteResponse services req = do
  body <- strictRequestBody req
  case decodeMfaPayload body >>= validateMfaPayload services req of
    Left err ->
      pure (jsonResponse status400 (object ["error" .= err]))
    Right payload -> do
      outcome <-
        (services ^. #completeMfa)
          MfaCompletion
            { ceremonyId = payload ^. #ceremonyId
            , assertion = payload ^. #assertion
            }
      pure $ case outcome of
        LoginSucceeded tokens ->
          mfaSuccessResponse services tokens (payload ^. #returnDestination)
        LoginMfaRequired _ ->
          jsonResponse status401 (object ["error" .= ("mfa_required" :: Text)])
        LoginFailed _ ->
          jsonResponse status401 (object ["error" .= ("mfa_failed" :: Text)])

decodeMfaPayload :: LBS.ByteString -> Either Text MfaPayload
decodeMfaPayload body =
  case eitherDecode body of
    Left err -> Left (Text.pack err)
    Right payload -> Right payload

mfaSuccessResponse :: AccessServices -> SessionTokens -> Text -> Response
mfaSuccessResponse services tokens returnDestination =
  case sessionHeaders services tokens of
    Left err ->
      jsonResponse status500 (object ["error" .= err])
    Right headers ->
      jsonResponseWithHeaders status200 headers (object ["redirect" .= returnDestination])

data MfaPayload = MfaPayload
  { ceremonyId :: !Text
  , assertion :: !Value
  , csrf :: !Text
  , returnDestination :: !Text
  }
  deriving stock (Generic)

instance FromJSON MfaPayload where
  parseJSON =
    withObject
      "MfaPayload"
      ( \o -> do
          ceremonyId <- o .: "ceremonyId"
          assertion <- o .: "assertion"
          csrf <- o .: "csrf"
          rawRd <- o .:? "rd"
          pure
            MfaPayload
              { ceremonyId = ceremonyId
              , assertion = assertion
              , csrf = csrf
              , returnDestination = maybe "/" id (safeReturnDestination (maybe "/" id rawRd))
              }
      )

validateMfaPayload :: AccessServices -> Request -> MfaPayload -> Either Text MfaPayload
validateMfaPayload _services req payload =
  case cookieTextValue "__Host-nagare_csrf" (requestHeaders req) of
    Just stored | stored == payload ^. #csrf -> Right payload
    _ -> Left "csrf validation failed"

sessionHeaders :: AccessServices -> SessionTokens -> Either Text [Header]
sessionHeaders services tokens = do
  settings <- maybe (Left "login is not configured") Right (services ^. #cookieSettings)
  sessionHeader <- sessionCookieHeader settings (tokens ^. #accessToken) (tokens ^. #expiresIn)
  refreshHeaders <-
    case tokens ^. #refreshToken of
      Nothing ->
        Right []
      Just refresh ->
        case settings ^. #cookieKey of
          Nothing -> Right []
          Just _ -> do
            refreshHeader <- refreshCookieHeader settings refresh defaultRefreshCookieMaxAgeSeconds
            Right [refreshHeader]
  Right (sessionHeader : refreshHeaders)

refreshTokenFromRequest :: AccessServices -> Request -> Maybe Text
refreshTokenFromRequest services req = do
  settings <- services ^. #cookieSettings
  key <- settings ^. #cookieKey
  value <- cookieTextValue "nagare_refresh" (requestHeaders req)
  decodeRefreshCookieValue key value

clearAuthCookies :: AccessServices -> Response -> Response
clearAuthCookies services =
  addResponseHeaders (clearAuthCookieHeaders services)

clearAuthCookieHeaders :: AccessServices -> [Header]
clearAuthCookieHeaders services =
  case services ^. #cookieSettings of
    Nothing -> []
    Just settings ->
      [header | Right header <- [clearSessionCookieHeader settings, clearRefreshCookieHeader settings]]

addResponseHeaders :: [Header] -> Response -> Response
addResponseHeaders headers =
  mapResponseHeaders (headers <>)

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
          { credentialId = loginIdValue
          , email = emailValue
          , password = password
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

loginMfaResponse :: MfaChallenge -> Text -> Text -> Response
loginMfaResponse challenge csrf returnDestination =
  responseLBS
    status200
    [("Content-Type", "text/html; charset=utf-8")]
    (LBS.fromStrict (TE.encodeUtf8 (mfaFormHtml challenge csrf returnDestination)))

mfaFormHtml :: MfaChallenge -> Text -> Text -> Text
mfaFormHtml challenge csrf returnDestination =
  Text.concat
    [ "<!doctype html><html><head><meta charset=\"utf-8\"><title>Complete sign in</title>"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    , "</head><body><main><h1>Complete sign in</h1>"
    , "<p id=\"status\">Waiting for passkey...</p>"
    , "<button id=\"start\" type=\"button\">Use passkey</button>"
    , "<script>"
    , "const ceremonyId="
    , jsString (challenge ^. #ceremonyId)
    , ";const csrf="
    , jsString csrf
    , ";const rd="
    , jsString returnDestination
    , ";const options="
    , jsonText (challenge ^. #options)
    , ";"
    , mfaJavaScript
    , "</script></main></body></html>"
    ]

jsString :: Text -> Text
jsString =
  TE.decodeUtf8 . LBS.toStrict . encode

jsonText :: Value -> Text
jsonText =
  TE.decodeUtf8 . LBS.toStrict . encode

mfaJavaScript :: Text
mfaJavaScript =
  Text.concat
    [ "function b64uToBuf(v){const p='='.repeat((4-v.length%4)%4);const b=(v+p).replace(/-/g,'+').replace(/_/g,'/');const s=atob(b);const a=new Uint8Array(s.length);for(let i=0;i<s.length;i++)a[i]=s.charCodeAt(i);return a.buffer;}"
    , "function bufToB64u(b){const a=new Uint8Array(b);let s='';for(let i=0;i<a.length;i++)s+=String.fromCharCode(a[i]);return btoa(s).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');}"
    , "function decodeOpts(o){const c=JSON.parse(JSON.stringify(o));c.challenge=b64uToBuf(c.challenge);if(c.allowCredentials)c.allowCredentials=c.allowCredentials.map(x=>({...x,id:b64uToBuf(x.id)}));return c;}"
    , "function encodeCred(c){return {id:c.id,type:c.type,rawId:bufToB64u(c.rawId),response:{authenticatorData:bufToB64u(c.response.authenticatorData),clientDataJSON:bufToB64u(c.response.clientDataJSON),signature:bufToB64u(c.response.signature),userHandle:c.response.userHandle?bufToB64u(c.response.userHandle):null},clientExtensionResults:c.getClientExtensionResults()};}"
    , "async function finish(){const s=document.getElementById('status');try{s.textContent='Waiting for passkey...';const cred=await navigator.credentials.get({publicKey:decodeOpts(options)});const res=await fetch('/_nagare/mfa/complete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ceremonyId,csrf,rd,assertion:encodeCred(cred)})});const body=await res.json();if(res.ok&&body.redirect){window.location.assign(body.redirect);}else{s.textContent='Passkey verification failed';}}catch(e){s.textContent='Passkey verification failed';}}"
    , "document.getElementById('start').addEventListener('click',finish);finish();"
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
