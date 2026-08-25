-- | Login adapter for shomei's generated Servant client.
module Nagare.Access.ShomeiClient
  ( completeMfaWithShomei
  , loginWithShomei
  , refreshWithShomei
  , shomeiLoginEnvFromAuthPlane
  )
where

import Control.Applicative ((<|>))
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Access.Auth (LoginCredentials (..), LoginOutcome (..), MfaChallenge (..), MfaCompletion (..), SessionTokens (..))
import Nagare.Access.Config (AuthPlaneConfig (..))
import Shomei.Client qualified as Shomei
import Shomei.Mfa.Dto qualified as Mfa
import Shomei.Session.Dto qualified as DTO

loginWithShomei :: Shomei.ClientEnv -> LoginCredentials -> IO LoginOutcome
loginWithShomei env credentials =
  case loginCredentialId credentials <|> loginCredentialEmail credentials of
    Nothing -> pure (LoginFailed "invalid login")
    Just loginId -> do
      result <- Shomei.login env (DTO.LoginRequest loginId (loginCredentialPassword credentials))
      pure $ case result of
        Right (Shomei.ApplicationSuccess response) ->
          case Shomei.cookieBody response of
            DTO.LoginMfaRequiredResponse ceremonyId options _methods ->
              LoginMfaRequired MfaChallenge {mfaCeremonyId = ceremonyId, mfaOptions = options}
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
          (mfaCompletionCeremonyId completion)
          (Mfa.PasskeyProof (mfaCompletionAssertion completion))
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

shomeiLoginEnvFromAuthPlane :: AuthPlaneConfig -> IO Shomei.ClientEnv
shomeiLoginEnvFromAuthPlane cfg =
  Shomei.shomeiClientEnv (Text.unpack (shomeiUrl cfg))

tokenPairOutcome :: Text -> DTO.TokenPairResponse -> LoginOutcome
tokenPairOutcome _ (DTO.TokenPairResponse (Just access) refresh expires) =
  LoginSucceeded
    SessionTokens
      { accessToken = access
      , refreshToken = refresh
      , expiresIn = expires
      }
tokenPairOutcome failureMessage _ = LoginFailed failureMessage
