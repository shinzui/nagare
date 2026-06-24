module Main (main) where

import Nagare.Access.App (app)
import Nagare.Access.Challenge
import Nagare.Access.Config
import Network.HTTP.Types (hAccept, status200, status404)
import Network.Wai.Test (SResponse (..), defaultRequest, request, runSession, setPath)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain $
    testGroup
      "nagare-access"
      [ configTests
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
        classifyChallenge RequestShape {requestPath = "/", requestHeaders = [(hAccept, "text/html")]}
          @?= RedirectDocument "/_nagare/login?rd=%2F"
    , testCase "JSON request gets a JSON challenge" $
        classifyChallenge RequestShape {requestPath = "/api", requestHeaders = [(hAccept, "application/json")]}
          @?= JsonApi "/_nagare/login?rd=%2Fapi"
    , testCase "XHR request gets a JSON challenge" $
        classifyChallenge RequestShape {requestPath = "/api", requestHeaders = [("X-Requested-With", "XMLHttpRequest")]}
          @?= JsonApi "/_nagare/login?rd=%2Fapi"
    , testCase "cors fetch gets a JSON challenge" $
        classifyChallenge RequestShape {requestPath = "/api", requestHeaders = [("Sec-Fetch-Mode", "cors")]}
          @?= JsonApi "/_nagare/login?rd=%2Fapi"
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
    ]

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
