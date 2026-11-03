-- | ADR 34: a context behind an edge replaces @Cache-Control@ on proxied protected responses.
module EdgeCacheControlSpec (edgeCacheControlTests) where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Access.App (appWithRuntime)
import Nagare.Access.Auth (AuthenticatedUser (..))
import Nagare.Access.BackendMap
import Nagare.Access.Config (parseRuntimeConfig)
import Nagare.Access.Prelude
import Nagare.Access.Proxy (proxyForwarder, withProxiedCacheControl)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (status200)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (defaultRequest, request, runSession, setPath, simpleBody, simpleHeaders, simpleStatus)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TestServices (testServices)

edgeCacheControlTests :: TestTree
edgeCacheControlTests =
  testGroup
    "edge Cache-Control"
    [ testCase "replaces Cache-Control on a proxied response only when configured" $
        testWithApplication (pure cacheableUpstreamApp) $ \port -> do
          manager <- HC.newManager HC.defaultManagerSettings
          let user = AuthenticatedUser {subject = "user:alice"}
              target = BackendTarget (Text.pack ("http://127.0.0.1:" <> show port)) ProtectedBackend Nothing Nothing
              proxyApp header req respond =
                proxyForwarder manager user "tools.example.com" target req >>= respond . withProxiedCacheControl header
          edge <- runSession (request (setPath defaultRequest "/report.pdf")) (proxyApp (Just "private, no-store, no-transform"))
          simpleStatus edge @?= status200
          simpleBody edge @?= "pdf"
          filter ((== "Cache-Control") . fst) (simpleHeaders edge) @?= [("Cache-Control", "private, no-store, no-transform")]
          direct <- runSession (request (setPath defaultRequest "/report.pdf")) (proxyApp Nothing)
          lookup "Cache-Control" (simpleHeaders direct) @?= Just "public, max-age=600"
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
    ]

cacheableUpstreamApp :: Wai.Application
cacheableUpstreamApp _ respond =
  respond (Wai.responseLBS status200 [("Content-Type", "application/pdf"), ("Cache-Control", "public, max-age=600")] "pdf")
