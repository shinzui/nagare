-- | The enforcer runtime every WAI-level test starts from: a verifier that
-- admits one signed-in subject, an authorizer that allows, and a proxy that
-- answers "proxied". Tests override the one service under test.
module TestServices (testServices) where

import Nagare.Access.App (textResponse)
import Nagare.Access.Auth
import Nagare.Access.DecisionCache (AccessDecision (..), AuthorizationResult (..), disabledDecisionCache)
import Nagare.Access.Prelude
import Network.HTTP.Types (status200)

testServices :: AccessServices
testServices =
  AccessServices
    { verifyCredential = \_ -> pure (Right AuthenticatedUser {subject = "user:alice"})
    , authorizeUser = \_ _ -> pure (AuthorizationDecision AccessAllowed)
    , forwardAuthorized = \_ _ _ _ -> pure (textResponse status200 "proxied")
    , loginUser = \_ -> pure (LoginFailed "invalid login")
    , completeMfa = \_ -> pure (LoginFailed "mfa failed")
    , refreshUserSession = \_ -> pure (LoginFailed "refresh failed")
    , revokeSession = \_ -> pure ()
    , forwardPortal = \_ _ _ -> pure (PortalPassThrough (textResponse status200 "portal"))
    , fetchPortalPage = \_ _ -> pure Nothing
    , newCsrfToken = pure "csrf-token"
    , decisionCache = disabledDecisionCache
    , cookieSettings = Nothing
    }
