-- | The operator's tunnel credential and connector checks (ADR 34).
--
-- The tunnel token is an interception credential: a connector started anywhere with it receives a
-- share of every request. These helpers only ever carry it between the API and sops.
module Nagare.Ops.CloudflareTunnel
  ( Connector (..)
  , connectorProblems
  , expectedConnectors
  , gradeTunnelConnectors
  , gradeTunnelRules
  , parseConnectors
  , parseTunnelId
  , parseTunnelRules
  , parseTunnelToken
  , tokenSecretYaml
  , tunnelRuleProblems
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.CloudflareRuntime (tunnelIngressRules)
import Nagare.Inventory.Components.CloudflareZone (connectorOrigin)
import Nagare.Ops.Probe (Probe (..), ProbeStatus (..))

data Connector = Connector
  { connectorId :: !Text
  , connectorVersion :: !Text
  , connectorOrigins :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

result :: Int -> ByteString -> Either Text Value
result status bytes = do
  unless (status >= 200 && status < 300) (Left ("Cloudflare answered HTTP " <> T.pack (show status)))
  envelope <- first (const "Cloudflare's response is not JSON") (eitherDecodeStrict bytes)
  case envelope of
    Object fields
      | KM.lookup "success" fields == Just (Bool True)
      , Just value <- KM.lookup "result" fields ->
          Right value
    _ -> Left "Cloudflare's response was unsuccessful"

text :: Text -> Value -> Maybe Text
text key (Object fields) = case KM.lookup (Key.fromText key) fields of
  Just (String value) -> Just value
  _ -> Nothing
text _ _ = Nothing

-- | The one undeleted tunnel with this exact name.
parseTunnelId :: Text -> Int -> ByteString -> Either Text Text
parseTunnelId name status bytes = do
  value <- result status bytes
  case value of
    Array tunnels -> case [tunnel | tunnel <- toList tunnels, text "name" tunnel == Just name] of
      [tunnel] -> maybe (Left "the tunnel has no ID") Right (text "id" tunnel)
      [] -> Left ("Cloudflare has no tunnel named " <> name <> "; apply the reviewed bootstrap stage that creates it first")
      _ -> Left ("more than one Cloudflare tunnel is named " <> name)
    _ -> Left "Cloudflare's tunnel listing has no result array"

-- | The token is returned as the bare result. It is never part of an error.
parseTunnelToken :: Int -> ByteString -> Either Text Text
parseTunnelToken status bytes = do
  value <- result status bytes
  case value of
    String token | T.length token > 40 && T.all (`notElem` (" \n\r\"'\\" :: String)) token -> Right token
    _ -> Left "Cloudflare returned no usable tunnel token"

parseConnectors :: Int -> ByteString -> Either Text [Connector]
parseConnectors status bytes = do
  value <- result status bytes
  case value of
    Array connectors -> traverse connector (toList connectors)
    _ -> Left "Cloudflare's connection listing has no result array"
  where
    connector value@(Object fields) = do
      identifier <- maybe (Left "a connector has no ID") Right (text "id" value)
      let origins = case KM.lookup "conns" fields of
            Just (Array conns) -> [origin | conn <- toList conns, Just origin <- [text "origin_ip" conn]]
            _ -> []
      Right (Connector identifier (maybe "" id (text "version" value)) (sort (nub origins)))
    connector _ = Left "a connector is not an object"

-- | The connector Deployment's replicas.
expectedConnectors :: Int
expectedConnectors = 2

-- | What should make an operator look: the wrong number of connectors, or any from another address,
-- since a connector started anywhere with the token receives a share of every request.
connectorProblems :: Int -> Text -> [Connector] -> [Text]
connectorProblems expected vmAddress connectors =
  [ "expected " <> T.pack (show expected) <> " connectors, Cloudflare lists " <> T.pack (show (length connectors))
  | length connectors /= expected
  ]
    <> [ "connector " <> connector ^. #connectorId <> " connects from " <> origin <> ", not this context's VM (" <> vmAddress <> ")"
       | connector <- connectors
       , origin <- connector ^. #connectorOrigins
       , origin /= vmAddress
       ]

-- | What @doctor@ and @status@ say about Cloudflare's own listing. Without the operator's credentials it
-- cannot look, which is a warning: an operator without them can still read everything else.
gradeTunnelConnectors :: Int -> Maybe Text -> Maybe (Either Text [Connector]) -> Probe
gradeTunnelConnectors _ _ Nothing =
  Probe probeName StatusWarn "not checked: set CF_ACCOUNT_ID and CF_API_TOKEN to compare Cloudflare's listing with this context"
gradeTunnelConnectors _ _ (Just (Left reason)) = Probe probeName StatusUnknown reason
gradeTunnelConnectors _ Nothing (Just (Right _)) = Probe probeName StatusUnknown "this context's stack has no publicIp output to compare with"
gradeTunnelConnectors expected (Just address) (Just (Right connectors)) =
  case connectorProblems expected address connectors of
    [] -> Probe probeName StatusOk (T.pack (show (length connectors)) <> " connector(s), all from this context's VM")
    problems -> Probe probeName StatusFail (T.intercalate "; " problems)

probeName :: Text
probeName = "Tunnel connectors"

-- | One stored ingress rule: its hostname and path, and where it sends them.
ingressRule :: Value -> Maybe (Maybe Text, Maybe Text, Text)
ingressRule rule = (text "hostname" rule,text "path" rule,) <$> text "service" rule

parseTunnelRules :: Int -> ByteString -> Either Text [(Maybe Text, Maybe Text, Text)]
parseTunnelRules status bytes = do
  value <- result status bytes
  case value of
    Object fields
      | Just (Object config) <- KM.lookup "config" fields
      , Just (Array rules) <- KM.lookup "ingress" config ->
          maybe (Left "a stored tunnel rule has no service") Right (traverse ingressRule (toList rules))
    _ -> Left "Cloudflare's tunnel configuration has no ingress rules"

-- | Whoever holds the API token or the account can repoint these at anything the pod can reach, so any
-- difference from the declared rules is worth an operator's look.
tunnelRuleProblems :: Text -> [(Maybe Text, Maybe Text, Text)] -> [Text]
tunnelRuleProblems base stored =
  [ "Cloudflare's tunnel rules differ from the declared ones: " <> T.intercalate ", " (map describe stored)
  | Just stored /= traverse ingressRule (tunnelIngressRules base connectorOrigin)
  ]
  where
    describe (hostname, path, service) = maybe "*" id hostname <> maybe "" ("/" <>) path <> " -> " <> service

gradeTunnelRules :: Text -> Maybe (Either Text [(Maybe Text, Maybe Text, Text)]) -> Probe
gradeTunnelRules _ Nothing = Probe "Tunnel rules" StatusWarn "not checked: set CF_ACCOUNT_ID and CF_API_TOKEN to compare Cloudflare's rules with the declared ones"
gradeTunnelRules _ (Just (Left reason)) = Probe "Tunnel rules" StatusUnknown reason
gradeTunnelRules base (Just (Right stored)) = case tunnelRuleProblems base stored of
  [] -> Probe "Tunnel rules" StatusOk "Cloudflare's rules are the declared ones"
  problems -> Probe "Tunnel rules" StatusFail (T.intercalate "; " problems)

-- | The Secret the connector scope binds, in the shape it checks. It goes to sops on stdin.
tokenSecretYaml :: Text -> Text
tokenSecretYaml token =
  T.unlines
    [ "apiVersion: v1"
    , "kind: Secret"
    , "metadata:"
    , "  name: cloudflare-tunnel-token"
    , "  namespace: cloudflare-tunnel"
    , "stringData:"
    , "  token: \"" <> token <> "\""
    ]
