{-# LANGUAGE OverloadedRecordDot #-}

-- | EP-264 M2: with an @https@ issuer the enforcer answers Shomei's four
-- OIDC endpoints on the issuer's host, the auth portal's, and nothing else of
-- Shomei. The end-to-end cases run a real Shomei with the platform's settings
-- and a portal that signs a user in and hands the session back unchanged.
module OidcProviderSpec (oidcProviderTests) where

import Control.Monad (forM, forM_, replicateM_)
import Crypto.Hash (SHA256 (..), hashWith)
import Crypto.JOSE.JWK (JWKSet)
import Data.Aeson (Value (..), eitherDecode, eitherDecodeStrict, encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base64, Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import GHC.Stack (HasCallStack)
import Nagare.Access.App (appWithRuntime, textResponse)
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.Config (AuthPlaneConfig (..))
import Nagare.Access.Cookie (signedCookieSettings)
import Nagare.Access.Credential (Credential (..))
import Nagare.Access.DecisionCache (AccessDecision (..), AuthorizationResult (..))
import Nagare.Access.Jwks (fetchJwksFromShomei, newJwksCache)
import Nagare.Access.Oidc
import Nagare.Access.Portal (AccessToken (..))
import Nagare.Access.Prelude hiding ((.=))
import Nagare.Access.Proxy (newProxyManager, portalForwarder, shomeiOidcProvider)
import Nagare.Access.Shomei (verifyShomeiCredentialCached)
import Nagare.Access.ShomeiClient (loginWithShomei, logoutWithShomei, refreshWithShomei, shomeiLoginEnvFromAuthPlane)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (Header, HeaderName, Status, hAccept, hCacheControl, hHost, hLocation, parseQuery, status200, status302, status303, statusCode)
import Network.Wai (Application, Request, pathInfo, queryString, requestHeaders, requestMethod, responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (SRequest (..), SResponse (..), defaultRequest, request, runSession, setPath, srequest)
import RealShomei (withOidcShomeiServer)
import Shomei.Account.Dto qualified as ShomeiAccountDTO
import Shomei.Account.LoginId.Domain (mkLoginId)
import Shomei.Account.User.Domain (NewUser (..))
import Shomei.Account.User.Domain qualified as UserDomain
import Shomei.Account.User.Dto qualified as ShomeiUserDTO
import Shomei.Account.User.Store (createUser)
import Shomei.Authorization.Claims.Domain (Scope (..))
import Shomei.Client qualified as ShomeiClient
import Shomei.Id (genOAuthClientId, genServiceAccountDbId, idText)
import Shomei.OAuth.Client.Domain (ClientType (PublicClient), NewOAuthClient (..))
import Shomei.OAuth.Client.Store (createOAuthClient)
import Shomei.Server.App qualified as ShomeiServer
import Shomei.ServiceAccount.Domain (NewServiceAccount (..))
import Shomei.ServiceAccount.Secret (sha256Hex)
import Shomei.ServiceAccount.Store (createServiceAccount)
import Shomei.Time.Store (now)
import Test.Tasty
import Test.Tasty.HUnit
import TestServices (testServices, withHeader)

oidcProviderTests :: TestTree
oidcProviderTests =
  testGroup
    "OIDC endpoints on the issuer host (EP-264 M2)"
    [ testCase "an anonymous authorize is sent to the portal, whose hand-off returns to it, and the signed-in authorize mints a code the token endpoint exchanges for a token the public key set verifies" $
        withProvider Nothing $ \fixture -> do
          let app = fixture ^. #app
          verifier <- pure ("pkce-verifier-" <> BC.replicate 40 'v')
          let authorizeQuery = authorizeParams (fixture ^. #publicClient) verifier
          -- Anonymous: Shomei names the portal's login with the validated request.
          anonymous <- get app portalHost ("/oauth/authorize" <> authorizeQuery) [(hAccept, browserAccept)]
          simpleStatus anonymous @?= status302
          loginLocation <- location anonymous
          assertBool (show loginLocation) ((TE.encodeUtf8 issuer <> "/login?return_to=") `BS.isPrefixOf` loginLocation)
          returnTo <- maybe (assertFailure "no return_to") pure (queryValue "return_to" loginLocation)
          assertBool (show returnTo) ((TE.encodeUtf8 issuer <> "/oauth/authorize?") `BS.isPrefixOf` returnTo)
          -- The portal signs the user in and hands the session back with that return_to.
          handedOff <- get app portalHost (pathAndQuery loginLocation) [(hAccept, browserAccept)]
          simpleStatus handedOff @?= status303
          location handedOff >>= (@?= returnTo)
          session <- setCookie "nagare_session" handedOff
          -- Signed in: Shomei answers the loopback client at once.
          authorized <- get app portalHost (pathAndQuery returnTo) [(hAccept, browserAccept), ("Cookie", "nagare_session=" <> session)]
          simpleStatus authorized @?= status302
          callback <- location authorized
          assertBool (show callback) ("http://127.0.0.1:18090/callback?" `BS.isPrefixOf` callback)
          queryValue "state" callback @?= Just "s1"
          queryValue "iss" callback @?= Just (TE.encodeUtf8 issuer)
          code <- maybe (assertFailure "no code") pure (queryValue "code" callback)
          exchanged <-
            post
              app
              portalHost
              "/oauth/token"
              [("Content-Type", "application/x-www-form-urlencoded")]
              (form [("grant_type", "authorization_code"), ("client_id", fixture ^. #publicClient), ("code", code), ("code_verifier", verifier), ("redirect_uri", redirectUri)])
          simpleStatus exchanged @?= status200
          accessToken <- jsonText "access_token" exchanged
          refreshToken <- jsonText "refresh_token" exchanged
          -- The token verifies against the key set fetched through the enforcer.
          jwksResponse <- get app portalHost "/.well-known/jwks.json" []
          simpleStatus jwksResponse @?= status200
          jwks <- assertRight (eitherDecode (simpleBody jwksResponse) :: Either String JWKSet)
          cache <- newJwksCache 300 (pure 0) (pure (Right jwks))
          verified <- verifyShomeiCredentialCached cache (fixture ^. #authConfig) (BearerToken accessToken)
          verified @?= Right AuthenticatedUser {subject = fixture ^. #alice}
          (header, claims) <- jwtParts accessToken
          lookupText "typ" header @?= Just "at+jwt"
          lookupText "iss" claims @?= Just issuer
          assertBool ("aud is " <> show (KM.lookup "aud" claims)) (KM.lookup "aud" claims `elem` [Just (String "nagare-access"), Just (toJSON ["nagare-access" :: Text])])
          assertBool "the token has no session id" (maybe False (not . Text.null) (lookupText "sid" claims))
          -- The public client refreshes with its bare client_id.
          refreshed <-
            post
              app
              portalHost
              "/oauth/token"
              [("Content-Type", "application/x-www-form-urlencoded")]
              (form [("grant_type", "refresh_token"), ("client_id", fixture ^. #publicClient), ("refresh_token", TE.encodeUtf8 refreshToken)])
          simpleStatus refreshed @?= status200
          (_, refreshedClaims) <- jwtParts =<< jsonText "access_token" refreshed
          lookupText "iss" refreshedClaims @?= Just issuer
          -- No site grant was asked for.
          readIORef (fixture ^. #enCalls) >>= (@?= 0)
    , testCase "discovery names the issuer, S256 and the two exact endpoint URLs" $
        withProvider Nothing $ \fixture -> do
          res <- get (fixture ^. #app) portalHost "/.well-known/openid-configuration" []
          simpleStatus res @?= status200
          document <- assertRight (eitherDecode (simpleBody res) :: Either String Value)
          case document of
            Object fields -> do
              KM.lookup "issuer" fields @?= Just (String issuer)
              KM.lookup "authorization_endpoint" fields @?= Just (String (issuer <> "/oauth/authorize"))
              KM.lookup "token_endpoint" fields @?= Just (String (issuer <> "/oauth/token"))
              KM.lookup "code_challenge_methods_supported" fields @?= Just (toJSON ["S256" :: Text])
            other -> assertFailure ("discovery is not an object: " <> show other)
    , testCase "a service account gets a client_credentials token with HTTP Basic and no cookie, Origin or CSRF token" $
        withProvider Nothing $ \fixture -> do
          res <- clientCredentials (fixture ^. #app) (fixture ^. #serviceAccount)
          simpleStatus res @?= status200
          (_, claims) <- jwtParts =<< jsonText "access_token" res
          lookupText "iss" claims @?= Just issuer
          assertBool ("aud is " <> show (KM.lookup "aud" claims)) (KM.lookup "aud" claims `elem` [Just (String "nagare-access"), Just (toJSON ["nagare-access" :: Text])])
    , testCase "discovery, the key set and the token endpoint answer directly, never with a redirect, even with an expired session" $
        withProvider Nothing $ \fixture -> do
          let app = fixture ^. #app
              stale = ("Cookie", "nagare_session=expired.token.value; nagare_refresh=stale")
          discovery <- get app portalHost "/.well-known/openid-configuration" [stale]
          jwks <- get app portalHost "/.well-known/jwks.json" [stale]
          token <- clientCredentialsWith app (fixture ^. #serviceAccount) [stale]
          forM_ [discovery, jwks, token] $ \res -> simpleStatus res @?= status200
    , testCase "Shomei's per-client limiter admits the first consumer's load through the enforcer's one address, beside ten failed grants" $
        withProvider Nothing $ \fixture -> do
          let app = fixture ^. #app
          -- RateLimitConfig at the pin: a 60-request burst refilled at 60 a minute
          -- per client address, shared by every throttled route. Fifteen minutes
          -- of the load, sent at once, is stricter than the load itself.
          replicateM_ 10 $ do
            failed <- clientCredentials app (fst (fixture ^. #serviceAccount), "wrong-secret")
            assertBool ("a failed grant answered " <> show (simpleStatus failed)) (statusCode (simpleStatus failed) `elem` [400, 401])
          grants <- forM [1 .. 4 :: Int] (const (clientCredentials app (fixture ^. #serviceAccount)))
          forM_ grants $ \res -> simpleStatus res @?= status200
          refresh <- signInPublicClient fixture
          final <- chainRefreshes app (fixture ^. #publicClient) refresh (20 :: Int)
          assertBool "the twentieth refresh failed" (not (Text.null final))
    , testCase "the authorize route asks En nothing and lets any signed-in user through, whatever their grants" $ do
        calls <- newIORef (0 :: Int)
        seen <- newIORef []
        let services =
              testServices
                & #authorizeUser
                .~ (\_ _ -> modifyIORef' calls (+ 1) >> pure (AuthorizationDecision AccessDenied))
                & #oidcProvider
                .~ Just (stubProvider seen)
        res <- runSession (request (withHeader "Cookie" "nagare_session=alice" (hostRequest portalHost "/oauth/authorize?client_id=x"))) (appWithRuntime backends services)
        simpleStatus res @?= status302
        readIORef calls >>= (@?= 0)
        readIORef seen >>= (@?= [(OidcAuthorize, Just "alice")])
    , testCase "a client's own Authorization header is not taken as the session at the authorize route" $ do
        seen <- newIORef []
        let services = testServices & #oidcProvider .~ Just (stubProvider seen)
        _ <- runSession (request (withHeader "Authorization" "Bearer client-token" (hostRequest portalHost "/oauth/authorize?client_id=x"))) (appWithRuntime backends services)
        readIORef seen >>= (@?= [(OidcAuthorize, Nothing)])
    , testCase "Shomei's redirect reaches the browser byte for byte" $ do
        seen <- newIORef []
        let services = testServices & #oidcProvider .~ Just (stubProvider seen)
        res <- runSession (request (withHeader "Cookie" "nagare_session=alice" (hostRequest portalHost "/oauth/authorize?client_id=x"))) (appWithRuntime backends services)
        lookup hLocation (simpleHeaders res) @?= Just stubLocation
    , testCase "only the four method-and-path pairs on the issuer host reach Shomei; everything else goes to the portal" $ do
        seen <- newIORef []
        let services = testServices & #oidcProvider .~ Just (stubProvider seen)
            app = appWithRuntime backends services
        forM_ [("GET", "/.well-known/openid-configuration"), ("GET", "/.well-known/jwks.json"), ("GET", "/oauth/authorize"), ("POST", "/oauth/token")] $ \(method, path) -> do
          res <- runSession (request ((hostRequest portalHost path) {requestMethod = method})) app
          simpleBody res @?= "shomei"
        length <$> readIORef seen >>= (@?= 4)
        forM_
          [ ("GET", "/v1/admin/users")
          , ("POST", "/v1/auth/signup")
          , ("GET", "/oauth/userinfo")
          , ("POST", "/oauth/introspect")
          , ("POST", "/oauth/revoke")
          , ("GET", "/metrics")
          , ("GET", "/openapi.json")
          , ("GET", "/health/ready")
          , ("POST", "/oauth/authorize")
          , ("GET", "/oauth/token")
          , ("GET", "/.well-known/jwks.json/")
          , ("GET", "/oauth//authorize")
          ]
          $ \(method, path) -> do
            res <- runSession (request ((hostRequest portalHost path) {requestMethod = method})) app
            simpleBody res @?= "portal\n"
        length <$> readIORef seen >>= (@?= 4)
        -- The same paths on a protected host are the site's, never Shomei's.
        protected <- runSession (request (withHeader "Cookie" "nagare_session=alice" (hostRequest "app.example.test" "/.well-known/openid-configuration"))) app
        simpleBody protected @?= "proxied\n"
        length <$> readIORef seen >>= (@?= 4)
    , testCase "with the opaque issuer nagare-shomei no endpoint is served and the portal keeps every path" $ do
        oidcHostFromIssuer "nagare-shomei" @?= Nothing
        oidcHostFromIssuer "https://auth.example.test/" @?= Nothing
        oidcHostFromIssuer "https://auth.example.test:8443" @?= Nothing
        oidcHostFromIssuer "http://auth.example.test" @?= Nothing
        publicHostText <$> oidcHostFromIssuer issuer @?= Just portalHost
        let app = appWithRuntime backends testServices
        forM_ ["/.well-known/openid-configuration", "/.well-known/jwks.json", "/oauth/authorize"] $ \path -> do
          res <- runSession (request (hostRequest portalHost path)) app
          simpleBody res @?= "portal\n"
    , testCase "behind an edge every endpoint's answer is private and no-transform; directly it is Shomei's own" $ do
        let edge = Just "private, no-store, no-transform"
        withProvider edge $ \fixture -> do
          responses <- endpointResponses fixture
          forM_ responses $ \(name, res) -> do
            let cacheControl = [value | (header, value) <- simpleHeaders res, header == hCacheControl]
            case cacheControl of
              [value] -> do
                assertBool (name <> ": " <> show value) ("private" `BS.isPrefixOf` value && "no-transform" `BS.isInfixOf` value)
                assertBool (name <> ": " <> show value) (not ("public" `BS.isInfixOf` value) && not ("s-maxage" `BS.isInfixOf` value))
              other -> assertFailure (name <> " has Cache-Control " <> show other)
            forM_ ["CDN-Cache-Control", "Cloudflare-CDN-Cache-Control", "Surrogate-Control"] $ \header ->
              assertBool (name <> " keeps " <> show header) (isNothing (lookup header (simpleHeaders res)))
        withProvider Nothing $ \fixture -> do
          direct <- endpointResponses fixture
          withShomei <- forM direct $ \(name, res) -> pure (name, [value | (header, value) <- simpleHeaders res, header == hCacheControl])
          upstream <- directShomeiCacheControl fixture
          withShomei @?= upstream
    ]

issuer :: Text
issuer = "https://auth.example.test"

portalHost :: Text
portalHost = "auth.example.test"

-- | What a browser sends on navigation.
browserAccept :: ByteString
browserAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

redirectUri :: ByteString
redirectUri = "http://127.0.0.1:18090/callback"

data Fixture = Fixture
  { app :: !Application
  , authConfig :: !AuthPlaneConfig
  , shomeiUrl :: !String
  , publicClient :: !ByteString
  , serviceAccount :: !(ByteString, ByteString)
  , alice :: !Text
  , enCalls :: !(IORef Int)
  }
  deriving stock (Generic)

-- | A real Shomei with the platform's OIDC settings, a public client for the
-- loopback redirect, a service account, the user alice, a portal that signs
-- alice in and hands the session back, and the enforcer in front of both.
withProvider :: Maybe ByteString -> (Fixture -> IO a) -> IO a
withProvider edge action =
  withOidcShomeiServer issuer $ \env shomeiPort -> do
    let shomeiBase = "http://127.0.0.1:" <> show shomeiPort
    clientEnv <- ShomeiClient.shomeiClientEnv shomeiBase
    signupResult <-
      ShomeiClient.signup
        clientEnv
        ShomeiAccountDTO.SignupRequest
          { ShomeiAccountDTO.loginId = "alice"
          , ShomeiAccountDTO.email = Just "alice@example.com"
          , ShomeiAccountDTO.password = alicePassword
          , ShomeiAccountDTO.displayName = "Alice"
          }
        >>= either (assertFailure . ("signup failed: " <>) . show) pure
    aliceId <- case signupResult of
      ShomeiClient.ApplicationSuccess response -> pure (ShomeiClient.cookieBody response).user.userId
      _ -> assertFailure "signup returned an application error"
    (clientId, accountId) <- registerClients env
    manager <- newProxyManager
    let authCfg =
          AuthPlaneConfig
            { shomeiUrl = Text.pack shomeiBase
            , shomeiIssuer = issuer
            , shomeiAudience = "nagare-access"
            , enUrl = "http://127.0.0.1:1"
            , enApiKey = Nothing
            , cookieDomain = ".example.test"
            , cookieKey = Just "cookie-secret"
            }
    loginEnv <- shomeiLoginEnvFromAuthPlane authCfg
    testWithApplication (pure (portalStub loginEnv)) $ \portalPort -> do
      jwksCache <- newJwksCache 0 (pure 0) (fetchJwksFromShomei manager authCfg)
      calls <- newIORef 0
      let services =
            testServices
              { verifyCredential = verifyShomeiCredentialCached jwksCache authCfg
              , authorizeUser = \_ _ -> modifyIORef' calls (+ 1) >> pure (AuthorizationDecision AccessDenied)
              , authorizeDelegation = \_ _ -> modifyIORef' calls (+ 1) >> pure (AuthorizationDecision AccessDenied)
              , refreshUserSession = \token -> RefreshResult RefreshShared <$> refreshWithShomei loginEnv token
              , revokeSession = logoutWithShomei loginEnv
              , forwardPortal = portalForwarder manager
              , cookieSettings = Just (signedCookieSettings ".example.test" "cookie-secret")
              , oidcProvider = shomeiOidcProvider manager (Text.pack shomeiBase) issuer edge
              }
          routes =
            either (error . show) id $
              backendMapFromTargets
                [ (portalHost, BackendTarget ("http://127.0.0.1:" <> Text.pack (show portalPort)) PortalBackend Nothing Nothing)
                , ("app.example.test", BackendTarget "http://127.0.0.1:1" ProtectedBackend Nothing Nothing)
                ]
      action
        Fixture
          { app = appWithRuntime routes services
          , authConfig = authCfg
          , shomeiUrl = shomeiBase
          , publicClient = TE.encodeUtf8 clientId
          , serviceAccount = (TE.encodeUtf8 accountId, serviceSecret)
          , alice = aliceId
          , enCalls = calls
          }

alicePassword :: Text
alicePassword = "A-long-random-password-42"

serviceSecret :: ByteString
serviceSecret = "publisher-secret-0123456789abcdef"

-- | The public loopback client and the service account, as
-- @shomei-admin oauth-clients create@ and @service-accounts create@ store them.
registerClients :: ShomeiServer.Env -> IO (Text, Text)
registerClients env = do
  registered <- ShomeiServer.runAppIO env $ do
    clientDbId <- genOAuthClientId
    createdAt <- now
    _ <-
      createOAuthClient
        NewOAuthClient
          { oauthClientId = clientDbId
          , clientId = idText clientDbId
          , secretHash = Nothing
          , clientType = PublicClient
          , displayName = "cli"
          , redirectUris = [TE.decodeUtf8 redirectUri]
          , allowedScopes = Set.fromList [Scope "openid"]
          , createdAt = createdAt
          }
    accountDbId <- genServiceAccountDbId
    let accountId = idText accountDbId
    backing <- createUser NewUser {loginId = either (error . show) id (mkLoginId accountId), email = Nothing, displayName = Just "publisher"}
    _ <-
      createServiceAccount
        NewServiceAccount
          { serviceAccountId = accountDbId
          , clientId = accountId
          , userId = backing.userId
          , secretHash = sha256Hex (TE.decodeUtf8 serviceSecret)
          , displayName = "publisher"
          , allowedScopes = Set.empty
          , createdAt = createdAt
          }
    pure (idText clientDbId, accountId)
  either (assertFailure . ("client registration failed: " <>) . show) pure registered

-- | The reference portal's contract: sign the user in, then hand the session
-- to the enforcer with @return_to@ unchanged.
portalStub :: ShomeiClient.ClientEnv -> Application
portalStub loginEnv req respond = case pathInfo req of
  ["login"] -> do
    outcome <- loginWithShomei loginEnv LoginCredentials {credentialId = Just "alice", email = Nothing, password = alicePassword}
    case outcome of
      LoginSucceeded tokens -> do
        let returnTo = TE.decodeUtf8 <$> (lookup "return_to" (queryString req) >>= id)
            handoff =
              encode
                ( object
                    [ "accessToken" .= (tokens ^. #accessToken)
                    , "refreshToken" .= (tokens ^. #refreshToken)
                    , "returnTo" .= returnTo
                    ]
                )
        respond (responseLBS status200 [("Nagare-Session-Establish", convertToBase Base64URLUnpadded (LBS.toStrict handoff))] "")
      other -> respond (textResponse (toEnum 500) ("portal sign-in failed: " <> Text.pack (show other)))
  _ -> respond (textResponse status200 "portal")

authorizeParams :: ByteString -> ByteString -> ByteString
authorizeParams clientId verifier =
  "?"
    <> form
      [ ("response_type", "code")
      , ("client_id", clientId)
      , ("redirect_uri", redirectUri)
      , ("scope", "openid")
      , ("state", "s1")
      , ("code_challenge", convertToBase Base64URLUnpadded (BA.convert (hashWith SHA256 verifier) :: ByteString))
      , ("code_challenge_method", "S256")
      ]

form :: [(ByteString, ByteString)] -> ByteString
form = BS.intercalate "&" . map (\(key, value) -> key <> "=" <> urlEncodeValue value)
  where
    urlEncodeValue = BC.concatMap encodeChar
    encodeChar c
      | c `elem` (['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "-._~") = BC.singleton c
      | otherwise = BC.pack ('%' : hex (fromEnum c))
    hex n = [digits !! (n `div` 16), digits !! (n `mod` 16)]
    digits = "0123456789ABCDEF"

clientCredentials :: Application -> (ByteString, ByteString) -> IO SResponse
clientCredentials app account = clientCredentialsWith app account []

clientCredentialsWith :: Application -> (ByteString, ByteString) -> [Header] -> IO SResponse
clientCredentialsWith app (accountId, secret) extra =
  post
    app
    portalHost
    "/oauth/token"
    ([("Content-Type", "application/x-www-form-urlencoded"), ("Authorization", "Basic " <> basic accountId secret)] <> extra)
    "grant_type=client_credentials"

-- | One code flow for the public client, returning its refresh token.
signInPublicClient :: Fixture -> IO Text
signInPublicClient fixture = do
  let app = fixture ^. #app
      verifier = "pkce-verifier-" <> BC.replicate 40 'r'
  anonymous <- get app portalHost ("/oauth/authorize" <> authorizeParams (fixture ^. #publicClient) verifier) [(hAccept, browserAccept)]
  loginLocation <- location anonymous
  handedOff <- get app portalHost (pathAndQuery loginLocation) [(hAccept, browserAccept)]
  session <- setCookie "nagare_session" handedOff
  returnTo <- location handedOff
  authorized <- get app portalHost (pathAndQuery returnTo) [(hAccept, browserAccept), ("Cookie", "nagare_session=" <> session)]
  callback <- location authorized
  code <- maybe (assertFailure "no code") pure (queryValue "code" callback)
  exchanged <-
    post
      app
      portalHost
      "/oauth/token"
      [("Content-Type", "application/x-www-form-urlencoded")]
      (form [("grant_type", "authorization_code"), ("client_id", fixture ^. #publicClient), ("code", code), ("code_verifier", verifier), ("redirect_uri", redirectUri)])
  simpleStatus exchanged @?= status200
  jsonText "refresh_token" exchanged

-- | Refresh @count@ times, each with the token the previous one returned.
chainRefreshes :: Application -> ByteString -> Text -> Int -> IO Text
chainRefreshes _ _ token 0 = pure token
chainRefreshes app clientId token count = do
  res <-
    post
      app
      portalHost
      "/oauth/token"
      [("Content-Type", "application/x-www-form-urlencoded")]
      (form [("grant_type", "refresh_token"), ("client_id", clientId), ("refresh_token", TE.encodeUtf8 token)])
  simpleStatus res @?= status200
  next <- jsonText "refresh_token" res
  chainRefreshes app clientId next (count - 1)

-- | The four endpoints' answers through the enforcer.
endpointResponses :: Fixture -> IO [(String, SResponse)]
endpointResponses fixture = do
  let app = fixture ^. #app
  discovery <- get app portalHost "/.well-known/openid-configuration" []
  jwks <- get app portalHost "/.well-known/jwks.json" []
  authorize <- get app portalHost ("/oauth/authorize" <> authorizeParams (fixture ^. #publicClient) ("pkce-verifier-" <> BC.replicate 40 'c')) [(hAccept, browserAccept)]
  token <- clientCredentials app (fixture ^. #serviceAccount)
  pure [("discovery", discovery), ("jwks", jwks), ("authorize", authorize), ("token", token)]

-- | The same four answers' Cache-Control straight from Shomei.
directShomeiCacheControl :: Fixture -> IO [(String, [ByteString])]
directShomeiCacheControl fixture = do
  manager <- HC.newManager HC.defaultManagerSettings
  let fetch name method path headers body = do
        base <- HC.parseRequest (fixture ^. #shomeiUrl <> BC.unpack path)
        response <- HC.httpLbs base {HC.method = method, HC.requestHeaders = headers, HC.requestBody = HC.RequestBodyBS body, HC.redirectCount = 0} manager
        pure (name, [value | (header, value) <- HC.responseHeaders response, header == hCacheControl])
      (accountId, secret) = fixture ^. #serviceAccount
  sequence
    [ fetch "discovery" "GET" "/.well-known/openid-configuration" [] ""
    , fetch "jwks" "GET" "/.well-known/jwks.json" [] ""
    , fetch "authorize" "GET" ("/oauth/authorize" <> authorizeParams (fixture ^. #publicClient) ("pkce-verifier-" <> BC.replicate 40 'd')) [(hAccept, browserAccept)] ""
    , fetch "token" "POST" "/oauth/token" [("Content-Type", "application/x-www-form-urlencoded"), ("Authorization", "Basic " <> basic accountId secret)] "grant_type=client_credentials"
    ]

stubLocation :: ByteString
stubLocation = "http://127.0.0.1:18090/callback?code=c%2Fd&state=s%201&iss=https%3A%2F%2Fauth.example.test"

-- | A Shomei stand-in that records what reaches it.
stubProvider :: IORef [(OidcRoute, Maybe Text)] -> OidcProvider
stubProvider seen =
  OidcProvider
    { host = either (error . show) id (mkPublicHost portalHost)
    , forward = \route token _ -> do
        modifyIORef' seen (<> [(route, (\(AccessToken access) -> access) <$> token)])
        pure $ case route of
          OidcAuthorize -> responseLBS status302 [(hLocation, stubLocation)] "shomei"
          _ -> responseLBS status200 [] "shomei"
    }

backends :: BackendMap
backends =
  either (error . show) id $
    backendMapFromTargets
      [ (portalHost, BackendTarget "http://auth.personal.svc.cluster.local" PortalBackend Nothing Nothing)
      , ("app.example.test", BackendTarget "http://app.personal.svc.cluster.local" ProtectedBackend Nothing Nothing)
      ]

hostRequest :: Text -> ByteString -> Request
hostRequest host path = withHeader hHost (TE.encodeUtf8 host) (setPath defaultRequest path)

get :: Application -> Text -> ByteString -> [Header] -> IO SResponse
get app host path headers = runSession (request (foldr (uncurry withHeader) (hostRequest host path) headers)) app

post :: Application -> Text -> ByteString -> [Header] -> ByteString -> IO SResponse
post app host path headers body =
  runSession (srequest (SRequest ((foldr (uncurry withHeader) (hostRequest host path) headers) {requestMethod = "POST"}) (LBS.fromStrict body))) app

location :: (HasCallStack) => SResponse -> IO ByteString
location res = maybe (assertFailure ("no Location on " <> show (simpleStatus res) <> ": " <> show (simpleBody res))) pure (lookup hLocation (simpleHeaders res))

-- | A URL's path and query, for a request to its host.
pathAndQuery :: ByteString -> ByteString
pathAndQuery url = case BS.breakSubstring "://" url of
  (_, rest) | not (BS.null rest) -> BC.dropWhile (/= '/') (BS.drop 3 rest)
  _ -> url

queryValue :: ByteString -> ByteString -> Maybe ByteString
queryValue key url = lookup key (parseQuery (BC.drop 1 (BC.dropWhile (/= '?') url))) >>= id

setCookie :: (HasCallStack) => ByteString -> SResponse -> IO ByteString
setCookie name res =
  case [BC.takeWhile (/= ';') value | (header, raw) <- simpleHeaders res, header == ("Set-Cookie" :: HeaderName), Just value <- [BS.stripPrefix (name <> "=") raw]] of
    value : _ -> pure value
    [] -> assertFailure ("no Set-Cookie for " <> show name)

jsonText :: (HasCallStack) => Text -> SResponse -> IO Text
jsonText key res = case eitherDecode (simpleBody res) of
  Right (Object fields) | Just (String value) <- KM.lookup (Key.fromText key) fields -> pure value
  _ -> assertFailure ("no " <> Text.unpack key <> " in " <> show (simpleBody res))

jwtParts :: (HasCallStack) => Text -> IO (KM.KeyMap Value, KM.KeyMap Value)
jwtParts token = case Text.splitOn "." token of
  [header, payload, _] -> (,) <$> part header <*> part payload
  _ -> assertFailure "the access token is not a compact JWT"
  where
    part segment = case convertFromBase Base64URLUnpadded (TE.encodeUtf8 segment) >>= eitherDecodeStrict of
      Right (Object fields) -> pure fields
      other -> assertFailure ("unreadable JWT segment: " <> show other)

lookupText :: Text -> KM.KeyMap Value -> Maybe Text
lookupText key fields = case KM.lookup (Key.fromText key) fields of
  Just (String value) -> Just value
  _ -> Nothing

-- | An HTTP Basic credential, in standard padded base64.
basic :: ByteString -> ByteString -> ByteString
basic accountId secret = convertToBase Base64 (accountId <> ":" <> secret)

assertRight :: (HasCallStack, Show a) => Either a b -> IO b
assertRight (Left err) = assertFailure ("expected Right, got Left " <> show err)
assertRight (Right value) = pure value
