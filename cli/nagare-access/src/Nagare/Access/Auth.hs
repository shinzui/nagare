-- | Request-path authentication and authorization interfaces.
module Nagare.Access.Auth
  ( AccessServices (..)
  , AuthFailure (..)
  , AuthenticatedUser (..)
  , LoginCredentials (..)
  , LoginOutcome (..)
  , SessionTokens (..)
  )
where

import Data.Text (Text)
import Nagare.Access.BackendMap (BackendTarget)
import Nagare.Access.Cookie (CookieSettings)
import Nagare.Access.Credential (Credential)
import Nagare.Access.DecisionCache (AccessDecision, DecisionCache)
import Network.Wai (Request, Response)

newtype AuthenticatedUser = AuthenticatedUser
  { userSubject :: Text
  }
  deriving stock (Eq, Show)

data AuthFailure
  = InvalidCredential
  | ExpiredCredential
  | VerificationUnavailable Text
  deriving stock (Eq, Show)

data LoginCredentials = LoginCredentials
  { loginCredentialId :: !(Maybe Text)
  , loginCredentialEmail :: !(Maybe Text)
  , loginCredentialPassword :: !Text
  }
  deriving stock (Eq, Show)

data SessionTokens = SessionTokens
  { accessToken :: !Text
  , refreshToken :: !(Maybe Text)
  , expiresIn :: !Int
  }
  deriving stock (Eq, Show)

data LoginOutcome
  = LoginSucceeded !SessionTokens
  | LoginMfaRequired
  | LoginFailed !Text
  deriving stock (Eq, Show)

data AccessServices = AccessServices
  { verifyCredential :: !(Credential -> IO (Either AuthFailure AuthenticatedUser))
  , authorizeUser :: !(AuthenticatedUser -> Text -> IO AccessDecision)
  , forwardAuthorized :: !(AuthenticatedUser -> Text -> BackendTarget -> Request -> IO Response)
  , loginUser :: !(LoginCredentials -> IO LoginOutcome)
  , newCsrfToken :: !(IO Text)
  , decisionCache :: !DecisionCache
  , cookieSettings :: !(Maybe CookieSettings)
  }
