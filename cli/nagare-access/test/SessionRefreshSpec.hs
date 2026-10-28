-- | A browser session survives everything except Shomei saying no: an
-- unreachable Shomei answers 503 with the cookies kept (EP-211 M2).
module SessionRefreshSpec (sessionRefreshTests) where

import Crypto.JOSE.JWK (JWKSet (..))
import Data.Aeson (eitherDecode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Nagare.Access.App (appWithRuntime)
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.Cookie (refreshCookieHeader, signedCookieSettings)
import Nagare.Access.Credential (Credential (..))
import Nagare.Access.Jwks (getCachedJwks, newJwksCache)
import Nagare.Access.Prelude
import Nagare.Access.ShomeiClient (refreshWithShomei)
import Nagare.Contract.Problem (ProblemDetails)
import Network.HTTP.Types (HeaderName, hAccept, hHost, status200, status503)
import Network.Wai (Request)
import Network.Wai.Test (SResponse (..), defaultRequest, request, runSession, setPath)
import RealShomei (withRealShomeiServer)
import Shomei.Client qualified as ShomeiClient
import Test.Tasty
import Test.Tasty.HUnit
import TestServices (testServices, withHeader)

sessionRefreshTests :: TestTree
sessionRefreshTests =
  testGroup
    "session refresh"
    [ testCase "an unavailable refresh answers 503 and keeps both cookies" $ do
        refreshed <- newIORef (0 :: Int)
        let services =
              signedServices
                & #verifyCredential
                .~ (\_ -> pure (Left ExpiredCredential))
                & #refreshUserSession
                .~ (\_ -> modifyIORef' refreshed (+ 1) >> pure (LoginUnavailable "shomei did not answer"))
        document <- protectedRequest services (withHeader hAccept "text/html")
        simpleStatus document @?= status503
        simpleBody document @?= "authentication service unavailable\n"
        setCookies document @?= []
        api <- protectedRequest services (withHeader hAccept "application/json" . (`setPath` "/api"))
        simpleStatus api @?= status503
        problem <- assertRight (eitherDecode (simpleBody api) :: Either String ProblemDetails)
        problem ^. #code @?= "authentication_unavailable"
        setCookies api @?= []
        readIORef refreshed >>= (@?= 2)
    , testCase "unavailable verification answers 503 without spending the refresh token" $ do
        refreshed <- newIORef (0 :: Int)
        let services =
              signedServices
                & #verifyCredential
                .~ (\_ -> pure (Left (VerificationUnavailable "jwks down")))
                & #refreshUserSession
                .~ (\_ -> modifyIORef' refreshed (+ 1) >> pure (LoginFailed "should not run"))
        res <- protectedRequest services (withHeader hAccept "text/html")
        simpleStatus res @?= status503
        setCookies res @?= []
        readIORef refreshed >>= (@?= 0)
    , testCase "a refreshed pair that cannot be verified still replaces the spent cookies" $ do
        let services =
              signedServices
                & #verifyCredential
                .~ ( \credential -> pure $ case credential of
                       SessionCookie "access.new" -> Left (VerificationUnavailable "jwks down")
                       _ -> Left ExpiredCredential
                   )
                & #refreshUserSession
                .~ (\_ -> pure (LoginSucceeded SessionTokens {accessToken = "access.new", refreshToken = Just "refresh.new", expiresIn = 900, remembered = True}))
        res <- protectedRequest services (withHeader hAccept "text/html")
        simpleStatus res @?= status503
        lookup "nagare_session" (map (BS.break (== 61)) (setCookies res)) @?= Just "=access.new; Domain=.example.test; Path=/; Max-Age=900; HttpOnly; Secure; SameSite=Lax"
        length (setCookies res) @?= 2
        assertBool "the rotated refresh cookie is not empty" (not (any ("nagare_refresh=;" `BS.isPrefixOf`) (setCookies res)))
    , testCase "the portal keeps the session cookies while Shomei is unavailable" $ do
        refreshCookie <- refreshCookieValue "refresh.old"
        let services =
              signedServices
                & #verifyCredential
                .~ (\_ -> pure (Left ExpiredCredential))
                & #refreshUserSession
                .~ (\_ -> pure (LoginUnavailable "shomei did not answer"))
            req =
              withHeader "Cookie" ("nagare_session=access.old; nagare_refresh=" <> refreshCookie) $
                withHeader hHost "auth.example.test" (setPath defaultRequest "/")
        res <- runSession (request req) (appWithRuntime portalBackends services)
        simpleStatus res @?= status200
        setCookies res @?= []
    , testCase "a failed key refetch keeps serving the last key set for a day" $ do
        clock <- newIORef 100
        answer <- newIORef (Right (JWKSet []))
        cache <- newJwksCache 300 (readIORef clock) (readIORef answer)
        getCachedJwks cache >>= (@?= Right (JWKSet []))
        writeIORef answer (Left "shomei down")
        writeIORef clock (100 + 300 + 86399)
        getCachedJwks cache >>= (@?= Right (JWKSet []))
        writeIORef clock (100 + 300 + 86400)
        getCachedJwks cache >>= (@?= Left "shomei down")
    , testCase "Shomei's rejection of an unknown refresh token ends the session" $
        withRealShomeiServer $ \port -> do
          env <- ShomeiClient.shomeiClientEnv ("http://127.0.0.1:" <> show port)
          outcome <- refreshWithShomei env "refresh_token_unknown"
          assertBool ("expected LoginFailed, got " <> show outcome) (isFailed outcome)
    , testCase "an unreachable Shomei leaves the session alone" $ do
        env <- ShomeiClient.shomeiClientEnv "http://127.0.0.1:1"
        refreshWithShomei env "refresh.old" >>= (@?= LoginUnavailable "shomei did not answer")
    ]

signedServices :: AccessServices
signedServices =
  testServices & #cookieSettings .~ Just (signedCookieSettings ".example.test" "cookie-secret")

-- | A request to the protected host carrying an expired session and a valid
-- refresh cookie.
protectedRequest :: AccessServices -> (Request -> Request) -> IO SResponse
protectedRequest services shape = do
  refreshCookie <- refreshCookieValue "refresh.old"
  runSession
    ( request
        ( shape $
            withHeader "Cookie" ("nagare_session=access.old; nagare_refresh=" <> refreshCookie) $
              withHeader hHost "app.example.test" (setPath defaultRequest "/")
        )
    )
    (appWithRuntime portalBackends services)

portalBackends :: BackendMap
portalBackends =
  either (error . show) id $
    backendMapFromTargets
      [ ("app.example.test", BackendTarget "http://app.personal.svc.cluster.local" ProtectedBackend Nothing Nothing)
      , ("auth.example.test", BackendTarget "http://auth.personal.svc.cluster.local" PortalBackend Nothing Nothing)
      ]

isFailed :: LoginOutcome -> Bool
isFailed (LoginFailed _) = True
isFailed _ = False

setCookies :: SResponse -> [ByteString]
setCookies res = [value | (name, value) <- simpleHeaders res, name == ("Set-Cookie" :: HeaderName)]

refreshCookieValue :: Text -> IO ByteString
refreshCookieValue token = do
  hdr <- assertRight (refreshCookieHeader (signedCookieSettings ".example.test" "cookie-secret") token (Just 2592000))
  maybe (assertFailure "missing refresh cookie value") pure (BS.stripPrefix "nagare_refresh=" (snd hdr) >>= Just . fst . BS.break (== 59))

assertRight :: (HasCallStack, Show a) => Either a b -> IO b
assertRight (Left err) = assertFailure ("expected Right, got Left " <> show err)
assertRight (Right value) = pure value
