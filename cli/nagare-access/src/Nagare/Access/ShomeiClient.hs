-- | Login adapter for shomei's generated Servant client.
module Nagare.Access.ShomeiClient
  ( completeMfaWithShomei
  , loginWithShomei
  , refreshWithShomei
  , shomeiLoginEnvFromAuthPlane
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Access.Auth (LoginCredentials (..), LoginOutcome (..), MfaChallenge (..), MfaCompletion (..), SessionTokens (..))
import Nagare.Access.Config (AuthPlaneConfig (..))
import Shomei.Client qualified as Shomei
import Shomei.Servant.DTO qualified as DTO

loginWithShomei :: Shomei.ClientEnv -> LoginCredentials -> IO LoginOutcome
loginWithShomei env credentials = do
  result <-
    Shomei.login
      env
      ( DTO.LoginRequest
          (loginCredentialId credentials)
          (loginCredentialEmail credentials)
          (loginCredentialPassword credentials)
      )
  pure $ case result of
    Left _ ->
      LoginFailed "invalid login"
    Right (DTO.LoginMfaRequiredResponse ceremonyId options) ->
      LoginMfaRequired MfaChallenge {mfaCeremonyId = ceremonyId, mfaOptions = options}
    Right (DTO.LoginCompleteResponse _ (DTO.TokenPairResponse access refresh expires)) ->
      LoginSucceeded (sessionTokens access refresh expires)

completeMfaWithShomei :: Shomei.ClientEnv -> MfaCompletion -> IO LoginOutcome
completeMfaWithShomei env completion = do
  result <-
    Shomei.mfaComplete
      env
      ( DTO.MfaCompleteRequest
          (mfaCompletionCeremonyId completion)
          (mfaCompletionAssertion completion)
      )
  pure $ case result of
    Left _ ->
      LoginFailed "mfa failed"
    Right (DTO.TokenPairResponse access refresh expires) ->
      LoginSucceeded (sessionTokens access refresh expires)

refreshWithShomei :: Shomei.ClientEnv -> Text -> IO LoginOutcome
refreshWithShomei env refreshToken = do
  result <- Shomei.refresh env (DTO.RefreshRequest refreshToken)
  pure $ case result of
    Left _ ->
      LoginFailed "refresh failed"
    Right (DTO.TokenPairResponse access refresh expires) ->
      LoginSucceeded (sessionTokens access refresh expires)

shomeiLoginEnvFromAuthPlane :: AuthPlaneConfig -> IO Shomei.ClientEnv
shomeiLoginEnvFromAuthPlane cfg =
  Shomei.shomeiClientEnv (Text.unpack (shomeiUrl cfg))

sessionTokens :: Text -> Text -> Int -> SessionTokens
sessionTokens access refresh expires =
  SessionTokens
    { accessToken = access
    , refreshToken = Just refresh
    , expiresIn = expires
    }
