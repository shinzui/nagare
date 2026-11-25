{-# LANGUAGE BlockArguments #-}

-- | What a context move observes (EP-243): Cloudflare's view of the zone, DNSSEC and records, the
-- parent's delegation and public resolvers through @dig@, cert-manager's renewal times, and HTTP
-- probes of the VM and the edge. Every read here is a read; 'Nagare.Context.MoveChecks' decides.
module Nagare.Cli.Move.Observe
  ( MoveEnv (..)
  , ApexRecord (..)
  , observeZone
  , observeDnssec
  , observeApexRecord
  , observeParentDs
  , observeParentDelegation
  , observeParentDelegates
  , observeResolverNameServers
  , observeCloudDnsNameServers
  , describeZoneNameServers
  , observeRenewals
  , observeConnectors
  , probeDirect
  , probeEdge
  , probeEdgeHosts
  , moveProbeHost
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Traversable (for)
import Nagare.Cdn.Cloudflare (cfRequestWithStatus)
import Nagare.Context.MoveChecks
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.CloudflareZone (cloudflareTunnelName)
import Nagare.Ops.CloudflareTunnel (connectorProblems, expectedConnectors, parseConnectors, parseTunnelId)
import Nagare.Ops.Probe (captureTool)
import System.Environment (lookupEnv)

-- | What every observation needs: the context's name and base domain, its project, the VM's public
-- address, and the Cloud DNS zone's name from the stack.
data MoveEnv = MoveEnv
  { contextText :: !Text
  , base :: !Text
  , project :: !Text
  , publicIp :: !Text
  , dnsZoneName :: !(Maybe Text)
  }
  deriving stock (Generic)

-- | The zone's apex record as Cloudflare holds it.
data ApexRecord = ApexRecord
  { toVm :: !Bool
  , modifiedOn :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

-- | Cloudflare's zone for @CF_ZONE_ID@, or 'Nothing' when the credentials name none.
observeZone :: IO (Either Text (Maybe ZoneStatus))
observeZone =
  lookupText "CF_ZONE_ID" >>= \case
    Nothing -> pure (Right Nothing)
    Just zone ->
      cloudflare ("/zones/" <> zone) <&> fmap \result ->
        Just
          ZoneStatus
            { zoneName = fromMaybe "" (field "name" result)
            , zoneState = fromMaybe "unknown" (field "status" result)
            , assignedNameServers = texts "name_servers" result
            , activatedOn = time =<< field "activated_on" result
            }

observeDnssec :: IO (Either Text DnssecStatus)
observeDnssec = withZone $ \zone ->
  cloudflare ("/zones/" <> zone <> "/dnssec") <&> fmap \result ->
    DnssecStatus (fromMaybe "unknown" (field "status" result)) (field "ds" result)

-- | The apex record: a DNS-only A record points at the VM; a proxied CNAME at the tunnel.
observeApexRecord :: Text -> IO (Either Text ApexRecord)
observeApexRecord name = withZone $ \zone ->
  cloudflare ("/zones/" <> zone <> "/dns_records?name.exact=" <> name) <&> \case
    Left reason -> Left reason
    -- The apex also holds the operator's own records (MX, TXT); only the A or CNAME is the move's.
    Right (Array records) -> case filter ((`elem` [Just "A", Just "CNAME"]) . field "type") (toList records) of
      [record] ->
        Right
          ApexRecord
            { toVm = field "type" record == Just "A" && boolField "proxied" record == Just False
            , modifiedOn = time =<< field "modified_on" record
            }
      found -> Left ("Cloudflare holds " <> T.pack (show (length found)) <> " A or CNAME records for " <> name <> ", not one")
    Right _ -> Left "Cloudflare's record listing has no result array"

-- | Whether the parent publishes a DS record for the domain.
observeParentDs :: Text -> IO (Either Text Bool)
observeParentDs name = fmap (any ((== "DS") . (^. #recordType))) <$> digRecords ["+noall", "+answer", "DS", T.unpack name]

-- | The name servers the parent delegates to, and the delegation's TTL, asked of a parent server.
observeParentDelegation :: Text -> IO (Either Text ([Text], Int))
observeParentDelegation name = do
  let parent = T.drop 1 (T.dropWhile (/= '.') name)
  servers <- digRecords ["+noall", "+answer", "NS", T.unpack parent]
  case [r ^. #value | r <- either (const []) id servers, r ^. #recordType == "NS"] of
    [] -> pure (Left ("no name server answers for the parent zone " <> parent))
    server : _ -> do
      delegation <- digRecords ["+norecurse", "+noall", "+authority", "NS", T.unpack name, "@" <> T.unpack server]
      pure $
        delegation >>= \records -> case [r | r <- records, r ^. #recordType == "NS"] of
          [] -> Left ("the parent server " <> server <> " delegates no name servers for " <> name)
          found -> Right (map (^. #value) found, minimum (map (^. #ttl) found))

-- | EP-246 D7: whether the parent zone still delegates @name@ to any name server, asked of the parent's
-- own server so no cache answers.
observeParentDelegates :: Text -> IO (Either Text Bool)
observeParentDelegates name = do
  let parent = T.drop 1 (T.dropWhile (/= '.') name)
  servers <- digRecords ["+noall", "+answer", "NS", T.unpack parent]
  case [r ^. #value | r <- either (const []) id servers, r ^. #recordType == "NS"] of
    [] -> pure (Left ("no name server answers for the parent zone " <> parent))
    server : _ -> do
      delegation <- digRecords ["+norecurse", "+noall", "+authority", "NS", T.unpack name, "@" <> T.unpack server]
      pure (any (\r -> r ^. #recordType == "NS") <$> delegation)

-- | What three public resolvers answer for the domain's name servers.
observeResolverNameServers :: Text -> IO [[Text]]
observeResolverNameServers name =
  for ["1.1.1.1", "8.8.8.8", "9.9.9.9"] $ \resolver ->
    either (const []) (\records -> [r ^. #value | r <- records, r ^. #recordType == "NS"])
      <$> digRecords ["+noall", "+answer", "NS", T.unpack name, "@" <> resolver]

-- | The Cloud DNS zone's own name servers, read from the context's project only.
observeCloudDnsNameServers :: MoveEnv -> IO (Either Text [Text])
observeCloudDnsNameServers env = case env ^. #dnsZoneName of
  Nothing -> pure (Left "the stack has no dnsZoneName output; the Cloud DNS zone is not retained")
  Just zone -> describeZoneNameServers (env ^. #project) zone

-- | One Cloud DNS zone's name servers, read with an explicit @--project@ so the read stays in the context's
-- project.
describeZoneNameServers :: Text -> Text -> IO (Either Text [Text])
describeZoneNameServers project zone =
  captureTool
    "gcloud"
    ["dns", "managed-zones", "describe", T.unpack zone, "--project=" <> T.unpack project, "--format=value(nameServers)"]
    <&> \case
      Nothing -> Left ("gcloud could not describe the Cloud DNS zone " <> zone)
      Just bytes -> case T.split (\c -> c == ';' || c == ',' || c == '\n') (TE.decodeUtf8 bytes) of
        names | servers@(_ : _) <- filter (not . T.null) (map T.strip names) -> Right servers
        _ -> Left ("the Cloud DNS zone " <> zone <> " lists no name servers")

-- | Every cert-manager Certificate's renewal time, through the context's admitted cluster.
observeRenewals :: IO (Either Text [(Text, Maybe UTCTime)])
observeRenewals =
  captureTool "kubectl" ["get", "certificates.cert-manager.io", "-A", "-o", "json", "--request-timeout=10s"] <&> \case
    Nothing -> Left "kubectl could not list cert-manager Certificates"
    Just bytes -> do
      value <- first T.pack (eitherDecodeStrict bytes)
      case value of
        Object top | Just (Array items) <- KM.lookup "items" top -> Right (map certificate (toList items))
        _ -> Left "the Certificate listing has no items"
  where
    certificate item =
      ( fromMaybe "?" (nested ["metadata", "namespace"] item) <> "/" <> fromMaybe "?" (nested ["metadata", "name"] item)
      , time =<< nested ["status", "renewalTime"] item
      )

-- | Problems with the context's tunnel connectors, empty when exactly its own are connected.
observeConnectors :: MoveEnv -> IO (Either Text [Text])
observeConnectors env =
  lookupText "CF_ACCOUNT_ID" >>= \case
    Nothing -> pure (Left "CF_ACCOUNT_ID is not set")
    Just account -> do
      let name = cloudflareTunnelName (env ^. #contextText)
      listed <- request ("/accounts/" <> account <> "/cfd_tunnel?is_deleted=false&name=" <> name)
      case listed >>= uncurry (parseTunnelId name) of
        Left reason -> pure (Left reason)
        Right tunnelId -> do
          connections <- request ("/accounts/" <> account <> "/cfd_tunnel/" <> tunnelId <> "/connections")
          pure (connectorProblems expectedConnectors (env ^. #publicIp) <$> (connections >>= uncurry parseConnectors))

-- | The host a move samples: under the wildcard, so it exists in every posture and needs no app.
moveProbeHost :: Text -> Text
moveProbeHost name = "nagare-move-check." <> name

-- | Whether the VM answers HTTP for the host on its own address, and whether public DNS sends the
-- host there.
probeDirect :: MoveEnv -> Bool -> IO Bool
probeDirect env throughDns = do
  let host = moveProbeHost (env ^. #base)
  answered <- httpAnswer ["--resolve", T.unpack host <> ":80:" <> T.unpack (env ^. #publicIp), "http://" <> T.unpack host <> "/"]
  resolved <-
    if throughDns
      then either (const False) (any (\r -> r ^. #recordType == "A" && r ^. #value == env ^. #publicIp)) <$> digRecords ["+noall", "+answer", "A", T.unpack host, "@1.1.1.1"]
      else pure True
  pure (resolved && maybe False (not . snd) answered)

-- | Each sampled host answers through Cloudflare's edge (a @cf-ray@ header, no 52x or 530), asked at
-- the edge address 1.1.1.1 resolves, so no cache on this machine decides. 'Nothing' when public DNS
-- still answers with the VM's address.
probeEdge :: MoveEnv -> IO [(Text, Maybe Bool)]
probeEdge env = probeEdgeHosts env [env ^. #base, moveProbeHost (env ^. #base)]

-- | The same for the given hosts (EP-246: every new name).
probeEdgeHosts :: MoveEnv -> [Text] -> IO [(Text, Maybe Bool)]
probeEdgeHosts env hosts =
  for hosts $ \host -> do
    addresses <- either (const []) (\records -> [r ^. #value | r <- records, r ^. #recordType == "A"]) <$> digRecords ["+noall", "+answer", "A", T.unpack host, "@1.1.1.1"]
    case addresses of
      _ | env ^. #publicIp `elem` addresses -> pure (host, Nothing)
      edge : _ -> do
        answered <- httpAnswer ["--resolve", T.unpack host <> ":443:" <> T.unpack edge, "https://" <> T.unpack host <> "/"]
        pure (host, Just (maybe False (\(code, viaEdge) -> viaEdge && not (code >= 520 && code <= 530)) answered))
      [] -> pure (host, Just False)

-- | The status code and whether Cloudflare's edge answered, or 'Nothing' when nothing answered.
httpAnswer :: [String] -> IO (Maybe (Int, Bool))
httpAnswer arguments =
  captureTool "curl" (["-sS", "-o", "/dev/null", "--max-time", "15", "-w", "%{http_code} %header{cf-ray}"] <> arguments) <&> \case
    Nothing -> Nothing
    Just bytes -> case T.words (TE.decodeUtf8 bytes) of
      code : rest | T.all (`elem` ['0' .. '9']) code, code /= "000" -> Just (read (T.unpack code), not (null rest))
      _ -> Nothing

digRecords :: [String] -> IO (Either Text [DigRecord])
digRecords arguments =
  maybe (Left "dig could not answer; is it on PATH?") (Right . parseDigRecords . TE.decodeUtf8)
    <$> captureTool "dig" (["+time=5", "+tries=2"] <> arguments)

withZone :: (Text -> IO (Either Text a)) -> IO (Either Text a)
withZone action = lookupText "CF_ZONE_ID" >>= maybe (pure (Left "CF_ZONE_ID is not set")) action

cloudflare :: Text -> IO (Either Text Value)
cloudflare path = (>>= uncurry envelope) <$> request path

request :: Text -> IO (Either Text (Int, ByteString))
request path =
  lookupText "CF_API_TOKEN" >>= \case
    Nothing -> pure (Left "CF_API_TOKEN is not set")
    Just token -> cfRequestWithStatus token "GET" path Nothing

envelope :: Int -> ByteString -> Either Text Value
envelope status bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object top
      | status >= 200 && status < 300
      , Just (Bool True) <- KM.lookup "success" top
      , Just result <- KM.lookup "result" top ->
          Right result
    _ -> Left ("Cloudflare answered HTTP " <> T.pack (show status))

lookupText :: String -> IO (Maybe Text)
lookupText name = (\case Just v | not (null v) -> Just (T.pack v); _ -> Nothing) <$> lookupEnv name

field :: Text -> Value -> Maybe Text
field name = \case
  Object fields | Just (String v) <- KM.lookup (Key.fromText name) fields -> Just v
  _ -> Nothing

boolField :: Text -> Value -> Maybe Bool
boolField name = \case
  Object fields | Just (Bool v) <- KM.lookup (Key.fromText name) fields -> Just v
  _ -> Nothing

texts :: Text -> Value -> [Text]
texts name = \case
  Object fields | Just (Array values) <- KM.lookup (Key.fromText name) fields -> [v | String v <- toList values]
  _ -> []

nested :: [Text] -> Value -> Maybe Text
nested path value = case path of
  [] -> Nothing
  [name] -> field name value
  name : rest -> case value of
    Object fields -> nested rest =<< KM.lookup (Key.fromText name) fields
    _ -> Nothing

time :: Text -> Maybe UTCTime
time = iso8601ParseM . T.unpack
