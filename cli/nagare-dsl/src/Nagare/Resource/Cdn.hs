-- | A hostname-specific DNS declaration. The platform's load balancer is an
-- accepted dependency, never a member of the application scope.
module Nagare.Resource.Cdn (compileGoogleDnsRecord, compileCloudflareDnsRecord, compileCloudflareCacheContribution, compileCdnDisable) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Cdn.Types (Cdn (..), CdnCacheRule (..), CdnProvider (CloudflareCdn))
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types

compileGoogleDnsRecord ::
  ScopeId ->
  LogicalKey ->
  Name ->
  Name ->
  Name ->
  Text ->
  ResourceId ->
  ResourceId ->
  SourceLocation ->
  Either (NonEmpty InventoryError) ResourceBundle
compileGoogleDnsRecord owner key project zone host target domain backend source = do
  role <- first invalid (mkName "dns-a")
  unless
    (validDnsIpv4 target)
    (Left (invalid "Google DNS target must be an IPv4 address"))
  let resource =
        ManagedResource
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
    invalid message =
      inventoryError "invalid-google-dns" message
        & #scopes
        .~ [owner]
        & #sources
        .~ [source]
        & (:| [])

-- | Each proxied record is claimed by its workload scope, separately from
-- the owner-composed zone cache ruleset it references.
compileCloudflareDnsRecord ::
  ScopeId ->
  LogicalKey ->
  Name ->
  Name ->
  Text ->
  ResourceId ->
  ResourceId ->
  SourceLocation ->
  Either (NonEmpty InventoryError) ResourceBundle
compileCloudflareDnsRecord owner key zone host target domain ruleset source = do
  role <- first invalid (mkName "cloudflare-dns-a")
  unless
    (validDnsIpv4 target)
    (Left (invalid "Cloudflare proxied A target must be an IPv4 address"))
  unless
    (scopeKind owner `elem` [Application, Standalone])
    (Left (invalid "Cloudflare DNS record requires a workload owner"))
  let resource =
        ManagedResource
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
    invalid message =
      inventoryError "invalid-cloudflare-dns" message
        & #scopes
        .~ [owner]
        & #sources
        .~ [source]
        & (:| [])

-- | A host contributes only its typed cache intent. The zone owner composes
-- every host into one ruleset; this bundle cannot directly write the zone.
compileCloudflareCacheContribution ::
  ScopeId ->
  ScopeId ->
  Name ->
  Name ->
  Cdn ->
  ResourceId ->
  SourceLocation ->
  Either (NonEmpty InventoryError) ResourceBundle
compileCloudflareCacheContribution contributor rulesOwner zone host cdn route source = do
  unless
    (cdn ^. #provider == CloudflareCdn)
    (Left (invalid "Cloudflare cache contribution requires the Cloudflare provider"))
  unless
    ( scopeKind contributor `elem` [Application, Standalone]
        && scopeKind rulesOwner == Platform
    )
    (Left (invalid "Cloudflare cache contribution requires a workload and platform owner"))
  let intent =
        CloudflareCacheIntent
          host
          (cdn ^. #defaultTtlSeconds)
          (cdn ^. #cacheStaticAssets)
          [(rule ^. #pathPrefix, rule ^. #edgeTtlSeconds) | rule <- cdn ^. #cacheRules]
  pure
    ( ResourceBundle
        []
        []
        []
        [RegisterCloudflareCache rulesOwner zone intent route]
        []
        []
    )
  where
    invalid message =
      inventoryError "invalid-cloudflare-cache" message
        & #scopes
        .~ [contributor, rulesOwner]
        & #sources
        .~ [source]
        & (:| [])

-- | Disable one accepted workload hostname without relinquishing its DNS claim.
-- Google routes the exact host to the guarded platform origin. Cloudflare keeps
-- the same record unproxied and withdraws only this host's cache contribution.
compileCdnDisable :: ScopeSnapshot -> Text -> Text -> Either Text ScopeDeclaration
compileCdnDisable snapshot rawHost origin = do
  host <- mkName (T.toLower (T.dropWhileEnd (== '.') (T.strip rawHost)))
  unless (validDnsIpv4 origin) (Left "CDN disable requires the accepted platform origin IPv4 address")
  inventory <- first (T.pack . show) (composeSnapshot snapshot)
  selected <- case [ resource
                   | Managed resource <- inventoryDeclarations inventory
                   , case resource ^. #address of
                       DnsRecord _ _ name -> name == host
                       CloudflareDnsRecord _ name -> name == host
                       _ -> False
                   ] of
    [resource] | scopeKind (resource ^. #owner) `elem` [Application, Standalone] -> Right resource
    _ -> Left "CDN disable requires exactly one accepted workload DNS owner; platform/apex and foreign hosts refuse"
  (_, scope) <-
    maybe
      (Left "CDN owner scope is absent")
      Right
      (Map.lookup (selected ^. #owner) (snapshotScopes snapshot))
  desired <- case (selected ^. #address, selected ^. #spec) of
    (DnsRecord {}, DnsARecord _ ttl) -> Right (DnsARecord origin ttl)
    (CloudflareDnsRecord {}, CloudflareProxiedARecord address)
      | address == origin -> Right (CloudflareDnsOnlyARecord address)
    (CloudflareDnsRecord {}, CloudflareDnsOnlyARecord address)
      | address == origin -> Right (CloudflareDnsOnlyARecord address)
    _ -> Left "CDN DNS intent does not match the accepted origin"
  let replace (Managed resource)
        | resource ^. #identity == selected ^. #identity = Managed (resource & #spec .~ desired)
      replace declaration = declaration
      keep (RegisterCloudflareCache _ zone intent _) = case selected ^. #address of
        CloudflareDnsRecord selectedZone _ -> zone /= selectedZone || cacheHost intent /= host
        _ -> True
      keep _ = True
  revised <-
    first
      (T.pack . show)
      ( mkScopeDeclaration
          (scopeId scope)
          [ bundle & #declarations %~ map replace & #contributions %~ filter keep
          | bundle <- scopeBundles scope
          ]
      )
  pure
    ( maybe
        id
        withScopeConfigDigest
        (scopeConfigDigest scope)
        (withScopeOverrides (scopeOverrides scope) revised)
    )
