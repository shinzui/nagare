-- | "Keep me signed in": Shomei reports whether a session is remembered with
-- every token pair, and the enforcer gives a remembered session persistent
-- cookies and any other session browser-session cookies, on the portal
-- hand-off and on every later refresh.
module RememberedSessionSpec (rememberedSessionTests) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import GHC.Stack (HasCallStack)
import Nagare.Access.App (appWithRuntime)
import Nagare.Access.Auth
import Nagare.Access.BackendMap
import Nagare.Access.Cookie (CookieSettings, decodeRefreshCookieValue, defaultCookieSettings, refreshCookieHeader, sessionCookieHeader, signedCookieSettings)
import Nagare.Access.Credential (credentialToken)
import Nagare.Access.Portal (AccessToken (..), RefreshToken (..), SessionHandoff (..))
import Nagare.Access.Prelude
import Network.HTTP.Types (HeaderName, hHost, status200, status303)
import Network.Wai.Test (SResponse (..), defaultRequest, request, runSession, setPath)
import Test.Tasty
import Test.Tasty.HUnit
import TestServices (testServices, withHeader)

rememberedSessionTests :: TestTree
rememberedSessionTests =
  testGroup
    "remembered sessions"
    [ testCase "a cookie without a max age is a browser-session cookie" $ do
        session <- assertRight (sessionCookieHeader (defaultCookieSettings ".example.test") "jwt.token" Nothing)
        snd session @?= "nagare_session=jwt.token; Domain=.example.test; Path=/; HttpOnly; Secure; SameSite=Lax"
        refresh <- assertRight (refreshCookieHeader settings "refresh.token" Nothing)
        assertBool "no Max-Age expected" (not ("Max-Age" `BS.isInfixOf` snd refresh))
        value <- maybe (assertFailure "missing refresh cookie value") pure (cookieValue "nagare_refresh" (snd refresh))
        decodeRefreshCookieValue "cookie-secret" (TE.decodeUtf8 value) @?= Just "refresh.token"
    , testCase "the portal hand-off makes cookies persistent only for a remembered session" $
        for_ [True, False] $ \remembered -> do
          let services =
                rotatingTo remembered
                  & #forwardPortal
                  .~ ( \_ _ _ ->
                         pure
                           ( PortalSessionEstablish
                               SessionHandoff
                                 { accessToken = AccessToken "portal-access"
                                 , refreshToken = RefreshToken "portal-refresh"
                                 , returnTo = Just "https://app.example.test/"
                                 }
                           )
                     )
          res <- runSession (request (withHeader hHost "auth.example.test" (setPath defaultRequest "/login"))) (appWithRuntime backends services)
          simpleStatus res @?= status303
          assertCookies remembered res
    , testCase "a refresh keeps each session's cookie persistence" $
        for_ [True, False] $ \remembered -> do
          refreshCookie <- assertRight (refreshCookieHeader settings "refresh.old" (Just 2592000))
          value <- maybe (assertFailure "missing refresh cookie value") pure (cookieValue "nagare_refresh" (snd refreshCookie))
          res <-
            runSession
              (request (withHeader "Cookie" ("nagare_refresh=" <> value) (withHeader hHost "app.example.test" (setPath defaultRequest "/"))))
              (appWithRuntime backends (rotatingTo remembered))
          simpleStatus res @?= status200
          assertCookies remembered res
    ]

settings :: CookieSettings
settings = signedCookieSettings ".example.test" "cookie-secret"

-- | Services whose Shomei rotates any refresh token into a pair reporting
-- @remembered@, and that accept only the portal's and the rotated access token.
rotatingTo :: Bool -> AccessServices
rotatingTo remembered =
  testServices
    & #cookieSettings
    .~ Just settings
    & #verifyCredential
    .~ ( \credential ->
           pure $
             if credentialToken credential `elem` ["portal-access", "access.new"]
               then Right AuthenticatedUser {subject = "user:alice"}
               else Left InvalidCredential
       )
    & #refreshUserSession
    .~ (\_ -> pure (LoginSucceeded SessionTokens {accessToken = "access.new", refreshToken = Just "refresh.new", expiresIn = 900, remembered}))

assertCookies :: (HasCallStack) => Bool -> SResponse -> IO ()
assertCookies remembered res = do
  let cookies = [value | (name, value) <- simpleHeaders res, name == ("Set-Cookie" :: HeaderName)]
  length cookies @?= 2
  map (cookieValue "nagare_session") cookies @?= [Just "access.new", Nothing]
  assertBool
    (if remembered then "a remembered session gets Max-Age" else "any other session gets no Max-Age")
    (all (\cookie -> "; Max-Age=" `BS.isInfixOf` cookie == remembered) cookies)

cookieValue :: ByteString -> ByteString -> Maybe ByteString
cookieValue name header = fst . BS.break (== 59) <$> BS.stripPrefix (name <> "=") header

backends :: BackendMap
backends =
  either (error . Text.unpack) id $
    backendMapFromTargets
      [ ("app.example.test", BackendTarget "http://app.personal.svc.cluster.local" ProtectedBackend Nothing Nothing)
      , ("auth.example.test", BackendTarget "http://auth.personal.svc.cluster.local" PortalBackend Nothing Nothing)
      ]

assertRight :: (HasCallStack, Show a) => Either a b -> IO b
assertRight (Left err) = assertFailure ("expected Right, got Left " <> show err)
assertRight (Right value) = pure value
