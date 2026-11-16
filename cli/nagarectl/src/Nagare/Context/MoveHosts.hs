-- | Every URL a move onto the tunnel changes (EP-243 D11), read from the accepted scopes. The free
-- edge certificate covers the base and one label below it, so a default name @<name>.<namespace>.<base>@
-- becomes @<name>-<namespace>.<base>@, a grant on the old name does not reach the new one, and a
-- custom domain two labels deep needs Advanced Certificate Manager.
module Nagare.Context.MoveHosts
  ( HostChange (..)
  , hostChanges
  , renderHostChange
  , blocksMove
  )
where

import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.Text qualified as T
import Nagare.Deploy.Host (HostShape (..), defaultHostName)
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Types

data HostChange
  = -- | A workload's default name, from the nested to the flat form.
    DefaultRenamed !Text !Text
  | -- | Grants, or a protected route, on a default name that the move would leave behind.
    ProtectedRenamed !Text !Text
  | -- | A custom domain deeper than one label below the base.
    NeedsAdvancedCertificate !Text
  deriving stock (Eq, Ord, Show)

-- | The changes, in a stable order, for the accepted members of a context with base domain @base@.
hostChanges :: Text -> [ManagedResource] -> [HostChange]
hostChanges base members =
  sort . nub $
    [ if nested `elem` protectedHosts then ProtectedRenamed nested flat else DefaultRenamed nested flat
    | (namespace, name) <- services
    , let nested = defaultHostName NestedHosts name namespace base
          flat = defaultHostName FlatHosts name namespace base
    ]
      <> [NeedsAdvancedCertificate host | host <- customDomains, deep host, host `notElem` nestedDefaults]
  where
    nestedDefaults = [defaultHostName NestedHosts name namespace base | (namespace, name) <- services]
    addresses = concat [m ^. #address : m ^. #aliases | m <- members]
    services =
      [ (nameText namespace, nameText name)
      | Kubernetes _ "serving.knative.dev" kind (Just namespace) name <- addresses
      , nameText kind == "service"
      , nameText namespace `notElem` ["nagare-system", "knative-serving", "kourier-system"]
      ]
    customDomains =
      [nameText name | Kubernetes _ "serving.knative.dev" kind _ name <- addresses, nameText kind == "domainmapping"]
    -- A protected workload's default name is a DomainMapping to the enforcer, and its grants are on that host.
    protectedHosts =
      customDomains
        <> [nameText host | AccessTuple _ host _ <- addresses]
        <> [nameText host | TeamAccessTuple _ host _ <- addresses]
    deep host = case T.stripSuffix ("." <> base) host of
      Just label -> T.any (== '.') label
      Nothing -> False

-- | A change the move cannot carry yet: a protected name holds grants and an enforcer route that
-- would have to be re-declared on the new name, and a deep custom domain stops being served.
blocksMove :: HostChange -> Bool
blocksMove = \case
  DefaultRenamed _ _ -> False
  ProtectedRenamed _ _ -> True
  NeedsAdvancedCertificate _ -> True

renderHostChange :: HostChange -> Text
renderHostChange = \case
  DefaultRenamed old new -> "  " <> old <> " -> " <> new
  ProtectedRenamed old new -> "  " <> old <> " -> " <> new <> " (protected: its route and grants are on the old name)"
  NeedsAdvancedCertificate host -> "  " <> host <> " (two labels below the base: needs Advanced Certificate Manager, or a one-label name)"
