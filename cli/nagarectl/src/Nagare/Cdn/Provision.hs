-- | The deploy-time CDN provisioning seam (MasterPlan 11, EP-58). One
-- provider-dispatching function, 'provisionCdn', turns a typed 'Cdn' plus a
-- resolved 'CdnTarget' into edge configuration, dispatching on the provider to
-- EP-57's Cloudflare API module or to Cloud DNS for the standing Google load
-- balancer. Its shared backend cache policy belongs to Pulumi. A pure
-- intermediate 'CdnPlan' (built by 'planCdn', printed by
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
  , googleCdnHostname
  , renderCdnPlan
  , gcloudDnsDescribeArgs
  , gcloudDnsCreateArgs
  , gcloudDnsUpdateArgs
  , gcloudDnsUpsertArgs

    -- * Provisioning (IO; total via Either)
  , provisionCdn
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cdn.Cloudflare
  ( OriginTlsMode (Flexible)
  , applyCacheRules
  , loadCloudflareCreds
  , setOriginTlsMode
  , upsertProxiedRecord
  )
import Nagare.Dsl.Cdn.Types (Cdn (..), CdnCacheRule (..), CdnProvider (..))
import Nagare.Dsl.Prelude
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

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
  , baseDomain :: !Text
  -- ^ the context-owned platform zone used to constrain Google CDN names
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
  | -- | The platform's Pulumi scope owns this record; no application write.
    DnsReference !Text !Text
  | -- | path prefix, ttl description ("31536000s" | "never")
    CacheRule !Text !Text
  | -- | origin-TLS mode description, e.g. "Flexible"
    OriginTls !Text
  deriving stock (Generic, Eq, Show)

-- ---------------------------------------------------------------------------
-- Pure planning

-- | Build the ordered action list for a 'Cdn' + 'CdnTarget'. Cloudflare points a
-- proxied record at the origin IP (its edge sits transparently in front), sets
-- the origin-TLS mode, and applies the cache rules. Google writes a more-specific
-- Cloud DNS A record at the anycast IP (so the hostname wins over the wildcard)
-- without changing the Pulumi-owned backend cache behaviour.
planCdn :: Cdn -> CdnTarget -> GcpStackRefs -> Either Text CdnPlan
planCdn cdn target refs =
  case cdn ^. #provider of
    CloudflareCdn -> Right (CdnPlan CloudflareCdn (cloudflareActions cdn target))
    GcpCloudCdn -> do
      mapM_ (googleCdnHostname (target ^. #baseDomain)) (target ^. #hostnames)
      unless (cdn ^. #cacheStaticAssets && isNothing (cdn ^. #defaultTtlSeconds)
          && null (cdn ^. #cacheRules))
        (Left "Google CDN cache policy belongs to the Pulumi platform owner; per-application cache overrides are unsupported")
      Right (CdnPlan GcpCloudCdn (gcpActions target refs))

-- | The standing Google certificate covers the exact base apex and one label
-- below it. Cloudflare has no such restriction because it owns edge TLS in the
-- hostname's independent authority.
googleCdnHostname :: Text -> Text -> Either Text ()
googleCdnHostname base hostname
  | hostname == base = Right ()
  | Just label <- T.stripSuffix ("." <> base) hostname
  , not (T.null label)
  , not (T.any (== '.') label) =
      Right ()
  | otherwise =
      Left
        ( hostname
            <> " is not covered by the Google CDN certificate; use the exact base domain "
            <> base
            <> " or one label below it, or select Cloudflare for an unrelated zone"
        )

cloudflareActions :: Cdn -> CdnTarget -> [CdnAction]
cloudflareActions cdn target =
  [DnsUpsert h (target ^. #originIp) "proxied" | h <- target ^. #hostnames]
    ++ [OriginTls "Flexible"]
    ++ [CacheRule (r ^. #pathPrefix) (ttlDesc (r ^. #edgeTtlSeconds)) | r <- cdn ^. #cacheRules]
    ++ [CacheRule "(static assets)" "31536000s" | cdn ^. #cacheStaticAssets]
    ++ maybe [] (\t -> [CacheRule "(default)" (tshow t <> "s")]) (cdn ^. #defaultTtlSeconds)

gcpActions :: CdnTarget -> GcpStackRefs -> [CdnAction]
gcpActions target refs =
  [ if h == target ^. #baseDomain
      then DnsReference h (refs ^. #globalIp)
      else DnsUpsert h (refs ^. #globalIp) "Cloud DNS A-record"
  | h <- target ^. #hostnames
  ]

-- | The description of an edge TTL for a plan line: @Just n@ -> @"<n>s"@,
-- @Nothing@ -> @"never"@ (a never-cache / bypass rule).
ttlDesc :: Maybe Int -> Text
ttlDesc Nothing = "never"
ttlDesc (Just n) = tshow n <> "s"

-- | The exact idempotent update argv. Live provisioning first describes the
-- record, skips an exact match, creates an absent record, or runs this update.
gcloudDnsUpsertArgs :: Text -> Text -> Text -> Text -> [Text]
gcloudDnsUpsertArgs = gcloudDnsUpdateArgs

gcloudDnsDescribeArgs :: Text -> Text -> Text -> [Text]
gcloudDnsDescribeArgs project zone hostname =
  [ "dns"
  , "record-sets"
  , "describe"
  , hostname <> "."
  , "--type=A"
  , "--zone=" <> zone
  , "--format=json"
  , "--project=" <> project
  ]

gcloudDnsCreateArgs :: Text -> Text -> Text -> Text -> [Text]
gcloudDnsCreateArgs project zone hostname ip =
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

gcloudDnsUpdateArgs :: Text -> Text -> Text -> Text -> [Text]
gcloudDnsUpdateArgs project zone hostname ip =
  [ "dns"
  , "record-sets"
  , "update"
  , hostname <> "."
  , "--type=A"
  , "--ttl=300"
  , "--rrdatas=" <> ip
  , "--zone=" <> zone
  , "--project=" <> project
  ]

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
    renderAction (DnsReference host ip) =
      "DNS: " <> host <> " -> " <> ip <> " (Pulumi-owned reference; no write)"
    renderAction (CacheRule prefix ttl) = "Cache: " <> prefix <> " -> " <> ttl
    renderAction (OriginTls mode) = "Origin TLS: " <> mode

-- ---------------------------------------------------------------------------
-- IO provisioning (dispatch on provider)

-- | Provision the chosen CDN for a live origin. Cloudflare goes through EP-57's
-- API module; Google runs only the planned Cloud DNS commands. Total: any
-- credential/zone/API/@gcloud@ failure is a 'Left'. Called AFTER the origin is
-- Ready, so a 'Left' never takes the origin down — the caller reports it and
-- keeps the origin URL.
provisionCdn :: Cdn -> CdnTarget -> GcpStackRefs -> IO (Either Text CdnResult)
provisionCdn cdn target refs =
  case cdn ^. #provider of
    CloudflareCdn -> provisionCloudflare cdn target
    GcpCloudCdn -> case planCdn cdn target refs of
      Left err -> pure (Left err)
      Right plan -> provisionGcp refs plan target

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

provisionGcp :: GcpStackRefs -> CdnPlan -> CdnTarget -> IO (Either Text CdnResult)
provisionGcp refs plan target = do
  referenced <- runSteps
    [verifyGcpDnsReference refs hostname ip
    | DnsReference hostname ip <- plan ^. #actions]
  case referenced of
    Left err -> pure (Left err)
    Right () -> go (plan ^. #actions)
  where
    hosts = target ^. #hostnames
    done =
      Right
        ( CdnResult
            ["https://" <> h | h <- hosts]
            ("Google Cloud CDN: " <> tshow (length hosts) <> " hostname(s) routed to the load balancer")
        )
    go [] = pure done
    go (DnsUpsert hostname ip _ : rest) = do
      result <- upsertGcpDns refs hostname ip
      case result of
        Left err -> pure (Left err)
        Right () -> go rest
    go (DnsReference _ _ : rest) = go rest
    go (_ : rest) = go rest

-- | The platform owns the apex record. Confirm its accepted target before
-- touching any application-owned host record, without assuming its TTL.
verifyGcpDnsReference :: GcpStackRefs -> Text -> Text -> IO (Either Text ())
verifyGcpDnsReference refs hostname ip = do
  described <- runGcloud (gcloudDnsDescribeArgs (refs ^. #project) (refs ^. #dnsZone) hostname)
  pure $ case described of
    Left diagnostic -> Left (hostname <> ": platform-owned Cloud DNS record cannot be read: " <> diagnostic)
    Right out -> case parseRecordSet out of
      Left err -> Left (hostname <> ": platform-owned Cloud DNS record is invalid: " <> err)
      Right ([current], _) | current == ip -> Right ()
      Right _ -> Left (hostname <> ": platform-owned Cloud DNS record does not point to the selected CDN IP")

upsertGcpDns :: GcpStackRefs -> Text -> Text -> IO (Either Text ())
upsertGcpDns refs hostname ip = do
  described <- runGcloud (gcloudDnsDescribeArgs project zone hostname)
  case described of
    Right out -> case parseRecordSet out of
      Right ([current], 300) | current == ip -> pure (Right ())
      Right _ -> mutate (gcloudDnsUpdateArgs project zone hostname ip)
      Left err -> pure (Left (hostname <> ": cannot inspect the existing Cloud DNS A record: " <> err))
    Left diagnostic
      | isNotFound diagnostic -> mutate (gcloudDnsCreateArgs project zone hostname ip)
      | otherwise -> pure (Left (hostname <> ": Cloud DNS describe failed: " <> diagnostic))
  where
    project = refs ^. #project
    zone = refs ^. #dnsZone
    mutate args = do
      result <- runGcloud args
      pure $ case result of
        Right _ -> Right ()
        Left diagnostic -> Left ("gcloud failed: gcloud " <> T.unwords args <> ": " <> diagnostic)
    isNotFound diagnostic =
      let lower = T.toLower diagnostic
       in any (`T.isInfixOf` lower) ["not found", "not_found", "does not exist", "404"]

runGcloud :: [Text] -> IO (Either Text BC.ByteString)
runGcloud args = do
  result <- try (readProcessWithExitCode "gcloud" (map T.unpack args) "")
  pure $ case result of
    Left (err :: IOException) -> Left (T.pack (show err))
    Right (ExitSuccess, out, _) -> Right (TE.encodeUtf8 (T.pack out))
    Right (ExitFailure code, out, err) ->
      Left
        ( "exit "
            <> tshow code
            <> ": "
            <> T.strip (T.pack (if null err then out else err))
        )

parseRecordSet :: BC.ByteString -> Either Text ([Text], Int)
parseRecordSet bytes =
  case eitherDecodeStrict bytes of
    Left err -> Left (T.pack err)
    Right (Object object) -> do
      rrdatas <- field "rrdatas" object
      ttl <- field "ttl" object
      Right (rrdatas, ttl)
    Right _ -> Left "response is not an object"
  where
    field key object = case KeyMap.lookup (Key.fromText key) object of
      Nothing -> Left ("response has no " <> key)
      Just value -> case Aeson.fromJSON value of
        Aeson.Error err -> Left (key <> " is invalid: " <> T.pack err)
        Aeson.Success result -> Right result

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
