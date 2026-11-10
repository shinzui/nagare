-- | The enforcer runtime every WAI-level test starts from: a verifier that
-- admits one signed-in subject, an authorizer that allows, and a proxy that
-- answers "proxied". Tests override the one service under test.
module TestServices (sharedRefresh, testServices, withHeader) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Nagare.Access.App (textResponse)
import Nagare.Access.Auth
import Nagare.Access.DecisionCache (AccessDecision (..), AuthorizationResult (..), disabledDecisionCache)
import Nagare.Access.Prelude
import Network.HTTP.Types (HeaderName, status200)
import Network.Wai (Request, requestHeaders)

testServices :: AccessServices
testServices =
  AccessServices
    { verifyCredential = \_ -> pure (Right AuthenticatedUser {subject = "user:alice"})
    , authorizeUser = \_ _ -> pure (AuthorizationDecision AccessAllowed)
    , forwardAuthorized = \_ _ _ _ _ -> pure (textResponse status200 "proxied")
    , loginUser = \_ -> pure (LoginFailed "invalid login")
    , completeMfa = \_ -> pure (LoginFailed "mfa failed")
    , refreshUserSession = sharedRefresh (\_ -> pure (LoginFailed "refresh failed"))
    , revokeSession = \_ -> pure ()
    , forwardPortal = \_ _ _ _ -> pure (PortalPassThrough (textResponse status200 "portal"))
    , fetchPortalPage = \_ _ -> pure Nothing
    , newCsrfToken = pure "csrf-token"
    , decisionCache = disabledDecisionCache
    , cookieSettings = Nothing
    }

-- | A refresh that never leads, so the request is forwarded with its cookies
-- instead of answering with the rotation redirect.
sharedRefresh :: (Text -> IO LoginOutcome) -> Text -> IO RefreshResult
sharedRefresh refresh token = RefreshResult RefreshShared <$> refresh token

withHeader :: HeaderName -> ByteString -> Request -> Request
withHeader name value req =
  req {requestHeaders = (name, value) : requestHeaders req}
