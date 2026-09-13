-- | Login adapter for shomei's generated Servant client.
module Nagare.Access.ShomeiClient
  ( completeMfaWithShomei
  , loginWithShomei
  , logoutWithShomei
  , refreshWithShomei
  , shomeiLoginEnvFromAuthPlane
  )
where

import Nagare.Access.Prelude
import Data.Generics.Labels ()

import Control.Applicative ((<|>))
import Control.Exception (SomeException, catch)
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Access.Auth (LoginCredentials (..), LoginOutcome (..), MfaChallenge (..), MfaCompletion (..), SessionTokens (..))
import Nagare.Access.Config (AuthPlaneConfig (..))
import Nagare.Access.Portal (AccessToken (..))
import Shomei.Client qualified as Shomei
import Shomei.Mfa.Dto qualified as Mfa
import Shomei.Session.Dto qualified as DTO

loginWithShomei :: Shomei.ClientEnv -> LoginCredentials -> IO LoginOutcome
loginWithShomei env credentials =
  case credentials ^. #credentialId <|> credentials ^. #email of
    Nothing -> pure (LoginFailed "invalid login")
    Just loginId -> do
      result <- Shomei.login env (DTO.LoginRequest loginId (credentials ^. #password))
      pure $ case result of
        Right (Shomei.ApplicationSuccess response) ->
          case Shomei.cookieBody response of
            DTO.LoginMfaRequiredResponse ceremonyId options _methods ->
              LoginMfaRequired MfaChallenge {ceremonyId = ceremonyId, options = options}
            DTO.LoginCompleteResponse _ tokenPair ->
              tokenPairOutcome "invalid login" tokenPair
        -- Upstream now exposes RFC 7807 details on every non-success constructor.
        -- Preserve nagare-access's existing outward failure text in this compatibility change.
        _ -> LoginFailed "invalid login"

completeMfaWithShomei :: Shomei.ClientEnv -> MfaCompletion -> IO LoginOutcome
completeMfaWithShomei env completion = do
  result <-
    Shomei.mfaComplete
      env
      ( Mfa.MfaCompleteRequest
          (completion ^. #ceremonyId)
          (Mfa.PasskeyProof (completion ^. #assertion))
      )
  pure $ case result of
    Right (Shomei.ApplicationSuccess response) ->
      tokenPairOutcome "mfa failed" (Shomei.cookieBody response)
    _ -> LoginFailed "mfa failed"

refreshWithShomei :: Shomei.ClientEnv -> Text -> IO LoginOutcome
refreshWithShomei env refreshToken = do
  result <- Shomei.refresh env (DTO.RefreshRequest (Just refreshToken))
  pure $ case result of
    Right (Shomei.ApplicationSuccess response) ->
      tokenPairOutcome "refresh failed" (Shomei.cookieBody response)
    _ -> LoginFailed "refresh failed"

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
tokenPairOutcome _ (DTO.TokenPairResponse (Just access) refresh expires) =
  LoginSucceeded
    SessionTokens
      { accessToken = access
      , refreshToken = refresh
      , expiresIn = expires
      }
tokenPairOutcome failureMessage _ = LoginFailed failureMessage
