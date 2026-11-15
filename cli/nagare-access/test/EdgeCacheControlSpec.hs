-- | ADR 34, EP-245 D1: a context behind an edge tightens @Cache-Control@ on
-- proxied protected responses and strips the CDN override headers.
module EdgeCacheControlSpec (edgeCacheControlTests) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Access.App (appWithRuntime)
import Nagare.Access.Auth (AuthenticatedUser (..))
import Nagare.Access.BackendMap
import Nagare.Access.Config (parseRuntimeConfig)
import Nagare.Access.EdgeCacheControl (cdnOverrideHeaders, tightenCacheControl, withProxiedCacheControl)
import Nagare.Access.Prelude
import Nagare.Access.Proxy (proxyForwarder)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (Header, status200, status304, status403)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (SRequest (..), defaultRequest, request, runSession, setPath, simpleBody, simpleHeaders, simpleStatus, srequest)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))
import TestServices (testServices)

edgeCacheControlTests :: TestTree
edgeCacheControlTests =
  testGroup
    "edge Cache-Control"
    [ testCase "tightens each upstream Cache-Control through the proxy, and leaves direct mode alone" $
        for_ proxiedCases $ \(label, upstream, expected) ->
          testWithApplication (pure (upstreamWith upstream)) $ \port -> do
            manager <- HC.newManager HC.defaultManagerSettings
            let user = AuthenticatedUser {subject = "user:alice"}
                target = BackendTarget (Text.pack ("http://127.0.0.1:" <> show port)) ProtectedBackend Nothing Nothing
                proxyApp header req respond =
                  proxyForwarder manager user "tools.example.com" target [] req >>= respond . withProxiedCacheControl header
            edge <- runSession (request (setPath defaultRequest "/report.pdf")) (proxyApp (Just edgeFallback))
            simpleStatus edge @?= status200
            simpleBody edge @?= "pdf"
            assertEqual (label <> ": Cache-Control") [("Cache-Control", expected)] (filter ((== "Cache-Control") . fst) (simpleHeaders edge))
            assertEqual (label <> ": no CDN override header") [] (filter ((`elem` cdnOverrideHeaders) . fst) (simpleHeaders edge))
            assertEqual (label <> ": validators kept") (lookup "ETag" upstream) (lookup "ETag" (simpleHeaders edge))
            direct <- runSession (request (setPath defaultRequest "/report.pdf")) (proxyApp Nothing)
            assertEqual (label <> ": direct mode unchanged") upstream (filter ((`notElem` ["Content-Type", "Transfer-Encoding", "Date", "Server"]) . fst) (simpleHeaders direct))
    , testCase "a 304 revalidation keeps the admin API's validators behind the edge" $
        testWithApplication (pure revalidatingApp) $ \port -> do
          manager <- HC.newManager HC.defaultManagerSettings
          let user = AuthenticatedUser {subject = "user:kotei"}
              target = BackendTarget (Text.pack ("http://127.0.0.1:" <> show port)) ProtectedBackend (Just "/v1") Nothing
          res <-
            runSession
              (request (setPath defaultRequest "/v1/openapi.json") {Wai.requestHeaders = [("If-None-Match", "\"abc\"")]})
              (\req respond -> proxyForwarder manager user "admin.example.com" target [] req >>= respond . withProxiedCacheControl (Just edgeFallback))
          simpleStatus res @?= status304
          lookup "ETag" (simpleHeaders res) @?= Just "\"abc\""
          lookup "Cache-Control" (simpleHeaders res) @?= Just "private, no-cache, no-transform"
    , testCase "merges every Cache-Control value and keeps quoted commas in one directive" $ do
        tightenCacheControl ["no-cache=\"Set-Cookie, X\", private=\"Y\"", " max-age=5 ,, PUBLIC"]
          @?= Just "private, no-cache=\"Set-Cookie, X\", max-age=5, no-transform"
        tightenCacheControl ["private, no-transform, s-maxage=60"] @?= Just "private, no-transform"
        tightenCacheControl [" , "] @?= Nothing
        tightenCacheControl [] @?= Nothing
    , testCase "parses the header and refuses an injection" $ do
        cfg <- either (assertFailure . Text.unpack) pure (parseRuntimeConfig [("NAGARE_ACCESS_PROXIED_CACHE_CONTROL", " private, no-store, no-transform ")])
        cfg ^. #proxiedCacheControl @?= Just "private, no-store, no-transform"
        unset <- either (assertFailure . Text.unpack) pure (parseRuntimeConfig [])
        unset ^. #proxiedCacheControl @?= Nothing
        assertBool
          "expected a refusal"
          (either (const True) (const False) (parseRuntimeConfig [("NAGARE_ACCESS_PROXIED_CACHE_CONTROL", "x\r\nSet-Cookie: a=b")]))
    , testCase "login form replaces a CSRF cookie it could not safely echo" $ do
        res <-
          runSession
            (request (setPath defaultRequest "/_nagare/login") {Wai.requestHeaders = [("Cookie", "__Host-nagare_csrf=\"bad value\"")]})
            (appWithRuntime emptyBackendMap (testServices & #newCsrfToken .~ pure "fresh-token"))
        lookup "Set-Cookie" (simpleHeaders res)
          @?= Just "__Host-nagare_csrf=fresh-token; Path=/; Max-Age=600; Secure; SameSite=Lax"
    , testCase "a sign-in form submitted after its CSRF cookie expired comes back ready to submit, and signs nobody in" $ do
        let submit = (setPath defaultRequest "/_nagare/login") {Wai.requestMethod = "POST"}
        res <-
          runSession
            (srequest (SRequest submit "loginId=alice&password=secret&csrf=old-token&rd=%2Ftools"))
            (appWithRuntime emptyBackendMap (testServices & #newCsrfToken .~ pure "fresh-token"))
        simpleStatus res @?= status403
        lookup "Set-Cookie" (simpleHeaders res)
          @?= Just "__Host-nagare_csrf=fresh-token; Path=/; Max-Age=600; Secure; SameSite=Lax"
        let body = LBS.toStrict (simpleBody res)
        assertBool "the form must carry the fresh token" ("name=\"csrf\" value=\"fresh-token\"" `BS.isInfixOf` body)
        assertBool "the form must keep the return destination" ("name=\"rd\" value=\"/tools\"" `BS.isInfixOf` body)
        assertBool "the form must say why" ("expired" `BS.isInfixOf` body)
    ]

edgeFallback :: BS.ByteString
edgeFallback = "private, no-store, no-transform"

-- | Upstream headers, and the @Cache-Control@ the edge must then carry.
proxiedCases :: [(String, [Header], BS.ByteString)]
proxiedCases =
  [ ("no upstream header", [], edgeFallback)
  , ("hashed asset", [("Cache-Control", "public, max-age=31536000, immutable")], "private, max-age=31536000, immutable, no-transform")
  , ("admin API validators", [("Cache-Control", "private, no-cache"), ("ETag", "\"abc\""), ("Vary", "Authorization, Cookie, Accept")], "private, no-cache, no-transform")
  , ("no-store", [("Cache-Control", "no-store")], "private, no-store, no-transform")
  ,
    ( "CDN override headers"
    , [("Cache-Control", "public, s-maxage=600, max-age=60"), ("Cloudflare-CDN-Cache-Control", "max-age=600"), ("CDN-Cache-Control", "max-age=600"), ("Surrogate-Control", "max-age=600")]
    , "private, max-age=60, no-transform"
    )
  ]

upstreamWith :: [Header] -> Wai.Application
upstreamWith headers _ respond =
  respond (Wai.responseLBS status200 (("Content-Type", "application/pdf") : headers) "pdf")

-- | The admin API's validator shape (@Nagare.Api.Server.Validators@).
revalidatingApp :: Wai.Application
revalidatingApp req respond =
  respond $
    if lookup "If-None-Match" (Wai.requestHeaders req) == Just "\"abc\""
      then Wai.responseLBS status304 [("ETag", "\"abc\""), ("Cache-Control", "private, no-cache")] ""
      else Wai.responseLBS status200 [("ETag", "\"abc\""), ("Cache-Control", "private, no-cache")] "{}"
