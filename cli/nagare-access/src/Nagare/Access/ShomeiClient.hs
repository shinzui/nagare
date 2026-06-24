-- | Login adapter for shomei's generated Servant client.
module Nagare.Access.ShomeiClient
  ( loginWithShomei
  , shomeiLoginEnvFromAuthPlane
  )
where

import Data.Text qualified as Text
import Nagare.Access.Auth (LoginCredentials (..), LoginOutcome (..), SessionTokens (..))
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
    Right (DTO.LoginMfaRequiredResponse _ _) ->
      LoginMfaRequired
    Right (DTO.LoginCompleteResponse _ (DTO.TokenPairResponse access refresh expires)) ->
      LoginSucceeded
        SessionTokens
          { accessToken = access
          , refreshToken = Just refresh
          , expiresIn = expires
          }

shomeiLoginEnvFromAuthPlane :: AuthPlaneConfig -> IO Shomei.ClientEnv
shomeiLoginEnvFromAuthPlane cfg =
  Shomei.shomeiClientEnv (Text.unpack (shomeiUrl cfg))
