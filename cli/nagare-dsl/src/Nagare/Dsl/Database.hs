-- | The typed managed-database model (MasterPlan 9, IP1). A 'Database' names an
-- engine, pins a version, requests a disk size and resource limits, and sets a
-- retention policy. Every constrained field goes through a smart constructor, so
-- an illegal database (bad name, unpinned version, unsupported engine/version)
-- cannot be written down. Reuses 'Namespace', 'Quantity', 'Resources', and
-- 'RetentionPolicy' from "Nagare.Dsl.Types"; it does not duplicate them.
--
-- Engine facts ('engineImage' / 'enginePort' / 'enginePorts' / 'engineDataPath' /
-- 'engineSecretKeys' / 'engineMemoryConfig') were verified against the live
-- single-node cluster by EP-43
-- (@docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md@):
-- Postgres 18, Redis 8, and ClickHouse 25.8 (LTS) each run as a single-replica
-- StatefulSet with a @local-path@ PVC and credentials sourced from the managed
-- Secret @nagare-db-\<name\>@.
module Nagare.Dsl.Database
  ( -- * Engine
    Engine (..)
  , engineToken
  , parseEngine
  , engineImage
  , enginePort
  , enginePorts
  , engineDataPath
  , engineSecretKeys
  , engineStartupSecretKeys
  , engineMemoryConfig
  , defaultEngineVersion

    -- * DatabaseName (re-exported from "Nagare.Dsl.Types")
  , DatabaseName
  , mkDatabaseName
  , databaseNameText

    -- * EngineVersion
  , EngineVersion
  , mkEngineVersion
  , engineVersionText

    -- * Database
  , Database (..)

    -- * Managed Secret naming (IP3)
  , dbSecretName
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isDigit)
import Data.Text qualified as Text
import Nagare.Dsl.Types
  ( DatabaseName
  , Namespace
  , Quantity
  , Resources
  , RetentionPolicy
  , databaseNameText
  , mkDatabaseName
  )

-- | The supported database engines. A typed dimension, not a unit of
-- decomposition: every engine shares the renderer and the JSON shape and differs
-- only in the data tabulated by 'engineImage' / 'enginePort' / 'engineDataPath'
-- / 'engineSecretKeys'.
data Engine = Postgres | Redis | ClickHouse
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | The lowercase token used in JSON, labels, and resource names:
-- @Postgres -> "postgres"@, @Redis -> "redis"@, @ClickHouse -> "clickhouse"@.
engineToken :: Engine -> Text
engineToken Postgres = "postgres"
engineToken Redis = "redis"
engineToken ClickHouse = "clickhouse"

-- | Parse an engine token back (the loader uses this). Unknown tokens are
-- 'Nothing' so the caller can raise a precise 'MarshalError'.
parseEngine :: Text -> Maybe Engine
parseEngine "postgres" = Just Postgres
parseEngine "redis" = Just Redis
parseEngine "clickhouse" = Just ClickHouse
parseEngine _ = Nothing

-- | The official container image repository for an engine (no tag; the tag is
-- the pinned 'EngineVersion'). Confirmed against EP-43's verified manifests.
engineImage :: Engine -> Text
engineImage Postgres = "postgres"
engineImage Redis = "redis"
engineImage ClickHouse = "clickhouse/clickhouse-server"

