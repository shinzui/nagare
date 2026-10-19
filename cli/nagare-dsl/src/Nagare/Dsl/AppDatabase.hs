-- | An app database (EP-202): a logical database (or, on ClickHouse, a set of
-- them) inside a shared server, with its own runtime and migration users.
-- The server stays owned by platform operations; an app database names the
-- server it lives in and is declared from the consuming app's repository.
--
-- User names, Secret names and the grant sets are derived here, once. The
-- grant sets are the ones proven against the real engines in
-- @cli/nagarectl/test/fixtures/app-database/@.
module Nagare.Dsl.AppDatabase
  ( -- * Names
    AppDatabaseName
  , mkAppDatabaseName
  , appDatabaseNameText
  , LogicalDatabaseName
  , mkLogicalDatabaseName
  , logicalDatabaseNameText

    -- * Declaration
  , AppDatabase (..)
  , validateAppDatabase

    -- * Derived names
  , AppDatabaseRole (..)
  , appDatabaseRoleToken
  , appDatabaseUser
  , appDatabaseSecretName
  , serverInitialDatabase

    -- * Declared access
  , Grant (..)
  , appDatabaseAttributes
  , appDatabaseServerGrants
  , appDatabaseDatabaseGrants
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as Text
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (DatabaseName, Namespace, databaseNameText)
import Nagare.Resource.Types (LogicalKey)

-- | A DNS label of 1–36 characters that starts with a letter. The bound keeps
-- the backup CronJob name @nagare-dbbackup-\<name\>@ within Kubernetes' 52
-- characters and the derived user names within PostgreSQL's 63. Constructor
-- hidden; use 'mkAppDatabaseName'.
newtype AppDatabaseName = AppDatabaseName Text
  deriving stock (Eq, Ord, Show)

mkAppDatabaseName :: Text -> Either Text AppDatabaseName
mkAppDatabaseName t
  | Text.null t = Left "app database name must not be empty"
  | Text.length t > 36 =
      Left ("app database name too long (" <> Text.show (Text.length t) <> " chars, max 36)")
  | not (startsWithLetter t) = Left ("app database name must start with a letter: " <> t)
  | Text.isSuffixOf "-" t = Left "app database name must not end with a hyphen"
  | not (Text.all (\c -> isAsciiLower c || isDigit c || c == '-') t) =
      Left ("app database name contains invalid characters (allowed: a-z, 0-9, -): " <> t)
  | otherwise = Right (AppDatabaseName t)

appDatabaseNameText :: AppDatabaseName -> Text
appDatabaseNameText (AppDatabaseName t) = t

-- | A SQL identifier, @[a-z][a-z0-9_]{0,47}@, so it needs no quoting on
-- either engine. Constructor hidden; use 'mkLogicalDatabaseName'.
newtype LogicalDatabaseName = LogicalDatabaseName Text
  deriving stock (Eq, Ord, Show)

mkLogicalDatabaseName :: Text -> Either Text LogicalDatabaseName
mkLogicalDatabaseName t
  | Text.null t = Left "logical database name must not be empty"
  | Text.length t > 48 =
      Left ("logical database name too long (" <> Text.show (Text.length t) <> " chars, max 48)")
  | not (startsWithLetter t) = Left ("logical database name must start with a letter: " <> t)
  | not (Text.all (\c -> isAsciiLower c || isDigit c || c == '_') t) =
      Left ("logical database name contains invalid characters (allowed: a-z, 0-9, _): " <> t)
  | otherwise = Right (LogicalDatabaseName t)

logicalDatabaseNameText :: LogicalDatabaseName -> Text
logicalDatabaseNameText (LogicalDatabaseName t) = t

startsWithLetter :: Text -> Bool
startsWithLetter t = maybe False (isAsciiLower . fst) (Text.uncons t)

-- | An app database. Like 'Nagare.Dsl.Database.Database', the record is open:
-- its fields are validated values, and 'validateAppDatabase' checks the rules
-- that span fields.
data AppDatabase = AppDatabase
  { name :: !AppDatabaseName
  , logicalKey :: !(Maybe LogicalKey)
  , server :: !DatabaseName
  , engine :: !Engine
  , namespace :: !Namespace
  , logicalDatabases :: !(NonEmpty LogicalDatabaseName)
  }
  deriving stock (Generic, Eq, Show)

-- | Refuse an engine without users and grants (Redis), a PostgreSQL app
-- database with other than one logical database, a repeated logical database,
-- and a name the engine or the server reserves.
validateAppDatabase :: AppDatabase -> Either Text AppDatabase
validateAppDatabase db = do
  when (db ^. #engine == Redis) (Left "app databases are not supported on Redis")
  when
    (db ^. #engine == Postgres && length (db ^. #logicalDatabases) /= 1)
    (Left "a PostgreSQL app database has exactly one logical database")
  unless
    (length (nub names) == length names)
    (Left "app database repeats a logical database")
  case filter (`elem` reserved) names of
    [] -> Right db
    clash : _ -> Left ("logical database name is reserved on this server: " <> clash)
  where
    names = map logicalDatabaseNameText (NE.toList (db ^. #logicalDatabases))
    reserved = case db ^. #engine of
      Postgres -> ["postgres", "template0", "template1", serverInitialDatabase (db ^. #server)]
      _ -> ["default", "system", "information_schema"]

-- | The server's initial database, which the server render creates as
-- @POSTGRES_DB@ (hyphens become underscores).
serverInitialDatabase :: DatabaseName -> Text
serverInitialDatabase = Text.replace "-" "_" . databaseNameText

data AppDatabaseRole = RuntimeRole | MigrationRole
  deriving stock (Eq, Ord, Show, Enum, Bounded)

appDatabaseRoleToken :: AppDatabaseRole -> Text
appDatabaseRoleToken RuntimeRole = "runtime"
appDatabaseRoleToken MigrationRole = "migration"

-- | @kansoku-pg@ runtime → @kansoku_pg_runtime@.
appDatabaseUser :: AppDatabaseName -> AppDatabaseRole -> Text
appDatabaseUser n r = Text.replace "-" "_" (appDatabaseNameText n) <> "_" <> appDatabaseRoleToken r

-- | @kansoku-pg@ runtime → @kansoku-pg-runtime@.
appDatabaseSecretName :: AppDatabaseName -> AppDatabaseRole -> Text
appDatabaseSecretName n r = appDatabaseNameText n <> "-" <> appDatabaseRoleToken r

-- | A privilege set on one object class, e.g. @("tables", ["SELECT", ...])@
-- for PostgreSQL default privileges or @("database", [...])@ for a
-- ClickHouse @db.*@ grant.
data Grant = Grant
  { objectClass :: !Text
  , privileges :: ![Text]
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | The attributes a user is created with.
appDatabaseAttributes :: Engine -> AppDatabaseRole -> [Text]
appDatabaseAttributes Postgres _ =
  ["LOGIN", "NOSUPERUSER", "NOCREATEDB", "NOCREATEROLE", "NOREPLICATION", "NOBYPASSRLS"]
appDatabaseAttributes _ _ = ["HOST ANY"]

-- | Server-wide grants. Only the ClickHouse migration user has one: the
-- write-only @FILE@ source its per-database @BACKUP ... TO File(...)@ needs.
appDatabaseServerGrants :: Engine -> AppDatabaseRole -> [Grant]
appDatabaseServerGrants ClickHouse MigrationRole = [Grant "file" ["WRITE"]]
appDatabaseServerGrants _ _ = []

-- | Grants on one logical database. On PostgreSQL the migration user owns the
-- database and its @public@ schema; the runtime user reads and writes what
-- the migration user creates through default privileges. On ClickHouse both
-- are explicit lists, never @ALL@, whose expansion changes between versions.
appDatabaseDatabaseGrants :: Engine -> AppDatabaseRole -> [Grant]
appDatabaseDatabaseGrants Postgres MigrationRole =
  [Grant "database" ["OWNER"], Grant "schema" ["OWNER"]]
appDatabaseDatabaseGrants Postgres RuntimeRole =
  [ Grant "database" ["CONNECT", "TEMPORARY"]
  , Grant "schema" ["USAGE"]
  , Grant "default-schemas" ["USAGE"]
  , Grant "default-tables" ["SELECT", "INSERT", "UPDATE", "DELETE"]
  , Grant "default-sequences" ["USAGE", "SELECT"]
  , Grant "default-functions" ["EXECUTE"]
  ]
appDatabaseDatabaseGrants ClickHouse MigrationRole =
  [ Grant
      "database"
      [ "SHOW TABLES"
      , "SHOW COLUMNS"
      , "SHOW DICTIONARIES"
      , "SELECT"
      , "INSERT"
      , "ALTER TABLE"
      , "ALTER VIEW"
      , "CREATE DATABASE"
      , "CREATE TABLE"
      , "CREATE VIEW"
      , "CREATE DICTIONARY"
      , "DROP TABLE"
      , "DROP VIEW"
      , "DROP DICTIONARY"
      , "TRUNCATE"
      , "OPTIMIZE"
      , "BACKUP"
      , "dictGet"
      ]
  ]
appDatabaseDatabaseGrants ClickHouse RuntimeRole =
  [ Grant
      "database"
      ["SHOW TABLES", "SHOW COLUMNS", "SELECT", "INSERT", "ALTER UPDATE", "ALTER DELETE", "dictGet"]
  ]
appDatabaseDatabaseGrants Redis _ = []
