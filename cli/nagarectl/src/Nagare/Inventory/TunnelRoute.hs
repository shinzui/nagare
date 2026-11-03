-- | What a context behind a tunnel accepts as a route (ADR 34).
--
-- The zone's two records carry every hostname, so nothing here makes a Cloudflare call. The free edge
-- certificate covers the zone and one label below it, and the edge ends TLS. Direct contexts take none
-- of these checks and hold none of these claims.
module Nagare.Inventory.TunnelRoute
  ( checkTunnelRoutes
  , defaultHostClaims
  )
where

import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Deploy.Host (HostShape (..), defaultHostName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (DomainSpec (..), DomainTls (..), domainText)
import Nagare.Resource.Types (ProviderAddress (Hostname), mkName)

-- | Refuse what cannot work behind the tunnel, before anything is applied.
checkTunnelRoutes :: HostShape -> Text -> Bool -> [DomainSpec] -> Either Text ()
checkTunnelRoutes NestedHosts _ _ _ = Right ()
checkTunnelRoutes FlatHosts base hasCdn domains = do
  when
    hasCdn
    (Left "a per-site CDN is not available behind a Cloudflare Tunnel: the whole zone is already proxied, so remove cdn")
  mapM_ check domains
  where
    check domain = do
      let host = domainText (domain ^. #domain)
      case domain ^. #tls of
        SuppliedTlsSecret _ -> Left ("domain " <> host <> ": Cloudflare ends TLS for a tunnel context, so remove its TLS Secret")
        AutomaticTls -> Right ()
      if host == base
        then Right ()
        else case T.stripSuffix ("." <> base) host of
          Just label
            | T.any (== '.') label ->
                Left
                  ( "domain "
                      <> host
                      <> " is deeper than the free edge certificate covers ("
                      <> base
                      <> " and one label below it); a deeper name needs Cloudflare's Advanced Certificate Manager at $10 a month"
                  )
            | otherwise -> Right ()
          Nothing -> Left ("domain " <> host <> " is outside this context's Cloudflare zone " <> base)

-- | The claim a workload holds on its flattened default name, so the inventory refuses a second workload
-- that flattens to the same name: @a-b@ in namespace @c@ and @a@ in namespace @b-c@. Platform services
-- live in @nagare-system@ and hold no claim of their own, so a tenant may not spell one of their names.
-- A name the workload also declares as a domain is already claimed by its route.
defaultHostClaims :: HostShape -> Text -> Text -> Text -> [DomainSpec] -> Either Text [ProviderAddress]
defaultHostClaims NestedHosts _ _ _ _ = Right []
defaultHostClaims FlatHosts name namespace base domains = do
  let host = defaultHostName FlatHosts name namespace base
  when
    (namespace /= platformNamespace && ("-" <> platformNamespace <> ".") `T.isInfixOf` host)
    (Left ("default name " <> host <> " is reserved for the platform's own services: rename this workload or its namespace"))
  when
    (T.length name + 1 + T.length namespace > 63)
    (Left ("default name " <> host <> " has a first label longer than 63 characters: shorten the workload or namespace name"))
  if host `elem` map (domainText . (^. #domain)) domains
    then Right []
    else (: []) . Hostname <$> mkName host
  where
    platformNamespace = "nagare-system" :: Text
