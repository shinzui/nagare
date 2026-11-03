-- | The shape of a workload's default public hostname (ADR 20, ADR 34).
--
-- A context behind a tunnel flattens default names to one label below the base, because the free edge
-- certificate covers the base and one label only. This agrees with the Knative domain template that
-- 'Nagare.Inventory.Components.Upstream.tunnelDomainTemplate' installs.
module Nagare.Deploy.Host
  ( HostShape (..)
  , defaultHostName
  , previewHostName
  , reservedHostLabels
  )
where

import Data.Text (Text)
import Nagare.Dsl.Prelude

data HostShape
  = -- | @\<name>.\<namespace>.\<base>@
    NestedHosts
  | -- | @\<name>-\<namespace>.\<base>@
    FlatHosts
  deriving stock (Eq, Show)

defaultHostName :: HostShape -> Text -> Text -> Text -> Text
defaultHostName NestedHosts name namespace base = name <> "." <> namespace <> "." <> base
defaultHostName FlatHosts name namespace base = name <> "-" <> namespace <> "." <> base

-- | A preview's hostname, from its normalized name and its site.
previewHostName :: HostShape -> Text -> Text -> Text -> Text
previewHostName NestedHosts preview site base = preview <> "." <> site <> ".preview." <> base
previewHostName FlatHosts preview site base = preview <> "-" <> site <> "-preview." <> base

-- | One-label names the platform itself uses. A flattened default name cannot contain a dot, so it can
-- only collide with these if a workload's name and namespace are chosen to spell one.
reservedHostLabels :: [Text]
reservedHostLabels = ["admin", "auth", "hooks"]
