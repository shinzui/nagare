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
  , LoginState (..)
  , emptyCatalog
  , parsePostgresCatalog
  , parseClickHouseCatalog
  , MemberState (..)
  , classifyUser
  , classifyDatabase
  )
where

import Data.Aeson (FromJSON (parseJSON), Value, eitherDecodeStrict, withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.List (nub, sort, (\\))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Database.AppDatabase.Sql (DatabaseAccess (..))
import Nagare.Dsl.AppDatabase (AppDatabaseRole (..), Grant (..), appDatabaseDatabaseGrants, appDatabaseServerGrants)
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

data CatalogUser = CatalogUser
  { physical :: !Text
  , login :: !LoginState
  , serverGrants :: ![Text]
  , anomalies :: ![Text]
  -- ^ facts that are drift by themselves: an elevated attribute, a role
  -- membership, a grant option, a grant on another database
  }
  deriving stock (Generic, Eq, Show)

data CatalogDatabase = CatalogDatabase
  { physical :: !Text
  , owner :: !(Maybe Text)
  , grants :: ![CatalogGrant]
  , schemaOwners :: !(Map Text Text)
  , defaultAclRoles :: ![Text]
  , anomalies :: ![Text]
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
  roles <- o .: "roles" >>= traverse (withObject "role" (\r -> (,,,) <$> r .: "name" <*> r .: "oid" <*> r .: "login" <*> r .: "elevated"))
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
            )
          | (name, oid, canLogin, elevated) <- roles :: [(Text, Text, Bool, [Text])]
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

-- ClickHouse --------------------------------------------------------------

data ChRow
  = ChUser !Text !Text ![Text] !Bool
  | ChGrant !Text !Text !(Maybe Text) !Bool
  | ChRole !Text !Text
  | ChDatabase !Text !Text

instance FromJSON ChRow where
  parseJSON = withObject "row" $ \o ->
    (o .: "kind" :: Parser Text) >>= \case
      "user" -> do
        names <- concat <$> traverse (o .:) ["host_names", "host_names_regexp", "host_names_like"]
        ChUser <$> o .: "name" <*> o .: "physical" <*> o .: "host_ip" <*> pure (null (names :: [Text]))
      "grant" -> do
        tableLevel <- (\t c -> isJust (t :: Maybe Text) || isJust (c :: Maybe Text)) <$> o .:? "table" <*> o .:? "column"
        partial <- (/= (0 :: Int)) <$> o .: "is_partial_revoke"
        option <- (/= (0 :: Int)) <$> o .: "grant_option"
        ChGrant <$> o .: "user_name" <*> o .: "access_type" <*> o .:? "database" <*> pure (tableLevel || partial || option)
      "role" -> ChRole <$> o .: "user_name" <*> o .: "granted_role_name"
      "database" -> ChDatabase <$> o .: "name" <*> o .: "physical"
      other -> fail ("unknown observation row " <> T.unpack other)

-- | Tagged JSONEachRow rows; the users and databases the query asked for
-- decide which grants belong to which side.
parseClickHouseCatalog :: [Text] -> [Text] -> ByteString -> Either Text Catalog
parseClickHouseCatalog ourUsers ourDatabases bytes = do
  rows <- traverse (\line -> decodeValue "ClickHouse observation" line >>= first T.pack . parseEither parseJSON) (filter (not . BC.null) (BC.lines bytes))
  let userMap =
        Map.fromList
          [ (name, CatalogUser ("clickhouse-user:" <> physical') (loginOf hosts noNames) [privilege' | ChGrant who privilege' Nothing False <- rows, who == name] (userAnomalies name))
          | ChUser name physical' hosts noNames <- rows
          ]
      userAnomalies name =
        ["role " <> role | ChRole who role <- rows, who == name]
          <> ["grant option, partial revoke or table-level grant of " <> privilege' | ChGrant who privilege' _ True <- rows, who == name]
          <> ["grant of " <> privilege' <> " on database " <> db | ChGrant who privilege' (Just db) False <- rows, who == name, db `notElem` ourDatabases]
      databaseMap =
        Map.fromList
          [ ( name
            , CatalogDatabase
                ("clickhouse-database:" <> physical')
                Nothing
                [CatalogGrant who "database" privilege' | ChGrant who privilege' (Just db) False <- rows, db == name]
                Map.empty
                []
                ["special grant of " <> privilege' <> " to " <> who | ChGrant who privilege' (Just db) True <- rows, db == name, who `notElem` ourUsers]
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

-- Classification ----------------------------------------------------------

data MemberState
  = MemberAbsent
  | MemberComplete !Text
  | -- | present, short of the declared access; the reason says what is missing
    MemberIncomplete !Text !Text
  | -- | present with access Nagare never grants
    MemberDrift !Text
  deriving stock (Eq, Show)

-- | The user's own logical databases are given so that access to their
-- scratch restores (@<db>_restore_<id>@, granted by @db app-database restore@)
-- is not drift; access to any other database still is.
classifyUser :: Engine -> AppDatabaseRole -> Bool -> Text -> [Text] -> Catalog -> MemberState
classifyUser engine role enabled name own catalog = case Map.lookup name (catalog ^. #users) of
  Nothing -> MemberAbsent
  Just user
    | not (null (anomaliesOf user)) -> MemberDrift (name <> ": " <> T.intercalate "; " (anomaliesOf user))
    | user ^. #login == LoginRestricted -> MemberDrift (name <> ": login is restricted to particular hosts")
    | not (null extra) -> MemberDrift (name <> ": server-wide " <> T.intercalate ", " extra)
    | user ^. #login /= wantedLogin -> MemberIncomplete (user ^. #physical) (name <> (if enabled then ": cannot log in" else ": can still log in"))
    | enabled && not (null missing) -> MemberIncomplete (user ^. #physical) (name <> ": lacks server-wide " <> T.intercalate ", " missing)
    | not enabled && not (null (user ^. #serverGrants)) -> MemberIncomplete (user ^. #physical) (name <> ": keeps server-wide grants")
    | otherwise -> MemberComplete (user ^. #physical)
    where
      declared = concatMap (^. #privileges) (appDatabaseServerGrants engine role)
      extra = nub (user ^. #serverGrants) \\ declared
      missing = declared \\ (user ^. #serverGrants)
      wantedLogin = if enabled then LoginOn else LoginOff
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
        exact who role = held who "database" db == declaredFor ClickHouse role "database"
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
      | who == "PUBLIC" && target' `elem` ["database", "schema:public"] = Right True
      | who == "PUBLIC" && target' == "default-functions" && what == "EXECUTE" = Right False
      | who == "pg_database_owner" && target' == "schema:public" && Map.lookup "public" (db ^. #schemaOwners) == Just "pg_database_owner" = Right True
      | otherwise = Left (who <> " holds " <> what <> " on " <> target')
      where
        who = g ^. #grantee
        what = g ^. #privilege
        target' = g ^. #target
