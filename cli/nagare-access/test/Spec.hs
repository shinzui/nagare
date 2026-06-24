{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Control.Exception (bracket)
import Crypto.JOSE.JWK (JWKSet (..))
import Data.Aeson (ToJSON, Value, decode, eitherDecode, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Effectful (IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Check qualified as EnCheck
import En.Client
  ( CaveatContextWire (..)
  , CheckDecisionWire (..)
  , CheckRequestWire (..)
  , CheckResponseWire (..)
  , ConsistencyWire (..)
  , ObjectRefWire (..)
  , SubjectWire (..)
  )
import En.Conformance.Kikan qualified as Kikan
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Lookup qualified as EnLookup
import En.Reachability (ReachabilityGraph, compileSchema)
import En.Schema qualified as EnRaw
import En.Schema.Builder qualified as EnBuilder
import En.Servant.API qualified as EnApi
import En.Servant.Seam (Env (..))
import En.Tuple qualified as EnTuple
import GHC.Stack (HasCallStack)
import Hasql.Pool qualified as HasqlPool
import Nagare.Access.App (app, appWithBackends, appWithRuntime, textResponse)
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.Challenge
  ( ChallengeMode (..)
  , RequestShape (RequestShape)
  , classifyChallenge
  , loginPathFor
  , safeReturnDestination
  )
import Nagare.Access.Config
import Nagare.Access.Cookie
import Nagare.Access.Credential
import Nagare.Access.DecisionCache
import Nagare.Access.En
import Nagare.Access.Jwks
import Nagare.Access.Proxy
import Nagare.Access.Shomei
import Nagare.Access.ShomeiClient
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (HeaderName, Status, hAccept, hHost, hLocation, status200, status302, status400, status401, status403, status404, status502)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import Network.Wai (Request, rawQueryString, requestHeaders, requestMethod)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (SRequest (..), SResponse (..), defaultRequest, request, runSession, setPath, srequest)
import Shomei.Client qualified as ShomeiClient
import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256))
import Shomei.Error (TokenError (..))
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Servant.DTO qualified as ShomeiDTO
import Shomei.Server.App qualified as ShomeiServer
import Shomei.Server.Boot qualified as ShomeiBoot
import Shomei.Server.Keys (bootstrapKeys)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain $
    testGroup
      "nagare-access"
      [ configTests
      , backendMapTests
      , cookieTests
      , credentialTests
      , jwksTests
      , shomeiTests
      , enTests
      , decisionCacheTests
      , proxyTests
      , challengeTests
      , appTests
      ]

configTests :: TestTree
configTests =
  testGroup
    "config"
    [ testCase "empty listen uses the default port" $
        parseListen "" @?= Right defaultListen
    , testCase "colon port parses" $
        listenPort <$> parseListen ":9090" @?= Right 9090
    , testCase "bare port parses" $
        listenPort <$> parseListen "9090" @?= Right 9090
    , testCase "host port parses and retains the port" $
        listenPort <$> parseListen "127.0.0.1:9090" @?= Right 9090
    , testCase "bad port is rejected" $
        assertBool "expected Left" (isLeft (parseListen "nope"))
    , testCase "runtime config defaults auth plane off and decision cache to 30 seconds" $ do
        cfg <- assertRight (parseRuntimeConfig [])
        runtimeListen cfg @?= defaultListen
        authPlaneConfig cfg @?= Nothing
        decisionTtlSeconds cfg @?= 30
        backendMapPath cfg @?= Nothing
    , testCase "runtime config reads backend map path and zero decision ttl" $ do
        cfg <-
          assertRight
            ( parseRuntimeConfig
                [ ("NAGARE_ACCESS_BACKENDS", "/etc/nagare/backends.json")
                , ("NAGARE_ACCESS_DECISION_TTL", "0")
                ]
            )
        backendMapPath cfg @?= Just "/etc/nagare/backends.json"
        decisionTtlSeconds cfg @?= 0
    , testCase "runtime config reads complete auth plane settings" $ do
        cfg <- assertRight (parseRuntimeConfig completeAuthEnv)
        authPlaneConfig cfg
          @?= Just
            AuthPlaneConfig
              { shomeiUrl = "http://shomei.nagare-system.svc.cluster.local"
              , shomeiIssuer = "https://auth.apps.example.com"
              , shomeiAudience = "nagare-access"
              , enUrl = "http://en.nagare-system.svc.cluster.local"
              , cookieDomain = ".apps.example.com"
              , cookieKey = Just "cookie-secret"
              }
    , testCase "runtime config rejects partial auth plane settings" $
        assertBool
          "expected Left"
          (isLeft (parseRuntimeConfig [("NAGARE_ACCESS_SHOMEI_URL", "http://shomei")]))
    , testCase "runtime config rejects malformed auth urls" $
        assertBool
          "expected Left"
          (isLeft (parseRuntimeConfig (replaceEnv "NAGARE_ACCESS_SHOMEI_URL" "shomei" completeAuthEnv)))
    , testCase "runtime config rejects negative decision ttl" $
        assertBool
          "expected Left"
          (isLeft (parseRuntimeConfig [("NAGARE_ACCESS_DECISION_TTL", "-1")]))
    ]

challengeTests :: TestTree
challengeTests =
  testGroup
    "challenge"
    [ testCase "safe return destination accepts same-host paths" $
        safeReturnDestination "/foo?bar=baz" @?= Just "/foo?bar=baz"
    , testCase "safe return destination rejects scheme redirects" $
        safeReturnDestination "https://evil.example" @?= Nothing
    , testCase "safe return destination rejects protocol-relative redirects" $
        safeReturnDestination "//evil.example" @?= Nothing
    , testCase "login path encodes the return destination" $
        loginPathFor "/foo bar" @?= "/_nagare/login?rd=%2Ffoo%20bar"
    , testCase "HTML navigation gets a redirect challenge" $
        classifyChallenge (RequestShape "/" [(hAccept, "text/html")])
          @?= RedirectDocument "/_nagare/login?rd=%2F"
    , testCase "JSON request gets a JSON challenge" $
        classifyChallenge (RequestShape "/api" [(hAccept, "application/json")])
          @?= JsonApi "/_nagare/login?rd=%2Fapi"
    , testCase "XHR request gets a JSON challenge" $
        classifyChallenge (RequestShape "/api" [("X-Requested-With", "XMLHttpRequest")])
          @?= JsonApi "/_nagare/login?rd=%2Fapi"
    , testCase "cors fetch gets a JSON challenge" $
        classifyChallenge (RequestShape "/api" [("Sec-Fetch-Mode", "cors")])
          @?= JsonApi "/_nagare/login?rd=%2Fapi"
    ]

backendMapTests :: TestTree
backendMapTests =
  testGroup
    "backend map"
    [ testCase "decodes host to upstream JSON" $ do
        backends <- assertRight (decodeBackendMap "{\"Tools.Example.com\":\"http://tools.personal.svc.cluster.local\"}")
        lookupBackend "tools.example.com" backends @?= Just (BackendTarget "http://tools.personal.svc.cluster.local")
    , testCase "lookup strips Host header port" $ do
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        lookupBackend "tools.example.com:443" backends @?= Just (BackendTarget "http://tools.personal.svc.cluster.local")
    , testCase "lookup can return the canonical host used for auth decisions" $ do
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        lookupBackendWithHost "Tools.Example.com:443" backends @?= Just ("tools.example.com", BackendTarget "http://tools.personal.svc.cluster.local")
    , testCase "rejects non-object JSON" $
        assertBool "expected Left" (isLeft (decodeBackendMap "[]"))
    , testCase "rejects non-string upstreams" $
        assertBool "expected Left" (isLeft (decodeBackendMap "{\"tools.example.com\": 7}"))
    , testCase "rejects upstreams without an HTTP scheme" $
        assertBool "expected Left" (isLeft (backendMapFromList [("tools.example.com", "tools.personal")]))
    ]

cookieTests :: TestTree
cookieTests =
  testGroup
    "cookies"
    [ testCase "session cookie includes domain and security flags" $ do
        hdr <- assertRight (sessionCookieHeader (defaultCookieSettings ".apps.example.com") "jwt.token" 900)
        hdr
          @?= ( "Set-Cookie"
              , "nagare_session=jwt.token; Domain=.apps.example.com; Path=/; Max-Age=900; HttpOnly; Secure; SameSite=Lax"
              )
    , testCase "clear session cookie expires the shared-domain cookie" $ do
        hdr <- assertRight (clearSessionCookieHeader (defaultCookieSettings ".apps.example.com"))
        hdr
          @?= ( "Set-Cookie"
              , "nagare_session=; Domain=.apps.example.com; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; Secure; SameSite=Lax"
              )
    , testCase "__Host csrf cookie omits Domain" $ do
        hdr <- assertRight (csrfCookieHeader "csrf-token" 600)
        hdr @?= ("Set-Cookie", "__Host-nagare_csrf=csrf-token; Path=/; Max-Age=600; Secure; SameSite=Lax")
    , testCase "cookie values reject header separators" $
        assertBool "expected Left" (isLeft (sessionCookieHeader (defaultCookieSettings ".apps.example.com") "bad;token" 900))
    , testCase "refresh cookie wraps the token with an authenticated value" $ do
        hdr <- assertRight (refreshCookieHeader (signedCookieSettings ".apps.example.com" "cookie-secret") "refresh.token" 2592000)
        value <- maybe (assertFailure "missing refresh cookie value") pure (cookieValueFromSetCookie "nagare_refresh" hdr)
        decodeRefreshCookieValue "cookie-secret" (TE.decodeUtf8 value) @?= Just "refresh.token"
    , testCase "refresh cookie rejects a tampered value" $ do
        hdr <- assertRight (refreshCookieHeader (signedCookieSettings ".apps.example.com" "cookie-secret") "refresh.token" 2592000)
        value <- maybe (assertFailure "missing refresh cookie value") pure (cookieValueFromSetCookie "nagare_refresh" hdr)
        decodeRefreshCookieValue "cookie-secret" (TE.decodeUtf8 (value <> "x")) @?= Nothing
    ]

credentialTests :: TestTree
credentialTests =
  testGroup
    "credentials"
    [ testCase "extracts nagare_session from Cookie" $
        extractCredential [("Cookie", "theme=dark; nagare_session=jwt.cookie; other=1")]
          @?= Just (SessionCookie "jwt.cookie")
    , testCase "cookie credential wins over bearer token" $
        extractCredential [("Authorization", "Bearer jwt.bearer"), ("Cookie", "nagare_session=jwt.cookie")]
          @?= Just (SessionCookie "jwt.cookie")
    , testCase "falls back to bearer authorization" $
        extractCredential [("Authorization", "Bearer jwt.bearer")]
          @?= Just (BearerToken "jwt.bearer")
    , testCase "bearer scheme is case-insensitive" $
        extractCredential [("Authorization", "bearer jwt.bearer")]
          @?= Just (BearerToken "jwt.bearer")
    , testCase "rejects empty session cookie" $
        extractCredential [("Cookie", "nagare_session=; other=1")] @?= Nothing
    , testCase "rejects unsupported authorization scheme" $
        extractCredential [("Authorization", "Basic nope")] @?= Nothing
    ]

jwksTests :: TestTree
jwksTests =
  testGroup
    "jwks"
    [ testCase "jwks url appends the well-known path" $ do
        cfg <- completeAuthConfig
        jwksUrlFor cfg @?= "http://shomei.nagare-system.svc.cluster.local/.well-known/jwks.json"
    , testCase "jwks url tolerates a trailing shomei url slash" $ do
        cfg <- authConfigFromEnv (replaceEnv "NAGARE_ACCESS_SHOMEI_URL" "http://shomei/" completeAuthEnv)
        jwksUrlFor cfg @?= "http://shomei/.well-known/jwks.json"
    , testCase "decodes an empty jwks document" $
        decodeJwks "{\"keys\":[]}" @?= Right (JWKSet [])
    , testCase "cached jwks reuses a fresh successful fetch" $ do
        loads <- newIORef (0 :: Int)
        cache <- newJwksCache 30 (pure 100) (modifyIORef' loads (+ 1) >> pure (Right (JWKSet [])))
        getCachedJwks cache >>= (@?= Right (JWKSet []))
        getCachedJwks cache >>= (@?= Right (JWKSet []))
        readIORef loads >>= (@?= 1)
    , testCase "cached jwks reloads after ttl expiry" $ do
        now <- newIORef 100
        loads <- newIORef (0 :: Int)
        cache <- newJwksCache 30 (readIORef now) (modifyIORef' loads (+ 1) >> pure (Right (JWKSet [])))
        getCachedJwks cache >>= (@?= Right (JWKSet []))
        modifyIORef' now (+ 30)
        getCachedJwks cache >>= (@?= Right (JWKSet []))
        readIORef loads >>= (@?= 2)
    , testCase "zero ttl disables jwks caching" $ do
        loads <- newIORef (0 :: Int)
        cache <- newJwksCache 0 (pure 100) (modifyIORef' loads (+ 1) >> pure (Right (JWKSet [])))
        getCachedJwks cache >>= (@?= Right (JWKSet []))
        getCachedJwks cache >>= (@?= Right (JWKSet []))
        readIORef loads >>= (@?= 2)
    , testCase "cached shomei verifier reports unavailable jwks" $ do
        cfg <- completeAuthConfig
        cache <- newJwksCache 30 (pure 100) (pure (Left "jwks down"))
        verifyShomeiCredentialCached cache cfg (BearerToken "not-a-jwt")
          >>= (@?= Left (VerificationUnavailable "jwks down"))
    ]

shomeiTests :: TestTree
shomeiTests =
  testGroup
    "shomei"
    [ testCase "shomei config is derived from auth-plane issuer and audience" $ do
        runtime <- assertRight (parseRuntimeConfig completeAuthEnv)
        cfg <- maybe (assertFailure "expected auth-plane config") pure (authPlaneConfig runtime)
        let shomeiCfg = shomeiConfigFromAuthPlane cfg
        issuer shomeiCfg @?= Issuer "https://auth.apps.example.com"
        audience shomeiCfg @?= Audience "nagare-access"
    , testCase "expired shomei tokens map to expired credentials" $
        tokenErrorToAuthFailure TokenExpired @?= ExpiredCredential
    , testCase "malformed shomei token verifies as an invalid credential" $ do
        runtime <- assertRight (parseRuntimeConfig completeAuthEnv)
        cfg <- maybe (assertFailure "expected auth-plane config") pure (authPlaneConfig runtime)
        verifyShomeiCredential (JWKSet []) cfg (BearerToken "not-a-jwt")
          >>= (@?= Left InvalidCredential)
    , testCase "login, refresh, and MFA adapters use shomei HTTP wire protocol" $
        testWithApplication (pure shomeiAdapterStubApp) $ \port -> do
          cfg <- authConfigFromEnv (replaceEnv "NAGARE_ACCESS_SHOMEI_URL" ("http://127.0.0.1:" <> show port) completeAuthEnv)
          env <- shomeiLoginEnvFromAuthPlane cfg

          loginWithShomei
            env
            LoginCredentials
              { loginCredentialId = Just "alice"
              , loginCredentialEmail = Nothing
              , loginCredentialPassword = "secret"
              }
            >>= ( @?=
                    LoginSucceeded
                      SessionTokens
                        { accessToken = "access.from-login"
                        , refreshToken = Just "refresh.from-login"
                        , expiresIn = 900
                        }
                )

          loginWithShomei
            env
            LoginCredentials
              { loginCredentialId = Just "mfa"
              , loginCredentialEmail = Nothing
              , loginCredentialPassword = "secret"
              }
            >>= ( @?=
                    LoginMfaRequired
                      MfaChallenge
                        { mfaCeremonyId = "ceremony-1"
                        , mfaOptions = object ["challenge" .= ("abc" :: Text)]
                        }
                )

          refreshWithShomei env "refresh.old"
            >>= ( @?=
                    LoginSucceeded
                      SessionTokens
                        { accessToken = "access.from-refresh"
                        , refreshToken = Just "refresh.from-refresh"
                        , expiresIn = 901
                        }
                )

          completeMfaWithShomei env MfaCompletion {mfaCompletionCeremonyId = "ceremony-1", mfaCompletionAssertion = object ["id" .= ("credential-1" :: Text)]}
            >>= ( @?=
                    LoginSucceeded
                      SessionTokens
                        { accessToken = "access.from-mfa"
                        , refreshToken = Just "refresh.from-mfa"
                        , expiresIn = 902
                        }
                )
    ]

enTests :: TestTree
enTests =
  testGroup
    "en"
    [ testCase "builds the app access check for the authenticated user and host" $ do
        let req = buildCheckRequest AuthenticatedUser {userSubject = "alice"} "tools.example.com"
        req.consistency @?= MinimizeLatencyWire
        req.context @?= CaveatContextWire mempty
        req.subject @?= SubjectIdWire ObjectRefWire {objectType = "user", objectId = "alice"}
        req.permission @?= "access"
        req.object @?= ObjectRefWire {objectType = "app", objectId = "tools.example.com"}
    , testCase "maps en decisions into access decisions" $ do
        checkResponseToDecision (CheckResponseWire AllowedWire) @?= AccessAllowed
        checkResponseToDecision (CheckResponseWire DeniedWire) @?= AccessDenied
        checkResponseToDecision (CheckResponseWire (ConditionalWire [])) @?= AccessConditional
    , testCase "rejects malformed en base URLs when constructing the client env" $ do
        manager <- HC.newManager HC.defaultManagerSettings
        cfg <- completeAuthConfig
        env <- enClientEnvFromAuthPlane manager cfg
        assertBool "expected Right" (not (isLeft env))
        badEnv <- enClientEnvFromAuthPlane manager (cfg {enUrl = "not a url"})
        assertBool "expected Left" (isLeft badEnv)
    , testCase "authorizes through the real en HTTP client and servant app" $
        testWithApplication (pure (enAccessApp [grantAppAccessTuple "tools.example.com" "alice"])) $ \port -> do
          manager <- HC.newManager HC.defaultManagerSettings
          cfg <- completeAuthConfig
          clientEnv <- assertRight =<< enClientEnvFromAuthPlane manager (cfg {enUrl = Text.pack ("http://127.0.0.1:" <> show port)})

          authorizeWithEn clientEnv AuthenticatedUser {userSubject = "alice"} "tools.example.com"
            >>= (@?= AccessAllowed)
          authorizeWithEn clientEnv AuthenticatedUser {userSubject = "bob"} "tools.example.com"
            >>= (@?= AccessDenied)
    ]

decisionCacheTests :: TestTree
decisionCacheTests =
  testGroup
    "decision cache"
    [ testCase "cache hit reuses the previous decision" $ do
        clock <- newIORef 100
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (readIORef clock)
        let key = DecisionKey {subject = "user:alice", host = "tools.example.com"}
            load = modifyIORef' loads (+ 1) >> pure AccessAllowed
        first <- cacheLookupOrLoad cache key load
        second <- cacheLookupOrLoad cache key load
        first @?= AccessAllowed
        second @?= AccessAllowed
        readIORef loads >>= (@?= 1)
    , testCase "expired entry reloads" $ do
        clock <- newIORef 100
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (readIORef clock)
        let key = DecisionKey {subject = "user:alice", host = "tools.example.com"}
            load = modifyIORef' loads (+ 1) >> pure AccessDenied
        cacheLookupOrLoad cache key load >>= (@?= AccessDenied)
        modifyIORef' clock (+ 30)
        cacheLookupOrLoad cache key load >>= (@?= AccessDenied)
        readIORef loads >>= (@?= 2)
    , testCase "zero ttl disables caching" $ do
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 0 (pure 100)
        let key = DecisionKey {subject = "user:alice", host = "tools.example.com"}
            load = modifyIORef' loads (+ 1) >> pure AccessConditional
        cacheLookupOrLoad cache key load >>= (@?= AccessConditional)
        cacheLookupOrLoad cache key load >>= (@?= AccessConditional)
        readIORef loads >>= (@?= 2)
    , testCase "subject and host both participate in the cache key" $ do
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (pure 100)
        let load = modifyIORef' loads (+ 1) >> pure AccessAllowed
        cacheLookupOrLoad cache DecisionKey {subject = "user:alice", host = "tools.example.com"} load >>= (@?= AccessAllowed)
        cacheLookupOrLoad cache DecisionKey {subject = "user:bob", host = "tools.example.com"} load >>= (@?= AccessAllowed)
        cacheLookupOrLoad cache DecisionKey {subject = "user:alice", host = "admin.example.com"} load >>= (@?= AccessAllowed)
        readIORef loads >>= (@?= 3)
    ]

proxyTests :: TestTree
proxyTests =
  testGroup
    "proxy"
    [ testCase "builds upstream request from backend base URL and original path/query" $ do
        let waiReq =
              (setPath defaultRequest "/assets/app.js")
                { requestMethod = "POST"
                , rawQueryString = "?v=1"
                }
            user = AuthenticatedUser {userSubject = "user:alice"}
            target = BackendTarget "http://tools.personal.svc.cluster.local/base"
        proxyReq <- assertRight =<< buildProxyRequest user "tools.example.com" target waiReq
        HC.method proxyReq @?= "POST"
        HC.path proxyReq @?= "/base/assets/app.js"
        HC.queryString proxyReq @?= "?v=1"
        case HC.requestBody proxyReq of
          HC.RequestBodyStreamChunked _ -> pure ()
          _ -> assertFailure "expected proxy request body to stream"
    , testCase "strips spoofable and hop-by-hop request headers before injecting trusted identity" $ do
        let waiReq =
              withHeader "X-Forwarded-User" "user:mallory" $
                withHeader "X-Forwarded-Host" "evil.example" $
                  withHeader "Connection" "upgrade" $
                    withHeader hHost "tools.example.com" $
                      setPath defaultRequest "/"
            user = AuthenticatedUser {userSubject = "user:alice"}
            target = BackendTarget "http://tools.personal.svc.cluster.local"
        proxyReq <- assertRight =<< buildProxyRequest user "tools.example.com" target waiReq
        lookup "X-Forwarded-User" (HC.requestHeaders proxyReq) @?= Just "user:alice"
        lookup "X-Forwarded-Host" (HC.requestHeaders proxyReq) @?= Just "tools.example.com"
        lookup "X-Forwarded-Proto" (HC.requestHeaders proxyReq) @?= Just "https"
        lookup "Connection" (HC.requestHeaders proxyReq) @?= Nothing
        lookup hHost (HC.requestHeaders proxyReq) @?= Nothing
        lookup "Accept-Encoding" (HC.requestHeaders proxyReq) @?= Just ""
    , testCase "streams upstream response bodies through WAI" $
        testWithApplication (pure streamingUpstreamApp) $ \port -> do
          manager <- HC.newManager HC.defaultManagerSettings
          let user = AuthenticatedUser {userSubject = "user:alice"}
              target = BackendTarget (Text.pack ("http://127.0.0.1:" <> show port))
              proxyApp req respond =
                proxyForwarder manager user "tools.example.com" target req >>= respond
          res <- runSession (request (setPath defaultRequest "/events")) proxyApp
          simpleStatus res @?= status200
          simpleBody res @?= "event: one\n\nevent: two\n\n"
          lookup "Content-Type" (simpleHeaders res) @?= Just "text/event-stream"
          lookup "Connection" (simpleHeaders res) @?= Nothing
    , testCase "tunnels websocket upgrade bytes after upstream 101" $
        testWithApplication (pure websocketUpstreamApp) $ \upstreamPort ->
          testWithApplication (pure (websocketProxyApp upstreamPort)) $ \proxyPort ->
            withTcpConnection proxyPort $ \socket -> do
              SocketBS.sendAll socket websocketUpgradeRequest
              response <- readUntil socket "\r\n\r\n"
              assertBool "expected 101 response" ("HTTP/1.1 101 Switching Protocols" `BS.isPrefixOf` response)
              assertBool "expected websocket accept header" ("Sec-WebSocket-Accept: test-accept" `BS.isInfixOf` response)
              SocketBS.sendAll socket "hello"
              echoed <- assertSocketRead socket
              echoed @?= "upstream:hello"
    ]

appTests :: TestTree
appTests =
  testGroup
    "app"
    [ testCase "healthz returns 200" $ do
        res <- runSession (request (setPath defaultRequest "/_nagare/healthz")) app
        simpleStatus res @?= status200
        simpleBody res @?= "ok\n"
    , testCase "unknown route returns 404" $ do
        res <- runSession (request (setPath defaultRequest "/")) app
        simpleStatus res @?= status404
    , testCase "userinfo without a valid token returns JSON 401" $ do
        res <- runSession (request (setPath defaultRequest "/_nagare/userinfo")) (appWithRuntime emptyBackendMap testServices)
        simpleStatus res @?= status401
        jsonBody res @?= Right (object ["authenticated" .= False])
    , testCase "userinfo with a valid token returns the authenticated subject" $ do
        res <-
          runSession
            (request (withHeader "Authorization" "Bearer valid" (setPath defaultRequest "/_nagare/userinfo")))
            (appWithRuntime emptyBackendMap testServices)
        simpleStatus res @?= status200
        jsonBody res @?= Right (object ["authenticated" .= True, "user" .= ("user:alice" :: Text)])
    , testCase "logout redirects to login and clears the configured shared session cookie" $ do
        res <-
          runSession
            (request (setPath defaultRequest "/_nagare/logout"))
            (appWithRuntime emptyBackendMap (testServices {cookieSettings = Just (defaultCookieSettings ".apps.example.com")}))
        simpleStatus res @?= status302
        lookup hLocation (simpleHeaders res) @?= Just "/_nagare/login"
        lookup "Set-Cookie" (simpleHeaders res)
          @?= Just "nagare_session=; Domain=.apps.example.com; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; Secure; SameSite=Lax"
    , testCase "login form sets csrf cookie and preserves a safe return destination" $ do
        res <-
          runSession
            (request (setPath defaultRequest "/_nagare/login?rd=%2Ftools%3Ftab%3D1"))
            (appWithRuntime emptyBackendMap (testServices {newCsrfToken = pure "csrf-token"}))
        simpleStatus res @?= status200
        lookup "Set-Cookie" (simpleHeaders res)
          @?= Just "__Host-nagare_csrf=csrf-token; Path=/; Max-Age=600; Secure; SameSite=Lax"
        assertBool "expected hidden csrf" (bodyContains "name=\"csrf\" value=\"csrf-token\"" res)
        assertBool "expected hidden rd" (bodyContains "name=\"rd\" value=\"/tools?tab=1\"" res)
    , testCase "login form rejects an unsafe return destination by falling back to root" $ do
        res <-
          runSession
            (request (setPath defaultRequest "/_nagare/login?rd=https%3A%2F%2Fevil.example"))
            (appWithRuntime emptyBackendMap (testServices {newCsrfToken = pure "csrf-token"}))
        simpleStatus res @?= status200
        assertBool "expected root rd" (bodyContains "name=\"rd\" value=\"/\"" res)
    , testCase "login submit with valid csrf sets the shared session cookie and redirects" $ do
        seen <- newIORef []
        let services =
              testServices
                { cookieSettings = Just (signedCookieSettings ".apps.example.com" "cookie-secret")
                , loginUser = \credentials -> do
                    modifyIORef' seen (<> [credentials])
                    pure (LoginSucceeded SessionTokens {accessToken = "access.jwt", refreshToken = Just "refresh.token", expiresIn = 900})
                }
            req =
              SRequest
                ( withHeader "Cookie" "__Host-nagare_csrf=csrf-token" $
                    withHeader "Content-Type" "application/x-www-form-urlencoded" $
                      (setPath defaultRequest "/_nagare/login") {requestMethod = "POST"}
                )
                "loginId=alice&password=secret&csrf=csrf-token&rd=%2Ftools"
        res <- runSession (srequest req) (appWithRuntime emptyBackendMap services)
        simpleStatus res @?= status302
        lookup hLocation (simpleHeaders res) @?= Just "/tools"
        lookup "Set-Cookie" (simpleHeaders res)
          @?= Just "nagare_session=access.jwt; Domain=.apps.example.com; Path=/; Max-Age=900; HttpOnly; Secure; SameSite=Lax"
        length (filter ((== "Set-Cookie") . fst) (simpleHeaders res)) @?= 2
        readIORef seen
          >>= ( @?=
                  [ LoginCredentials
                      { loginCredentialId = Just "alice"
                      , loginCredentialEmail = Nothing
                      , loginCredentialPassword = "secret"
                      }
                  ]
              )
    , testCase "login submit with MFA renders a passkey challenge page" $ do
        let services =
              testServices
                { loginUser = \_ ->
                    pure
                      ( LoginMfaRequired
                          MfaChallenge
                            { mfaCeremonyId = "ceremony-1"
                            , mfaOptions = object ["challenge" .= ("abc" :: Text), "allowCredentials" .= ([] :: [Value])]
                            }
                      )
                }
            req =
              SRequest
                ( withHeader "Cookie" "__Host-nagare_csrf=csrf-token" $
                    withHeader "Content-Type" "application/x-www-form-urlencoded" $
                      (setPath defaultRequest "/_nagare/login") {requestMethod = "POST"}
                )
                "loginId=alice&password=secret&csrf=csrf-token&rd=%2Ftools"
        res <- runSession (srequest req) (appWithRuntime emptyBackendMap services)
        simpleStatus res @?= status200
        assertBool "expected ceremony id" (bodyContains "ceremony-1" res)
        assertBool "expected WebAuthn options" (bodyContains "\"challenge\":\"abc\"" res)
        assertBool "expected MFA completion endpoint" (bodyContains "/_nagare/mfa/complete" res)
    , testCase "mfa completion sets session cookies and returns redirect JSON" $ do
        seen <- newIORef []
        let assertion = object ["id" .= ("credential-1" :: Text)]
            services =
              testServices
                { cookieSettings = Just (signedCookieSettings ".apps.example.com" "cookie-secret")
                , completeMfa = \completion -> do
                    modifyIORef' seen (<> [completion])
                    pure (LoginSucceeded SessionTokens {accessToken = "access.jwt", refreshToken = Just "refresh.token", expiresIn = 900})
                }
            req =
              SRequest
                ( withHeader "Cookie" "__Host-nagare_csrf=csrf-token" $
                    withHeader "Content-Type" "application/json" $
                      (setPath defaultRequest "/_nagare/mfa/complete") {requestMethod = "POST"}
                )
                "{\"ceremonyId\":\"ceremony-1\",\"csrf\":\"csrf-token\",\"rd\":\"/tools\",\"assertion\":{\"id\":\"credential-1\"}}"
        res <- runSession (srequest req) (appWithRuntime emptyBackendMap services)
        simpleStatus res @?= status200
        jsonBody res @?= Right (object ["redirect" .= ("/tools" :: Text)])
        lookup "Set-Cookie" (simpleHeaders res)
          @?= Just "nagare_session=access.jwt; Domain=.apps.example.com; Path=/; Max-Age=900; HttpOnly; Secure; SameSite=Lax"
        length (filter ((== "Set-Cookie") . fst) (simpleHeaders res)) @?= 2
        readIORef seen
          >>= ( @?=
                  [ MfaCompletion
                      { mfaCompletionCeremonyId = "ceremony-1"
                      , mfaCompletionAssertion = assertion
                      }
                  ]
              )
    , testCase "mfa completion rejects csrf mismatch before calling shomei" $ do
        calls <- newIORef (0 :: Int)
        let services =
              testServices
                { completeMfa = \_ -> modifyIORef' calls (+ 1) >> pure (LoginFailed "should not run")
                }
            req =
              SRequest
                ( withHeader "Cookie" "__Host-nagare_csrf=csrf-token" $
                    withHeader "Content-Type" "application/json" $
                      (setPath defaultRequest "/_nagare/mfa/complete") {requestMethod = "POST"}
                )
                "{\"ceremonyId\":\"ceremony-1\",\"csrf\":\"other-token\",\"rd\":\"/tools\",\"assertion\":{}}"
        res <- runSession (srequest req) (appWithRuntime emptyBackendMap services)
        simpleStatus res @?= status400
        readIORef calls >>= (@?= 0)
    , testCase "login submit rejects csrf mismatch before calling shomei" $ do
        calls <- newIORef (0 :: Int)
        let services =
              testServices
                { loginUser = \_ -> modifyIORef' calls (+ 1) >> pure (LoginFailed "should not run")
                }
            req =
              SRequest
                ( withHeader "Cookie" "__Host-nagare_csrf=csrf-token" $
                    (setPath defaultRequest "/_nagare/login") {requestMethod = "POST"}
                )
                "loginId=alice&password=secret&csrf=other-token&rd=%2Ftools"
        res <- runSession (srequest req) (appWithRuntime emptyBackendMap services)
        simpleStatus res @?= status403
        readIORef calls >>= (@?= 0)
    , testCase "login submit requires a principal and password" $ do
        let req =
              SRequest
                ( withHeader "Cookie" "__Host-nagare_csrf=csrf-token" $
                    (setPath defaultRequest "/_nagare/login") {requestMethod = "POST"}
                )
                "loginId=&password=&csrf=csrf-token&rd=%2Ftools"
        res <- runSession (srequest req) (appWithRuntime emptyBackendMap testServices)
        simpleStatus res @?= status400
    , testCase "missing access cookie refreshes the session and forwards the request" $ do
        refreshCookie <- refreshCookieValue "cookie-secret" "refresh.old"
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        let services =
              testServices
                { cookieSettings = Just (signedCookieSettings ".apps.example.com" "cookie-secret")
                , verifyCredential = \credential ->
                    case credential of
                      SessionCookie "access.new" -> pure (Right AuthenticatedUser {userSubject = "user:alice"})
                      _ -> pure (Left InvalidCredential)
                , refreshUserSession = \token -> do
                    token @?= "refresh.old"
                    pure (LoginSucceeded SessionTokens {accessToken = "access.new", refreshToken = Just "refresh.new", expiresIn = 900})
                }
        res <-
          runSession
            (request (withHeader "Cookie" ("nagare_refresh=" <> refreshCookie) (withHeader hHost "tools.example.com" (setPath defaultRequest "/"))))
            (appWithRuntime backends services)
        simpleStatus res @?= status200
        simpleBody res @?= "proxied\n"
        lookup "Set-Cookie" (simpleHeaders res)
          @?= Just "nagare_session=access.new; Domain=.apps.example.com; Path=/; Max-Age=900; HttpOnly; Secure; SameSite=Lax"
        length (filter ((== "Set-Cookie") . fst) (simpleHeaders res)) @?= 2
    , testCase "failed refresh clears auth cookies and returns the existing challenge" $ do
        refreshCookie <- refreshCookieValue "cookie-secret" "refresh.old"
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        let services =
              testServices
                { cookieSettings = Just (signedCookieSettings ".apps.example.com" "cookie-secret")
                , verifyCredential = \_ -> pure (Left ExpiredCredential)
                , refreshUserSession = \_ -> pure (LoginFailed "refresh failed")
                }
        res <-
          runSession
            ( request
                ( withHeader "Cookie" ("nagare_refresh=" <> refreshCookie) $
                    withHeader hHost "tools.example.com" $
                      withHeader hAccept "application/json" $
                        setPath defaultRequest "/api"
                )
            )
            (appWithRuntime backends services)
        simpleStatus res @?= status401
        length (filter ((== "Set-Cookie") . fst) (simpleHeaders res)) @?= 2
    , testCase "protected host without a token returns a document redirect" $ do
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        res <- runSession (request (withHeader hHost "tools.example.com" (withHeader hAccept "text/html" (setPath defaultRequest "/")))) (appWithBackends backends)
        simpleStatus res @?= status302
        lookup hLocation (simpleHeaders res) @?= Just "/_nagare/login?rd=%2F"
    , testCase "protected API request without a token returns JSON 401" $ do
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        res <- runSession (request (withHeader hHost "tools.example.com" (withHeader hAccept "application/json" (setPath defaultRequest "/api")))) (appWithBackends backends)
        simpleStatus res @?= status401
        simpleBody res @?= "{\"error\":\"unauthenticated\",\"login\":\"/_nagare/login?rd=%2Fapi\"}"
    , testCase "protected request with invalid token returns a challenge" $ do
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        res <-
          runSession
            (request (withHeader hHost "tools.example.com" (withHeader "Authorization" "Bearer invalid" (withHeader hAccept "application/json" (setPath defaultRequest "/api")))))
            (appWithRuntime backends (testServices {verifyCredential = \_ -> pure (Left InvalidCredential)}))
        simpleStatus res @?= status401
    , testCase "denied protected request returns 403" $ do
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        res <-
          runSession
            (request (withHeader hHost "tools.example.com" (withHeader "Authorization" "Bearer valid" (setPath defaultRequest "/"))))
            (appWithRuntime backends (testServices {authorizeUser = \_ _ -> pure AccessDenied}))
        simpleStatus res @?= status403
        simpleBody res @?= "Forbidden"
    , testCase "allowed protected request is forwarded" $ do
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        res <-
          runSession
            (request (withHeader hHost "tools.example.com" (withHeader "Authorization" "Bearer valid" (setPath defaultRequest "/"))))
            (appWithRuntime backends testServices)
        simpleStatus res @?= status200
        simpleBody res @?= "proxied\n"
    , testCase "authorization decisions are cached per subject and host" $ do
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (pure 100)
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        let services =
              testServices
                { decisionCache = cache
                , authorizeUser = \_ _ -> modifyIORef' loads (+ 1) >> pure AccessAllowed
                }
            req = request (withHeader hHost "tools.example.com" (withHeader "Authorization" "Bearer valid" (setPath defaultRequest "/")))
        runSession req (appWithRuntime backends services) >>= \res -> simpleStatus res @?= status200
        runSession req (appWithRuntime backends services) >>= \res -> simpleStatus res @?= status200
        readIORef loads >>= (@?= 1)
    , testCase "authorization receives the canonical host without the request port" $ do
        seen <- newIORef ([] :: [Text])
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        let services =
              testServices
                { authorizeUser = \_ host -> modifyIORef' seen (<> [host]) >> pure AccessAllowed
                }
        res <-
          runSession
            (request (withHeader hHost "Tools.Example.com:443" (withHeader "Authorization" "Bearer valid" (setPath defaultRequest "/"))))
            (appWithRuntime backends services)
        simpleStatus res @?= status200
        readIORef seen >>= (@?= ["tools.example.com"])
    , testCase "request path uses real en over HTTP before proxying to an upstream" $
        testWithApplication (pure (enAccessApp [grantAppAccessTuple "tools.example.com" "alice"])) $ \enPort ->
          testWithApplication (pure identityUpstreamApp) $ \upstreamPort -> do
            manager <- HC.newManager HC.defaultManagerSettings
            cfg <- completeAuthConfig
            clientEnv <- assertRight =<< enClientEnvFromAuthPlane manager (cfg {enUrl = Text.pack ("http://127.0.0.1:" <> show enPort)})
            backends <- assertRight (backendMapFromList [("tools.example.com", "http://127.0.0.1:" <> Text.pack (show upstreamPort))])
            let services =
                  testServices
                    { verifyCredential = \case
                        BearerToken "alice-token" -> pure (Right AuthenticatedUser {userSubject = "alice"})
                        BearerToken "bob-token" -> pure (Right AuthenticatedUser {userSubject = "bob"})
                        _ -> pure (Left InvalidCredential)
                    , authorizeUser = authorizeWithEn clientEnv
                    , forwardAuthorized = proxyForwarder manager
                    }
                authedReq token =
                  request $
                    withHeader hHost "tools.example.com" $
                      withHeader "Authorization" ("Bearer " <> token) $
                        setPath defaultRequest "/"

            allowed <- runSession (authedReq "alice-token") (appWithRuntime backends services)
            simpleStatus allowed @?= status200
            simpleBody allowed @?= "upstream saw user alice"

            denied <- runSession (authedReq "bob-token") (appWithRuntime backends services)
            simpleStatus denied @?= status403
    , testCase "real shomei JWT plus real en authorization proxies an allowed request" $
        withRealShomeiServer $ \shomeiPort -> do
          let shomeiBaseUrl = "http://127.0.0.1:" <> show shomeiPort
              password = "A-long-random-password-42"
          shomeiClientEnv <- ShomeiClient.shomeiClientEnv shomeiBaseUrl
          signup <-
            ShomeiClient.signup
              shomeiClientEnv
              ShomeiDTO.SignupRequest
                { ShomeiDTO.loginId = Just "alice"
                , ShomeiDTO.email = Just "alice@example.com"
                , ShomeiDTO.password = password
                , ShomeiDTO.displayName = "Alice"
                }
              >>= either (assertFailure . ("signup failed: " <>) . show) pure
          let subject = signup.user.userId
          testWithApplication (pure (enAccessApp [grantAppAccessTuple "tools.example.com" subject])) $ \enPort ->
            testWithApplication (pure identityUpstreamApp) $ \upstreamPort -> do
              manager <- HC.newManager HC.defaultManagerSettings
              let authCfg =
                    AuthPlaneConfig
                      { shomeiUrl = Text.pack shomeiBaseUrl
                      , shomeiIssuer = "shomei"
                      , shomeiAudience = "shomei-clients"
                      , enUrl = Text.pack ("http://127.0.0.1:" <> show enPort)
                      , cookieDomain = ".apps.example.com"
                      , cookieKey = Just "cookie-secret"
                      }
              jwksCache <- newJwksCache 0 (pure 0) (fetchJwksFromShomei manager authCfg)
              enClientEnv <- assertRight =<< enClientEnvFromAuthPlane manager authCfg
              shomeiLoginEnv <- shomeiLoginEnvFromAuthPlane authCfg
              decisionCache <- newDecisionCache 0 (pure 0)
              backends <- assertRight (backendMapFromList [("tools.example.com", "http://127.0.0.1:" <> Text.pack (show upstreamPort))])
              let services =
                    AccessServices
                      { verifyCredential = verifyShomeiCredentialCached jwksCache authCfg
                      , authorizeUser = authorizeWithEn enClientEnv
                      , forwardAuthorized = proxyForwarder manager
                      , loginUser = loginWithShomei shomeiLoginEnv
                      , completeMfa = completeMfaWithShomei shomeiLoginEnv
                      , refreshUserSession = refreshWithShomei shomeiLoginEnv
                      , newCsrfToken = pure "csrf-token"
                      , decisionCache
                      , cookieSettings = Just (signedCookieSettings ".apps.example.com" "cookie-secret")
                      }
                  accessApp = appWithRuntime backends services
                  loginReq =
                    SRequest
                      ( withHeader "Cookie" "__Host-nagare_csrf=csrf-token" $
                          withHeader "Content-Type" "application/x-www-form-urlencoded" $
                            (setPath defaultRequest "/_nagare/login") {requestMethod = "POST"}
                      )
                      ("loginId=alice&password=" <> LBS.fromStrict (TE.encodeUtf8 password) <> "&csrf=csrf-token&rd=%2F")
              loginRes <- runSession (srequest loginReq) accessApp
              simpleStatus loginRes @?= status302
              sessionValue <- setCookieValue "nagare_session" loginRes

              allowed <-
                runSession
                  ( request $
                      withHeader hHost "tools.example.com" $
                        withHeader "Cookie" ("nagare_session=" <> sessionValue) $
                          setPath defaultRequest "/"
                  )
                  accessApp
              simpleStatus allowed @?= status200
              simpleBody allowed @?= "upstream saw user " <> LBS.fromStrict (TE.encodeUtf8 subject)
    , testCase "unknown protected host returns a clear backend error" $ do
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        res <- runSession (request (withHeader hHost "other.example.com" (setPath defaultRequest "/"))) (appWithBackends backends)
        simpleStatus res @?= status502
        simpleBody res @?= "no backend configured for host other.example.com"
    ]

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

assertRight :: (HasCallStack, Show a) => Either a b -> IO b
assertRight (Left err) = assertFailure ("expected Right, got Left " <> show err)
assertRight (Right value) = pure value

jsonBody :: SResponse -> Either String Value
jsonBody =
  eitherDecode . simpleBody

bodyContains :: ByteString -> SResponse -> Bool
bodyContains needle res =
  needle `BS.isInfixOf` LBS.toStrict (simpleBody res)

cookieValueFromSetCookie :: ByteString -> (HeaderName, ByteString) -> Maybe ByteString
cookieValueFromSetCookie name (_, value) =
  BS.stripPrefix (name <> "=") value >>= Just . fst . BS.break (== 59)

refreshCookieValue :: Text -> Text -> IO ByteString
refreshCookieValue key token = do
  hdr <- assertRight (refreshCookieHeader (signedCookieSettings ".apps.example.com" key) token 2592000)
  maybe (assertFailure "missing refresh cookie value") pure (cookieValueFromSetCookie "nagare_refresh" hdr)

setCookieValue :: ByteString -> SResponse -> IO ByteString
setCookieValue name res =
  case [value | header <- simpleHeaders res, Just value <- [cookieValueFromSetCookie name header]] of
    value : _ -> pure value
    [] -> assertFailure ("missing Set-Cookie for " <> show name)

completeAuthEnv :: [(String, String)]
completeAuthEnv =
  [ ("NAGARE_ACCESS_SHOMEI_URL", "http://shomei.nagare-system.svc.cluster.local")
  , ("NAGARE_ACCESS_SHOMEI_ISSUER", "https://auth.apps.example.com")
  , ("NAGARE_ACCESS_SHOMEI_AUDIENCE", "nagare-access")
  , ("NAGARE_ACCESS_EN_URL", "http://en.nagare-system.svc.cluster.local")
  , ("NAGARE_ACCESS_COOKIE_DOMAIN", ".apps.example.com")
  , ("NAGARE_ACCESS_COOKIE_KEY", "cookie-secret")
  ]

replaceEnv :: String -> String -> [(String, String)] -> [(String, String)]
replaceEnv name value =
  map (\entry@(k, _) -> if k == name then (name, value) else entry)

completeAuthConfig :: IO AuthPlaneConfig
completeAuthConfig =
  authConfigFromEnv completeAuthEnv

authConfigFromEnv :: [(String, String)] -> IO AuthPlaneConfig
authConfigFromEnv env = do
  runtime <- assertRight (parseRuntimeConfig env)
  maybe (assertFailure "expected auth-plane config") pure (authPlaneConfig runtime)

withHeader :: HeaderName -> ByteString -> Request -> Request
withHeader name value req =
  req {requestHeaders = (name, value) : requestHeaders req}

shomeiAdapterStubApp :: Wai.Application
shomeiAdapterStubApp req respond =
  case (requestMethod req, Wai.pathInfo req) of
    ("POST", ["auth", "login"]) -> do
      body <- Wai.strictRequestBody req
      case decode body of
        Just (ShomeiDTO.LoginRequest (Just "alice") _ "secret") ->
          respondJson status200 (ShomeiDTO.LoginCompleteResponse shomeiUser (ShomeiDTO.TokenPairResponse "access.from-login" "refresh.from-login" 900))
        Just (ShomeiDTO.LoginRequest (Just "mfa") _ "secret") ->
          respondJson status200 (ShomeiDTO.LoginMfaRequiredResponse "ceremony-1" (object ["challenge" .= ("abc" :: Text)]))
        _ ->
          respondJson status401 (object ["error" .= ("invalid_login" :: Text)])
    ("POST", ["auth", "refresh"]) -> do
      body <- Wai.strictRequestBody req
      case decode body of
        Just (ShomeiDTO.RefreshRequest "refresh.old") ->
          respondJson status200 (ShomeiDTO.TokenPairResponse "access.from-refresh" "refresh.from-refresh" 901)
        _ ->
          respondJson status401 (object ["error" .= ("invalid_refresh" :: Text)])
    ("POST", ["auth", "mfa", "complete"]) -> do
      body <- Wai.strictRequestBody req
      case decode body of
        Just (ShomeiDTO.MfaCompleteRequest "ceremony-1" _) ->
          respondJson status200 (ShomeiDTO.TokenPairResponse "access.from-mfa" "refresh.from-mfa" 902)
        _ ->
          respondJson status401 (object ["error" .= ("invalid_mfa" :: Text)])
    _ ->
      respond (Wai.responseLBS status404 [] "not found")
  where
    respondJson :: (ToJSON a) => Status -> a -> IO Wai.ResponseReceived
    respondJson status value =
      respond (Wai.responseLBS status [("Content-Type", "application/json")] (encode value))

shomeiUser :: ShomeiDTO.UserResponse
shomeiUser =
  ShomeiDTO.UserResponse
    { ShomeiDTO.userId = "user-1"
    , ShomeiDTO.loginId = "alice"
    , ShomeiDTO.email = Just "alice@example.com"
    , ShomeiDTO.displayName = "Alice"
    , ShomeiDTO.status = "active"
    }

type EnAccessEffects = '[ConsistencyStore, TupleStore, Error EnError, IOE]

enAccessApp :: [EnTuple.Tuple] -> Wai.Application
enAccessApp tuples =
  EnApi.app env
  where
    env :: Env EnAccessEffects
    env =
      Env
        { runPorts =
            runEff
              . runErrorNoCallStack
              . Kikan.runTupleStoreInMemory tuples
              . Kikan.runConsistencyStoreInMemory
        , graph = nagareAccessGraph
        , checkOperation = EnCheck.check
        , lookupWithDeadlineOperation = EnLookup.lookupWithDeadline
        , maxBatchSize = 20
        }

nagareAccessGraph :: ReachabilityGraph
nagareAccessGraph =
  either (error . show) id (compileSchema nagareAccessSchema)

nagareAccessSchema :: EnRaw.Schema
nagareAccessSchema =
  either (error . show) id $ do
    userObject <- EnBuilder.object "user" []
    appObject <-
      EnBuilder.object
        "app"
        [ EnBuilder.relation "viewer" [EnBuilder.subject "user"] EnBuilder.this
        , EnBuilder.permission "access" (EnBuilder.computed "viewer")
        ]
    EnBuilder.build [userObject, appObject]

grantAppAccessTuple :: Text -> Text -> EnTuple.Tuple
grantAppAccessTuple host user =
  EnTuple.Tuple
    { EnTuple.object = appRef host
    , EnTuple.relation = EnRaw.RelationName "viewer"
    , EnTuple.subject = EnTuple.SubjectId (userRef user)
    , EnTuple.caveat = Nothing
    }

appRef :: Text -> EnTuple.ObjectRef
appRef host =
  EnTuple.ObjectRef {EnTuple.objectType = EnRaw.ObjectType "app", EnTuple.objectId = host}

userRef :: Text -> EnTuple.ObjectRef
userRef user =
  EnTuple.ObjectRef {EnTuple.objectType = EnRaw.ObjectType "user", EnTuple.objectId = user}

withRealShomeiServer :: (Int -> IO a) -> IO a
withRealShomeiServer action =
  withShomeiMigratedDatabase $ \connStr ->
    bracket (acquirePool 4 connStr) HasqlPool.release $ \pool -> do
      (key, jwks) <- bootstrapKeys ES256 pool
      manager <- HC.newManager HC.defaultManagerSettings
      let shomeiCfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
          env =
            ShomeiServer.Env
              { ShomeiServer.envPool = pool
              , ShomeiServer.envConfig = shomeiCfg
              , ShomeiServer.envKey = key
              , ShomeiServer.envJwks = jwks
              , ShomeiServer.envHttpManager = manager
              }
      testWithApplication (pure (ShomeiBoot.application env)) action

streamingUpstreamApp :: Wai.Application
streamingUpstreamApp _req respond =
  respond $
    Wai.responseStream
      status200
      [ ("Content-Type", "text/event-stream")
      , ("Connection", "keep-alive")
      ]
      ( \write flush -> do
          write (Builder.byteString "event: one\n\n")
          flush
          write (Builder.byteString "event: two\n\n")
          flush
      )

identityUpstreamApp :: Wai.Application
identityUpstreamApp req respond =
  respond $
    Wai.responseLBS
      status200
      []
      ( case lookup "X-Forwarded-User" (requestHeaders req) of
          Just "alice" -> "upstream saw user alice"
          Just other -> "upstream saw user " <> LBS.fromStrict other
          Nothing -> "upstream saw no user"
      )

websocketProxyApp :: Int -> Wai.Application
websocketProxyApp upstreamPort req respond = do
  manager <- HC.newManager HC.defaultManagerSettings
  let user = AuthenticatedUser {userSubject = "user:alice"}
      target = BackendTarget (Text.pack ("http://127.0.0.1:" <> show upstreamPort))
  proxyForwarder manager user "tools.example.com" target req >>= respond

websocketUpstreamApp :: Wai.Application
websocketUpstreamApp _req respond =
  respond $
    Wai.responseRaw
      ( \src sink -> do
          sink $
            BS.concat
              [ "HTTP/1.1 101 Switching Protocols\r\n"
              , "Upgrade: websocket\r\n"
              , "Connection: Upgrade\r\n"
              , "Sec-WebSocket-Accept: test-accept\r\n"
              , "\r\n"
              ]
          chunk <- src
          sink ("upstream:" <> chunk)
      )
      (Wai.responseLBS status400 [] "raw unsupported")

websocketUpgradeRequest :: ByteString
websocketUpgradeRequest =
  BS.concat
    [ "GET /socket HTTP/1.1\r\n"
    , "Host: tools.example.com\r\n"
    , "Connection: Upgrade\r\n"
    , "Upgrade: websocket\r\n"
    , "Sec-WebSocket-Key: test-key\r\n"
    , "Sec-WebSocket-Version: 13\r\n"
    , "\r\n"
    ]

withTcpConnection :: Int -> (Socket.Socket -> IO a) -> IO a
withTcpConnection port =
  bracket open Socket.close
  where
    open = do
      let hints =
            Socket.defaultHints
              { Socket.addrSocketType = Socket.Stream
              }
      addr : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just (show port))
      socket <- Socket.socket (Socket.addrFamily addr) (Socket.addrSocketType addr) (Socket.addrProtocol addr)
      Socket.connect socket (Socket.addrAddress addr)
      pure socket

readUntil :: Socket.Socket -> ByteString -> IO ByteString
readUntil socket needle =
  go BS.empty
  where
    go acc
      | needle `BS.isInfixOf` acc = pure acc
      | otherwise = do
          chunk <- assertSocketRead socket
          go (acc <> chunk)

assertSocketRead :: Socket.Socket -> IO ByteString
assertSocketRead socket = do
  result <- timeout 1000000 (SocketBS.recv socket 4096)
  case result of
    Just chunk | not (BS.null chunk) -> pure chunk
    Just _ -> assertFailure "socket closed before expected bytes"
    Nothing -> assertFailure "timed out waiting for socket bytes"

testServices :: AccessServices
testServices =
  AccessServices
    { verifyCredential = \_ -> pure (Right AuthenticatedUser {userSubject = "user:alice"})
    , authorizeUser = \_ _ -> pure AccessAllowed
    , forwardAuthorized = \_ _ _ _ -> pure (textResponse status200 "proxied")
    , loginUser = \_ -> pure (LoginFailed "invalid login")
    , completeMfa = \_ -> pure (LoginFailed "mfa failed")
    , refreshUserSession = \_ -> pure (LoginFailed "refresh failed")
    , newCsrfToken = pure "csrf-token"
    , decisionCache = disabledDecisionCache
    , cookieSettings = Nothing
    }
