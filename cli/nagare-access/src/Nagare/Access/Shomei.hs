-- | Adapter from Shomei JWT verification to nagare-access auth services.
module Nagare.Access.Shomei
  ( shomeiConfigFromAuthPlane
  , tokenErrorToAuthFailure
  , verifyShomeiCredential
  , verifyShomeiCredentialCached
  )
where

import Crypto.JOSE.JWK (JWKSet)
import Nagare.Access.Auth (AuthFailure (..), AuthenticatedUser (..))
import Nagare.Access.Config (AuthPlaneConfig (..))
import Nagare.Access.Credential (Credential, credentialToken)
import Nagare.Access.Jwks (JwksCache, getCachedJwks)
import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Claims qualified as Claims
import Shomei.Error (TokenError (..))
import Shomei.Id qualified as ShomeiId
import Shomei.Jwt.Verify (verifyToken)

verifyShomeiCredential :: JWKSet -> AuthPlaneConfig -> Credential -> IO (Either AuthFailure AuthenticatedUser)
verifyShomeiCredential jwks cfg credential = do
  verified <- verifyToken jwks (shomeiConfigFromAuthPlane cfg) (credentialToken credential)
  pure $ case verified of
    Left err -> Left (tokenErrorToAuthFailure err)
    Right claims -> Right (claimsToUser claims)

verifyShomeiCredentialCached :: JwksCache -> AuthPlaneConfig -> Credential -> IO (Either AuthFailure AuthenticatedUser)
verifyShomeiCredentialCached cache cfg credential = do
  loaded <- getCachedJwks cache
  case loaded of
    Left err -> pure (Left (VerificationUnavailable err))
    Right jwks -> verifyShomeiCredential jwks cfg credential

shomeiConfigFromAuthPlane :: AuthPlaneConfig -> ShomeiConfig
shomeiConfigFromAuthPlane cfg =
  defaultShomeiConfig
    (Issuer (shomeiIssuer cfg))
    (Audience (shomeiAudience cfg))

tokenErrorToAuthFailure :: TokenError -> AuthFailure
tokenErrorToAuthFailure TokenExpired = ExpiredCredential
tokenErrorToAuthFailure TokenMalformed = InvalidCredential
tokenErrorToAuthFailure TokenSignatureInvalid = InvalidCredential
tokenErrorToAuthFailure TokenIssuerInvalid = InvalidCredential
tokenErrorToAuthFailure TokenAudienceInvalid = InvalidCredential
tokenErrorToAuthFailure (TokenOtherError _) = InvalidCredential

claimsToUser :: Claims.AuthClaims -> AuthenticatedUser
claimsToUser claims =
  AuthenticatedUser {userSubject = ShomeiId.idText (Claims.subject claims)}
