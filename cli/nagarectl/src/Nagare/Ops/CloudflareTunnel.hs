-- | The operator's tunnel credential and connector checks (ADR 34).
--
-- The tunnel token is an interception credential: a connector started anywhere with it receives a
-- share of every request. These helpers only ever carry it between the API and sops.
module Nagare.Ops.CloudflareTunnel
  ( Connector (..)
  , connectorProblems
  , parseConnectors
  , parseTunnelId
  , parseTunnelToken
  , tokenSecretYaml
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
