-- | What a server's catalogs say about an app database's users and
-- databases (EP-202), parsed from the observation queries in
-- "Nagare.Database.AppDatabase.Sql" into one engine-neutral shape, and
-- classified against the declared access.
--
-- A member is absent, complete, incomplete (the declared access can be
-- reached by adding grants or by the declared revocations), or drifted
-- (something Nagare never grants is present). Drift is never repaired:
-- planning refuses it with @app-database-grant-drift@.
module Nagare.Database.AppDatabase.Catalog
  ( Catalog (..)
  , CatalogUser (..)
  , CatalogDatabase (..)
  , CatalogGrant (..)
  , CatalogSetting (..)
  , CatalogTableGrant (..)
  , CatalogRelation (..)
  , CatalogFunction (..)
  , withPostgresRelations
  , ReaderDeclaration (..)
  , ReaderSpec (..)
  , ResolvedObject (..)
  , resolveReaderObjects
  , classifyReader
  , readerHeldSelects
  , readerDatabases
  , readerSchemas
  , readerDefinerCode
  , readerInvokerCode
  , readerSettings
  , readerRoleSettings
  , LoginState (..)
  , emptyCatalog
  , parsePostgresCatalog
  , parseClickHouseCatalog
  , MemberState (..)
  , UserDeclaration (..)
  , classifyUser
  , classifyDatabase
  , exceptionGrantToken
  , grantDriftCode
  , credentialMissingCode
  , DrainObservation (..)
  , parseDrainObservation
  , comparedIdentity
  )
where

