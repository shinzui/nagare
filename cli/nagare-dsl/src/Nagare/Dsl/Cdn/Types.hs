-- | The typed CDN (Content Delivery Network) model (MasterPlan 11, EP-55).
--
-- A CDN is a globally distributed cache that sits in front of an origin server:
-- a 'Cdn' value describes which provider fronts a site, the default edge
-- time-to-live for cacheable responses, whether fingerprinted static assets get
-- an aggressive long-cache rule, and a list of per-path cache overrides. It is
-- attached as an optional @cdn :: Maybe Cdn@ field to the three top-level
-- deployment shapes — 'Nagare.Dsl.Static.Types.StaticSite',
-- 'Nagare.Dsl.Server.Types.ServerSite', and 'Nagare.Dsl.Types.Deployment' — where
-- 'Nothing' means "no CDN" (unchanged behaviour).
--
-- This module renders no infrastructure and talks to no cloud; it only lets a
-- config author /describe/ a CDN through validating entry points. The wire
-- contract (provider tokens @"Cloudflare"@ / @"GcpCloudCdn"@, @edgeTtlSeconds:
-- null@ meaning "never cache this path") is fixed here and consumed by EP-56
-- (Google Cloud CDN in Pulumi), EP-57 (the Cloudflare API client), and EP-58
-- (the deploy seam and @nagarectl cdn@ command group).
--
-- Leaf builders follow the package convention: validating constructors named
-- @mkX@ return @Either Text X@; pure transformations that cannot produce an
-- invalid value are total functions. Construct from a preset
-- ('cloudflareCdn' / 'gcpCloudCdn') and refine with the @with*@ combinators.
module Nagare.Dsl.Cdn.Types
  ( -- * CdnProvider
    CdnProvider (..)

    -- * CdnCacheRule
  , CdnCacheRule (..)
  , mkCdnCacheRule
  , mkCacheRules

    -- * Cdn
  , Cdn (..)

    -- * Presets
  , cloudflareCdn
  , gcpCloudCdn

    -- * Combinators
  , withDefaultTtl
  , withCacheRule
  , withoutStaticAssetCache
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isSpace)
import Data.Text qualified as Text

-- | The CDN backend fronting a site. @CloudflareCdn@ is the preferred default
-- (larger edge network, free tier, DDoS protection); @GcpCloudCdn@ keeps an
-- all-GCP option (a global HTTP(S) load balancer with Cloud CDN enabled). The
-- JSON wire tokens are @"Cloudflare"@ and @"GcpCloudCdn"@ respectively.
data CdnProvider = CloudflareCdn | GcpCloudCdn
  deriving stock (Generic, Eq, Show)

-- | A per-path edge cache rule. Requests whose path begins with @pathPrefix@ get
-- @edgeTtlSeconds@ as their edge time-to-live; @Nothing@ means "never cache this
-- path" (bypass the edge cache). Construct with 'mkCdnCacheRule'.
data CdnCacheRule = CdnCacheRule
  { pathPrefix     :: !Text
  , edgeTtlSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

-- | The CDN configuration attached to a site or app. @defaultTtlSeconds@ is the
-- edge TTL for cacheable responses with no matching rule; @cacheStaticAssets@
-- turns on a long-cache rule for fingerprinted assets (js/css/fonts/images);
-- @cacheRules@ are per-path overrides applied in order. Construct via
-- 'cloudflareCdn' / 'gcpCloudCdn' and the @with*@ combinators.
data Cdn = Cdn
  { provider          :: !CdnProvider
  , defaultTtlSeconds :: !(Maybe Int)
  , cacheStaticAssets :: !Bool
  , cacheRules        :: ![CdnCacheRule]
  }
  deriving stock (Generic, Eq, Show)

-- | Validate and construct a 'CdnCacheRule'. The @pathPrefix@ must be non-empty
-- and not all whitespace; a 'Just' @edgeTtlSeconds@ must be >= 0. A 'Nothing'
-- TTL means "never cache this path" and is always allowed.
mkCdnCacheRule :: Text -> Maybe Int -> Either Text CdnCacheRule
mkCdnCacheRule prefix ttl
  | Text.null prefix = Left "cdn cache rule pathPrefix must not be empty"
  | Text.all isSpace prefix =
      Left "cdn cache rule pathPrefix must not be all whitespace"
  | Just n <- ttl, n < 0 =
      Left ("cdn cache rule edgeTtlSeconds must be >= 0 (or null), got: " <> tshow n)
  | otherwise = Right (CdnCacheRule {pathPrefix = prefix, edgeTtlSeconds = ttl})

-- | Build and validate a whole list of per-path rules at once, for the common
-- record-literal case. Equivalent to folding 'withCacheRule'.
mkCacheRules :: [(Text, Maybe Int)] -> Either Text [CdnCacheRule]
mkCacheRules = traverse (uncurry mkCdnCacheRule)

-- | A Cloudflare CDN with default settings: no default-TTL override (let the
-- provider/origin headers decide), static-asset caching enabled, no per-path
-- rules. Refine with the @with*@ combinators.
cloudflareCdn :: Cdn
cloudflareCdn =
  Cdn
    { provider = CloudflareCdn
    , defaultTtlSeconds = Nothing
    , cacheStaticAssets = True
    , cacheRules = []
    }

-- | A Google Cloud CDN with the same default settings as 'cloudflareCdn'.
gcpCloudCdn :: Cdn
gcpCloudCdn = cloudflareCdn {provider = GcpCloudCdn}

-- | Set a default edge TTL (in seconds) for everything not matched by a per-path
-- rule. Total: a caller-supplied negative value is still rejected on the
-- load-time round-trip by 'Nagare.Dsl.Load.toCdn'.
withDefaultTtl :: Int -> Cdn -> Cdn
withDefaultTtl n c = c {defaultTtlSeconds = Just n}

-- | Turn off the "cache fingerprinted static assets aggressively" behaviour.
withoutStaticAssetCache :: Cdn -> Cdn
withoutStaticAssetCache c = c {cacheStaticAssets = False}

-- | Append a validated per-path cache rule. Fails if the rule is invalid (empty
-- prefix, negative TTL).
withCacheRule :: Text -> Maybe Int -> Cdn -> Either Text Cdn
withCacheRule prefix ttl c = do
  rule <- mkCdnCacheRule prefix ttl
  Right c {cacheRules = cacheRules c <> [rule]}

-- Internal: show a value as Text for error messages.
tshow :: (Show a) => a -> Text
tshow = Text.pack . show
