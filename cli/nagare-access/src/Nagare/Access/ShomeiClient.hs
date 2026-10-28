-- | Login adapter for shomei's generated Servant client.
module Nagare.Access.ShomeiClient
  ( completeMfaWithShomei
  , loginWithShomei
  , logoutWithShomei
  , refreshWithShomei
  , shomeiLoginEnvFromAuthPlane
  , shomeiOutcome
  )
where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, catch)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Access.Auth (LoginCredentials (..), LoginOutcome (..), MfaChallenge (..), MfaCompletion (..), SessionTokens (..))
import Nagare.Access.Config (AuthPlaneConfig (..))
import Nagare.Access.Portal (AccessToken (..))
import Nagare.Access.Prelude
import Shomei.Client qualified as Shomei
import Shomei.Mfa.Dto qualified as Mfa
import Shomei.Session.Dto qualified as DTO

loginWithShomei :: Shomei.ClientEnv -> LoginCredentials -> IO LoginOutcome
loginWithShomei env credentials =
  case credentials ^. #credentialId <|> credentials ^. #email of
    Nothing -> pure (LoginFailed "invalid login")
    Just loginId -> do
      -- The built-in login page has no "keep me signed in", so its sessions
      -- are not remembered.
      result <- Shomei.login env (DTO.LoginRequest loginId (credentials ^. #password) Nothing)
      pure $ shomeiOutcome "invalid login" result $ \response ->
        case Shomei.cookieBody response of
          DTO.LoginMfaRequiredResponse ceremonyId options _methods ->
            LoginMfaRequired MfaChallenge {ceremonyId = ceremonyId, options = options}
          DTO.LoginCompleteResponse _ tokenPair ->
            tokenPairOutcome "invalid login" tokenPair

completeMfaWithShomei :: Shomei.ClientEnv -> MfaCompletion -> IO LoginOutcome
completeMfaWithShomei env completion = do
  result <-
    Shomei.mfaComplete
      env
      ( Mfa.MfaCompleteRequest
          (completion ^. #ceremonyId)
          (Mfa.PasskeyProof (completion ^. #assertion))
          Nothing
      )
  pure (shomeiOutcome "mfa failed" result (tokenPairOutcome "mfa failed" . Shomei.cookieBody))

refreshWithShomei :: Shomei.ClientEnv -> Text -> IO LoginOutcome
refreshWithShomei env refreshToken = do
  result <- Shomei.refresh env (DTO.RefreshRequest (Just refreshToken))
  pure (shomeiOutcome "refresh failed" result (tokenPairOutcome "refresh failed" . Shomei.cookieBody))

-- | Classify one Shomei answer. Only an explicit 4xx rejection is
-- 'LoginFailed'. A transport error, a rate limit, a 5xx or a response that
-- does not decode is 'LoginUnavailable': the token was never judged, and
-- every refresh reaches Shomei from this one pod's address, so a 429 says
-- nothing about this user. The client error is not shown, because a decode
-- failure carries Shomei's response body, which can hold tokens.
shomeiOutcome :: Text -> Either e (Shomei.ApplicationResult a) -> (a -> LoginOutcome) -> LoginOutcome
shomeiOutcome failure result success =
  case result of
    Right (Shomei.ApplicationSuccess value) -> success value
    Right (Shomei.ApplicationBadRequest _) -> LoginFailed failure
    Right (Shomei.ApplicationAuthenticationFailed _) -> LoginFailed failure
    Right (Shomei.ApplicationForbidden _) -> LoginFailed failure
    Right (Shomei.ApplicationNotFound _) -> LoginFailed failure
    Right (Shomei.ApplicationConflict _) -> LoginFailed failure
    Right (Shomei.ApplicationUnprocessable _) -> LoginFailed failure
    Right (Shomei.ApplicationRateLimited _) -> LoginUnavailable "shomei rate-limited the request"
    Right (Shomei.ApplicationInternal _) -> LoginUnavailable "shomei answered an internal error"
    Right (Shomei.ApplicationUnavailable _) -> LoginUnavailable "shomei reported a dependency unavailable"
    Left _ -> LoginUnavailable "shomei did not answer"

-- | Revoke a Shomei session on a best-effort basis. Logout must still clear the
-- browser cookies when Shomei is temporarily unreachable.
logoutWithShomei :: Shomei.ClientEnv -> AccessToken -> IO ()
logoutWithShomei env (AccessToken token) =
  revoke `catch` reportException
  where
    revoke = do
      result <- Shomei.logout env (Shomei.Token token)
      case result of
        Right _ -> pure ()
        Left err -> putStrLn ("warning: could not revoke Shomei session: " <> show err)
    reportException (err :: SomeException) =
      putStrLn ("warning: could not revoke Shomei session: " <> show err)

shomeiLoginEnvFromAuthPlane :: AuthPlaneConfig -> IO Shomei.ClientEnv
shomeiLoginEnvFromAuthPlane cfg =
  Shomei.shomeiClientEnv (Text.unpack (cfg ^. #shomeiUrl))

tokenPairOutcome :: Text -> DTO.TokenPairResponse -> LoginOutcome
tokenPairOutcome _ (DTO.TokenPairResponse (Just access) refresh expires remembered) =
  LoginSucceeded
    SessionTokens
      { accessToken = access
      , refreshToken = refresh
      , expiresIn = expires
      , -- A Shomei that predates remembered sessions keeps every session's
        -- cookies persistent, as before.
        remembered = fromMaybe True remembered
      }
tokenPairOutcome failureMessage _ = LoginFailed failureMessage