-- | The /primary/ in-container port for an engine — the one its connection URL
-- uses (EP-46 composes URLs against this). For ClickHouse this is the native
-- protocol port @9000@ (the @clickhouse://@ URL and @clickhouse-client@ use it),
-- not the HTTP port; the HTTP port is additionally exposed via 'enginePorts'.
enginePort :: Engine -> Int
enginePort Postgres = 5432
enginePort Redis = 6379
enginePort ClickHouse = 9000

-- | The named ports the ClusterIP Service and the StatefulSet container expose.
-- Single-port for Postgres/Redis; ClickHouse exposes both the native protocol
-- (@9000@) and the HTTP interface (@8123@), as EP-43 verified.
enginePorts :: Engine -> [(Text, Int)]
enginePorts Postgres = [("postgres", 5432)]
enginePorts Redis = [("redis", 6379)]
enginePorts ClickHouse = [("native", 9000), ("http", 8123)]

-- | The in-container path the data volume mounts at.
engineDataPath :: Engine -> Text
engineDataPath Postgres = "/var/lib/postgresql/data"
engineDataPath Redis = "/data"
engineDataPath ClickHouse = "/var/lib/clickhouse"

-- | The keys of the managed credential Secret 'dbSecretName', per engine (IP3).
-- The composed @*_URL@ keys are part of the contract (EP-46 injects them into
-- consuming apps) but are NOT wired into the database container itself; see
-- 'engineStartupSecretKeys'. The VALUES are filled by EP-45 at create time,
-- never by this pure model.
engineSecretKeys :: Engine -> [Text]
engineSecretKeys Postgres = ["POSTGRES_PASSWORD", "POSTGRES_USER", "POSTGRES_DB", "DATABASE_URL"]
engineSecretKeys Redis = ["REDIS_PASSWORD", "REDIS_URL"]
engineSecretKeys ClickHouse = ["CLICKHOUSE_PASSWORD", "CLICKHOUSE_USER", "CLICKHOUSE_URL"]

-- | The Secret keys the engine container reads at startup, wired into the
-- StatefulSet as @valueFrom.secretKeyRef@ env. This is 'engineSecretKeys' minus
-- the composed @*_URL@ (which embeds the password and is for consuming apps, not
-- the engine). Postgres reads @POSTGRES_*@ directly; Redis reads only the
-- password (interpolated into @--requirepass@ by the renderer's command, since
-- the @redis@ image does not honor a password env var on its own — EP-43);
-- ClickHouse reads @CLICKHOUSE_USER@/@CLICKHOUSE_PASSWORD@.
engineStartupSecretKeys :: Engine -> [Text]
engineStartupSecretKeys Postgres = ["POSTGRES_PASSWORD", "POSTGRES_USER", "POSTGRES_DB"]
engineStartupSecretKeys Redis = ["REDIS_PASSWORD"]
engineStartupSecretKeys ClickHouse = ["CLICKHOUSE_PASSWORD", "CLICKHOUSE_USER"]

-- | For engines that need a server-side config file, the content to mount into
-- the engine's config directory. Only ClickHouse needs one on the small
-- @e2-standard-2@ VM: an absolute @max_server_memory_usage@ cap (1.5 GiB) so the
-- engine cannot assume it owns most of the shared host RAM and starve the rest
-- of the cluster (EP-43 verified this keeps the node out of memory pressure).
-- 'Nothing' for engines that need no extra config.
engineMemoryConfig :: Engine -> Maybe Text
engineMemoryConfig ClickHouse =
  Just
    "<clickhouse>\n\
    \  <max_server_memory_usage>1610612736</max_server_memory_usage>\n\
    \  <mark_cache_size>268435456</mark_cache_size>\n\
    \</clickhouse>\n"
engineMemoryConfig _ = Nothing

-- | The modern default image tag for an engine, per user direction and verified
-- on the cluster by EP-43: Postgres @18@, Redis @8@, ClickHouse @25.8@ (the
-- current LTS — ClickHouse uses @YY.M@ calendar versioning, there is no bare
-- @25@ tag). EP-45's @db create@ uses this when the author does not pin a
-- version.
defaultEngineVersion :: Engine -> EngineVersion
defaultEngineVersion Postgres = EngineVersion "18"
defaultEngineVersion Redis = EngineVersion "8"
defaultEngineVersion ClickHouse = EngineVersion "25.8"

-- | A pinned engine image tag (e.g. @"18"@, @"8"@, @"25.8"@). Validated per
-- engine: must be non-empty, must not be the floating tag @"latest"@ (a database
-- image must be reproducible), must not contain spaces or a @':'@, and must start
-- with a digit. ClickHouse's @YY.M@ form (e.g. @"25.8"@) passes these rules. The
-- @engine@ argument is accepted so a future per-engine allow-list (from EP-43's
-- findings) can be added without changing the type.
newtype EngineVersion = EngineVersion Text
  deriving stock (Generic, Eq, Ord, Show)

mkEngineVersion :: Engine -> Text -> Either Text EngineVersion
mkEngineVersion eng t
  | Text.null t = Left "engine version must not be empty"
  | t == "latest" =
      Left "engine version must be pinned, not 'latest'"
  | Text.elem ' ' t = Left ("engine version must not contain spaces: " <> t)
  | Text.elem ':' t = Left ("engine version must not contain ':': " <> t)
  | not (firstCharOk t) =
      Left ("engine version must start with a digit (e.g. \"18\"): " <> t)
  | otherwise = Right (EngineVersion t)
  where
    _ = eng
    firstCharOk s = case Text.uncons s of
      Just (c, _) -> isDigit c
      Nothing -> False

engineVersionText :: EngineVersion -> Text
engineVersionText (EngineVersion t) = t

-- | A managed database. There is no hidden constructor for 'Database' — the
-- safety guarantee comes from the field types, not from hiding this record
-- (mirrors 'Nagare.Dsl.Types.Deployment').
data Database = Database
  { dbName :: !DatabaseName
  , engine :: !Engine
  , version :: !EngineVersion
  , namespace :: !Namespace
  , size :: !Quantity
  , resources :: !(Maybe Resources)
  , retention :: !RetentionPolicy
  }
  deriving stock (Generic, Eq, Show)

-- | The deterministic managed-credential Secret name for a database (IP3):
-- @dbSecretName "pg-main" == "nagare-db-pg-main"@. EP-45 writes this Secret;
-- EP-46/EP-47 discover it by this name (and by the IP3 labels). The pure
-- renderer references it but never emits its data.
dbSecretName :: Text -> Text
dbSecretName n = "nagare-db-" <> n
