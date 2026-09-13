-- | The deploy-time CDN provisioning seam (MasterPlan 11, EP-58). One
-- provider-dispatching function, 'provisionCdn', turns a typed 'Cdn' plus a
-- resolved 'CdnTarget' into edge configuration, dispatching on the provider to
-- EP-57's Cloudflare API module or to @gcloud@ against EP-56's standing Google
-- load balancer. A pure intermediate 'CdnPlan' (built by 'planCdn', printed by
-- 'renderCdnPlan') makes the @--dry-run@ output and the live run derive from the
-- same ordered action list, and holds NO secrets (the Cloudflare token never
-- appears here) so it is safe to print.
module Nagare.Cdn.Provision
  ( -- * Resolved inputs / outputs
    CdnTarget (..)
  , CdnResult (..)
  , GcpStackRefs (..)

    -- * Pure plan (unit-tested)
  , CdnPlan (..)
  , CdnAction (..)
  , planCdn
  , renderCdnPlan
  , gcloudDnsUpsertArgs
  , gcloudBackendCacheArgs

    -- * Provisioning (IO; total via Either)
  , provisionCdn
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cdn.Cloudflare
  ( OriginTlsMode (Flexible)
  , applyCacheRules
  , loadCloudflareCreds
  , setOriginTlsMode
  , upsertProxiedRecord
  )
import Nagare.Dsl.Cdn.Types (Cdn (..), CdnCacheRule (..), CdnProvider (..))
import Nagare.Dsl.Prelude
import Nagare.Ops.Probe (captureTool)

-- ---------------------------------------------------------------------------
-- Types

-- | Everything the seam needs that is independent of the provider, resolved by
-- the caller from the loaded config and the Pulumi outputs.
data CdnTarget = CdnTarget
  { hostnames :: ![Text]
  -- ^ the site's custom domains (the hostnames to front)
  , originIp :: !Text
  -- ^ the origin VM IP (the @publicIp@ stack output)
  , namespace :: !Text
  -- ^ the Knative namespace
  , service :: !Text
  -- ^ the Knative Service name
  }
  deriving stock (Generic, Eq, Show)

-- | What the caller prints on success — the now-edge-served URLs and a summary.
data CdnResult = CdnResult
  { edgeUrls :: ![Text]
  , summary :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | The Google-only inputs (EP-56 stack outputs). Unused on the Cloudflare branch.
data GcpStackRefs = GcpStackRefs
  { globalIp :: !Text
  , backendService :: !Text
  , urlMap :: !Text
  , dnsZone :: !Text
  , project :: !Text
  -- ^ the GCP project the gcloud argv target (EP-62; from 'Nagare.Target.project')
  }
  deriving stock (Generic, Eq, Show)

-- | An ordered, provider-specific list of actions a CDN provisioning would take.
data CdnPlan = CdnPlan
  { provider :: !CdnProvider
  , actions :: ![CdnAction]
  }
  deriving stock (Generic, Eq, Show)

data CdnAction
  = -- | hostname, target IP, kind ("proxied" | "A-record")
    DnsUpsert !Text !Text !Text
  | -- | path prefix, ttl description ("31536000s" | "never")
    CacheRule !Text !Text
  | -- | origin-TLS mode description, e.g. "Flexible"
    OriginTls !Text
  | -- | a gcloud argv we would run (already includes --project)
    GcloudCmd ![Text]
  deriving stock (Generic, Eq, Show)

-- ---------------------------------------------------------------------------
-- Pure planning

-- | Build the ordered action list for a 'Cdn' + 'CdnTarget'. Cloudflare points a
-- proxied record at the origin IP (its edge sits transparently in front), sets
-- the origin-TLS mode, and applies the cache rules. Google writes a more-specific
-- Cloud DNS A record at the anycast IP (so the hostname wins over the wildcard)
-- and updates the backend service's cache behaviour — both as @gcloud@ argv that
-- already carry @--project=\<target-project>@ (EP-62: from 'project').
planCdn :: Cdn -> CdnTarget -> GcpStackRefs -> CdnPlan
planCdn cdn target refs =
  case cdn ^. #provider of
    CloudflareCdn -> CdnPlan CloudflareCdn (cloudflareActions cdn target)
    GcpCloudCdn -> CdnPlan GcpCloudCdn (gcpActions cdn target refs)

cloudflareActions :: Cdn -> CdnTarget -> [CdnAction]
cloudflareActions cdn target =
  [DnsUpsert h (target ^. #originIp) "proxied" | h <- target ^. #hostnames]
    ++ [OriginTls "Flexible"]
    ++ [CacheRule (r ^. #pathPrefix) (ttlDesc (r ^. #edgeTtlSeconds)) | r <- cdn ^. #cacheRules]
    ++ [CacheRule "(static assets)" "31536000s" | cdn ^. #cacheStaticAssets]
    ++ maybe [] (\t -> [CacheRule "(default)" (tshow t <> "s")]) (cdn ^. #defaultTtlSeconds)

gcpActions :: Cdn -> CdnTarget -> GcpStackRefs -> [CdnAction]
gcpActions cdn target refs =
  [ GcloudCmd (gcloudDnsUpsertArgs (refs ^. #project) (refs ^. #dnsZone) h (refs ^. #globalIp))
  | h <- target ^. #hostnames
  ]
    ++ [GcloudCmd (gcloudBackendCacheArgs (refs ^. #project) (refs ^. #backendService) cdn)]

-- | The description of an edge TTL for a plan line: @Just n@ -> @"<n>s"@,
-- @Nothing@ -> @"never"@ (a never-cache / bypass rule).
ttlDesc :: Maybe Int -> Text
ttlDesc Nothing = "never"
ttlDesc (Just n) = tshow n <> "s"

-- | The exact @gcloud dns record-sets create@ argv for a more-specific A record
-- pointing @hostname@ at @ip@ in @zone@. Carries @--project=\<project>@ per the
-- repo isolation policy (EP-62). @disable@ later deletes this exact record so the
-- hostname falls back to the @*.<baseDomain>@ wildcard / VM.
gcloudDnsUpsertArgs :: Text -> Text -> Text -> Text -> [Text]
gcloudDnsUpsertArgs project zone hostname ip =
  [ "dns"
  , "record-sets"
  , "create"
  , hostname <> "."
  , "--type=A"
  , "--ttl=300"
  , "--rrdatas=" <> ip
  , "--zone=" <> zone
  , "--project=" <> project
  ]

-- | The exact @gcloud compute backend-services update@ argv applying this site's
-- cache behaviour on top of EP-56's standing backend service. @cacheStaticAssets@
-- selects @CACHE_ALL_STATIC@ (else @USE_ORIGIN_HEADERS@); a default TTL adds
-- @--default-ttl@. Carries @--project=\<project>@ (EP-62).
gcloudBackendCacheArgs :: Text -> Text -> Cdn -> [Text]
gcloudBackendCacheArgs project backendService cdn =
  [ "compute"
  , "backend-services"
  , "update"
  , backendService
  , "--cache-mode=" <> cacheMode
  ]
    ++ maybe [] (\t -> ["--default-ttl=" <> tshow t]) (cdn ^. #defaultTtlSeconds)
    ++ ["--project=" <> project]
  where
    cacheMode
      | cdn ^. #cacheStaticAssets = "CACHE_ALL_STATIC"
      | otherwise = "USE_ORIGIN_HEADERS"

-- | Render a plan as a stable, human-readable block for @--dry-run@.
renderCdnPlan :: CdnPlan -> Text
renderCdnPlan plan =
  T.unlines (header : map renderAction (plan ^. #actions))
  where
    header = "--- CDN plan (" <> providerToken (plan ^. #provider) <> ") ---"
    providerToken CloudflareCdn = "Cloudflare"
    providerToken GcpCloudCdn = "GcpCloudCdn"
    renderAction (DnsUpsert host ip kind) =
      "DNS: " <> host <> " -> " <> ip <> " (" <> kind <> ")"
    renderAction (CacheRule prefix ttl) = "Cache: " <> prefix <> " -> " <> ttl
    renderAction (OriginTls mode) = "Origin TLS: " <> mode
    renderAction (GcloudCmd args) = "gcloud " <> T.unwords args

-- ---------------------------------------------------------------------------
-- IO provisioning (dispatch on provider)

-- | Provision the chosen CDN for a live origin. Cloudflare goes through EP-57's
-- API module; Google runs the planned @gcloud@ commands. Total: any
-- credential/zone/API/@gcloud@ failure is a 'Left'. Called AFTER the origin is
-- Ready, so a 'Left' never takes the origin down — the caller reports it and
-- keeps the origin URL.
provisionCdn :: Cdn -> CdnTarget -> GcpStackRefs -> IO (Either Text CdnResult)
provisionCdn cdn target refs =
  case cdn ^. #provider of
    CloudflareCdn -> provisionCloudflare cdn target
    GcpCloudCdn -> provisionGcp (planCdn cdn target refs) target

provisionCloudflare :: Cdn -> CdnTarget -> IO (Either Text CdnResult)
provisionCloudflare cdn target = do
  ecreds <- loadCloudflareCreds
  case ecreds of
    Left e -> pure (Left e)
    Right creds -> do
      let hosts = target ^. #hostnames
          ip = target ^. #originIp
          steps =
            concat
              [ [ upsertProxiedRecord creds h ip
                , setOriginTlsMode creds h Flexible
                , applyCacheRules creds h cdn
                ]
              | h <- hosts
              ]
      r <- runSteps steps
      pure $ case r of
        Left e -> Left e
        Right () ->
          Right
            ( CdnResult
                ["https://" <> h | h <- hosts]
                ("Cloudflare edge: " <> tshow (length hosts) <> " hostname(s) proxied")
            )

provisionGcp :: CdnPlan -> CdnTarget -> IO (Either Text CdnResult)
provisionGcp plan target = go (plan ^. #actions)
  where
    hosts = target ^. #hostnames
    done =
      Right
        ( CdnResult
            ["https://" <> h | h <- hosts]
            ("Google Cloud CDN: " <> tshow (length hosts) <> " hostname(s) routed to the load balancer")
        )
    go [] = pure done
    go (GcloudCmd args : rest) = do
      m <- captureTool "gcloud" (map T.unpack args)
      case m of
        Nothing -> pure (Left ("gcloud failed: gcloud " <> T.unwords args))
        Just _ -> go rest
    go (_ : rest) = go rest

-- | Run a sequence of @IO (Either Text ())@ steps, short-circuiting on the first
-- 'Left'.
runSteps :: [IO (Either Text ())] -> IO (Either Text ())
runSteps [] = pure (Right ())
runSteps (a : as) = do
  r <- a
  case r of
    Left e -> pure (Left e)
    Right () -> runSteps as

-- Internal: show a value as Text.
tshow :: (Show a) => a -> Text
tshow = T.pack . show
