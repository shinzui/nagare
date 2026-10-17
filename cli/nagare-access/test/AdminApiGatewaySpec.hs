-- | The gateway in front of the admin API (EP-198 M1): an admin backend's
-- @/v1@ paths are always answered with the shared problem documents, its UI
-- paths keep the browser flow, ordinary hosts classify JSON clients by their
-- Accept and bearer, and proxy failures never carry exception text.
module AdminApiGatewaySpec (adminApiGatewayTests) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Data.Aeson (eitherDecode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Stack (HasCallStack)
import Nagare.Access.App (appWithRuntime, textResponse)
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.DecisionCache (AccessDecision (..), AuthorizationResult (..))
import Nagare.Access.Prelude
import Nagare.Access.Proxy (proxyForwarder)
import Nagare.Contract.Problem (ProblemDetails)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (Status, hAccept, hHost, hLocation, status200, status302, status304, status401, status403, status502, status503, status504, statusCode)
import Network.Socket qualified as Socket
import Network.Wai (Request, requestHeaders)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (SResponse (..), defaultRequest, request, runSession, setPath)
import Test.Tasty
import Test.Tasty.HUnit
import TestServices (testServices, withHeader)

adminApiGatewayTests :: TestTree
adminApiGatewayTests =
  testGroup
    "admin API gateway (EP-198)"
    [ backendTargetTests
    , apiPathTests
    , acceptTests
    , proxyFailureTests
    ]

adminTargetJson :: ByteString
adminTargetJson =
  "{\"admin.example.test\":{\"upstream\":\"http://nagare-admin-api.nagare-system.svc.cluster.local\",\"role\":\"protected\",\"apiPrefix\":\"/v1\",\"timeoutSeconds\":15},\"tools.example.test\":\"http://tools.personal.svc.cluster.local\"}"

adminBackends :: IO BackendMap
adminBackends = assertRight (decodeBackendMap adminTargetJson)

backendTargetTests :: TestTree
backendTargetTests =
  testGroup
    "backend target"
    [ testCase "the object form carries the API prefix and timeout; a string entry has neither" $ do
        backends <- adminBackends
        lookupBackend "admin.example.test" backends
          @?= Just (BackendTarget "http://nagare-admin-api.nagare-system.svc.cluster.local" ProtectedBackend (Just "/v1") (Just 15))
        lookupBackend "tools.example.test" backends
          @?= Just (BackendTarget "http://tools.personal.svc.cluster.local" ProtectedBackend Nothing Nothing)
    , testCase "a prefix that is not an absolute path below the root is refused" $
        for_ ["\"v1\"", "\"/\"", "\"/v1/\""] $ \prefix ->
          assertLeft (decodeBackendMap (entryWith ("\"apiPrefix\":" <> prefix)))
    , testCase "a timeout outside 1 to 300 seconds is refused" $
        for_ ["0", "301"] $ \seconds ->
          assertLeft (decodeBackendMap (entryWith ("\"timeoutSeconds\":" <> seconds)))
    , testCase "API paths are the prefix and below it, never a sibling" $ do
        let target = BackendTarget "http://api.svc" ProtectedBackend (Just "/v1") Nothing
        map (isApiPath target) ["/v1", "/v1/", "/v1/sites", "/v10", "/v1x/sites", "/", "/ui/v1"]
          @?= [True, True, True, False, False, False, False]
        isApiPath (target & #apiPrefix .~ Nothing) "/v1" @?= False
    ]
  where
    entryWith field =
      "{\"admin.example.test\":{\"upstream\":\"http://api.svc\",\"role\":\"protected\"," <> field <> "}}"

apiPathTests :: TestTree
apiPathTests =
  testGroup
    "admin backend paths"
    [ testCase "an unauthenticated /v1 request is a 401 problem whatever it accepts" $ do
        backends <- adminBackends
        for_ [Nothing, Just "*/*", Just "text/html"] $ \accept -> do
          res <- ask backends noCredential (maybe id (withHeader hAccept) accept (adminRequest "/v1/sites"))
          assertUnauthenticated res "/_nagare/login?rd=%2Fv1%2Fsites"
        ask backends noCredential (adminRequest "/v1") >>= \res -> assertUnauthenticated res "/_nagare/login?rd=%2Fv1"
    , testCase "UI paths and a sibling of the prefix keep the document redirect" $ do
        backends <- adminBackends
        for_ ["/", "/v10"] $ \path -> do
          res <- ask backends noCredential (withHeader hAccept "text/html" (adminRequest path))
          simpleStatus res @?= status302
          assertBool "a login redirect" (maybe False ("/_nagare/login" `BS.isPrefixOf`) (lookup hLocation (simpleHeaders res)))
    , testCase "an expired bearer on /v1 is a 401 problem" $ do
        backends <- adminBackends
        res <-
          ask
            backends
            (testServices & #verifyCredential .~ (\_ -> pure (Left ExpiredCredential)))
            (withHeader "Authorization" "Bearer expired" (adminRequest "/v1/sites"))
        assertUnauthenticated res "/_nagare/login?rd=%2Fv1%2Fsites"
    , testCase "a valid bearer without a grant is a 403 forbidden problem and never reaches the API" $ do
        backends <- adminBackends
        reached <- newIORef False
        res <-
          ask
            backends
            ( testServices
                & #authorizeUser
                .~ (\_ _ -> pure (AuthorizationDecision AccessDenied))
                & #forwardAuthorized
                .~ (\_ _ _ _ -> writeIORef reached True >> pure (textResponse status200 "proxied"))
            )
            (bearer (adminRequest "/v1/sites"))
        problem <- assertProblem res status403 "forbidden"
        problem ^. #gatewayError @?= Just "forbidden"
        readIORef reached >>= (@?= False)
    , testCase "an unavailable authorizer is a 503 authorization_unavailable problem" $ do
        backends <- adminBackends
        res <- ask backends (testServices & #authorizeUser .~ (\_ _ -> pure (AuthorizationUnavailable "en is down"))) (bearer (adminRequest "/v1/sites"))
        problem <- assertProblem res status503 "authorization_unavailable"
        problem ^. #retryable @?= True
    , testCase "an authorizer that does not answer within the gateway's budget is a 503" $ do
        backends <- adminBackends
        res <-
          ask
            backends
            (testServices & #authorizeUser .~ (\_ _ -> threadDelay 30000000 >> pure (AuthorizationDecision AccessAllowed)))
            (bearer (adminRequest "/v1/sites"))
        void (assertProblem res status503 "authorization_unavailable")
    , testCase "a granted bearer on /v1 is forwarded to the API backend" $ do
        backends <- adminBackends
        seen <- newIORef Nothing
        res <-
          ask
            backends
            (testServices & #forwardAuthorized .~ (\_ _ target _ -> writeIORef seen (Just target) >> pure (textResponse status200 "proxied")))
            (bearer (adminRequest "/v1/sites"))
        simpleStatus res @?= status200
        readIORef seen >>= (@?= Just (BackendTarget "http://nagare-admin-api.nagare-system.svc.cluster.local" ProtectedBackend (Just "/v1") (Just 15)))
    ]
  where
    noCredential = testServices & #verifyCredential .~ (\_ -> pure (Left InvalidCredential))
    adminRequest path = withHeader hHost "admin.example.test" (setPath defaultRequest path)

acceptTests :: TestTree
acceptTests =
  testGroup
    "ordinary host classification"
    [ testCase "a structured +json media type is an API request" $
        ordinary [(hAccept, "application/vnd.foo+json")] >>= assertJsonChallenge
    , testCase "HTML ranked above JSON, or JSON at quality zero, is a document request" $
        for_ ["text/html,application/json;q=0.5", "application/json;q=0", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"] $ \accept ->
          ordinary [(hAccept, accept)] >>= (@?= status302) . simpleStatus
    , testCase "JSON ranked at least as high as HTML is an API request" $
        ordinary [(hAccept, "text/html;q=0.5, application/json")] >>= assertJsonChallenge
    , testCase "a bearer request without Accept is an API request" $
        ordinary [("Authorization", "Bearer x")] >>= assertJsonChallenge
    ]
  where
    ordinary headers = do
      backends <- adminBackends
      ask
        backends
        (testServices & #verifyCredential .~ (\_ -> pure (Left InvalidCredential)))
        (foldr (uncurry withHeader) (withHeader hHost "tools.example.test" (setPath defaultRequest "/api")) headers)
    assertJsonChallenge res = assertUnauthenticated res "/_nagare/login?rd=%2Fapi"

proxyFailureTests :: TestTree
proxyFailureTests =
  testGroup
    "proxy"
    [ testCase "an unreachable API upstream is a 502 problem with no exception text" $ do
        port <- closedPort
        res <- proxied (apiTarget port Nothing) (setPath defaultRequest "/v1/sites")
        problem <- assertProblem res status502 "upstream_unavailable"
        problem ^. #retryable @?= True
        for_ ["ConnectionFailure", "127.0.0.1", "HttpException", Text.pack (show port)] $ \leaked ->
          assertBool ("the body names " <> Text.unpack leaked) (not (leaked `Text.isInfixOf` lazyText (simpleBody res)))
    , testCase "an API upstream slower than its timeout is a 504 problem" $
        testWithApplication (pure (\_ respond -> threadDelay 5000000 >> respond (Wai.responseLBS status200 [] "late"))) $ \port -> do
          res <- proxied (apiTarget port (Just 1)) (setPath defaultRequest "/v1/sites")
          void (assertProblem res status504 "upstream_timeout")
    , testCase "an unreachable ordinary upstream is a plain 502 with no exception text" $ do
        port <- closedPort
        res <- proxied (BackendTarget (loopback port) ProtectedBackend Nothing Nothing) (setPath defaultRequest "/")
        simpleStatus res @?= status502
        simpleBody res @?= "The upstream service is unavailable.\n"
    , testCase "validators and a 304 pass through; a spoofed identity is replaced" $ do
        seen <- newIORef []
        let upstream req respond = do
              writeIORef seen (requestHeaders req)
              respond (Wai.responseLBS status304 [("ETag", "\"abc\""), ("Nagare-Head-Revision", "7")] "")
        testWithApplication (pure upstream) $ \port -> do
          res <-
            proxied
              (apiTarget port (Just 15))
              (withHeader "If-None-Match" "\"abc\"" (withHeader "X-Forwarded-User" "user:mallory" (setPath defaultRequest "/v1/sites")))
          simpleStatus res @?= status304
          lookup "ETag" (simpleHeaders res) @?= Just "\"abc\""
          lookup "Nagare-Head-Revision" (simpleHeaders res) @?= Just "7"
          headers <- readIORef seen
          lookup "If-None-Match" headers @?= Just "\"abc\""
          [value | ("X-Forwarded-User", value) <- headers] @?= ["user:alice"]
    ]
  where
    apiTarget port seconds = BackendTarget (loopback port) ProtectedBackend (Just "/v1") seconds
    loopback port = Text.pack ("http://127.0.0.1:" <> show port)
    lazyText = Text.pack . map (toEnum . fromIntegral) . LBS.unpack

-- | Forward one request through the real proxy with a fresh manager.
proxied :: BackendTarget -> Request -> IO SResponse
proxied target req = do
  manager <- HC.newManager HC.defaultManagerSettings
  let user = AuthenticatedUser {subject = "user:alice"}
  runSession (request req) (\waiReq respond -> proxyForwarder manager user "admin.example.test" target waiReq >>= respond)

-- | A loopback port nothing listens on: bound, then released.
closedPort :: IO Int
closedPort =
  bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
    Socket.bind sock (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    fromIntegral <$> Socket.socketPort sock

ask :: BackendMap -> AccessServices -> Request -> IO SResponse
ask backends services req = runSession (request req) (appWithRuntime backends services)

bearer :: Request -> Request
bearer = withHeader "Authorization" "Bearer valid"

assertUnauthenticated :: (HasCallStack) => SResponse -> Text -> IO ()
assertUnauthenticated res login = do
  problem <- assertProblem res status401 "unauthenticated"
  lookup "WWW-Authenticate" (simpleHeaders res) @?= Just "Bearer"
  problem ^. #gatewayError @?= Just "unauthenticated"
  problem ^. #login @?= Just login

assertProblem :: (HasCallStack) => SResponse -> Status -> Text -> IO ProblemDetails
assertProblem res status code = do
  simpleStatus res @?= status
  lookup "Content-Type" (simpleHeaders res) @?= Just "application/problem+json"
  lookup "Cache-Control" (simpleHeaders res) @?= Just "no-store"
  problem <- assertRight (eitherDecode (simpleBody res) :: Either String ProblemDetails)
  problem ^. #code @?= code
  problem ^. #status @?= statusCode status
  problem ^. #problemType @?= "about:blank"
  pure problem

assertRight :: (HasCallStack, Show a) => Either a b -> IO b
assertRight (Left err) = assertFailure ("expected Right, got Left " <> show err)
assertRight (Right value) = pure value

assertLeft :: (HasCallStack) => Either a b -> IO ()
assertLeft (Left _) = pure ()
assertLeft (Right _) = assertFailure "expected Left"
