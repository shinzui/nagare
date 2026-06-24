-- | Request-path authentication and authorization interfaces.
module Nagare.Access.Auth
  ( AccessServices (..)
  , AuthFailure (..)
  , AuthenticatedUser (..)
  )
where

import Data.Text (Text)
import Nagare.Access.BackendMap (BackendTarget)
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

data AccessServices = AccessServices
  { verifyCredential :: !(Credential -> IO (Either AuthFailure AuthenticatedUser))
  , authorizeUser :: !(AuthenticatedUser -> Text -> IO AccessDecision)
  , forwardAuthorized :: !(AuthenticatedUser -> BackendTarget -> Request -> IO Response)
  , decisionCache :: !DecisionCache
  }
