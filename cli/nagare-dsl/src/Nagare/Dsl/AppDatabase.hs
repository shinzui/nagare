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

    -- * Privileges inside the app's own databases (EP-208)
  , ClickHousePrivilege
  , mkClickHousePrivilege
  , clickHousePrivilegeText
  , OwnPrivileges (..)
  , DatabasePrivileges (..)
  , noOwnPrivileges
  , noDatabasePrivileges
  , runtimeOwnsObjects
  , validDatabasePrivileges

    -- * Readers (EP-206)
  , ReaderName
  , mkReaderName
  , readerNameText
  , SchemaName
  , mkSchemaName
  , schemaNameText
  , RelationName
  , mkRelationName
  , relationNameText
  , ReaderObject (..)
  , AppDatabaseReader (..)
  , ReaderGrant (..)
  , UserExtension (..)
  , noUserExtension
  , appDatabaseReader
  , defaultReaderLimits
  , parseAppDatabaseRole
  , appDatabaseRoles

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
  , appDatabaseServerRevokedGrants
  , appDatabaseDatabaseGrants
  )
where

import Data.Aeson (FromJSON (parseJSON), Object, ToJSON (toJSON), Value (Object, String), object, withObject, withText, (.:), (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (for_, traverse_)
import Data.Generics.Labels ()
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as Text
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (AppDatabaseName, DatabaseName, Namespace, ReaderName, ServiceName, appDatabaseNameText, databaseNameText, mkAppDatabaseName, mkReaderName, mkServiceName, readerNameText, serviceNameText)
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
  , maxResultRows :: !(Maybe Int)
  , maxResultBytes :: !(Maybe Int)
  , maxThreads :: !(Maybe Int)
  -- ^ the last three are ClickHouse ceilings a reader must set (EP-206)
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
  , readers :: ![AppDatabaseReader]
  -- ^ named read-only users over declared objects (EP-206)
  , privileges :: !DatabasePrivileges
  -- ^ privileges inside the app's own databases (EP-208)
  , owners :: ![ServiceName]
  -- ^ workloads of the namespace that bind the migration credential (EP-208)
  }
  deriving stock (Generic, Eq, Show)

-- | A ClickHouse privilege granted on each of the app's own databases
-- (EP-208): letters and single spaces, at most 48 characters, never @ALL@
-- or @NONE@. The server's own privilege tree decides what it stands for, so
-- Nagare ships no list. Constructor hidden; use 'mkClickHousePrivilege'.
newtype ClickHousePrivilege = ClickHousePrivilege Text
  deriving stock (Eq, Ord, Show)

mkClickHousePrivilege :: Text -> Either Text ClickHousePrivilege
mkClickHousePrivilege t
  | Text.null t || Text.length t > 48 = Left ("ClickHouse privilege is 1 to 48 characters: " <> t)
  | not (Text.all (\c -> isAsciiLetter c || c == ' ') t) || Text.words t /= Text.splitOn " " t =
      Left ("ClickHouse privilege is words of letters separated by single spaces: " <> t)
  | Text.toUpper t `elem` ["ALL", "NONE"] = Left ("ClickHouse privilege must name what it grants, not " <> t)
  | otherwise = Right (ClickHousePrivilege t)
  where
    isAsciiLetter c = isAsciiLower c || isAsciiUpper c

clickHousePrivilegeText :: ClickHousePrivilege -> Text
clickHousePrivilegeText (ClickHousePrivilege t) = t

-- | What one user may do inside the app's own databases beyond the fixed
-- grant set. On PostgreSQL the runtime may create in named schemas
-- (@createIn@) and create schemas of its own (@createSchemas@); on
-- ClickHouse either user takes privileges granted @ON \<db\>.*@.
data OwnPrivileges = OwnPrivileges
  { createIn :: ![SchemaName]
  , createSchemas :: !Bool
  , clickhouse :: ![ClickHousePrivilege]
  }
  deriving stock (Generic, Eq, Ord, Show)

data DatabasePrivileges = DatabasePrivileges
  { runtime :: !OwnPrivileges
  , migration :: !OwnPrivileges
  }
  deriving stock (Generic, Eq, Ord, Show)

noOwnPrivileges :: OwnPrivileges
noOwnPrivileges = OwnPrivileges [] False []

noDatabasePrivileges :: DatabasePrivileges
noDatabasePrivileges = DatabasePrivileges noOwnPrivileges noOwnPrivileges

-- | Whether the runtime may own objects, which makes the migration user a
-- member of the runtime role so backups and migrations reach them.
runtimeOwnsObjects :: DatabasePrivileges -> Bool
runtimeOwnsObjects p = not (null (p ^. #runtime . #createIn)) || p ^. #runtime . #createSchemas

-- | The privileges fit the engine: @createIn@ and @createSchemas@ are
-- PostgreSQL and the runtime's only (the migration user owns the database),
-- @clickhouse@ is ClickHouse, nothing repeats, and no ClickHouse token is
-- already one of that user's fixed grants.
validDatabasePrivileges :: Engine -> DatabasePrivileges -> Either Text ()
validDatabasePrivileges engine' p = do
  let migration' = p ^. #migration
  for_ [("runtime", RuntimeRole, p ^. #runtime), ("migration", MigrationRole, migration')] $ \(who, role, own) -> do
    let schemas = own ^. #createIn
        tokens = map clickHousePrivilegeText (own ^. #clickhouse)
    unless (length (nub schemas) == length schemas) (Left ("the " <> who <> " privileges repeat a schema"))
    unless (length (nub tokens) == length tokens) (Left ("the " <> who <> " privileges repeat a ClickHouse privilege"))
    case engine' of
      ClickHouse -> do
        unless (null schemas && not (own ^. #createSchemas)) (Left "createIn and createSchemas are PostgreSQL privileges")
        case filter (`elem` concatMap (^. #privileges) (appDatabaseDatabaseGrants ClickHouse role)) tokens of
          [] -> pure ()
          fixed : _ -> Left ("the " <> who <> " user already holds " <> fixed <> " on its databases")
      _ -> unless (null tokens) (Left "clickhouse privileges are ClickHouse privileges")
  unless (null (migration' ^. #createIn) && not (migration' ^. #createSchemas)) (Left "the migration user owns the database; createIn and createSchemas are the runtime's")

-- | A PostgreSQL schema or a table or view name, @[a-z][a-z0-9_]{0,62}@, so
-- it needs no quoting or escaping in SQL.
newtype SchemaName = SchemaName Text
  deriving stock (Eq, Ord, Show)

newtype RelationName = RelationName Text
  deriving stock (Eq, Ord, Show)

identifier :: Text -> Text -> Either Text Text
identifier what t
  | Text.null t || Text.length t > 63 = Left (what <> " is 1 to 63 characters: " <> t)
  | not (startsWithLetter t) || not (Text.all (\c -> isAsciiLower c || isDigit c || c == '_') t) =
      Left (what <> " is a lowercase letter then letters, digits or underscores: " <> t)
  | otherwise = Right t

mkSchemaName :: Text -> Either Text SchemaName
mkSchemaName = fmap SchemaName . identifier "schema name"

schemaNameText :: SchemaName -> Text
schemaNameText (SchemaName t) = t

mkRelationName :: Text -> Either Text RelationName
mkRelationName = fmap RelationName . identifier "table or view name"

relationNameText :: RelationName -> Text
relationNameText (RelationName t) = t

-- | What a reader may @SELECT@: one table or view, or on PostgreSQL every view
-- of a schema as observed at plan time. A PostgreSQL relation without a
-- schema is in @public@; ClickHouse has none.
data ReaderObject
  = ReaderRelation {database :: !LogicalDatabaseName, schema :: !(Maybe SchemaName), relation :: !RelationName}
  | ReaderSchemaViews {database :: !LogicalDatabaseName, schemaViews :: !SchemaName}
  deriving stock (Generic, Eq, Ord, Show)

-- | A declared reader: its objects, its limits (on ClickHouse all five of
-- 'defaultReaderLimits'' ceilings, on PostgreSQL at least a connection
-- limit), the applications or workers of the app database's namespace that
-- may bind it, and whether it is retired (its login and grants off, its
-- Secret and declaration kept).
data AppDatabaseReader = AppDatabaseReader
  { name :: !ReaderName
  , objects :: !(NonEmpty ReaderObject)
  , limits :: !UserLimits
  , consumers :: ![ServiceName]
  , retired :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | What a reader's user spec carries beyond 'UserAccess'.
data ReaderGrant = ReaderGrant
  { objects :: !(NonEmpty ReaderObject)
  , consumers :: ![ServiceName]
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | A user spec's reviewed extension: EP-204's access, for a reader its
-- objects and consumers, and for the migration user the workloads that bind
-- its credential (EP-208).
data UserExtension = UserExtension
  { access :: !UserAccess
  , reader :: !(Maybe ReaderGrant)
  , owners :: ![ServiceName]
  }
  deriving stock (Generic, Eq, Ord, Show)

noUserExtension :: UserExtension
noUserExtension = UserExtension noUserAccess Nothing []

-- | Kansoku's reader profile: 30 s, 512 MiB, 10,000 rows, 10 MiB and 4
-- threads on ClickHouse; 5 connections and a 30 s statement timeout on
-- PostgreSQL. Use the engine's half.
defaultReaderLimits :: Engine -> UserLimits
defaultReaderLimits ClickHouse =
  noUserLimits
    { maxExecutionSeconds = Just 30
    , maxMemoryBytes = Just 536870912
    , maxResultRows = Just 10000
    , maxResultBytes = Just 10485760
    , maxThreads = Just 4
    }
defaultReaderLimits _ = noUserLimits {connectionLimit = Just 5, statementTimeoutSeconds = Just 30}

appDatabaseReader :: AppDatabase -> ReaderName -> Maybe AppDatabaseReader
appDatabaseReader db reader = find ((== reader) . (^. #name)) (db ^. #access . #readers)

noUserLimits :: UserLimits
noUserLimits = UserLimits Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

noUserAccess :: UserAccess
noUserAccess = UserAccess [] noUserLimits

noAppDatabaseAccess :: AppDatabaseAccess
noAppDatabaseAccess = AppDatabaseAccess noUserAccess noUserAccess [] [] noDatabasePrivileges []

appDatabaseUserAccess :: AppDatabase -> AppDatabaseRole -> UserAccess
appDatabaseUserAccess db RuntimeRole = db ^. #access . #runtime
appDatabaseUserAccess db MigrationRole = db ^. #access . #migration
appDatabaseUserAccess db (ReaderRole reader) = maybe noUserAccess (\r -> UserAccess [] (r ^. #limits)) (appDatabaseReader db reader)

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
      unless (all (isNothing . snd) [entry | entry@(n, _) <- limitList, n `notElem` postgresLimits]) (Left "maxMemoryBytes, maxExecutionSeconds, maxConcurrentQueries, maxResultRows, maxResultBytes and maxThreads are ClickHouse limits")
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
      , ("maxResultRows", l ^. #maxResultRows)
      , ("maxResultBytes", l ^. #maxResultBytes)
      , ("maxThreads", l ^. #maxThreads)
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
              , ("maxResultRows", l ^. #maxResultRows)
              , ("maxResultBytes", l ^. #maxResultBytes)
              , ("maxThreads", l ^. #maxThreads)
              ]
          ]
      )

instance FromJSON UserLimits where
  parseJSON = withObject "limits" $ \o -> do
    onlyKeys ["maxMemoryBytes", "maxExecutionSeconds", "maxConcurrentQueries", "connectionLimit", "statementTimeoutSeconds", "maxResultRows", "maxResultBytes", "maxThreads"] o
    UserLimits <$> o .:? "maxMemoryBytes" <*> o .:? "maxExecutionSeconds" <*> o .:? "maxConcurrentQueries" <*> o .:? "connectionLimit" <*> o .:? "statementTimeoutSeconds" <*> o .:? "maxResultRows" <*> o .:? "maxResultBytes" <*> o .:? "maxThreads"

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
          <> ["readers" .= (a ^. #readers) | not (null (a ^. #readers))]
          <> ["privileges" .= (a ^. #privileges) | a ^. #privileges /= noDatabasePrivileges]
          <> ["owners" .= map serviceNameText (a ^. #owners) | not (null (a ^. #owners))]
      )

instance FromJSON AppDatabaseAccess where
  parseJSON = withObject "access" $ \o -> do
    onlyKeys ["runtime", "migration", "monitoring", "readers", "privileges", "owners"] o
    AppDatabaseAccess
      <$> (fromMaybe noUserAccess <$> o .:? "runtime")
      <*> (fromMaybe noUserAccess <$> o .:? "migration")
      <*> (fromMaybe [] <$> o .:? "monitoring")
      <*> (fromMaybe [] <$> o .:? "readers")
      <*> (fromMaybe noDatabasePrivileges <$> o .:? "privileges")
      <*> (fromMaybe [] <$> o .:? "owners" >>= traverse (checked mkServiceName))

instance ToJSON ClickHousePrivilege where toJSON = String . clickHousePrivilegeText

instance FromJSON ClickHousePrivilege where
  parseJSON = withText "ClickHouse privilege" (checked mkClickHousePrivilege)

instance ToJSON OwnPrivileges where
  toJSON p =
    object
      ( ["createIn" .= map schemaNameText (p ^. #createIn) | not (null (p ^. #createIn))]
          <> ["createSchemas" .= True | p ^. #createSchemas]
          <> ["clickhouse" .= (p ^. #clickhouse) | not (null (p ^. #clickhouse))]
      )

instance FromJSON OwnPrivileges where
  parseJSON = withObject "own-database privileges" $ \o -> do
    onlyKeys ["createIn", "createSchemas", "clickhouse"] o
    OwnPrivileges
      <$> (fromMaybe [] <$> o .:? "createIn" >>= traverse (checked mkSchemaName))
      <*> (fromMaybe False <$> o .:? "createSchemas")
      <*> (fromMaybe [] <$> o .:? "clickhouse")

instance ToJSON DatabasePrivileges where
  toJSON p =
    object
      ( ["runtime" .= (p ^. #runtime) | p ^. #runtime /= noOwnPrivileges]
          <> ["migration" .= (p ^. #migration) | p ^. #migration /= noOwnPrivileges]
      )

instance FromJSON DatabasePrivileges where
  parseJSON = withObject "database privileges" $ \o -> do
    onlyKeys ["runtime", "migration"] o
    DatabasePrivileges <$> (fromMaybe noOwnPrivileges <$> o .:? "runtime") <*> (fromMaybe noOwnPrivileges <$> o .:? "migration")

instance ToJSON ReaderObject where
  toJSON = \case
    ReaderRelation db schema' relation' ->
      object (["database" .= logicalDatabaseNameText db, "relation" .= relationNameText relation'] <> maybe [] (\sc -> ["schema" .= schemaNameText sc]) schema')
    ReaderSchemaViews db schema' -> object ["database" .= logicalDatabaseNameText db, "schemaViews" .= schemaNameText schema']

instance FromJSON ReaderObject where
  parseJSON = withObject "reader object" $ \o -> do
    onlyKeys ["database", "schema", "relation", "schemaViews"] o
    db <- o .: "database" >>= checked mkLogicalDatabaseName
    relation' <- o .:? "relation"
    schemaViews' <- o .:? "schemaViews"
    case (relation', schemaViews') of
      (Just r, Nothing) -> ReaderRelation db <$> (o .:? "schema" >>= traverse (checked mkSchemaName)) <*> checked mkRelationName r
      (Nothing, Just v) -> do
        schema' <- o .:? "schema" :: Parser (Maybe Text)
        unless (isNothing schema') (fail "a schemaViews object names its schema there")
        ReaderSchemaViews db <$> checked mkSchemaName v
      _ -> fail "a reader object names exactly one of relation and schemaViews"

instance ToJSON AppDatabaseReader where
  toJSON r =
    object
      ( [ "name" .= readerNameText (r ^. #name)
        , "objects" .= NE.toList (r ^. #objects)
        , "limits" .= (r ^. #limits)
        ]
          <> ["consumers" .= map serviceNameText (r ^. #consumers) | not (null (r ^. #consumers))]
          <> ["retired" .= True | r ^. #retired]
      )

instance FromJSON AppDatabaseReader where
  parseJSON = withObject "reader" $ \o -> do
    onlyKeys ["name", "objects", "limits", "consumers", "retired"] o
    name' <- o .: "name" >>= checked mkReaderName
    objects' <- o .: "objects" >>= maybe (fail "a reader declares at least one object") pure . NE.nonEmpty
    limits' <- fromMaybe noUserLimits <$> o .:? "limits"
    consumers' <- fromMaybe [] <$> o .:? "consumers" >>= traverse (checked mkServiceName)
    retired' <- fromMaybe False <$> o .:? "retired"
    pure (AppDatabaseReader name' objects' limits' consumers' retired')

instance ToJSON ReaderGrant where
  toJSON g = object (["objects" .= NE.toList (g ^. #objects)] <> ["consumers" .= map serviceNameText (g ^. #consumers) | not (null (g ^. #consumers))])

instance FromJSON ReaderGrant where
  parseJSON = withObject "reader grant" $ \o -> do
    onlyKeys ["objects", "consumers"] o
    objects' <- o .: "objects" >>= maybe (fail "a reader grant has at least one object") pure . NE.nonEmpty
    consumers' <- fromMaybe [] <$> o .:? "consumers" >>= traverse (checked mkServiceName)
    pure (ReaderGrant objects' consumers')

-- | Written as EP-204's access object, with a @reader@ key for a reader and
-- an @owners@ key for a migration user with owner bindings, so a user without
-- them keeps its EP-204 bytes.
instance ToJSON UserExtension where
  toJSON e = case toJSON (e ^. #access) of
    Object fields ->
      Object
        ( maybe id (KeyMap.insert "reader" . toJSON) (e ^. #reader)
            . (if null (e ^. #owners) then id else KeyMap.insert "owners" (toJSON (map serviceNameText (e ^. #owners))))
            $ fields
        )
    value -> value

instance FromJSON UserExtension where
  parseJSON = withObject "user extension" $ \o ->
    UserExtension
      <$> parseJSON (Object (KeyMap.delete "owners" (KeyMap.delete "reader" o)))
      <*> o .:? "reader"
      <*> (fromMaybe [] <$> o .:? "owners" >>= traverse (checked mkServiceName))

checked :: (Text -> Either Text a) -> Text -> Parser a
checked make = either (fail . Text.unpack) pure . make

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
  traverse_ (validReader db) (db ^. #access . #readers)
  validDatabasePrivileges (db ^. #engine) (db ^. #access . #privileges)
  let owners' = db ^. #access . #owners
  unless (length (nub owners') == length owners') (Left "app database repeats an owner")
  let readerNames = map (^. #name) (db ^. #access . #readers)
  unless (length (nub readerNames) == length readerNames) (Left "app database repeats a reader")
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

-- | A reader reads only the app's own databases, through objects that fit
-- the engine, under every ceiling its engine requires (EP-206, IR-33 AC-1).
validReader :: AppDatabase -> AppDatabaseReader -> Either Text ()
validReader db reader = do
  let who = "reader " <> readerNameText (reader ^. #name) <> ": "
      objects' = NE.toList (reader ^. #objects)
      limits' = reader ^. #limits
  case [o ^. #database | o <- objects', o ^. #database `notElem` NE.toList (db ^. #logicalDatabases)] of
    [] -> pure ()
    outside : _ -> Left (who <> "object outside the app's own databases: " <> logicalDatabaseNameText outside)
  unless (length (nub objects') == length objects') (Left (who <> "repeats an object"))
  first (who <>) (validUserAccess (db ^. #engine) (UserAccess [] limits'))
  case db ^. #engine of
    ClickHouse -> do
      unless (all (\case ReaderRelation _ Nothing _ -> True; _ -> False) objects') (Left (who <> "ClickHouse objects are tables or views without a schema"))
      let missing = [n | (n, Nothing) <- [("maxExecutionSeconds", limits' ^. #maxExecutionSeconds), ("maxMemoryBytes", limits' ^. #maxMemoryBytes), ("maxResultRows", limits' ^. #maxResultRows), ("maxResultBytes", limits' ^. #maxResultBytes), ("maxThreads", limits' ^. #maxThreads)]]
      unless (null missing) (Left (who <> "a ClickHouse reader sets every ceiling; missing " <> Text.intercalate ", " missing))
    _ -> when (isNothing (limits' ^. #connectionLimit)) (Left (who <> "a PostgreSQL reader sets a connection limit"))

-- | The server's initial database, which the server render creates as
-- @POSTGRES_DB@ (hyphens become underscores).
serverInitialDatabase :: DatabaseName -> Text
serverInitialDatabase = Text.replace "-" "_" . databaseNameText

-- | An app database's users: its runtime and migration users, and each
-- declared reader (EP-206).
data AppDatabaseRole = RuntimeRole | MigrationRole | ReaderRole !ReaderName
  deriving stock (Eq, Ord, Show)

-- | @runtime@, @migration@ or @reader-\<name\>@: the role token of a user
-- spec and of a credential Secret's labels.
appDatabaseRoleToken :: AppDatabaseRole -> Text
appDatabaseRoleToken RuntimeRole = "runtime"
appDatabaseRoleToken MigrationRole = "migration"
appDatabaseRoleToken (ReaderRole reader) = "reader-" <> readerNameText reader

-- | The only parser of a role token.
parseAppDatabaseRole :: Text -> Maybe AppDatabaseRole
parseAppDatabaseRole = \case
  "runtime" -> Just RuntimeRole
  "migration" -> Just MigrationRole
  token -> ReaderRole <$> (Text.stripPrefix "reader-" token >>= either (const Nothing) Just . mkReaderName)

-- | Every user an app database declares: runtime, migration, then its readers.
appDatabaseRoles :: AppDatabase -> [AppDatabaseRole]
appDatabaseRoles db = [RuntimeRole, MigrationRole] <> [ReaderRole (reader ^. #name) | reader <- db ^. #access . #readers]

-- | @kansoku-pg@ runtime → @kansoku_pg_runtime@; reader @dash@ →
-- @kansoku_pg_reader_dash@.
appDatabaseUser :: AppDatabaseName -> AppDatabaseRole -> Text
appDatabaseUser n r = Text.replace "-" "_" (appDatabaseNameText n) <> "_" <> Text.replace "-" "_" (appDatabaseRoleToken r)

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

-- | Privileges the engine adds to a user by itself from the persisted form of
-- a fixed grant, so every user-access block revokes them and observing them is
-- pending, never drift. ClickHouse without @enable_read_write_grants@ stores
-- @WRITE ON FILE@ as the legacy @FILE@, which reloads as READ and WRITE (BUG-7).
appDatabaseServerRevokedGrants :: Engine -> AppDatabaseRole -> [Grant]
appDatabaseServerRevokedGrants ClickHouse MigrationRole = [Grant "file" ["READ"]]
appDatabaseServerRevokedGrants _ _ = []

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
-- A reader's grants are its declared objects, rendered per object (EP-206).
appDatabaseDatabaseGrants _ (ReaderRole _) = []
