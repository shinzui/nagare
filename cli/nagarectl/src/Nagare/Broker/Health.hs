-- | Provider-neutral health checks for managed brokers.
module Nagare.Broker.Health
  ( HealthStatus (..)
  , HealthCheck (..)
  , BrokerHealth (..)
  , brokerHealth
  , formatBrokerHealth
  , parsePodReady
  , parseVictoriaUp
  )
where

import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Char (ord)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Vector qualified as V
import Nagare.Broker.Discover (BrokerRow (..))
import Nagare.Dsl.Prelude
import Nagare.Ops.Probe (captureTool)
import Numeric (showHex)
import "generic-lens" Data.Generics.Labels ()

data HealthStatus = HealthOk | HealthWarn | HealthUnknown | HealthFail
  deriving stock (Generic, Eq, Show)

data HealthCheck = HealthCheck
  { name :: !Text
  , status :: !HealthStatus
  , detail :: !Text
  }
  deriving stock (Generic, Eq, Show)

data BrokerHealth = BrokerHealth
  { checks :: ![HealthCheck]
  }
  deriving stock (Generic, Eq, Show)

brokerHealth :: Text -> BrokerRow -> IO BrokerHealth
brokerHealth ns row = do
  pod <- readinessCheck ns row
  endpoint <- metricsEndpointCheck ns row
  scrape <- scrapeCheck row
  pure BrokerHealth {checks = [pod, endpoint, scrape]}

formatBrokerHealth :: BrokerHealth -> Text
formatBrokerHealth health =
  T.unlines ("Health:" : map (("  " <>) . formatCheck) (health ^. #checks))
  where
    formatCheck c =
      pad 8 (statusText (c ^. #status))
        <> pad 18 (c ^. #name)
        <> c
          ^. #detail
    statusText = \case
      HealthOk -> "OK"
      HealthWarn -> "WARN"
      HealthUnknown -> "UNKNOWN"
      HealthFail -> "FAIL"
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

readinessCheck :: Text -> BrokerRow -> IO HealthCheck
readinessCheck ns row = do
  m <-
    captureTool
      "kubectl"
      [ "get"
      , "pod"
      , T.unpack (row ^. #name <> "-0")
      , "-n"
      , T.unpack ns
      , "-o"
      , "json"
      ]
  pure $ case m >>= parsePodReady of
    Just True -> HealthCheck "readiness" HealthOk ("pod/" <> row ^. #name <> "-0 Ready")
    Just False -> HealthCheck "readiness" HealthFail ("pod/" <> row ^. #name <> "-0 not Ready")
    Nothing -> HealthCheck "readiness" HealthUnknown "pod readiness unavailable"

metricsEndpointCheck :: Text -> BrokerRow -> IO HealthCheck
metricsEndpointCheck ns row = do
  m <-
    captureTool
      "kubectl"
      [ "get"
      , "--raw"
      , T.unpack (brokerMetricsProxyPath ns (row ^. #name))
      ]
  pure $ case m of
    Just out
      | "redpanda_" `T.isInfixOf` decodeUtf8 out ->
          HealthCheck "metrics endpoint" HealthOk "/public_metrics reachable"
      | otherwise -> HealthCheck "metrics endpoint" HealthWarn "/public_metrics returned no Redpanda public metrics"
    Nothing -> HealthCheck "metrics endpoint" HealthUnknown "/public_metrics unavailable through service proxy"

scrapeCheck :: BrokerRow -> IO HealthCheck
scrapeCheck row = do
  m <-
    captureTool
      "kubectl"
      [ "get"
      , "--raw"
      , T.unpack (victoriaQueryPath (row ^. #name))
      ]
  pure $ case m of
    Just out -> case parseVictoriaUp (row ^. #name) out of
      Right True -> HealthCheck "metrics scrape" HealthOk "VictoriaMetrics has up=1 for this broker"
      Right False -> HealthCheck "metrics scrape" HealthWarn "VictoriaMetrics has no up=1 sample for this broker"
      Left err -> HealthCheck "metrics scrape" HealthUnknown err
    Nothing -> HealthCheck "metrics scrape" HealthUnknown "VictoriaMetrics query unavailable"

brokerMetricsProxyPath :: Text -> Text -> Text
brokerMetricsProxyPath ns brokerName =
  "/api/v1/namespaces/"
    <> ns
    <> "/services/"
    <> brokerName
    <> ":9644/proxy/public_metrics"

victoriaQueryPath :: Text -> Text
victoriaQueryPath brokerName =
  "/api/v1/namespaces/monitoring/services/vmsingle-vmks-victoria-metrics-k8s-stack:8429/proxy/api/v1/query?query="
    <> percentEncode ("up{job=\"nagare-brokers\",nagare_broker=\"" <> brokerName <> "\"}")

parsePodReady :: ByteString -> Maybe Bool
parsePodReady bs = do
  Aeson.Object root <- Aeson.decodeStrict bs
  Aeson.Object status <- KeyMap.lookup "status" root
  Aeson.Array conditions <- KeyMap.lookup "conditions" status
  condition <- findReadyCondition (V.toList conditions)
  Aeson.String state <- KeyMap.lookup "status" condition
  pure (state == "True")
  where
    findReadyCondition [] = Nothing
    findReadyCondition (Aeson.Object o : rest) =
      case KeyMap.lookup "type" o of
        Just (Aeson.String "Ready") -> Just o
        _ -> findReadyCondition rest
    findReadyCondition (_ : rest) = findReadyCondition rest

parseVictoriaUp :: Text -> ByteString -> Either Text Bool
parseVictoriaUp brokerName bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode VictoriaMetrics response: " <> T.pack e)
    Right v ->
      if responseStatus v /= Just "success"
        then Left "VictoriaMetrics query did not return success"
        else Right (any matchingUp (queryResults v))
  where
    matchingUp item =
      textAt ["metric", "nagare_broker"] item == Just brokerName
        && sampleValue item == Just "1"

responseStatus :: Aeson.Value -> Maybe Text
responseStatus = textAt ["status"]

queryResults :: Aeson.Value -> [Aeson.Value]
queryResults v =
  case lookupPath ["data", "result"] v of
    Just (Aeson.Array xs) -> V.toList xs
    _ -> []

sampleValue :: Aeson.Value -> Maybe Text
sampleValue item =
  case lookupPath ["value"] item of
    Just (Aeson.Array xs)
      | V.length xs >= 2 ->
          case xs V.! 1 of
            Aeson.String s -> Just s
            _ -> Nothing
    _ -> Nothing

lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing

percentEncode :: Text -> Text
percentEncode = T.concatMap encodeChar
  where
    encodeChar c
      | c `elem` safe = T.singleton c
      | otherwise = "%" <> hex2 (ord c)
    safe = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> ['-', '_', '.', '~']
    hex2 n =
      let h = T.toUpper (T.pack (showHex n ""))
       in if T.length h == 1 then "0" <> h else h
