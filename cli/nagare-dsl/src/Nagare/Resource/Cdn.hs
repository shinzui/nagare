-- | A hostname-specific DNS declaration. The platform's load balancer is an
-- accepted dependency, never a member of the application scope.
module Nagare.Resource.Cdn
  (compileGoogleDnsRecord, compileCloudflareDnsRecord, compileCloudflareCacheContribution) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Nagare.Dsl.Cdn.Types (Cdn (..), CdnCacheRule (..), CdnProvider (CloudflareCdn))
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types

compileGoogleDnsRecord
  :: ScopeId -> LogicalKey -> Name -> Name -> Name -> Text
  -> ResourceId -> ResourceId -> SourceLocation
  -> Either (NonEmpty InventoryError) ResourceBundle
compileGoogleDnsRecord owner key project zone host target domain backend source = do
  role <- first invalid (mkName "dns-a")
  unless (validDnsIpv4 target)
    (Left (invalid "Google DNS target must be an IPv4 address"))
  let resource = ManagedResource
        { identity = mintResourceId owner key role
        , owner = owner
        , executor = CdnExecutor
        , address = DnsRecord project zone host
        , aliases = [Hostname host]
        , spec = DnsARecord target 300
        , lifecycle = Retain
        , dataPolicy = Stateless
        , sensitivity = Private
        , dependencies = [OrderedAfter domain, OrderedAfter backend]
        , delegations = []
        , source = source {path = path source <> "/cdn/dns/" <> nameText host}
        }
  pure (ResourceBundle [Managed resource] [] [] [] [] [])
  where
    invalid message = inventoryError "invalid-google-dns" message
      & #scopes .~ [owner]
      & #sources .~ [source]
      & (:| [])

-- | Each proxied record is claimed by its workload scope, separately from
-- the owner-composed zone cache ruleset it references.
compileCloudflareDnsRecord
  :: ScopeId -> LogicalKey -> Name -> Name -> Text
  -> ResourceId -> ResourceId -> SourceLocation
  -> Either (NonEmpty InventoryError) ResourceBundle
compileCloudflareDnsRecord owner key zone host target domain ruleset source = do
  role <- first invalid (mkName "cloudflare-dns-a")
  unless (validDnsIpv4 target)
    (Left (invalid "Cloudflare proxied A target must be an IPv4 address"))
  unless (scopeKind owner `elem` [Application, Standalone])
    (Left (invalid "Cloudflare DNS record requires a workload owner"))
  let resource = ManagedResource
        { identity = mintResourceId owner key role
        , owner = owner
        , executor = CdnExecutor
        , address = CloudflareDnsRecord zone host
        , aliases = [Hostname host]
        , spec = CloudflareProxiedARecord target
        , lifecycle = Retain
        , dataPolicy = Stateless
        , sensitivity = Private
        , dependencies = [OrderedAfter domain, OrderedAfter ruleset]
        , delegations = []
        , source = source {path = path source <> "/cdn/cloudflare-dns/" <> nameText host}
        }
  pure (ResourceBundle [Managed resource] [] [] [] [] [])
  where
    invalid message = inventoryError "invalid-cloudflare-dns" message
      & #scopes .~ [owner]
      & #sources .~ [source]
      & (:| [])

-- | A host contributes only its typed cache intent. The zone owner composes
-- every host into one ruleset; this bundle cannot directly write the zone.
compileCloudflareCacheContribution
  :: ScopeId -> ScopeId -> Name -> Name -> Cdn -> ResourceId -> SourceLocation
  -> Either (NonEmpty InventoryError) ResourceBundle
compileCloudflareCacheContribution contributor rulesOwner zone host cdn route source = do
  unless (cdn ^. #provider == CloudflareCdn)
    (Left (invalid "Cloudflare cache contribution requires the Cloudflare provider"))
  unless (scopeKind contributor `elem` [Application, Standalone]
      && scopeKind rulesOwner == Platform)
    (Left (invalid "Cloudflare cache contribution requires a workload and platform owner"))
  let intent = CloudflareCacheIntent host (cdn ^. #defaultTtlSeconds)
        (cdn ^. #cacheStaticAssets)
        [(rule ^. #pathPrefix, rule ^. #edgeTtlSeconds) | rule <- cdn ^. #cacheRules]
  pure (ResourceBundle [] [] []
    [RegisterCloudflareCache rulesOwner zone intent route] [] [])
  where
    invalid message = inventoryError "invalid-cloudflare-cache" message
      & #scopes .~ [contributor, rulesOwner]
      & #sources .~ [source]
      & (:| [])
