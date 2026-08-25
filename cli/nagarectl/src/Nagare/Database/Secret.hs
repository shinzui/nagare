-- | Pure helpers for the managed-database credential Secret (MasterPlan 9, IP3 —
-- the create-time half owned by EP-45).
--
-- EP-44 (@Nagare.Dsl.Database@) owns the Secret /name/, /key/, and /label/
-- contract and the renderer that references the Secret; this module generates the
-- credential /values/ (the composed connection URL and the per-engine key set)
-- and renders the @kind: Secret@ JSON that EP-45's create handler applies. EP-46
-- (app env injection) and EP-47 (backup/restore) read this Secret by name/label
-- and must never re-derive credentials.
--
-- The renderer mirrors @Nagare.Env.Store.renderEnvSecret@: type @Opaque@,
-- base64-encoded @data@ with deterministically sorted keys, plus the IP3 labels.
module Nagare.Database.Secret
  ( ConnectionParts (..)
  , composeConnectionUrl
  , percentEncode
  , secretKeysFor
  , DbSecretInputs (..)
  , renderDbSecret
  , b64encode
  , b64decode
  , dbHost
  , defaultDbUser
  , sanitizeDbName
  )
where

import Data.Aeson (encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteArray.Encoding (Base (Base64), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.List (sortOn)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Database (Engine (..), dbSecretName, engineToken)
import Nagare.Dsl.Prelude hiding ((.=))
import Network.HTTP.Types.URI (urlEncode)

-- | The pieces of a connection string. @cpHost@ is the in-cluster DNS name; the
-- port is fixed per engine in 'composeConnectionUrl'.
data ConnectionParts = ConnectionParts
  { cpUser :: !Text
  , cpPassword :: !Text
  , cpHost :: !Text
  , cpDb :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | The default application role created in every managed database.
defaultDbUser :: Text
defaultDbUser = "nagare"

-- | The deterministic in-cluster DNS host for a database's ClusterIP Service:
-- @\<name\>.\<namespace\>.svc.cluster.local@.
dbHost :: Text -> Text -> Text
dbHost name ns = name <> "." <> ns <> ".svc.cluster.local"

-- | A database name sanitized for use as a SQL database/identifier: hyphens
-- become underscores (@pg-main@ -> @pg_main@). DNS labels allow hyphens; many
-- SQL identifiers do not without quoting, so the default @POSTGRES_DB@ uses the
-- underscored form.
sanitizeDbName :: Text -> Text
sanitizeDbName = T.map (\c -> if c == '-' then '_' else c)

-- | Percent-encode a connection-URL userinfo component, preserving only the RFC
-- 3986 unreserved characters.
percentEncode :: Text -> Text
percentEncode = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

-- | The per-engine connection URL (MasterPlan IP3). Usernames and passwords are
-- percent-encoded because they occupy the URL's userinfo component. The password
-- is embedded, so this value is only ever stored in the managed Secret, never in
-- a ConfigMap or inline env literal.
composeConnectionUrl :: Engine -> ConnectionParts -> Text
composeConnectionUrl Postgres p =
  "postgresql://"
    <> percentEncode (cpUser p)
    <> ":"
    <> percentEncode (cpPassword p)
    <> "@"
    <> cpHost p
    <> ":5432/"
    <> cpDb p
composeConnectionUrl Redis p =
  "redis://:" <> percentEncode (cpPassword p) <> "@" <> cpHost p <> ":6379"
composeConnectionUrl ClickHouse p =
  "clickhouse://"
    <> percentEncode (cpUser p)
    <> ":"
    <> percentEncode (cpPassword p)
    <> "@"
    <> cpHost p
    <> ":9000"

-- | The engine-specific Secret key/value pairs (MasterPlan IP3), including the
-- composed connection URL. The key set matches
-- @Nagare.Dsl.Database.engineSecretKeys@.
secretKeysFor :: Engine -> ConnectionParts -> [(Text, Text)]
secretKeysFor Postgres p =
  [ ("POSTGRES_PASSWORD", cpPassword p)
  , ("POSTGRES_USER", cpUser p)
  , ("POSTGRES_DB", cpDb p)
  , ("DATABASE_URL", composeConnectionUrl Postgres p)
  ]
secretKeysFor Redis p =
  [ ("REDIS_PASSWORD", cpPassword p)
  , ("REDIS_URL", composeConnectionUrl Redis p)
  ]
secretKeysFor ClickHouse p =
  [ ("CLICKHOUSE_PASSWORD", cpPassword p)
  , ("CLICKHOUSE_USER", cpUser p)
  , ("CLICKHOUSE_URL", composeConnectionUrl ClickHouse p)
  ]

-- | Inputs to the managed-Secret renderer.
data DbSecretInputs = DbSecretInputs
  { dsiName :: !Text
  , dsiNamespace :: !Text
  , dsiEngine :: !Engine
  , dsiKvs :: ![(Text, Text)]
  }
  deriving stock (Generic, Eq, Show)

-- | Render the managed credential Secret (JSON bytes @kubectl apply -f@ accepts):
-- name @nagare-db-\<name\>@, type @Opaque@, base64 @data@ with sorted keys, and
-- the IP3 labels @nagare.dev/managed-by@, @nagare.dev/database@,
-- @nagare.dev/engine@.
renderDbSecret :: DbSecretInputs -> ByteString
renderDbSecret inp =
  LBS.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Secret" :: Text)
      , "type" .= ("Opaque" :: Text)
      , "metadata"
          .= object
            [ "name" .= dbSecretName (dsiName inp)
            , "namespace" .= dsiNamespace inp
            , "labels"
                .= object
                  [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
                  , "nagare.dev/database" .= dsiName inp
                  , "nagare.dev/engine" .= engineToken (dsiEngine inp)
                  ]
            ]
      , "data" .= dataObject (dsiKvs inp)
      ]
  where
    dataObject kvs =
      object [Key.fromText k .= b64encode v | (k, v) <- sortOn fst kvs]

-- base64 helpers (the @memory@ package, already a nagarectl dependency — same
-- codec choice as Nagare.Env.Store, whose b64 helpers are not exported).
b64encode :: Text -> Text
b64encode t = TE.decodeUtf8 (convertToBase Base64 (TE.encodeUtf8 t))

b64decode :: Text -> Either Text Text
b64decode t =
  case convertFromBase Base64 (TE.encodeUtf8 t) :: Either String ByteString of
    Left e -> Left ("could not base64-decode secret value: " <> T.pack e)
    Right bs ->
      case TE.decodeUtf8' bs of
        Left _ -> Left "secret value is not valid UTF-8 after base64 decoding"
        Right value -> Right value
