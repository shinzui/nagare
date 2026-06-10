-- | The @nagarectl cdn list@ / @cdn status@ presentation (MasterPlan 11, EP-58).
-- Pure row-building and formatters parallel to 'Nagare.Ops.Domains', plus a thin
-- discovery (`queryCdnRows`) that degrades gracefully to an empty list when the
-- cluster / cloud tools are unavailable (the powered-off VM, no Cloudflare token).
-- The formatters are the unit-tested, cluster-free surface.
module Nagare.Cdn.Status
  ( CdnRow (..)
  , CdnDnsTarget (..)
  , formatCdnList
  , formatCdnStatus
  , queryCdnRows
  ) where

import Nagare.Dsl.Prelude

import Data.Text qualified as T

-- | Where a CDN-fronted hostname currently points.
data CdnDnsTarget
  = -- | DNS resolves to the CDN edge (carries the edge IP / "proxied")
    PointsAtEdge !Text
  | -- | DNS resolves to the origin VM (carries the VM IP)
    PointsAtVm !Text
  | -- | could not be determined (tools unavailable / deferred)
    DnsUnknown
  deriving stock (Generic, Eq, Show)

-- | One CDN-fronted hostname's state for @cdn list@ / @cdn status@.
data CdnRow = CdnRow
  { cdnRowHost :: !Text
  , cdnRowProvider :: !Text
  -- ^ "Cloudflare" | "GcpCloudCdn"
  , cdnRowDns :: !CdnDnsTarget
  , cdnRowCache :: !Text
  -- ^ short cache summary, e.g. "default 3600s, 2 rules"
  , cdnRowReady :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Render an aligned @HOST / PROVIDER / DNS / CACHE / READY@ table, parallel to
-- 'Nagare.Ops.Domains.formatDomainList'. The empty case prints a clear sentinel.
formatCdnList :: [CdnRow] -> Text
formatCdnList [] = "(no CDN-fronted hostnames)\n"
formatCdnList rows =
  T.unlines (headerLine : map rowLine rows)
  where
    cols =
      [ ("HOST", cdnRowHost)
      , ("PROVIDER", cdnRowProvider)
      , ("DNS", dnsCell . cdnRowDns)
      , ("CACHE", cdnRowCache)
      , ("READY", readyCell . cdnRowReady)
      ]
    widthOf (h, f) = maximum (T.length h : map (T.length . f) rows)
    widths = map widthOf cols
    headerLine = T.intercalate "  " (zipWith pad widths (map fst cols))
    rowLine r = T.intercalate "  " (zipWith pad widths [f r | (_, f) <- cols])
    pad w t = t <> T.replicate (w - T.length t) " "

-- | Render one hostname's state as a field block (parallel to a single
-- @domains list@ row expanded).
formatCdnStatus :: CdnRow -> Text
formatCdnStatus r =
  T.unlines
    [ "Host:     " <> cdnRowHost r
    , "Provider: " <> cdnRowProvider r
    , "DNS:      " <> dnsCell (cdnRowDns r)
    , "Cache:    " <> cdnRowCache r
    , "Ready:    " <> readyCell (cdnRowReady r)
    ]

dnsCell :: CdnDnsTarget -> Text
dnsCell (PointsAtEdge ip) = "points at edge (" <> ip <> ")"
dnsCell (PointsAtVm ip) = "points at VM (" <> ip <> ")"
dnsCell DnsUnknown = "unknown"

readyCell :: Bool -> Text
readyCell True = "ready"
readyCell False = "pending"

-- | Thin discovery for @cdn list@ / @cdn status@. Enumerating which hostnames are
-- CDN-fronted, their provider, and whether DNS currently resolves to the edge or
-- the VM requires the cluster and the cloud tools (Cloud DNS / Cloudflare reads),
-- which are environment-gated (the VM is powered off; no Cloudflare token in CI).
-- Until those live reads are wired, this degrades gracefully to an empty list,
-- mirroring how 'Nagare.Ops.Status'/'runDomainsList' tolerate absent tools — so
-- @cdn list@ prints the empty sentinel rather than crashing. @baseDomain@,
-- @originIp@, and @namespace@ are accepted for the future live implementation.
queryCdnRows :: Text -> Text -> Text -> IO [CdnRow]
queryCdnRows _baseDomain _originIp _namespace = pure []
