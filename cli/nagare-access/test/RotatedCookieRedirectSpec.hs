-- | A GET or HEAD that leads a refresh is answered at once with the rotated
-- cookies, before any upstream wait, so a request dropped during that wait
-- cannot lose the session (EP-239, IR-41 AC-1 to AC-5). Every other request is
-- forwarded with the cookies on its response, as before. WebSocket delivery is
-- proved on real sockets in @Spec.hs@.
module RotatedCookieRedirectSpec (rotatedCookieRedirectTests) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Monad (forM, forM_, replicateM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Nagare.Access.App (appWithRuntime, textResponse)
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.Cookie (CookieSettings, refreshCookieHeader, signedCookieSettings)
import Nagare.Access.Credential (Credential (..))
import Nagare.Access.DecisionCache (AccessDecision (..), AuthorizationResult (..))
import Nagare.Access.Prelude
import Nagare.Access.RefreshCoalescer (coalesceRefresh, newRefreshCoalescer)
import Network.HTTP.Types (HeaderName, Method, Status, hHost, hLocation, status200, status307, statusCode)
import Network.Wai (Application, Request (..), strictRequestBody)
import Network.Wai.Test (SRequest (..), SResponse (..), defaultRequest, runSession, srequest)
import Test.Tasty
import Test.Tasty.HUnit
import TestServices (testServices, withHeader)

rotatedCookieRedirectTests :: TestTree
rotatedCookieRedirectTests =
  testGroup
    "rotated cookie redirect"
    [ testGroup "AC-1 and AC-2: a refresh-leading GET or HEAD" (concatMap redirectCases backends)
    , testGroup "AC-3: requests that cannot safely repeat are forwarded with the cookies" (concatMap forwardedCases backends)
    , testGroup "AC-4 and AC-5: only the leader redirects" (concatMap leaderCases backends)
    , testGroup "a pair that does not verify" unverifiedCases
    ]

data Backend = Backend
  { label :: !String
  , host :: !ByteString
  , upstreamCount :: !(World -> IORef Int)
  }
  deriving stock (Generic)

backends :: [Backend]
backends =
  [ Backend "protected backend" "app.example.test" (^. #forwarded)
  , Backend "portal backend" "auth.example.test" (^. #portalForwarded)
  ]

redirectCases :: Backend -> [TestTree]
redirectCases backend =
  [ testCase (backend ^. #label <> ": " <> show method <> " gets a 307 with no upstream contact, and its retry is served") $ do
      world <- newWorld acceptNewAccess
      first <- send world (expiredRequest backend method "/x" "?y=1")
      simpleStatus first @?= status307
      lookup hLocation (simpleHeaders first) @?= Just "/x?y=1"
      lookup "Cache-Control" (simpleHeaders first) @?= Just "no-store"
      simpleBody first @?= ""
      assertRotated first
      counts world @?=> Counts {refreshes = 1, authorizations = 0, forwarded = 0, portalForwarded = 0}

      retry <- send world (withCookies (rotatedCookies first) (baseRequest backend method "/x" "?y=1"))
      simpleStatus retry @?= status200
      setCookies retry @?= []
      readIORef (world ^. #refreshes) >>= (@?= 1)
      readIORef ((backend ^. #upstreamCount) world) >>= (@?= 1)
  | method <- ["GET", "HEAD"]
  ]

forwardedCases :: Backend -> [TestTree]
forwardedCases backend =
  [ testCase (backend ^. #label <> ": " <> name) $ do
      world <- newWorld acceptNewAccess
      res <- send world (shape <$> expiredRequest backend "GET" "/x" "")
      simpleStatus res @?= status200
      assertRotated res
      readIORef ((backend ^. #upstreamCount) world) >>= (@?= 1)
      readIORef (world ^. #refreshes) >>= (@?= 1)
  | (name, shape) <-
      [ ("a POST", \req -> req {requestMethod = "POST"})
      , ("a GET with Origin", withHeader "Origin" "https://other.example.test")
      , ("an upgrade request", withHeader "Upgrade" "websocket" . withHeader "Connection" "Upgrade")
      , ("a path that would redirect to another host", \req -> req {rawPathInfo = "//evil.example/x"})
      , ("a backslash path that browsers resolve to another host", \req -> req {rawPathInfo = "/\\evil.example"})
      , ("a path of invalid UTF-8", \req -> req {rawPathInfo = "/\xff"})
      , ("a query with a control character", \req -> req {rawQueryString = "?y=\x01"})
      ]
  ]
    <> [ testCase (backend ^. #label <> ": a POST body reaches the upstream") $ do
           world <- newWorld acceptNewAccess
           res <- sendBody world (expiredRequest backend "POST" "/x" "") "a request body"
           simpleStatus res @?= status200
           assertRotated res
           readIORef ((backend ^. #upstreamCount) world) >>= (@?= 1)
           readIORef (world ^. #lastBody) >>= (@?= "a request body")
       ]

leaderCases :: Backend -> [TestTree]
leaderCases backend =
  [ testCase (backend ^. #label <> ": a client that keeps no cookies is redirected once") $ do
      world <- newWorld acceptNewAccess
      first <- send world (expiredRequest backend "GET" "/x" "")
      simpleStatus first @?= status307
      second <- send world (expiredRequest backend "GET" "/x" "")
      simpleStatus second @?= status200
      assertRotated second
      readIORef (world ^. #refreshes) >>= (@?= 1)
      readIORef ((backend ^. #upstreamCount) world) >>= (@?= 1)
  , testCase (backend ^. #label <> ": a burst on one token is one refresh and one redirect") $ do
      gate <- newEmptyMVar
      world <- newWorldWith (readMVar gate) acceptNewAccess
      request' <- expiredRequest backend "GET" "/x" ""
      dones <- replicateM 8 newEmptyMVar
      forM_ dones $ \done -> forkIO (send world (pure request') >>= putMVar done)
      putMVar gate ()
      responses <- forM dones takeMVar
      let statuses = map simpleStatus responses
      length (filter (== status307) statuses) @?= 1
      length (filter (== status200) statuses) @?= 7
      readIORef (world ^. #refreshes) >>= (@?= 1)
      readIORef ((backend ^. #upstreamCount) world) >>= (@?= 7)
      forM_ responses assertRotated
  ]

unverifiedCases :: [TestTree]
unverifiedCases =
  [ testCase "a protected backend clears the cookies and challenges" $ do
      world <- newWorld rejectEverything
      res <- send world (expiredRequest protected "GET" "/x" "")
      assertBool ("no 307 expected, got " <> show (statusCode (simpleStatus res))) (simpleStatus res /= status307)
      assertCleared res
      readIORef (world ^. #forwarded) >>= (@?= 0)
  , testCase "the portal stays anonymous, clears the cookies and forwards" $ do
      world <- newWorld rejectEverything
      res <- send world (expiredRequest portal "GET" "/x" "")
      simpleStatus res @?= status200
      assertCleared res
      readIORef (world ^. #portalForwarded) >>= (@?= 1)
  ]
  where
    protected = Backend "protected backend" "app.example.test" (^. #forwarded)
    portal = Backend "portal backend" "auth.example.test" (^. #portalForwarded)

-- The fake world: the real coalescer around a counting refresh, and a counter
-- on each thing a redirect must not touch.

data World = World
  { services :: !AccessServices
  , refreshes :: !(IORef Int)
  , authorizations :: !(IORef Int)
  , forwarded :: !(IORef Int)
  , portalForwarded :: !(IORef Int)
  , lastBody :: !(IORef LBS.ByteString)
  }
  deriving stock (Generic)

data Counts = Counts
  { refreshes :: !Int
  , authorizations :: !Int
  , forwarded :: !Int
  , portalForwarded :: !Int
  }
  deriving stock (Generic, Eq, Show)

newWorld :: (Credential -> Either AuthFailure AuthenticatedUser) -> IO World
newWorld = newWorldWith (pure ())

-- | @hold@ runs inside the refresh, so a test can keep it in flight.
newWorldWith :: IO () -> (Credential -> Either AuthFailure AuthenticatedUser) -> IO World
newWorldWith hold verify = do
  refreshes <- newIORef 0
  authorizations <- newIORef 0
  forwarded <- newIORef 0
  portalForwarded <- newIORef 0
  lastBody <- newIORef ""
  coalescer <- newRefreshCoalescer 30 (pure 100)
  let refresh _ = do
        bump refreshes
        hold
        pure (LoginSucceeded SessionTokens {accessToken = "access.new", refreshToken = Just "refresh.new", expiresIn = 900, remembered = True})
      services =
        testServices
          & #cookieSettings
          .~ Just signedCookies
          & #verifyCredential
          .~ (pure . verify)
          & #refreshUserSession
          .~ coalesceRefresh coalescer refresh
          & #authorizeUser
          .~ (\_ _ -> bump authorizations >> pure (AuthorizationDecision AccessAllowed))
          & #forwardAuthorized
          .~ (\_ _ _ _ req -> bump forwarded >> recordBody lastBody req >> pure (textResponse status200 "proxied"))
          & #forwardPortal
          .~ (\_ _ _ req -> bump portalForwarded >> recordBody lastBody req >> pure (PortalPassThrough (textResponse status200 "portal")))
  pure World {services, refreshes, authorizations, forwarded, portalForwarded, lastBody}

recordBody :: IORef LBS.ByteString -> Request -> IO ()
recordBody ref req = strictRequestBody req >>= writeIORef ref

bump :: IORef Int -> IO ()
bump ref = atomicModifyIORef' ref (\n -> (n + 1, ()))

acceptNewAccess :: Credential -> Either AuthFailure AuthenticatedUser
acceptNewAccess (SessionCookie "access.new") = Right AuthenticatedUser {subject = "user:alice"}
acceptNewAccess _ = Left ExpiredCredential

rejectEverything :: Credential -> Either AuthFailure AuthenticatedUser
rejectEverything _ = Left ExpiredCredential

counts :: World -> IO Counts
counts world =
  Counts
    <$> readIORef (world ^. #refreshes)
    <*> readIORef (world ^. #authorizations)
    <*> readIORef (world ^. #forwarded)
    <*> readIORef (world ^. #portalForwarded)

(@?=>) :: (HasCallStack, Eq a, Show a) => IO a -> a -> IO ()
action @?=> expected = action >>= (@?= expected)

application :: World -> Application
application world = appWithRuntime routes (world ^. #services)

routes :: BackendMap
routes =
  either (error . show) id $
    backendMapFromTargets
      [ ("app.example.test", BackendTarget "http://app.personal.svc.cluster.local" ProtectedBackend Nothing Nothing)
      , ("auth.example.test", BackendTarget "http://auth.personal.svc.cluster.local" PortalBackend Nothing Nothing)
      ]

signedCookies :: CookieSettings
signedCookies = signedCookieSettings ".example.test" "cookie-secret"

send :: World -> IO Request -> IO SResponse
send world build = sendBody world build ""

sendBody :: World -> IO Request -> LBS.ByteString -> IO SResponse
sendBody world build body = do
  req <- build
  runSession (srequest (SRequest req body)) (application world)

baseRequest :: Backend -> Method -> ByteString -> ByteString -> Request
baseRequest backend method path query =
  withHeader hHost (backend ^. #host) $
    defaultRequest
      { requestMethod = method
      , rawPathInfo = path
      , rawQueryString = query
      , pathInfo = ["x"]
      }

-- | A request carrying an expired session and a live refresh cookie.
expiredRequest :: Backend -> Method -> ByteString -> ByteString -> IO Request
expiredRequest backend method path query = do
  refreshCookie <- signedRefreshCookie "refresh.old"
  pure (withHeader "Cookie" ("nagare_session=access.old; nagare_refresh=" <> refreshCookie) (baseRequest backend method path query))

withCookies :: ByteString -> Request -> IO Request
withCookies cookies = pure . withHeader "Cookie" cookies

-- | The @Cookie@ header a browser would send after storing this response's
-- cookies.
rotatedCookies :: SResponse -> ByteString
rotatedCookies res = BS.intercalate "; " (map (BS.takeWhile (/= 59)) (setCookies res))

signedRefreshCookie :: Text -> IO ByteString
signedRefreshCookie token =
  case refreshCookieHeader signedCookies token (Just 2592000) of
    Left err -> assertFailure ("refresh cookie failed: " <> show err)
    Right header ->
      maybe (assertFailure "missing refresh cookie value") (pure . BS.takeWhile (/= 59)) (BS.stripPrefix "nagare_refresh=" (snd header))

setCookies :: SResponse -> [ByteString]
setCookies res = [value | (name, value) <- simpleHeaders res, name == ("Set-Cookie" :: HeaderName)]

assertRotated :: (HasCallStack) => SResponse -> IO ()
assertRotated res =
  case setCookies res of
    [session, refresh] -> do
      assertBool ("rotated session cookie, got " <> show session) ("nagare_session=access.new;" `BS.isPrefixOf` session)
      assertBool ("rotated refresh cookie, got " <> show refresh) ("nagare_refresh=v" `BS.isPrefixOf` refresh)
    other -> assertFailure ("expected both rotated cookies once, got " <> show other)

assertCleared :: (HasCallStack) => SResponse -> IO ()
assertCleared res =
  case setCookies res of
    [session, refresh] -> do
      assertBool ("cleared session cookie, got " <> show session) ("nagare_session=;" `BS.isPrefixOf` session)
      assertBool ("cleared refresh cookie, got " <> show refresh) ("nagare_refresh=;" `BS.isPrefixOf` refresh)
    other -> assertFailure ("expected both cookies cleared, got " <> show other)
