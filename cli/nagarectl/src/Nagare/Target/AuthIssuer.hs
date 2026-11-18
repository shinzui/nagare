-- | EP-264: the token issuer a context gives its Shomei. @NAGARE_AUTH_ISSUER@
-- is the @https@ origin of the context's auth portal, and it turns Shomei into
-- an OpenID Connect provider for native clients. Unset, Shomei keeps the
-- opaque issuer @nagare-shomei@ and OIDC stays off.
--
-- Shomei publishes the issuer verbatim and compares @iss@ exactly, so the value
-- is accepted in one spelling only: @https://HOST@, with a lower-case DNS name
-- and no port, path, trailing slash, query, fragment or user info.
module Nagare.Target.AuthIssuer
  ( AuthIssuer
  , authIssuerVariable
  , mkAuthIssuer
  , parseAuthIssuer
  , authIssuerText
  , authIssuerHost
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude

-- | A validated issuer; its host is the auth portal's.
newtype AuthIssuer = AuthIssuer Text
  deriving stock (Eq, Ord, Show)

authIssuerVariable :: Text
authIssuerVariable = "NAGARE_AUTH_ISSUER"

-- | The issuer from the context, 'Nothing' when it is unset or empty.
parseAuthIssuer :: Map String Text -> Either Text (Maybe AuthIssuer)
parseAuthIssuer ctx = case T.strip <$> Map.lookup (T.unpack authIssuerVariable) ctx of
  Nothing -> Right Nothing
  Just raw | T.null raw -> Right Nothing
  Just raw -> Just <$> mkAuthIssuer raw

mkAuthIssuer :: Text -> Either Text AuthIssuer
mkAuthIssuer raw = case T.stripPrefix "https://" raw of
  Nothing -> refuse "must start with https://"
  Just host
    | T.any (`elem` ("/?#" :: String)) host -> refuse "must have no path, trailing slash, query or fragment"
    | T.any (== '@') host -> refuse "must have no user info"
    | T.any (== ':') host -> refuse "must have no port"
    | not (validHost host) -> refuse "must name a lower-case DNS host"
    | otherwise -> Right (AuthIssuer raw)
  where
    refuse rule = Left (authIssuerVariable <> "=" <> raw <> " " <> rule <> "; it is the auth portal's origin, https://HOST")
    validHost host =
      T.length host <= 253
        && length labels >= 2
        && all validLabel labels
      where
        labels = T.splitOn "." host
    validLabel label =
      not (T.null label)
        && T.length label <= 63
        && T.all (\c -> isAsciiLower c || isDigit c || c == '-') label
        && T.head label /= '-'
        && T.last label /= '-'

authIssuerText :: AuthIssuer -> Text
authIssuerText (AuthIssuer issuer) = issuer

-- | The portal host the issuer names.
authIssuerHost :: AuthIssuer -> Text
authIssuerHost (AuthIssuer issuer) = T.drop (T.length "https://") issuer
