{-# LANGUAGE PackageImports #-}

-- | Deploy-time generated database connection environment variables (MasterPlan
-- 9, EP-46, Integration Point IP5).
--
-- A pure assembly of the per-engine connection variables for a managed database
-- an app references. Host/port/user/db are inline @{Runtime}@ 'EnvLiteral's; the
-- password and the composed connection URL are 'EnvSecretRef's pointing at the
-- managed Secret @nagare-db-\<name\>@ (EP-45 / IP3). The map is merged into the
-- app's env at the deploy call site via 'Nagare.Env.Generated.mergeGenerated',
-- exactly like the @NAGARE_*@ identity variables.
--
-- Hard invariant: a @secretKeyRef@ reads the Secret key whose name equals the
-- env-variable name (see @Nagare.Dsl.Render.envEntryValue@). So the secret-ref
-- env names here (@POSTGRES_PASSWORD@, @DATABASE_URL@, …) are byte-identical to
-- the keys EP-45 writes into the Secret (IP3); they were chosen to match.
module Nagare.Database.Connection
  ( ConnIdentity (..)
  , connectionEnv
  , mergeConnectionEnvs
  ) where

import Nagare.Dsl.Prelude

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Database (DatabaseName, Engine (..), databaseNameText, dbSecretName)
import Nagare.Dsl.Types
  ( EnvName
  , EnvVar (EnvLiteral, EnvSecretRef)
  , Namespace
  , ScopedEnvVar
  , SecretName
  , envNameText
  , mkEnvName
  , mkSecretName
  , namespaceText
  , runtimeScoped
  )

-- | The non-secret connection identity for a database: the application role/user
-- and the logical database name. Redis has neither in the variable contract, so
-- both are 'Nothing' for Redis; Postgres populates both; ClickHouse populates
-- 'connUser'.
data ConnIdentity = ConnIdentity
  { connUser :: !(Maybe Text)
  , connDb :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | The per-engine connection variables for one referenced database, as a
-- @{Runtime}@-scoped env map. Literals: host, port, and (where applicable) user
-- and db. Secret references (into @nagare-db-\<name\>@, key = the env var name):
-- the password and the composed URL.
connectionEnv :: Engine -> DatabaseName -> Namespace -> ConnIdentity -> Map EnvName ScopedEnvVar
connectionEnv eng name ns ident =
  Map.fromList (lits <> refs)
  where
    host = databaseNameText name <> "." <> namespaceText ns <> ".svc.cluster.local"
    secret = dbSecretName (databaseNameText name)
    lit n v = (envName n, runtimeScoped (EnvLiteral v))
    ref n = (envName n, runtimeScoped (EnvSecretRef (secretName secret)))
    maybeLit n = maybe [] (\v -> [lit n v])
    (lits, refs) = case eng of
      Postgres ->
        ( [lit "POSTGRES_HOST" host, lit "POSTGRES_PORT" "5432"]
            <> maybeLit "POSTGRES_USER" (connUser ident)
            <> maybeLit "POSTGRES_DB" (connDb ident)
        , [ref "POSTGRES_PASSWORD", ref "DATABASE_URL"]
        )
      Redis ->
        ( [lit "REDIS_HOST" host, lit "REDIS_PORT" "6379"]
        , [ref "REDIS_PASSWORD", ref "REDIS_URL"]
        )
      ClickHouse ->
        ( [lit "CLICKHOUSE_HOST" host, lit "CLICKHOUSE_PORT" "9000"]
            <> maybeLit "CLICKHOUSE_USER" (connUser ident)
        , [ref "CLICKHOUSE_PASSWORD", ref "CLICKHOUSE_URL"]
        )

-- | Union of per-database connection maps, surfacing a collision on any shared
-- key (a same-engine canonical-name conflict). Different engines have disjoint
-- variable names and merge cleanly; two databases of the same engine both want
-- e.g. @DATABASE_URL@, which is a 'Left' so the deploy fails loudly rather than
-- silently dropping one.
mergeConnectionEnvs :: [Map EnvName ScopedEnvVar] -> Either Text (Map EnvName ScopedEnvVar)
mergeConnectionEnvs maps =
  case findCollision maps of
    Just k ->
      Left
        ( "two referenced databases of the same engine both inject '"
            <> envNameText k
            <> "'; only one database per engine may be referenced in v1"
        )
    Nothing -> Right (Map.unions maps)
  where
    findCollision = go Set.empty
      where
        go _ [] = Nothing
        go seen (m : ms) =
          let ks = Map.keysSet m
           in case Set.lookupMin (Set.intersection seen ks) of
                Just k -> Just k
                Nothing -> go (Set.union seen ks) ms

-- Internal constructors that cannot fail for the fixed names here; a failure is a
-- programmer error surfaced loudly (mirrors Nagare.Env.Generated's envName).
envName :: Text -> EnvName
envName t = either (\e -> error ("EP-46 connection env name invalid: " <> T.unpack e)) id (mkEnvName t)

secretName :: Text -> SecretName
secretName t = either (\e -> error ("EP-46 secret name invalid: " <> T.unpack e)) id (mkSecretName t)
