module Main (main) where

import Data.ByteString (ByteString)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
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
import Nagare.Access.Proxy
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (HeaderName, hAccept, hHost, hLocation, status200, status302, status401, status403, status404, status502)
import Network.Wai (Request, rawQueryString, requestHeaders, requestMethod)
import Network.Wai.Test (SResponse (..), defaultRequest, request, runSession, setPath)
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

withHeader :: HeaderName -> ByteString -> Request -> Request
withHeader name value req =
  req {requestHeaders = (name, value) : requestHeaders req}

testServices :: AccessServices
testServices =
  AccessServices
    { verifyCredential = \_ -> pure (Right AuthenticatedUser {userSubject = "user:alice"})
    , authorizeUser = \_ _ -> pure AccessAllowed
    , forwardAuthorized = \_ _ _ _ -> pure (textResponse status200 "proxied")
    , decisionCache = disabledDecisionCache
    }
