module Main (main) where

import Data.ByteString (ByteString)
import GHC.Stack (HasCallStack)
import Nagare.Access.App (app, appWithBackends)
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
import Network.HTTP.Types (HeaderName, hAccept, hHost, hLocation, status200, status302, status401, status404, status502)
import Network.Wai (Request, requestHeaders)
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

withHeader :: HeaderName -> ByteString -> Request -> Request
withHeader name value req =
  req {requestHeaders = (name, value) : requestHeaders req}