import Data.Aeson (FromJSON (parseJSON), Value, eitherDecodeStrict, withObject, (.!=), (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.List (nub, sort, (\\))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Nagare.Database.AppDatabase.Sql (DatabaseAccess (..), ResolvedObject (..), clickHouseCeilings, postgresTimeout)
import Nagare.Dsl.AppDatabase (AppDatabaseRole (..), Grant (..), GrantException, ReaderObject (..), UserAccess, UserLimits, appDatabaseDatabaseGrants, appDatabaseServerGrants, grantExceptionGrant, logicalDatabaseNameText, monitoringRoleToken, relationNameText, schemaNameText)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude

data LoginState = LoginOn | LoginOff | LoginRestricted
  deriving stock (Eq, Show)

-- | One privilege of one grantee on one target: @server@, @database@,
-- @schema:public@, @schema:\<name\>@ or @default-\<objects\>@.
data CatalogGrant = CatalogGrant
  { grantee :: !Text
  , target :: !Text
  , privilege :: !Text
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | One element of a ClickHouse user's own settings list.
data CatalogSetting = CatalogSetting
  { name :: !Text
  , value :: !(Maybe Text)
  , minimum :: !(Maybe Text)
  , maximum :: !(Maybe Text)
  , writability :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Ord, Show)

data CatalogUser = CatalogUser
  { physical :: !Text
  , login :: !LoginState
  , serverGrants :: ![Text]
  -- ^ global privileges, and an allow-listed system-table grant as
  -- @SELECT ON system.parts@
  , anomalies :: ![Text]
  -- ^ facts that are drift by themselves: an elevated attribute, a role
  -- membership, a grant option, a grant on another database
  , settings :: ![CatalogSetting]
  -- ^ ClickHouse: the user's own settings elements
  , inheritedProfiles :: ![Text]
  -- ^ ClickHouse: settings profiles the user's settings inherit
  , connectionLimit :: !(Maybe Int)
  -- ^ PostgreSQL: @rolconnlimit@, -1 for none
  , roleSettings :: ![Text]
  -- ^ PostgreSQL: server-wide role settings, as @statement_timeout=30s@
  , tableGrants :: ![CatalogTableGrant]
  -- ^ ClickHouse: table-level grants on the app's own databases, which only
  -- a reader holds (EP-206)
  }
  deriving stock (Generic, Eq, Show)

data CatalogTableGrant = CatalogTableGrant
  { database :: !Text
  , table :: !Text
  , privilege :: !Text
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | A PostgreSQL table or view, its options and the scope users' grants on it.
data CatalogRelation = CatalogRelation
  { schema :: !Text
  , name :: !Text
  , kind :: !Text
  , options :: ![Text]
  , grants :: ![(Text, Text)]
  -- ^ (grantee, privilege)
  }
  deriving stock (Generic, Eq, Show)

-- | A PostgreSQL SECURITY DEFINER function and who among PUBLIC and the scope
-- users may execute it.
data CatalogFunction = CatalogFunction
  { schema :: !Text
  , name :: !Text
  , signature :: !Text
  , executors :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

data CatalogDatabase = CatalogDatabase
  { physical :: !Text
  , owner :: !(Maybe Text)
  , grants :: ![CatalogGrant]
  , schemaOwners :: !(Map Text Text)
  , defaultAclRoles :: ![Text]
  , anomalies :: ![Text]
  , relations :: ![CatalogRelation]
  -- ^ PostgreSQL: every table and view outside the system schemas (EP-206)
  , definerFunctions :: ![CatalogFunction]
  }
  deriving stock (Generic, Eq, Show)

data Catalog = Catalog
  { users :: !(Map Text CatalogUser)
  , databases :: !(Map Text CatalogDatabase)
  , publicSystemAccess :: !Bool
  }
  deriving stock (Generic, Eq, Show)

emptyCatalog :: Catalog
emptyCatalog = Catalog Map.empty Map.empty False

-- PostgreSQL --------------------------------------------------------------

data PgGrant = PgGrant !Text !Text !Bool

instance FromJSON PgGrant where
  parseJSON = withObject "grant" $ \o -> PgGrant <$> o .: "grantee" <*> o .: "privilege" <*> o .: "grantable"

-- | The server document and, per existing database, its database document.
parsePostgresCatalog :: ByteString -> Map Text ByteString -> Either Text Catalog
parsePostgresCatalog serverBytes databaseBytes = do
  server <- decodeValue "PostgreSQL server observation" serverBytes
  first T.pack (parseEither (serverParser databaseBytes) server) >>= sequence'
  where
    sequence' (catalog, insides) = do
      parsed <- traverse (\(name, bytes) -> (name,) <$> (decodeValue "PostgreSQL database observation" bytes >>= first T.pack . parseEither insideParser)) (Map.toList insides)
      pure (catalog & #databases %~ \dbs -> foldr (\(name, extend) -> Map.adjust extend name) dbs parsed)

serverParser :: Map Text ByteString -> Value -> Parser (Catalog, Map Text ByteString)
serverParser databaseBytes = withObject "server" $ \o -> do
  -- Observations captured before EP-204 carry no connection limit or settings.
  roles <- o .: "roles" >>= traverse (withObject "role" (\r -> (,,,,,) <$> r .: "name" <*> r .: "oid" <*> r .: "login" <*> r .: "elevated" <*> r .:? "connectionLimit" .!= (-1) <*> r .:? "settings" .!= []))
  memberships <- o .: "memberships" >>= traverse (withObject "membership" (\m -> (,) <$> m .: "role" <*> m .: "member"))
  dbs <- o .: "databases" >>= traverse (withObject "database" (\d -> (,,,) <$> d .: "name" <*> d .: "oid" <*> d .: "owner" <*> d .: "grants"))
  publicAccess <- o .: "publicSystemAccess"
  foreign' <- o .: "foreignAccess"
  let userMap =
        Map.fromList
          [ ( name
            , CatalogUser
                ("postgres-role:" <> oid)
                (if canLogin then LoginOn else LoginOff)
                []
                ( map ("attribute " <>) elevated
                    <> ["membership " <> role <> " > " <> member | (role, member) <- memberships :: [(Text, Text)], name `elem` [role, member]]
                    <> ["access to database " <> db | entry <- foreign' :: [Text], Just db <- [T.stripPrefix (name <> " on ") entry]]
                )
                []
                []
                (Just connectionLimit')
                roleSettings'
                []
            )
          | (name, oid, canLogin, elevated, connectionLimit', roleSettings') <- roles :: [(Text, Text, Bool, [Text], Int, [Text])]
          ]
      databaseMap =
        Map.fromList
          [ ( name
            , CatalogDatabase
                ("postgres-database:" <> oid)
                (Just dbOwner)
                [CatalogGrant who "database" what | PgGrant who what _ <- dbGrants]
                Map.empty
                []
                ["grant option for " <> who <> " on database" | PgGrant who _ True <- dbGrants]
                []
                []
            )
          | (name, oid, dbOwner, dbGrants) <- dbs :: [(Text, Text, Text, [PgGrant])]
          ]
  pure (Catalog userMap databaseMap publicAccess, Map.restrictKeys databaseBytes (Map.keysSet databaseMap))

insideParser :: Value -> Parser (CatalogDatabase -> CatalogDatabase)
insideParser = withObject "database" $ \o -> do
  schemas <- o .: "schemas" >>= traverse (withObject "schema" (\s -> (,,) <$> s .: "name" <*> s .: "owner" <*> s .: "grants"))
  defaults <- o .: "defaultAcl" >>= traverse (withObject "default" (\d -> (,,) <$> d .: "role" <*> d .: "type" <*> d .: "grants"))
  let schemaGrants =
        [ CatalogGrant who ("schema:" <> name) what
        | (name, _, grantList) <- schemas :: [(Text, Text, [PgGrant])]
        , PgGrant who what _ <- grantList
        ]
      defaultGrants =
        [ CatalogGrant who ("default-" <> objectsOf kind) what
        | (_, kind, grantList) <- defaults :: [(Text, Text, [PgGrant])]
        , PgGrant who what _ <- grantList
        ]
      options =
        ["grant option for " <> who <> " on schema " <> name | (name, _, grantList) <- schemas, PgGrant who _ True <- grantList]
          <> ["grant option for " <> who <> " in default privileges" | (_, _, grantList) <- defaults, PgGrant who _ True <- grantList]
  pure $ \db ->
    db
      & #grants
      %~ (<> (schemaGrants <> defaultGrants))
      & #schemaOwners
      .~ Map.fromList [(name, schemaOwner) | (name, schemaOwner, _) <- schemas]
      & #defaultAclRoles
      .~ nub [role | (role, _, _) <- defaults]
      & #anomalies
      %~ (<> options)
  where
    objectsOf = \case
      "r" -> "tables"
      "S" -> "sequences"
      "f" -> "functions"
      "n" -> "schemas"
      "T" -> "types"
      other -> other

-- | Add each database's relation observation (EP-206) to a parsed catalog.
withPostgresRelations :: Map Text ByteString -> Catalog -> Either Text Catalog
withPostgresRelations documents catalog = do
  parsed <- traverse (\(db, bytes) -> (db,) <$> (decodeValue "PostgreSQL relation observation" bytes >>= first T.pack . parseEither relationsParser)) (Map.toList documents)
  pure (catalog & #databases %~ \dbs -> foldr (\(db, (relations', functions)) -> Map.adjust ((#relations .~ relations') . (#definerFunctions .~ functions)) db) dbs parsed)
  where
    relationsParser = withObject "relations" $ \o -> do
      relations' <-
        o .: "relations"
          >>= traverse
            ( withObject "relation" $ \r ->
                CatalogRelation
                  <$> r .: "schema"
                  <*> r .: "name"
                  <*> r .: "kind"
                  <*> r .: "options"
                  <*> (r .: "grants" >>= traverse (withObject "grant" (\g -> (,) <$> g .: "grantee" <*> g .: "privilege")))
            )
      functions <- o .: "definerFunctions" >>= traverse (withObject "function" (\f -> CatalogFunction <$> f .: "schema" <*> f .: "name" <*> f .: "signature" <*> f .: "executors"))
      pure (relations', functions)

-- ClickHouse --------------------------------------------------------------

data ChRow
  = ChUser !Text !Text ![Text] !Bool
  | ChGrant !Text !Text !(Maybe Text) !Bool
  | ChRole !Text !Text
  | -- | user, privilege, database, table: a plain table-level grant
    ChTableGrant !Text !Text !Text !Text
  | ChSetting !Text !(Maybe CatalogSetting) !(Maybe Text)
  | ChDatabase !Text !Text

instance FromJSON ChRow where
  parseJSON = withObject "row" $ \o ->
    (o .: "kind" :: Parser Text) >>= \case
      "user" -> do
        names <- concat <$> traverse (o .:) ["host_names", "host_names_regexp", "host_names_like"]
        ChUser <$> o .: "name" <*> o .: "physical" <*> o .: "host_ip" <*> pure (null (names :: [Text]))
      "grant" -> do
        table <- o .:? "table"
        column <- o .:? "column" :: Parser (Maybe Text)
        partial <- (/= (0 :: Int)) <$> o .: "is_partial_revoke"
        option <- (/= (0 :: Int)) <$> o .: "grant_option"
        who <- o .: "user_name"
        privilege' <- o .: "access_type"
        db <- o .:? "database"
        -- An allow-listed system-table SELECT is a server-wide grant token;
        -- whether it is declared is classification's decision.
        pure $ case (db, table) of
          (Just "system", Just t)
            | isNothing column && not partial && not option
            , token : _ <- [exceptionGrantToken e | e <- [minBound .. maxBound], grantExceptionGrant e == (privilege', "system." <> t)] ->
                ChGrant who token Nothing False
          (Just db', Just t) | isNothing column && not partial && not option -> ChTableGrant who privilege' db' t
          _ -> ChGrant who privilege' db (isJust table || isJust column || partial || option)
      "role" -> ChRole <$> o .: "user_name" <*> o .: "granted_role_name"
      "setting" -> do
        settingName <- o .:? "setting_name"
        settingElement <- traverse (\n -> CatalogSetting n <$> o .:? "value" <*> o .:? "min" <*> o .:? "max" <*> o .:? "writability") settingName
        ChSetting <$> o .: "user_name" <*> pure settingElement <*> o .:? "inherit_profile"
      "database" -> ChDatabase <$> o .: "name" <*> o .: "physical"
      other -> fail ("unknown observation row " <> T.unpack other)

-- | Tagged JSONEachRow rows; the users and databases the query asked for
-- decide which grants belong to which side.
parseClickHouseCatalog :: [Text] -> [Text] -> ByteString -> Either Text Catalog
parseClickHouseCatalog ourUsers ourDatabases bytes = do
  rows <- traverse (\line -> decodeValue "ClickHouse observation" line >>= first T.pack . parseEither parseJSON) (filter (not . BC.null) (BC.lines bytes))
  let userMap =
        Map.fromList
          [ ( name
            , CatalogUser
                ("clickhouse-user:" <> physical')
                (loginOf hosts noNames)
                [privilege' | ChGrant who privilege' Nothing False <- rows, who == name]
                (userAnomalies name)
                [element' | ChSetting who (Just element') _ <- rows, who == name]
                [profile | ChSetting who _ (Just profile) <- rows, who == name]
                Nothing
                []
                [CatalogTableGrant db table privilege' | ChTableGrant who privilege' db table <- rows, who == name, db `elem` ourDatabases]
            )
          | ChUser name physical' hosts noNames <- rows
          ]
      userAnomalies name =
        ["role " <> role | ChRole who role <- rows, who == name]
          <> ["grant option, partial revoke or table-level grant of " <> privilege' | ChGrant who privilege' _ True <- rows, who == name]
          <> ["grant of " <> privilege' <> " on database " <> db | ChGrant who privilege' (Just db) False <- rows, who == name, db `notElem` ourDatabases]
          <> ["table-level grant of " <> privilege' <> " on " <> db <> "." <> table | ChTableGrant who privilege' db table <- rows, who == name, db `notElem` ourDatabases]
      databaseMap =
        Map.fromList
          [ ( name
            , CatalogDatabase
                ("clickhouse-database:" <> physical')
                Nothing
                [CatalogGrant who "database" privilege' | ChGrant who privilege' (Just db) False <- rows, db == name]
                Map.empty
                []
                ( ["special grant of " <> privilege' <> " to " <> who | ChGrant who privilege' (Just db) True <- rows, db == name, who `notElem` ourUsers]
                    <> ["table-level grant of " <> privilege' <> " on " <> db <> "." <> table <> " to " <> who | ChTableGrant who privilege' db table <- rows, db == name, who `notElem` ourUsers]
                )
                []
                []
            )
          | ChDatabase name physical' <- rows
          ]
  pure (Catalog userMap databaseMap False)
  where
    loginOf hosts noNames
      | hosts == ["::/0"] && noNames = LoginOn
      | null hosts && noNames = LoginOff
      | otherwise = LoginRestricted

decodeValue :: Text -> ByteString -> Either Text Value
decodeValue what bytes = first (const (what <> " is malformed")) (eitherDecodeStrict (BC.strip bytes))

-- Drain (EP-205) ---------------------------------------------------------

-- | What a drain observes on the server.
data DrainObservation = DrainObservation
  { sessions :: !Int
  -- ^ ClickHouse: the blocked users' running queries; PostgreSQL: their sessions
  , unfinished :: ![Text]
  -- ^ the app's unfinished mutations, as @database.table mutation_id@
  , failed :: ![Text]
  -- ^ those with a failure reason, as @database.table mutation_id: reason@
  , identity :: !(Map Text Text)
  -- ^ the engine's server identity
  }
  deriving stock (Generic, Eq, Show)

parseDrainObservation :: Engine -> ByteString -> Either Text DrainObservation
parseDrainObservation ClickHouse bytes = do
  rows <- traverse (decodeValue "ClickHouse drain observation") (filter (not . BC.null) (BC.lines bytes))
  parsed <- first T.pack (traverse (parseEither row) rows)
  let mutations = [(database' <> "." <> table <> " " <> mutation, reason) | Right (database', table, mutation, reason) <- parsed]
  identity' <- case [fields | Left (Just fields) <- parsed] of
    [fields] -> Right fields
    _ -> Left "ClickHouse drain observation has no server identity"
  pure
    DrainObservation
      { sessions = length [() | Left Nothing <- parsed]
      , unfinished = map fst mutations
      , failed = [mutation <> ": " <> reason | (mutation, reason) <- mutations, not (T.null reason)]
      , identity = identity'
      }
  where
    -- Left Nothing: a running query; Left (Just identity): the server; Right: a mutation.
    row :: Value -> Parser (Either (Maybe (Map Text Text)) (Text, Text, Text, Text))
    row = withObject "row" $ \o ->
      (o .: "kind" :: Parser Text) >>= \case
        "session" -> pure (Left Nothing)
        "server" -> (\uuid started -> Left (Just (Map.fromList [("serverUUID", uuid), ("processStarted", started)]))) <$> o .: "uuid" <*> o .: "started"
        "mutation" -> (\d t m r -> Right (d, t, m, fromMaybe "" r)) <$> o .: "database" <*> o .: "table" <*> o .: "mutation_id" <*> o .:? "latest_fail_reason"
        other -> fail ("unknown drain observation row " <> T.unpack other)
parseDrainObservation _ bytes = do
  value <- decodeValue "PostgreSQL drain observation" bytes
  first T.pack $ flip parseEither value $ withObject "drain" $ \o -> do
    sessions' <- o .: "sessions"
    systemIdentifier <- o .: "systemIdentifier"
    started <- o .: "started"
    pure (DrainObservation sessions' [] [] (Map.fromList [("systemIdentifier", systemIdentifier), ("postmasterStarted", started)]))

-- | The identity fields drain and resume compare. ClickHouse's process start
-- time is whole seconds and may move by one between reads, so it is
-- recorded, not compared (EP-205 M1).
comparedIdentity :: Map Text Text -> Map Text Text
comparedIdentity = Map.delete "processStarted"

-- Classification ----------------------------------------------------------

-- | The refusal codes of an app-database observation. Their reasons are
-- composed here and in the adapter from names, privileges and settings, so a
-- plan refusal may print them.
grantDriftCode, credentialMissingCode :: Text
grantDriftCode = "app-database-grant-drift"
credentialMissingCode = "app-database-credential-missing"

data MemberState
  = MemberAbsent
  | MemberComplete !Text
  | -- | present, short of the declared access; the reason says what is missing
    MemberIncomplete !Text !Text
  | -- | present with access Nagare never grants
    MemberDrift !Text
  | -- | present, but its declaration cannot be served safely (code, reason): a
    -- reader whose schema exposes a write path (EP-206)
    MemberRefused !Text !Text
  deriving stock (Eq, Show)

-- | What a user member declares: its role, whether it may log in, and its
-- reviewed access as desired now and as accepted (EP-204). The accepted
-- access is what the last reviewed plan declared; an item it names that the
-- desired access no longer does is revoked or reset by review, not drift.
data UserDeclaration = UserDeclaration
  { role :: !AppDatabaseRole
  , enabled :: !Bool
  , desired :: !UserAccess
  , accepted :: !UserAccess
  }
  deriving stock (Generic, Eq, Show)

-- | The server-grant token observation reports for an exception: the bare
-- privilege for a global grant, @SELECT ON system.parts@ for a table.
exceptionGrantToken :: GrantException -> Text
exceptionGrantToken exception = case grantExceptionGrant exception of
  (privilege', "*.*") -> privilege'
  (privilege', object') -> privilege' <> " ON " <> object'

-- | The user's own logical databases are given so that access to their
-- scratch restores (@<db>_restore_<id>@, granted by @db app-database restore@)
-- is not drift; access to any other database still is.
--
-- Each item of the user's reviewed access follows one rule: equal to the
-- desired declaration is complete; equal to the accepted declaration but not
-- the desired one is incomplete (the update revokes or resets it); anything
-- else is drift; a desired item that is absent is incomplete (the update
-- restores it). A disabled user holds no exception, and keeps its limits.
classifyUser :: Engine -> UserDeclaration -> Text -> [Text] -> Catalog -> MemberState
classifyUser engine declaration name own catalog = case Map.lookup name (catalog ^. #users) of
  Nothing -> MemberAbsent
  Just user
    | not (null (anomaliesOf user)) -> MemberDrift (name <> ": " <> T.intercalate "; " (anomaliesOf user))
    | user ^. #login == LoginRestricted -> MemberDrift (name <> ": login is restricted to particular hosts")
    | not (null drifts) -> MemberDrift (name <> ": " <> T.intercalate "; " drifts)
    | user ^. #login /= wantedLogin -> MemberIncomplete (user ^. #physical) (name <> (if enabled' then ": cannot log in" else ": can still log in"))
    | not (null pending) -> MemberIncomplete (user ^. #physical) (name <> ": " <> T.intercalate "; " pending)
    | otherwise -> MemberComplete (user ^. #physical)
    where
      role' = declaration ^. #role
      enabled' = declaration ^. #enabled
      fixed = concatMap (^. #privileges) (appDatabaseServerGrants engine role')
      exceptionsOf access = map exceptionGrantToken (access ^. #exceptions)
      -- What the user should hold now, and what review may still take away.
      wantedGrants = if enabled' then fixed <> exceptionsOf (declaration ^. #desired) else []
      revocableGrants = fixed <> exceptionsOf (declaration ^. #desired) <> exceptionsOf (declaration ^. #accepted)
      wantedSettings = settingsOf (declaration ^. #desired)
      revocableSettings = settingsOf (declaration ^. #accepted)
      wantedRoleSettings = roleSettingsOf (declaration ^. #desired)
      revocableRoleSettings = roleSettingsOf (declaration ^. #accepted)
      drifts =
        ["server-wide " <> T.intercalate ", " extra | let extra = filter (`notElem` revocableGrants) (nub (user ^. #serverGrants)), not (null extra)]
          <> ["setting " <> describeSetting s | s <- user ^. #settings, s `notElem` wantedSettings, s `notElem` revocableSettings]
          <> ["inherits settings profile " <> p | p <- user ^. #inheritedProfiles]
          <> [ "connection limit " <> T.show limit
             | Just limit <- [user ^. #connectionLimit]
             , limit /= -1
             , Just limit /= declaredConnectionLimit (declaration ^. #desired)
             , Just limit /= declaredConnectionLimit (declaration ^. #accepted)
             ]
          <> ["role setting " <> entry | entry <- user ^. #roleSettings, entry `notElem` wantedRoleSettings, entry `notElem` revocableRoleSettings]
          <> ["table-level grant of " <> g ^. #privilege <> " on " <> g ^. #database <> "." <> g ^. #table | g <- user ^. #tableGrants]
      pending =
        ["lacks server-wide " <> T.intercalate ", " missing | let missing = wantedGrants \\ user ^. #serverGrants, not (null missing)]
          <> ["keeps server-wide " <> T.intercalate ", " kept | let kept = filter (`notElem` wantedGrants) (nub (user ^. #serverGrants)), not (null kept)]
          <> ["lacks setting " <> describeSetting s | s <- wantedSettings, s `notElem` user ^. #settings]
          <> ["keeps setting " <> describeSetting s | s <- user ^. #settings, s `notElem` wantedSettings]
          <> [ "connection limit is " <> T.show observed <> ", declared " <> T.show wanted
             | engine == Postgres
             , let wanted = fromMaybe (-1) (declaredConnectionLimit (declaration ^. #desired))
             , let observed = fromMaybe (-1) (user ^. #connectionLimit)
             , observed /= wanted
             ]
          <> ["lacks role setting " <> entry | entry <- wantedRoleSettings, entry `notElem` user ^. #roleSettings]
          <> ["keeps role setting " <> entry | entry <- user ^. #roleSettings, entry `notElem` wantedRoleSettings]
      wantedLogin = if enabled' then LoginOn else LoginOff
      anomaliesOf :: CatalogUser -> [Text]
      anomaliesOf user = filter (not . ownScratch) (user ^. #anomalies)
      ownScratch anomaly = case T.breakOnEnd "database " anomaly of
        (prefix, db)
          | prefix == "access to database " || ("grant of " `T.isPrefixOf` prefix && " on database " `T.isSuffixOf` prefix) ->
              or
                [ not (T.null restoreId) && T.length restoreId <= 20 && T.all (\c -> isAsciiLower c || isDigit c) restoreId
                | base <- own
                , Just restoreId <- [T.stripPrefix (base <> "_restore_") db]
                ]
        _ -> False
  where
    -- Limits apply only on their engine; validation keeps the others empty.
    settingsOf access
      | engine == ClickHouse = [CatalogSetting settingName (Just value) (Just "1") (Just value) Nothing | (settingName, value) <- clickHouseCeilings (access ^. #limits)]
      | otherwise = []
    roleSettingsOf access
      | engine == Postgres = ["statement_timeout=" <> postgresTimeout seconds | Just seconds <- [access ^. #limits . #statementTimeoutSeconds]]
      | otherwise = []
    declaredConnectionLimit access = if engine == Postgres then access ^. #limits . #connectionLimit else Nothing
    describeSetting s =
      s ^. #name
        <> maybe "" (" = " <>) (s ^. #value)
        <> maybe "" (" MIN " <>) (s ^. #minimum)
        <> maybe "" (" MAX " <>) (s ^. #maximum)
        <> maybe "" (" " <>) (s ^. #writability)

classifyDatabase :: DatabaseAccess -> Catalog -> MemberState
classifyDatabase access catalog = case Map.lookup name (catalog ^. #databases) of
  Nothing -> MemberAbsent
  Just db
    | not (null (db ^. #anomalies)) -> MemberDrift (name <> ": " <> T.intercalate "; " (db ^. #anomalies))
    | otherwise -> case access ^. #engine of
        ClickHouse -> clickhouse db
        _ -> postgres db
  where
    name = access ^. #database
    migration = access ^. #migration
    runtime = access ^. #runtime
    enabled = access ^. #enabled
    held who target' db = sort [g ^. #privilege | g <- db ^. #grants, g ^. #grantee == who, g ^. #target == target']
    declaredFor engine role target' = sort (concat [g ^. #privileges | g <- appDatabaseDatabaseGrants engine role, g ^. #objectClass == target'])
    clickhouse db
      | not (null foreign') = MemberDrift (name <> ": granted to " <> T.intercalate ", " foreign')
      | not (null (beyond migration MigrationRole <> beyond runtime RuntimeRole)) = MemberDrift (name <> ": grants beyond the declared set")
      | enabled && not (exact migration MigrationRole && exact runtime RuntimeRole) = MemberIncomplete (db ^. #physical) (name <> ": lacks declared grants")
      | not enabled && not (null (held migration "database" db <> held runtime "database" db)) = MemberIncomplete (db ^. #physical) (name <> ": keeps grants after retirement")
      | otherwise = MemberComplete (db ^. #physical)
      where
        foreign' = nub [g ^. #grantee | g <- db ^. #grants, g ^. #grantee `notElem` [migration, runtime]]
        beyond who role = held who "database" db \\ declaredFor ClickHouse role "database"
        -- A quiesced user's grants are withheld until resume (EP-205).
        exact who role
          | who `elem` access ^. #withheld = null (held who "database" db)
          | otherwise = held who "database" db == declaredFor ClickHouse role "database"
    postgres db
      | db ^. #owner /= Just migration = MemberDrift (name <> ": owned by " <> fromMaybe "nobody" (db ^. #owner))
      | not (null drifts) = MemberDrift (name <> ": " <> T.intercalate "; " (nub drifts))
      | not (null foreignSchemas) = MemberDrift (name <> ": schemas owned by another role: " <> T.intercalate ", " foreignSchemas)
      | not (null foreignDefaults) = MemberDrift (name <> ": default privileges set by " <> T.intercalate ", " foreignDefaults)
      | enabled && not complete = MemberIncomplete (db ^. #physical) (name <> ": lacks declared access")
      | not enabled && not (null runtimeDatabase) = MemberIncomplete (db ^. #physical) (name <> ": runtime can still connect")
      | otherwise = MemberComplete (db ^. #physical)
      where
        verdicts = map (postgresGrant db) (db ^. #grants)
        drifts = [reason | Left reason <- verdicts]
        fixable = or [needsFix | Right needsFix <- verdicts]
        foreignSchemas = [schema | (schema, schemaOwner) <- Map.toList (db ^. #schemaOwners), schema /= "public", schemaOwner /= migration]
        foreignDefaults = filter (/= migration) (db ^. #defaultAclRoles)
        publicOwned = Map.lookup "public" (db ^. #schemaOwners) == Just migration
        runtimeDatabase = held runtime "database" db
        complete =
          runtimeDatabase == declaredFor Postgres RuntimeRole "database"
            && all
              (\target' -> null (declaredFor Postgres RuntimeRole (classOf target') \\ held runtime target' db))
              ("schema:public" : [target' | g <- appDatabaseDatabaseGrants Postgres RuntimeRole, Just target' <- [defaultTarget (g ^. #objectClass)]])
            && publicOwned
            && not fixable
            && not (catalog ^. #publicSystemAccess)
    classOf target' = if "schema:" `T.isPrefixOf` target' then "schema" else target'
    defaultTarget objectClass = if "default-" `T.isPrefixOf` objectClass then Just objectClass else Nothing
    -- Right True: allowed but the declared access revokes it; Left: drift.
    postgresGrant db g
      | who == migration = Right False
      | who == runtime = if what `elem` declaredFor Postgres RuntimeRole (classOf target') then Right False else Left ("runtime holds " <> what <> " on " <> target')
      -- A declared reader's CONNECT and schema USAGE are judged by its own member.
      | who `elem` access ^. #readers && ((target' == "database" && what == "CONNECT") || ("schema:" `T.isPrefixOf` target' && what == "USAGE")) = Right False
      | who == "PUBLIC" && target' `elem` ["database", "schema:public"] = Right True
      | who == "PUBLIC" && target' == "default-functions" && what == "EXECUTE" = Right False
      | who == "pg_database_owner" && target' == "schema:public" && Map.lookup "public" (db ^. #schemaOwners) == Just "pg_database_owner" = Right True
      -- A declared monitoring role may read what the migration user owns:
      -- USAGE on its schemas and SELECT in its default privileges (PGMQ).
      | who `elem` map monitoringRoleToken (access ^. #monitoring)
      , Just schema <- T.stripPrefix "schema:" target'
      , Map.lookup schema (db ^. #schemaOwners) == Just migration
      , what == "USAGE" =
          Right False
      | who `elem` map monitoringRoleToken (access ^. #monitoring)
      , target' `elem` ["default-tables", "default-sequences"]
      , what == "SELECT" =
          Right False
      | otherwise = Left (who <> " holds " <> what <> " on " <> target')
      where
        who = g ^. #grantee
        what = g ^. #privilege
        target' = g ^. #target

-- Readers (EP-206) ----------------------------------------------------------

-- | A ClickHouse reader's settings: read-only and throwing on overflow,
-- fixed, and each ceiling also the default.
readerSettings :: UserLimits -> [CatalogSetting]
readerSettings limits =
  [ CatalogSetting "readonly" (Just "2") Nothing Nothing (Just "CONST")
  , CatalogSetting "result_overflow_mode" (Just "throw") Nothing Nothing (Just "CONST")
  ]
    <> [CatalogSetting settingName (Just value) (Just "1") (Just value) Nothing | (settingName, value) <- clickHouseCeilings limits]

-- | A PostgreSQL reader's role defaults, which a session may override: the
-- boundary is its grants.
readerRoleSettings :: UserLimits -> [Text]
readerRoleSettings limits = ["default_transaction_read_only=on"] <> ["statement_timeout=" <> postgresTimeout seconds | Just seconds <- [limits ^. #statementTimeoutSeconds]]

readerDefinerCode, readerInvokerCode :: Text
readerDefinerCode = "app-database-reader-definer-function"
readerInvokerCode = "app-database-reader-invoker-view"

-- | A reader's objects and limits, as one declaration names them.
data ReaderSpec = ReaderSpec
  { objects :: ![ReaderObject]
  , limits :: !UserLimits
  }
  deriving stock (Generic, Eq, Show)

-- | A reader member: whether it may log in, and its spec as desired now and
-- as accepted. An item only the accepted spec names is revoked or reset by
-- review; one neither names is drift.
data ReaderDeclaration = ReaderDeclaration
  { enabled :: !Bool
  , desired :: !ReaderSpec
  , accepted :: !(Maybe ReaderSpec)
  }
  deriving stock (Generic, Eq, Show)

-- | The declared objects the server has, and on PostgreSQL the relations it
-- does not have yet (pending: the app's migrations have not created them).
-- A schema's views are the views and materialized views observed in it.
resolveReaderObjects :: Engine -> [ReaderObject] -> Catalog -> ([ResolvedObject], [ResolvedObject])
resolveReaderObjects ClickHouse objects' _ = (nub [ResolvedObject (logicalDatabaseNameText db) Nothing (relationNameText rel) | ReaderRelation db _ rel <- objects'], [])
resolveReaderObjects _ objects' catalog = (nub (filter exists declared <> schemaViews), filter (not . exists) declared)
  where
    relationsOf db = maybe [] (^. #relations) (Map.lookup db (catalog ^. #databases))
    exists o = any (\r -> Just (r ^. #schema) == o ^. #schema && r ^. #name == o ^. #relation) (relationsOf (o ^. #database))
    declared = [ResolvedObject (logicalDatabaseNameText db) (Just (maybe "public" schemaNameText schema')) (relationNameText rel) | ReaderRelation db schema' rel <- objects']
    schemaViews =
      [ ResolvedObject (logicalDatabaseNameText db) (Just (schemaNameText schema')) (r ^. #name)
      | ReaderSchemaViews db schema' <- objects'
      , r <- relationsOf (logicalDatabaseNameText db)
      , r ^. #schema == schemaNameText schema'
      , r ^. #kind `elem` ["v", "m"]
      ]

-- | The databases a reader's objects live in.
readerDatabases :: [ReaderObject] -> [Text]
readerDatabases objects' = nub [logicalDatabaseNameText (o ^. #database) | o <- objects']

-- | PostgreSQL: the schemas a reader gets USAGE on, as (database, schema),
-- among those that exist. A schema the app's migrations have not created
-- yet is pending with its objects; ClickHouse has none.
readerSchemas :: Engine -> [ReaderObject] -> Catalog -> [(Text, Text)]
readerSchemas ClickHouse _ _ = []
readerSchemas _ objects' catalog =
  nub
    [ (db, sc)
    | (db, sc) <-
        [(logicalDatabaseNameText db, maybe "public" schemaNameText schema') | ReaderRelation db schema' _ <- objects']
          <> [(logicalDatabaseNameText db, schemaNameText schema') | ReaderSchemaViews db schema' <- objects']
    , Just cdb <- [Map.lookup db (catalog ^. #databases)]
    , Map.member sc (cdb ^. #schemaOwners)
    ]

-- | The objects a reader holds SELECT on.
readerHeldSelects :: Engine -> Text -> Catalog -> [ResolvedObject]
readerHeldSelects engine name catalog
  | engine == ClickHouse = [ResolvedObject (g ^. #database) Nothing (g ^. #table) | Just u <- [Map.lookup name (catalog ^. #users)], g <- u ^. #tableGrants, g ^. #privilege == "SELECT"]
  | otherwise =
      [ ResolvedObject db (Just (r ^. #schema)) (r ^. #name)
      | (db, cdb) <- Map.toList (catalog ^. #databases)
      , r <- cdb ^. #relations
      , (who, "SELECT") <- r ^. #grants
      , who == name
      ]

-- | Classify a reader, and name its pending objects. The boundary is its
-- grants: SELECT on each declared object, and on PostgreSQL CONNECT and
-- schema USAGE; its limits follow EP-204's rule. A PostgreSQL schema that
-- gives it a SECURITY DEFINER function, or a declared security_invoker view,
-- refuses (IR-33 AC-9).
classifyReader :: Engine -> ReaderDeclaration -> Text -> Catalog -> (MemberState, [ResolvedObject])
classifyReader engine declaration name catalog = case Map.lookup name (catalog ^. #users) of
  Nothing -> (MemberAbsent, pending)
  Just user
    | Just refusal <- refusalOf -> (refusal, pending)
    | not (null (user ^. #anomalies)) -> (MemberDrift (name <> ": " <> T.intercalate "; " (user ^. #anomalies)), pending)
    | user ^. #login == LoginRestricted -> (MemberDrift (name <> ": login is restricted to particular hosts"), pending)
    | not (null (drifts user)) -> (MemberDrift (name <> ": " <> T.intercalate "; " (drifts user)), pending)
    | user ^. #login /= (if enabled' then LoginOn else LoginOff) -> (MemberIncomplete (user ^. #physical) (name <> (if enabled' then ": cannot log in" else ": can still log in")), pending)
    | not (null (fixes user)) -> (MemberIncomplete (user ^. #physical) (name <> ": " <> T.intercalate "; " (fixes user)), pending)
    | otherwise -> (MemberComplete (user ^. #physical), pending)
  where
    enabled' = declaration ^. #enabled
    desiredSpec = declaration ^. #desired
    acceptedSpec = declaration ^. #accepted
    (present, pending) = resolveReaderObjects engine (desiredSpec ^. #objects) catalog
    acceptedObjects = maybe [] (\spec -> fst (resolveReaderObjects engine (spec ^. #objects) catalog)) acceptedSpec
    wanted = if enabled' then present else []
    render o = maybe (o ^. #database) id (o ^. #schema) <> "." <> o ^. #relation
    held =
      if engine == ClickHouse
        then [(ResolvedObject (g ^. #database) Nothing (g ^. #table), g ^. #privilege) | Just u <- [Map.lookup name (catalog ^. #users)], g <- u ^. #tableGrants]
        else
          [ (ResolvedObject db (Just (r ^. #schema)) (r ^. #name), privilege')
          | (db, cdb) <- Map.toList (catalog ^. #databases)
          , r <- cdb ^. #relations
          , (who, privilege') <- r ^. #grants
          , who == name
          ]
    heldSelects = [o | (o, "SELECT") <- held]
    schemasOf spec = readerSchemas engine (spec ^. #objects) catalog
    databasesOf spec = readerDatabases (spec ^. #objects)
    desiredSchemas = schemasOf desiredSpec
    revocableSchemas = maybe [] schemasOf acceptedSpec
    -- PostgreSQL database and schema grants of the reader.
    heldDatabase = [(db, g ^. #privilege) | (db, cdb) <- Map.toList (catalog ^. #databases), g <- cdb ^. #grants, g ^. #grantee == name, g ^. #target == "database"]
    heldSchemas = [((db, T.drop 7 (g ^. #target)), g ^. #privilege) | (db, cdb) <- Map.toList (catalog ^. #databases), g <- cdb ^. #grants, g ^. #grantee == name, "schema:" `T.isPrefixOf` (g ^. #target)]
    renderSchema (db, sc) = db <> "." <> sc
    wantedSettings = if engine == ClickHouse then readerSettings (desiredSpec ^. #limits) else []
    revocableSettings = if engine == ClickHouse then maybe [] (readerSettings . (^. #limits)) acceptedSpec else []
    wantedRoleSettings = if engine == ClickHouse then [] else readerRoleSettings (desiredSpec ^. #limits)
    revocableRoleSettings = if engine == ClickHouse then [] else maybe [] (readerRoleSettings . (^. #limits)) acceptedSpec
    desiredLimit = desiredSpec ^. #limits . #connectionLimit
    acceptedLimit = acceptedSpec >>= (^. #limits . #connectionLimit)
    drifts user =
      ["holds " <> p' <> " on " <> render o | (o, p') <- held, p' /= "SELECT"]
        <> ["holds SELECT on undeclared " <> render o | o <- heldSelects, o `notElem` present, o `notElem` acceptedObjects]
        <> ["server-wide " <> T.intercalate ", " (user ^. #serverGrants) | not (null (user ^. #serverGrants))]
        <> ["setting " <> describe' c | c <- user ^. #settings, c `notElem` wantedSettings, c `notElem` revocableSettings]
        <> ["inherits settings profile " <> p' | p' <- user ^. #inheritedProfiles]
        <> [ "connection limit " <> T.show limit
           | engine /= ClickHouse
           , Just limit <- [user ^. #connectionLimit]
           , limit /= -1
           , Just limit /= desiredLimit
           , Just limit /= acceptedLimit
           ]
        <> ["role setting " <> e | e <- user ^. #roleSettings, e `notElem` wantedRoleSettings, e `notElem` revocableRoleSettings]
        <> ["holds " <> p' <> " on database " <> db | (db, p') <- heldDatabase, p' /= "CONNECT" || db `notElem` (databasesOf desiredSpec <> maybe [] databasesOf acceptedSpec)]
        <> ["holds " <> p' <> " on schema " <> renderSchema sc | (sc, p') <- heldSchemas, p' /= "USAGE" || sc `notElem` (desiredSchemas <> revocableSchemas)]
    fixes user =
      ["lacks SELECT on " <> render o | o <- wanted, o `notElem` heldSelects]
        <> ["keeps SELECT on " <> render o | o <- heldSelects, o `notElem` wanted]
        <> ["lacks setting " <> describe' c | c <- wantedSettings, c `notElem` user ^. #settings]
        <> ["keeps setting " <> describe' c | c <- user ^. #settings, c `notElem` wantedSettings]
        <> [ "connection limit is " <> T.show observed <> ", declared " <> T.show want
           | engine /= ClickHouse
           , let want = fromMaybe (-1) desiredLimit
           , let observed = fromMaybe (-1) (user ^. #connectionLimit)
           , observed /= want
           ]
        <> ["lacks role setting " <> e | e <- wantedRoleSettings, e `notElem` user ^. #roleSettings]
        <> ["keeps role setting " <> e | e <- user ^. #roleSettings, e `notElem` wantedRoleSettings]
        <> ( if engine == ClickHouse
               then []
               else
                 ["lacks CONNECT on database " <> db | enabled', db <- databasesOf desiredSpec, (db, "CONNECT") `notElem` heldDatabase]
                   <> ["keeps CONNECT on database " <> db | (db, _) <- heldDatabase, not enabled' || db `notElem` databasesOf desiredSpec]
                   <> ["lacks USAGE on schema " <> renderSchema sc | enabled', sc <- desiredSchemas, (sc, "USAGE") `notElem` heldSchemas]
                   <> ["keeps USAGE on schema " <> renderSchema sc | (sc, _) <- heldSchemas, not enabled' || sc `notElem` desiredSchemas]
           )
    refusalOf
      | engine == ClickHouse || not enabled' = Nothing
      | not (null definers) = Just (MemberRefused readerDefinerCode (name <> ": " <> T.intercalate ", " definers <> " is SECURITY DEFINER and executable by the reader; revoke EXECUTE on it from PUBLIC in a migration"))
      | not (null invokers) = Just (MemberRefused readerInvokerCode (name <> ": " <> T.intercalate ", " invokers <> " is a security_invoker view, which would need the reader to hold its base tables"))
      | otherwise = Nothing
    definers =
      [ f ^. #schema <> "." <> f ^. #name <> "(" <> f ^. #signature <> ")"
      | db <- databasesOf desiredSpec
      , Just cdb <- [Map.lookup db (catalog ^. #databases)]
      , f <- cdb ^. #definerFunctions
      , (db, f ^. #schema) `elem` desiredSchemas
      , "PUBLIC" `elem` f ^. #executors || name `elem` f ^. #executors
      ]
    invokers =
      [ render o
      | o <- present
      , Just cdb <- [Map.lookup (o ^. #database) (catalog ^. #databases)]
      , r <- cdb ^. #relations
      , Just (r ^. #schema) == o ^. #schema && r ^. #name == o ^. #relation
      , any (`elem` ["security_invoker=true", "security_invoker=on", "security_invoker=1"]) (r ^. #options)
      ]
    describe' c =
      c ^. #name
        <> maybe "" (" = " <>) (c ^. #value)
        <> maybe "" (" MIN " <>) (c ^. #minimum)
        <> maybe "" (" MAX " <>) (c ^. #maximum)
        <> maybe "" (" " <>) (c ^. #writability)
