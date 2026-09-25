-- | A hostname-specific DNS declaration. The platform's load balancer is an
-- accepted dependency, never a member of the application scope.
module Nagare.Resource.Cdn (compileGoogleDnsRecord) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
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
