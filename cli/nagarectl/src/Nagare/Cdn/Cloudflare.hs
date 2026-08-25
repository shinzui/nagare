{-# LANGUAGE ScopedTypeVariables #-}

-- | The Cloudflare provider capability (MasterPlan 11, EP-57): the one module in
-- @nagarectl@ that talks to Cloudflare's REST API v4 to put a Cloudflare edge in
-- front of the VM. It can create-or-update a proxied DNS record, apply per-path
-- cache rules from a typed 'Cdn', set the origin-TLS ("SSL") mode, and purge the
-- edge cache.
--
-- Design (mirrors 'Nagare.Ops.Domains'): every URL/JSON shape is built by a
-- /pure/ function that is unit-tested with no network; the thin IO layer
-- (@cfRequest@ + the five exported actions) performs the HTTP and feeds the
-- bytes to pure parsers. Every exported IO function returns @Either Text@ and
-- never throws for an expected failure (auth rejected, zone not found,
-- Cloudflare @success:false@) — EP-58 turns a 'Left' into a clean user message
-- and a non-zero exit. This module is the only outbound-HTTP surface in the CLI;
-- the @CF_API_TOKEN@ scoped token is read from the environment and never logged.
module Nagare.Cdn.Cloudflare
  ( -- * Credentials and origin-TLS model
    CloudflareCreds (..)
  , OriginTlsMode (..)
  , loadCloudflareCreds

    -- * Provisioning (IO; total via Either)
  , upsertProxiedRecord
  , applyCacheRules
  , setOriginTlsMode
  , purgeHostname

    -- * Pure request-builders (unit-tested; no network)
  , buildUpsertRecordPayload
  , buildCacheRulesPayload
  , buildPurgePayload
  , sslModeToken
  , zoneNameFromHostname
  , parseEnvelopeUnit
  , parseDnsRecordId
  , parseZoneId
  )
where

import Control.Exception (catch)
import Data.Aeson (Value (..), decodeStrict, eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Cdn.Types (Cdn (..), CdnCacheRule (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import System.Environment (lookupEnv)

-- ---------------------------------------------------------------------------
-- Types

-- | Cloudflare API credentials. @cfApiToken@ is a scoped API token read from
-- @CF_API_TOKEN@; never logged. @cfZoneId@ is the optional @CF_ZONE_ID@; when
-- 'Nothing', the zone is discovered from the hostname via 'zoneNameFromHostname'
-- and a @GET /zones?name=<root>@ call.
data CloudflareCreds = CloudflareCreds
  { cfApiToken :: !Text
  , cfZoneId :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | How Cloudflare's edge connects back to the origin VM. 'Flexible' = edge to
-- origin over plain HTTP (works against today's HTTP-first Kourier origin);
-- 'Full' = HTTPS without verifying the origin cert; 'FullStrict' = HTTPS with
-- the origin cert verified. Default is 'Flexible' per EP-54 until the origin
-- serves the Let's Encrypt wildcard on port 443.
data OriginTlsMode = Flexible | Full | FullStrict
  deriving stock (Generic, Eq, Show)

-- ---------------------------------------------------------------------------
-- Pure request-builders (unit-tested; no network)

-- | The registrable domain (last two dot-labels) of a hostname. This is a
-- deliberately simple heuristic: it is correct for ordinary @sub.example.com@
-- inputs and the operator can always set @CF_ZONE_ID@ to bypass discovery for
-- multi-label public suffixes (e.g. @example.co.uk@).
zoneNameFromHostname :: Text -> Text
zoneNameFromHostname host =
  let labels = T.splitOn "." (T.toLower (T.dropWhileEnd (== '.') host))
   in T.intercalate "." (lastN 2 labels)
  where
    lastN n xs = drop (length xs - n) xs

-- | The Cloudflare @ssl@ setting token for an 'OriginTlsMode'.
sslModeToken :: OriginTlsMode -> Text
sslModeToken Flexible = "flexible"
sslModeToken Full = "full"
sslModeToken FullStrict = "strict"

-- | The request body to create or update a proxied A record pointing @hostname@
-- at @originIp@. @proxied: true@ is what routes the hostname through Cloudflare's
-- edge; @ttl: 1@ ("automatic") is mandatory for proxied records.
buildUpsertRecordPayload :: Text -> Text -> Value
buildUpsertRecordPayload hostname originIp =
  object
    [ "type" .= ("A" :: Text)
    , "name" .= hostname
    , "content" .= originIp
    , "proxied" .= True
    , "ttl" .= (1 :: Int)
    ]

-- | Translate a typed 'Cdn' into the Cloudflare cache-settings ruleset body.
-- Rule precedence is by array order: explicit path rules first, then the
-- static-asset long-cache rule (when @cacheStaticAssets@), then a catch-all
-- default-TTL rule last. @edgeTtlSeconds = Nothing@ becomes a "bypass cache"
-- rule (@cache: false@); a present TTL becomes @cache: true@ with an
-- @override_origin@ edge TTL.
buildCacheRulesPayload :: Text -> Cdn -> Value
buildCacheRulesPayload hostname cdn =
  object
    [ "rules"
        .= ( map (pathRule hostname) (cacheRules cdn)
               ++ staticAssetRules hostname (cacheStaticAssets cdn)
               ++ defaultRules hostname (defaultTtlSeconds cdn)
           )
    ]

-- | A per-path rule. @Just ttl@ caches for @ttl@ seconds; @Nothing@ bypasses.
pathRule :: Text -> CdnCacheRule -> Value
pathRule hostname (CdnCacheRule prefix mttl) =
  cacheRule
    ( hostExpr hostname
        <> " and starts_with(http.request.uri.path, "
        <> quoteExpr prefix
        <> ")"
    )
    mttl

-- | The fingerprinted-static-asset long-cache rule (one year) when enabled.
staticAssetRules :: Text -> Bool -> [Value]
staticAssetRules _ False = []
staticAssetRules hostname True =
  [ cacheRule
      ( hostExpr hostname
          <> " and (http.request.uri.path.extension in {\"js\" \"css\" \"woff2\""
          <> " \"woff\" \"png\" \"jpg\" \"jpeg\" \"gif\" \"svg\" \"webp\" \"ico\"})"
      )
      (Just 31536000)
  ]

-- | The catch-all default-TTL rule, last so specific rules win. Omitted when no
-- default TTL is configured (Cloudflare's own default caching then applies).
defaultRules :: Text -> Maybe Int -> [Value]
defaultRules _ Nothing = []
defaultRules hostname (Just ttl) = [cacheRule (hostExpr hostname) (Just ttl)]

-- | One ruleset rule from an expression and an optional edge TTL.
cacheRule :: Text -> Maybe Int -> Value
cacheRule expr mttl =
  object
    [ "expression" .= expr
    , "action" .= ("set_cache_settings" :: Text)
    , "action_parameters" .= actionParams mttl
    ]

actionParams :: Maybe Int -> Value
actionParams Nothing = object ["cache" .= False]
actionParams (Just ttl) =
  object
    [ "cache" .= True
    , "edge_ttl"
        .= object
          [ "mode" .= ("override_origin" :: Text)
          , "default" .= ttl
          ]
    ]

hostExpr :: Text -> Text
hostExpr hostname = "(http.host eq " <> quoteExpr hostname <> ")"

-- | A double-quoted literal for a Cloudflare filter expression.
quoteExpr :: Text -> Text
quoteExpr t = "\"" <> t <> "\""

-- | The purge request body. @[]@ purges the whole zone
-- (@{ "purge_everything": true }@); a non-empty path list purges those exact
-- URLs under @hostname@ over HTTPS.
buildPurgePayload :: Text -> [Text] -> Value
buildPurgePayload _ [] = object ["purge_everything" .= True]
buildPurgePayload hostname paths =
  object ["files" .= map (\p -> "https://" <> hostname <> p) paths]

-- ---------------------------------------------------------------------------
-- Envelope parsers (pure)

-- | Decode a Cloudflare envelope into @Right ()@ on @success:true@ or
-- @Left <messages>@ on @success:false@ (or undecodable bytes).
parseEnvelopeUnit :: ByteString -> Either Text ()
parseEnvelopeUnit bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode Cloudflare response: " <> T.pack e)
    Right v
      | envelopeOk v -> Right ()
      | otherwise -> Left (envelopeErrors v)

envelopeOk :: Value -> Bool
envelopeOk v = lookupBool ["success"] v == Just True

-- | Join the @errors[].message@ strings into one human line.
envelopeErrors :: Value -> Text
envelopeErrors v =
  case lookupPath ["errors"] v of
    Just (Array errs)
      | not (V.null errs) ->
          T.intercalate
            "; "
            [fromMaybe "unknown error" (textAt ["message"] e) | e <- V.toList errs]
    _ -> "Cloudflare reported failure with no error detail"

-- | A record id from a Cloudflare response. Handles both a single-object
-- @result.id@ (the create/update response) and a list @result[0].id@ (the
-- @GET /dns_records?name=...@ find response), so the find-or-create path in
-- 'upsertProxiedRecord' actually detects an existing record.
parseDnsRecordId :: ByteString -> Maybe Text
parseDnsRecordId bs = do
  v <- decodeStrict bs
  case lookupPath ["result"] v of
    Just (Array rs) -> rs V.!? 0 >>= textAt ["id"]
    _ -> textAt ["result", "id"] v

-- | The first matching zone id from a @GET /zones?name=...@ list response
-- (@result[0].id@).
parseZoneId :: ByteString -> Maybe Text
parseZoneId bs = do
  v <- decodeStrict bs
  Array results <- lookupPath ["result"] v
  first <- results V.!? 0
  textAt ["id"] first

-- ---------------------------------------------------------------------------
-- Three-line JSON walkers (local copies, mirroring Nagare.Ops.Domains)

lookupPath :: [Text] -> Value -> Maybe Value
lookupPath [] v = Just v
lookupPath (k : ks) (Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (String s) -> Just s
  _ -> Nothing

lookupBool :: [Text] -> Value -> Maybe Bool
lookupBool path v = case lookupPath path v of
  Just (Bool b) -> Just b
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- IO layer

cfBaseUrl :: Text
cfBaseUrl = "https://api.cloudflare.com/client/v4"

-- | Read @CF_API_TOKEN@ (required) and @CF_ZONE_ID@ (optional) from the
-- environment. Returns a 'Left' when the token is unset or empty; never echoes
-- the token.
loadCloudflareCreds :: IO (Either Text CloudflareCreds)
loadCloudflareCreds = do
  mtok <- lookupEnv "CF_API_TOKEN"
  mzone <- lookupEnv "CF_ZONE_ID"
  pure $ case mtok of
    Just t | not (null t) -> Right (CloudflareCreds (T.pack t) (T.pack <$> mzone))
    _ -> Left "CF_API_TOKEN is not set; export a scoped Cloudflare API token"

-- | Perform one Cloudflare call. @method@ is "GET"/"POST"/"PATCH"/"PUT"; @path@
-- is appended to 'cfBaseUrl'; @mbody@ is an optional JSON body. Returns the raw
-- response bytes (any HTTP status) so the caller's pure parser decides success
-- from the envelope. Catches a connection-level 'HttpException' into a 'Left' so
-- the function is total. The bearer token is set on the request and never logged.
cfRequest :: Text -> Text -> Text -> Maybe Value -> IO (Either Text ByteString)
cfRequest token method path mbody =
  ( do
      manager <- newTlsManager
      initReq <- parseRequest (T.unpack (method <> " " <> cfBaseUrl <> path))
      let req =
            initReq
              { requestHeaders =
                  [ ("Authorization", TE.encodeUtf8 ("Bearer " <> token))
                  , ("Content-Type", "application/json")
                  ]
              , requestBody = maybe (RequestBodyLBS "") (RequestBodyLBS . encode) mbody
              }
      resp <- httpLbs req manager
      pure (Right (LBS.toStrict (responseBody resp)))
  )
    `catch` \(e :: HttpException) ->
      pure (Left ("Cloudflare request failed: " <> T.pack (show e)))

-- | Resolve the zone id: use @cfZoneId@ if present, else discover it from the
-- hostname's registrable domain via @GET /zones?name=<root>@.
resolveZoneId :: CloudflareCreds -> Text -> IO (Either Text Text)
resolveZoneId creds host =
  case cfZoneId creds of
    Just z -> pure (Right z)
    Nothing -> do
      let root = zoneNameFromHostname host
      r <- cfRequest (cfApiToken creds) "GET" ("/zones?name=" <> root) Nothing
      pure $ case r of
        Left e -> Left e
        Right bs -> case parseZoneId bs of
          Just z -> Right z
          Nothing ->
            Left ("could not resolve Cloudflare zone for " <> host <> " (set CF_ZONE_ID)")

-- | Run an action with the resolved zone id, short-circuiting on a resolution
-- failure.
withZone :: CloudflareCreds -> Text -> (Text -> IO (Either Text a)) -> IO (Either Text a)
withZone creds host k = do
  ez <- resolveZoneId creds host
  case ez of
    Left e -> pure (Left e)
    Right zone -> k zone

-- | Perform one call and interpret its envelope as @Right ()@ / @Left message@.
sendUnit :: Text -> Text -> Text -> Maybe Value -> IO (Either Text ())
sendUnit token method path body = do
  r <- cfRequest token method path body
  pure (r >>= parseEnvelopeUnit)

-- | Create or update the proxied A record @hostname -> originIp@. Find-or-create:
-- list the record by name, then PATCH the existing one or POST a new one, so a
-- repeated deploy leaves exactly one record.
upsertProxiedRecord :: CloudflareCreds -> Text -> Text -> IO (Either Text ())
upsertProxiedRecord creds host originIp = withZone creds host $ \zone -> do
  let tok = cfApiToken creds
      body = buildUpsertRecordPayload host originIp
  listR <-
    cfRequest tok "GET" ("/zones/" <> zone <> "/dns_records?type=A&name=" <> host) Nothing
  case listR of
    Left e -> pure (Left e)
    Right bs -> case parseDnsRecordId bs of
      Just rid -> sendUnit tok "PATCH" ("/zones/" <> zone <> "/dns_records/" <> rid) (Just body)
      Nothing -> sendUnit tok "POST" ("/zones/" <> zone <> "/dns_records") (Just body)

-- | Apply the typed cache rules by replacing the @http_request_cache_settings@
-- phase entrypoint wholesale, so the live rules are always a function of the
-- 'Cdn' value with no stale-rule accumulation.
applyCacheRules :: CloudflareCreds -> Text -> Cdn -> IO (Either Text ())
applyCacheRules creds host cdn = withZone creds host $ \zone ->
  sendUnit
    (cfApiToken creds)
    "PUT"
    ("/zones/" <> zone <> "/rulesets/phases/http_request_cache_settings/entrypoint")
    (Just (buildCacheRulesPayload host cdn))

-- | Set the zone's origin-TLS ("SSL") mode.
setOriginTlsMode :: CloudflareCreds -> Text -> OriginTlsMode -> IO (Either Text ())
setOriginTlsMode creds host mode = withZone creds host $ \zone ->
  sendUnit
    (cfApiToken creds)
    "PATCH"
    ("/zones/" <> zone <> "/settings/ssl")
    (Just (object ["value" .= sslModeToken mode]))

-- | Purge the edge cache for @hostname@. @[]@ purges everything; a non-empty
-- path list purges those exact URLs.
purgeHostname :: CloudflareCreds -> Text -> [Text] -> IO (Either Text ())
purgeHostname creds host paths = withZone creds host $ \zone ->
  sendUnit
    (cfApiToken creds)
    "POST"
    ("/zones/" <> zone <> "/purge_cache")
    (Just (buildPurgePayload host paths))
