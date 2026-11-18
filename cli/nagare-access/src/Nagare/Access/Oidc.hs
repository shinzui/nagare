-- | EP-264: the four Shomei OpenID Connect endpoints the enforcer serves on
-- the issuer's host, and nothing else of Shomei. The issuer is the auth
-- portal's @https@ origin; every other path on that host still goes to the
-- portal.
module Nagare.Access.Oidc
  ( OidcRoute (..)
  , OidcProvider (..)
  , oidcHostFromIssuer
  , oidcRoute
  )
where

import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Nagare.Access.BackendMap (PublicHost, mkPublicHost)
import Nagare.Access.Portal (AccessToken)
import Nagare.Access.Prelude
import Network.HTTP.Types (Method)
import Network.Wai (Request, Response)

data OidcRoute
  = OidcDiscovery
  | OidcJwks
  | OidcAuthorize
  | OidcToken
  deriving stock (Generic, Eq, Show, Enum, Bounded)

-- | Where the endpoints are answered, and how a request reaches Shomei. The
-- forwarder gets the session's access token for 'OidcAuthorize' only.
data OidcProvider = OidcProvider
  { host :: !PublicHost
  , forward :: !(OidcRoute -> Maybe AccessToken -> Request -> IO Response)
  }
  deriving stock (Generic)

-- | The OIDC host of an issuer that is exactly @https://HOST@; any other
-- issuer, such as the opaque @nagare-shomei@, serves no endpoint.
oidcHostFromIssuer :: Text -> Maybe PublicHost
oidcHostFromIssuer issuer = do
  authority <- Text.stripPrefix "https://" issuer
  guard (not (Text.null authority) && not (Text.any (`elem` ("/?#@:" :: String)) authority))
  either (const Nothing) Just (mkPublicHost authority)

-- | The exact method and raw path of each endpoint. A trailing slash, another
-- method or any other path is not an endpoint.
oidcRoute :: Method -> ByteString -> Maybe OidcRoute
oidcRoute method path = case (method, path) of
  ("GET", "/.well-known/openid-configuration") -> Just OidcDiscovery
  ("GET", "/.well-known/jwks.json") -> Just OidcJwks
  ("GET", "/oauth/authorize") -> Just OidcAuthorize
  ("POST", "/oauth/token") -> Just OidcToken
  _ -> Nothing
