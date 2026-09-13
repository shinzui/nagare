-- | Request-path authentication and authorization interfaces.
module Nagare.Access.Auth
  ( AccessServices (..)
  , AuthFailure (..)
  , AuthenticatedUser (..)
  , LoginCredentials (..)
  , LoginOutcome (..)
  , MfaChallenge (..)
  , MfaCompletion (..)
  , PortalIdentity (..)
  , PortalPageRequest (..)
  , PortalUpstreamResult (..)
  , SessionTokens (..)
  )
where

import Data.Aeson (Value)
import Data.Text (Text)
import Nagare.Access.BackendMap (BackendTarget, Portal)
import Nagare.Access.Cookie (CookieSettings)
import Nagare.Access.Credential (Credential)
import Nagare.Access.DecisionCache (AuthorizationResult, DecisionCache)
import Nagare.Access.Portal (AccessToken, CapturedResponse, PortalPage, PortalPageKind, ReturnTarget, SessionHandoff)
import Nagare.Access.Prelude
import Network.Wai (Request, Response)

newtype AuthenticatedUser = AuthenticatedUser
  { subject :: Text
  }
  deriving stock (Generic, Eq, Show)

data AuthFailure
  = InvalidCredential
  | ExpiredCredential
  | VerificationUnavailable Text
  deriving stock (Generic, Eq, Show)

data LoginCredentials = LoginCredentials
  { credentialId :: !(Maybe Text)
  , email :: !(Maybe Text)
  , password :: !Text
  }
  deriving stock (Generic, Eq, Show)

data SessionTokens = SessionTokens
  { accessToken :: !Text
  , refreshToken :: !(Maybe Text)
  , expiresIn :: !Int
  }
  deriving stock (Generic, Eq, Show)

data MfaChallenge = MfaChallenge
  { ceremonyId :: !Text
  , options :: !Value
  }
  deriving stock (Generic, Eq, Show)

data MfaCompletion = MfaCompletion
  { ceremonyId :: !Text
  , assertion :: !Value
  }
  deriving stock (Generic, Eq, Show)

data LoginOutcome
  = LoginSucceeded !SessionTokens
  | LoginMfaRequired !MfaChallenge
  | LoginFailed !Text
  deriving stock (Generic, Eq, Show)

data PortalIdentity
  = PortalAnonymous
  | PortalAuthenticated !AuthenticatedUser !AccessToken
  deriving stock (Generic, Eq, Show)

data PortalUpstreamResult
  = PortalPassThrough !Response
  | PortalSessionEstablish !SessionHandoff
  | PortalHandoffMalformed !Text
  | PortalSessionClear !CapturedResponse
  deriving stock (Generic)

data PortalPageRequest = PortalPageRequest
  { kind :: !PortalPageKind
  , target :: !ReturnTarget
  , user :: !(Maybe AuthenticatedUser)
  }
  deriving stock (Generic, Eq, Show)

data AccessServices = AccessServices
  { verifyCredential :: !(Credential -> IO (Either AuthFailure AuthenticatedUser))
  , authorizeUser :: !(AuthenticatedUser -> Text -> IO AuthorizationResult)
  -- ^ Ask the authorizer about this user and host. The result distinguishes
  -- "the authorizer said no" from "the authorizer could not be reached".
  , forwardAuthorized :: !(AuthenticatedUser -> Text -> BackendTarget -> Request -> IO Response)
  , loginUser :: !(LoginCredentials -> IO LoginOutcome)
  , completeMfa :: !(MfaCompletion -> IO LoginOutcome)
  , refreshUserSession :: !(Text -> IO LoginOutcome)
  , revokeSession :: !(AccessToken -> IO ())
  , forwardPortal :: !(Portal -> PortalIdentity -> Request -> IO PortalUpstreamResult)
  , fetchPortalPage :: !(Portal -> PortalPageRequest -> IO (Maybe PortalPage))
  , newCsrfToken :: !(IO Text)
  , decisionCache :: !DecisionCache
  , cookieSettings :: !(Maybe CookieSettings)
  }
  deriving stock (Generic)
