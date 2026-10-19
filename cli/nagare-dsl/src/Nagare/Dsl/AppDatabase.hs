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

    -- * Reviewed access beyond the fixed grant set
  , AppDatabaseAccess (..)
  , UserAccess (..)
  , UserLimits (..)
  , GrantException (..)
  , MonitoringRole (..)
  , noAppDatabaseAccess
  , noUserAccess
  , noUserLimits
  , appDatabaseUserAccess
  , grantExceptionToken
  , parseGrantException
  , grantExceptionGrant
  , monitoringRoleToken
  , parseMonitoringRole
  , validUserAccess

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

import Data.Aeson (FromJSON (parseJSON), Object, ToJSON (toJSON), Value (String), object, withObject, withText, (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as Text
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (AppDatabaseName, DatabaseName, Namespace, appDatabaseNameText, databaseNameText, mkAppDatabaseName)
import Nagare.Resource.Types (LogicalKey)

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
  , access :: !AppDatabaseAccess
  -- ^ reviewed exceptions and limits (EP-204); 'noAppDatabaseAccess' for none
  }
  deriving stock (Generic, Eq, Show)

-- | An allow-listed ClickHouse privilege beyond the fixed grant set (EP-204).
-- The list is closed: a privilege outside it cannot be declared.
data GrantException
  = -- | @SELECT ON system.parts@, whose rows are the tables the user can see
    SystemParts
  | -- | @SELECT ON system.mutations@, likewise filtered
    SystemMutations
  | -- | @SELECT ON system.disks@: server storage, no tenant data
    SystemDisks
  | -- | @SELECT ON system.storage_policies@: server storage, no tenant data
    SystemStoragePolicies
  | -- | @CREATE ARBITRARY TEMPORARY TABLE@: session-local tables with any
    -- engine whose own grant the user holds, so not File, URL or S3
    ArbitraryTemporaryTables
  deriving stock (Eq, Ord, Show, Enum, Bounded)

grantExceptionToken :: GrantException -> Text
grantExceptionToken = \case
  SystemParts -> "system-parts"
  SystemMutations -> "system-mutations"
  SystemDisks -> "system-disks"
  SystemStoragePolicies -> "system-storage-policies"
  ArbitraryTemporaryTables -> "arbitrary-temporary-tables"

parseGrantException :: Text -> Maybe GrantException
parseGrantException token = find ((== token) . grantExceptionToken) [minBound .. maxBound]

-- | The privilege and the object it is granted on.
grantExceptionGrant :: GrantException -> (Text, Text)
grantExceptionGrant = \case
  SystemParts -> ("SELECT", "system.parts")
  SystemMutations -> ("SELECT", "system.mutations")
  SystemDisks -> ("SELECT", "system.disks")
  SystemStoragePolicies -> ("SELECT", "system.storage_policies")
  ArbitraryTemporaryTables -> ("CREATE ARBITRARY TEMPORARY TABLE", "*.*")

-- | A read-only PostgreSQL predefined role whose grants on the app's own
-- objects are expected (EP-204). Nagare never grants these itself.
data MonitoringRole = PgMonitor
  deriving stock (Eq, Ord, Show, Enum, Bounded)

monitoringRoleToken :: MonitoringRole -> Text
monitoringRoleToken PgMonitor = "pg_monitor"

parseMonitoringRole :: Text -> Maybe MonitoringRole
parseMonitoringRole token = find ((== token) . monitoringRoleToken) [minBound .. maxBound]

-- | Per-user limits the server applies. On ClickHouse the three are ceilings
-- (also the defaults); on PostgreSQL the connection limit is a ceiling and
-- the statement timeout is a role default a session may override.
data UserLimits = UserLimits
  { maxMemoryBytes :: !(Maybe Int)
  , maxExecutionSeconds :: !(Maybe Int)
  , maxConcurrentQueries :: !(Maybe Int)
  , connectionLimit :: !(Maybe Int)
  , statementTimeoutSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Ord, Show)

data UserAccess = UserAccess
  { exceptions :: ![GrantException]
  , limits :: !UserLimits
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | The reviewed access of an app database's two users, and the monitoring
-- roles its logical database tolerates.
data AppDatabaseAccess = AppDatabaseAccess
  { runtime :: !UserAccess
  , migration :: !UserAccess
  , monitoring :: ![MonitoringRole]
  }
  deriving stock (Generic, Eq, Show)

noUserLimits :: UserLimits
noUserLimits = UserLimits Nothing Nothing Nothing Nothing Nothing

noUserAccess :: UserAccess
noUserAccess = UserAccess [] noUserLimits

noAppDatabaseAccess :: AppDatabaseAccess
noAppDatabaseAccess = AppDatabaseAccess noUserAccess noUserAccess []

appDatabaseUserAccess :: AppDatabase -> AppDatabaseRole -> UserAccess
appDatabaseUserAccess db RuntimeRole = db ^. #access . #runtime
appDatabaseUserAccess db MigrationRole = db ^. #access . #migration

-- | One user's access fits its engine: ClickHouse takes exceptions and the
-- three ceilings, PostgreSQL the connection limit and statement timeout;
-- every limit is positive and fits the engine's range.
validUserAccess :: Engine -> UserAccess -> Either Text ()
validUserAccess engine' userAccess = do
  unless (length (nub exceptions') == length exceptions') (Left "an app-database user repeats a grant exception")
  case filter ((<= 0) . snd) [(n, v) | (n, Just v) <- limitList] of
    [] -> pure ()
    (n, _) : _ -> Left ("app-database limit " <> n <> " must be positive")
  case engine' of
    ClickHouse ->
      unless (all (isNothing . snd) [entry | entry@(n, _) <- limitList, n `elem` postgresLimits]) (Left "connectionLimit and statementTimeoutSeconds are PostgreSQL limits")
    _ -> do
      unless (null exceptions') (Left "grant exceptions are ClickHouse privileges; a PostgreSQL app database declares monitoring roles")
      unless (all (isNothing . snd) [entry | entry@(n, _) <- limitList, n `notElem` postgresLimits]) (Left "maxMemoryBytes, maxExecutionSeconds and maxConcurrentQueries are ClickHouse limits")
      -- PostgreSQL stores both as a 32-bit integer (the timeout in milliseconds).
      when (maybe False (> int32Max) (l ^. #connectionLimit)) (Left "connectionLimit exceeds PostgreSQL's range")
      when (maybe False (> int32Max `div` 1000) (l ^. #statementTimeoutSeconds)) (Left "statementTimeoutSeconds exceeds PostgreSQL's range")
  where
    exceptions' = userAccess ^. #exceptions
    l = userAccess ^. #limits
    limitList =
      [ ("maxMemoryBytes", l ^. #maxMemoryBytes)
      , ("maxExecutionSeconds", l ^. #maxExecutionSeconds)
      , ("maxConcurrentQueries", l ^. #maxConcurrentQueries)
      , ("connectionLimit", l ^. #connectionLimit)
      , ("statementTimeoutSeconds", l ^. #statementTimeoutSeconds)
      ]
    postgresLimits = ["connectionLimit", "statementTimeoutSeconds"] :: [Text]
    int32Max = 2147483647

-- JSON ----------------------------------------------------------------------
-- One encoding serves the emitted declaration, the user and database specs
-- and their digests. Every key is written only when it has a value, so a
-- declaration without access keeps its pre-EP-204 bytes; decoding refuses an
-- unknown key or token, so a misspelt ceiling cannot be dropped silently.

instance ToJSON GrantException where toJSON = String . grantExceptionToken

instance FromJSON GrantException where
  parseJSON = withText "grant exception" $ \token ->
    maybe (fail ("unknown grant exception " <> show token <> " (allowed: " <> Text.unpack (Text.intercalate ", " (map grantExceptionToken [minBound .. maxBound])) <> ")")) pure (parseGrantException token)

instance ToJSON MonitoringRole where toJSON = String . monitoringRoleToken

instance FromJSON MonitoringRole where
  parseJSON = withText "monitoring role" $ \token ->
    maybe (fail ("unknown monitoring role " <> show token <> " (allowed: pg_monitor)")) pure (parseMonitoringRole token)

instance ToJSON UserLimits where
  toJSON l =
    object
      ( concat
          [ maybe [] (\v -> [key .= v]) value
          | (key, value) <-
              [ ("maxMemoryBytes", l ^. #maxMemoryBytes)
              , ("maxExecutionSeconds", l ^. #maxExecutionSeconds)
              , ("maxConcurrentQueries", l ^. #maxConcurrentQueries)
              , ("connectionLimit", l ^. #connectionLimit)
              , ("statementTimeoutSeconds", l ^. #statementTimeoutSeconds)
              ]
          ]
      )

instance FromJSON UserLimits where
  parseJSON = withObject "limits" $ \o -> do
    onlyKeys ["maxMemoryBytes", "maxExecutionSeconds", "maxConcurrentQueries", "connectionLimit", "statementTimeoutSeconds"] o
    UserLimits <$> o .:? "maxMemoryBytes" <*> o .:? "maxExecutionSeconds" <*> o .:? "maxConcurrentQueries" <*> o .:? "connectionLimit" <*> o .:? "statementTimeoutSeconds"

instance ToJSON UserAccess where
  toJSON u =
    object
      ( ["exceptions" .= (u ^. #exceptions) | not (null (u ^. #exceptions))]
          <> ["limits" .= (u ^. #limits) | u ^. #limits /= noUserLimits]
      )

instance FromJSON UserAccess where
  parseJSON = withObject "user access" $ \o -> do
    onlyKeys ["exceptions", "limits"] o
    UserAccess <$> (fromMaybe [] <$> o .:? "exceptions") <*> (fromMaybe noUserLimits <$> o .:? "limits")

instance ToJSON AppDatabaseAccess where
  toJSON a =
    object
      ( ["runtime" .= (a ^. #runtime) | a ^. #runtime /= noUserAccess]
          <> ["migration" .= (a ^. #migration) | a ^. #migration /= noUserAccess]
          <> ["monitoring" .= (a ^. #monitoring) | not (null (a ^. #monitoring))]
      )

instance FromJSON AppDatabaseAccess where
  parseJSON = withObject "access" $ \o -> do
    onlyKeys ["runtime", "migration", "monitoring"] o
    AppDatabaseAccess
      <$> (fromMaybe noUserAccess <$> o .:? "runtime")
      <*> (fromMaybe noUserAccess <$> o .:? "migration")
      <*> (fromMaybe [] <$> o .:? "monitoring")

onlyKeys :: [Text] -> Object -> Parser ()
onlyKeys allowed o = case filter (`notElem` allowed) (map Key.toText (KeyMap.keys o)) of
  [] -> pure ()
  unknown -> fail ("unknown key " <> Text.unpack (Text.intercalate ", " unknown) <> " (allowed: " <> Text.unpack (Text.intercalate ", " allowed) <> ")")

-- | Refuse an engine without users and grants (Redis), a PostgreSQL app
-- database with other than one logical database, a repeated logical database,
-- a name the engine or the server reserves, and access that does not fit the
-- engine.
validateAppDatabase :: AppDatabase -> Either Text AppDatabase
validateAppDatabase db = do
  when (db ^. #engine == Redis) (Left "app databases are not supported on Redis")
  validUserAccess (db ^. #engine) (db ^. #access . #runtime)
  validUserAccess (db ^. #engine) (db ^. #access . #migration)
  let monitoring' = db ^. #access . #monitoring
  when (db ^. #engine == ClickHouse && not (null monitoring')) (Left "monitoring roles are PostgreSQL roles")
  unless (length (nub monitoring') == length monitoring') (Left "app database repeats a monitoring role")
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
