-- | The SQL the app-database adapter sends (EP-202), one rendering per
-- member-level command. Every rendering is pinned byte for byte to the blocks
-- proven against the real engines in @test/fixtures/app-database/@.
--
-- Passwords never reach the server as plaintext: PostgreSQL receives a
-- SCRAM-SHA-256 verifier (RFC 7677) and ClickHouse a salted SHA-256 hash, both
-- computed here. Every name is a validated identifier
-- ("Nagare.Dsl.AppDatabase"), so quoting needs no escaping.
module Nagare.Database.AppDatabase.Sql
  ( -- * Passwords
    PasswordHash (..)
  , hashPassword
  , scramVerifier
  , clickhouseSha256
  , scramVerifierMatches
  , clickhouseHashMatches

    -- * Commands
  , renderCreateUser
  , renderUserAccess
  , clickHouseCeilings
  , postgresTimeout
  , renderSetPassword
  , renderCreateDatabase
  , DatabaseAccess (..)
  , renderDatabaseAccess
  , renderScratchRestore

    -- * Observation
  , renderObserveServer
  , renderObserveDatabase
  , renderObservePassword
  , renderObserveClickHouse
  , renderTerminateSessions
  , renderObserveDrain
  )
where

import Crypto.Hash (Digest, SHA256 (..), hash)
import Crypto.KDF.PBKDF2 qualified as PBKDF2
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.ByteArray.Encoding (Base (Base16, Base64), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.AppDatabase (AppDatabaseRole (..), Grant (..), MonitoringRole, UserAccess, UserLimits, appDatabaseDatabaseGrants, appDatabaseServerGrants, grantExceptionGrant)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory (UserLogin (..))

-- | What a server stores for a password.
data PasswordHash
  = -- | @SCRAM-SHA-256$4096:salt$StoredKey:ServerKey@
    PostgresVerifier !Text
  | -- | hex SHA-256 and the salt text it was computed with
    ClickHouseSha256 !Text !Text
  deriving stock (Eq, Show)

-- | Hash with a caller-supplied 16-byte salt (random at execution, fixed in tests).
hashPassword :: Engine -> ByteString -> Text -> PasswordHash
hashPassword ClickHouse salt password = uncurry ClickHouseSha256 (clickhouseSha256 salt password)
hashPassword _ salt password = PostgresVerifier (scramVerifier salt password)

scramIterations :: Int
scramIterations = 4096

scramVerifier :: ByteString -> Text -> Text
scramVerifier salt password =
  "SCRAM-SHA-256$"
    <> T.pack (show scramIterations)
    <> ":"
    <> base64 salt
    <> "$"
    <> base64 storedKey
    <> ":"
    <> base64 serverKey
  where
    (storedKey, serverKey) = scramKeys salt scramIterations password

scramKeys :: ByteString -> Int -> Text -> (ByteString, ByteString)
scramKeys salt iterations password = (digestBytes (hash clientKey :: Digest SHA256), serverKey)
  where
    salted :: ByteString
    salted = PBKDF2.generate (PBKDF2.prfHMAC SHA256) (PBKDF2.Parameters iterations 32) (TE.encodeUtf8 password) salt
    clientKey = mac salted "Client Key"
    serverKey = mac salted "Server Key"
    mac :: ByteString -> ByteString -> ByteString
    mac key message = digestBytes (hmacGetDigest (hmac key message :: HMAC SHA256))

-- | Whether a stored verifier was made from this password: recompute its
-- StoredKey and ServerKey with the verifier's own salt and iteration count.
scramVerifierMatches :: Text -> Text -> Bool
scramVerifierMatches password verifier = case T.splitOn "$" <$> T.stripPrefix "SCRAM-SHA-256$" verifier of
  Just [parameters, keys]
    | [iterationText, saltText] <- T.splitOn ":" parameters
    , [storedText, serverText] <- T.splitOn ":" keys
    , [(iterations, "")] <- reads (T.unpack iterationText)
    , iterations > 0
    , Right salt <- unbase64 saltText ->
        let (stored, server) = scramKeys salt iterations password
         in base64 stored == storedText && base64 server == serverText
  _ -> False

-- | ClickHouse's @sha256_hash@: the salt is the uppercase hex text of the
-- salt bytes and is hashed as that text: @hex(SHA256(password ‖ saltText))@.
clickhouseSha256 :: ByteString -> Text -> (Text, Text)
clickhouseSha256 salt password = (T.toUpper (T.pack (show (hash (TE.encodeUtf8 (password <> saltText)) :: Digest SHA256))), saltText)
  where
    saltText = T.toUpper (hex salt)

-- | Whether a stored ClickHouse hash was made from this password.
clickhouseHashMatches :: Text -> Text -> Text -> Bool
clickhouseHashMatches password digest saltText = case convertFromBase Base16 (TE.encodeUtf8 (T.toLower saltText)) of
  Right salt -> fst (clickhouseSha256 salt password) == digest
  Left (_ :: String) -> False

base64 :: ByteString -> Text
base64 = TE.decodeUtf8 . convertToBase Base64

unbase64 :: Text -> Either String ByteString
unbase64 = convertFromBase Base64 . TE.encodeUtf8

hex :: ByteString -> Text
hex = TE.decodeUtf8 . convertToBase Base16

-- | The raw bytes of a crypton digest. crypton's byte-array class comes from
-- @ram@, not the @memory@ package nagarectl uses, so the bytes are taken from
-- the digest's lowercase hex rendering.
digestBytes :: (Show digest) => digest -> ByteString
digestBytes digest = either (error . ("crypton digest is not hex: " <>)) id (convertFromBase Base16 (TE.encodeUtf8 (T.pack (show digest))))

-- Commands ------------------------------------------------------------------

renderCreateUser :: Engine -> Text -> PasswordHash -> Text -> Text
renderCreateUser _ user (PostgresVerifier verifier) _ =
  "CREATE ROLE " <> pgIdent user <> " LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD " <> literal verifier <> ";\n"
renderCreateUser _ user (ClickHouseSha256 digest salt) defaultDatabase =
  "CREATE USER " <> user <> " IDENTIFIED WITH sha256_hash BY " <> literal digest <> " SALT " <> literal salt <> " HOST ANY DEFAULT DATABASE " <> defaultDatabase <> ";\n"

-- | Login on or off, with the user's server-wide grants, its reviewed grant
-- exceptions and its limits (EP-204). The statements depend only on the
-- declaration: every allow-listed exception is granted when declared and the
-- user is enabled, and revoked otherwise; the one settings statement
-- replaces the user's whole settings list. Limits follow the declaration
-- whether or not the user can log in.
renderUserAccess :: Engine -> AppDatabaseRole -> Text -> UserLogin -> UserAccess -> Text
renderUserAccess ClickHouse role user login access =
  T.unlines
    ( ("ALTER USER " <> user <> (if enabled then " HOST ANY;" else " HOST NONE;"))
        : [ (if enabled then "GRANT " else "REVOKE ") <> privilege <> " ON " <> T.toUpper (g ^. #objectClass) <> (if enabled then " TO " else " FROM ") <> user <> ";"
          | g <- appDatabaseServerGrants ClickHouse role
          , privilege <- g ^. #privileges
          ]
          <> [ if enabled && exception `elem` access ^. #exceptions
                 then "GRANT " <> privilege <> " ON " <> object' <> " TO " <> user <> ";"
                 else "REVOKE " <> privilege <> " ON " <> object' <> " FROM " <> user <> ";"
             | exception <- [minBound .. maxBound]
             , let (privilege, object') = grantExceptionGrant exception
             ]
          <> ["ALTER USER " <> user <> " SETTINGS " <> settings <> ";"]
    )
  where
    -- A quiesced ClickHouse user is off: an open native session outlives a
    -- login change but not a grant change (EP-205 M1).
    enabled = login == LoginOpen
    settings = case clickHouseCeilings (access ^. #limits) of
      [] -> "NONE"
      ceilings -> T.intercalate ", " [settingName <> " = " <> value <> " MIN 1 MAX " <> value | (settingName, value) <- ceilings]
renderUserAccess _ _ user login access =
  T.unlines $
    [ "ALTER ROLE " <> pgIdent user <> (if enabled then " LOGIN" else " NOLOGIN") <> " CONNECTION LIMIT " <> T.show (fromMaybe (-1) (access ^. #limits . #connectionLimit)) <> ";"
    , "ALTER ROLE " <> pgIdent user <> maybe " RESET statement_timeout;" (\seconds -> " SET statement_timeout = " <> literal (postgresTimeout seconds) <> ";") (access ^. #limits . #statementTimeoutSeconds)
    ]
      -- A quiesced role's sessions end at the drain, after its grace period.
      <> ["SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = " <> literal user <> ";" | login == LoginClosed]
  where
    enabled = login == LoginOpen

-- | The declared ClickHouse ceilings as settings and their values, in the
-- order they are sent.
clickHouseCeilings :: UserLimits -> [(Text, Text)]
clickHouseCeilings limits =
  [ (settingName, T.show value)
  | (settingName, Just value) <-
      [ ("max_memory_usage", limits ^. #maxMemoryBytes)
      , ("max_execution_time", limits ^. #maxExecutionSeconds)
      , ("max_concurrent_queries_for_user", limits ^. #maxConcurrentQueries)
      ]
  ]

-- | A role-level @statement_timeout@ as PostgreSQL stores it: @30s@.
postgresTimeout :: Int -> Text
postgresTimeout seconds = T.show seconds <> "s"

renderSetPassword :: Text -> PasswordHash -> Text
renderSetPassword user (PostgresVerifier verifier) = "ALTER ROLE " <> pgIdent user <> " PASSWORD " <> literal verifier <> ";\n"
renderSetPassword user (ClickHouseSha256 digest salt) =
  "ALTER USER " <> user <> " IDENTIFIED WITH sha256_hash BY " <> literal digest <> " SALT " <> literal salt <> ";\n"

renderCreateDatabase :: Engine -> Text -> Text -> Text
renderCreateDatabase ClickHouse database _ = "CREATE DATABASE IF NOT EXISTS " <> database <> " ENGINE = Atomic;\n"
renderCreateDatabase _ database owner = "CREATE DATABASE " <> pgIdent database <> " OWNER " <> pgIdent owner <> ";\n"

-- | The access declared on one logical database.
data DatabaseAccess = DatabaseAccess
  { engine :: !Engine
  , initialDatabase :: !Text
  , database :: !Text
  , migration :: !Text
  , runtime :: !Text
  , enabled :: !Bool
  , monitoring :: ![MonitoringRole]
  -- ^ roles whose read-only grants on the app's objects are tolerated; never granted
  , withheld :: ![Text]
  -- ^ quiesced users; on ClickHouse their grants are revoked until resume (EP-205)
  }
  deriving stock (Generic, Eq, Show)

renderDatabaseAccess :: DatabaseAccess -> Text
renderDatabaseAccess access = case (access ^. #engine, access ^. #enabled) of
  (ClickHouse, True) ->
    T.unlines
      [ if user `elem` access ^. #withheld
          then "REVOKE ALL ON " <> db <> ".* FROM " <> user <> ";"
          else "GRANT " <> T.intercalate ", " (g ^. #privileges) <> " ON " <> db <> ".* TO " <> user <> ";"
      | (role, user) <- [(MigrationRole, access ^. #migration), (RuntimeRole, access ^. #runtime)]
      , g <- appDatabaseDatabaseGrants ClickHouse role
      ]
  (ClickHouse, False) ->
    T.unlines ["REVOKE ALL ON " <> db <> ".* FROM " <> user <> ";" | user <- [access ^. #migration, access ^. #runtime]]
  (_, True) ->
    T.unlines $
      [ "REVOKE CONNECT, TEMPORARY ON DATABASE \"postgres\", \"template1\", " <> pgIdent (access ^. #initialDatabase) <> " FROM PUBLIC;"
      , "REVOKE ALL ON DATABASE " <> pgIdent db <> " FROM PUBLIC;"
      ]
        <> ["GRANT " <> privileges g <> " ON DATABASE " <> pgIdent db <> " TO " <> runtimeUser <> ";" | g <- runtimeGrants, g ^. #objectClass == "database"]
        <> [ "\\connect " <> pgIdent db
           , "ALTER SCHEMA public OWNER TO " <> migrationUser <> ";"
           , "REVOKE ALL ON SCHEMA public FROM PUBLIC;"
           ]
        <> ["GRANT " <> privileges g <> " ON SCHEMA public TO " <> runtimeUser <> ";" | g <- runtimeGrants, g ^. #objectClass == "schema"]
        <> [ "ALTER DEFAULT PRIVILEGES FOR ROLE " <> migrationUser <> " GRANT " <> privileges g <> " ON " <> objects <> " TO " <> runtimeUser <> ";"
           | g <- runtimeGrants
           , Just objects <- [T.toUpper <$> T.stripPrefix "default-" (g ^. #objectClass)]
           ]
  (_, False) ->
    T.unlines
      [ "REVOKE " <> privileges g <> " ON DATABASE " <> pgIdent db <> " FROM " <> runtimeUser <> ";"
      | g <- runtimeGrants
      , g ^. #objectClass == "database"
      ]
  where
    db = access ^. #database
    runtimeGrants = appDatabaseDatabaseGrants (access ^. #engine) RuntimeRole
    runtimeUser = pgIdent (access ^. #runtime)
    migrationUser = pgIdent (access ^. #migration)
    privileges g = T.intercalate ", " (g ^. #privileges)

-- | Restore into scratch names, as the administrator, with the declared
-- access on them: PostgreSQL creates the one scratch database owned by the
-- migration user (pg_restore then loads it), ClickHouse restores every
-- database of the archive under its scratch name.
renderScratchRestore :: Engine -> [(Text, Text)] -> Text -> Text -> Text -> Text
renderScratchRestore ClickHouse scratches archive migration runtime =
  T.unlines $
    ("RESTORE " <> T.intercalate ", " ["DATABASE " <> db <> " AS " <> scratch | (db, scratch) <- scratches] <> " FROM File(" <> literal archive <> ");")
      : [ "GRANT " <> T.intercalate ", " (g ^. #privileges) <> " ON " <> scratch <> ".* TO " <> user <> ";"
        | (role, user) <- [(MigrationRole, migration), (RuntimeRole, runtime)]
        , g <- appDatabaseDatabaseGrants ClickHouse role
        , (_, scratch) <- scratches
        ]
renderScratchRestore engine scratches _ migration runtime =
  T.unlines $
    concat
      [ [ "CREATE DATABASE " <> pgIdent scratch <> " OWNER " <> pgIdent migration <> ";"
        , "REVOKE ALL ON DATABASE " <> pgIdent scratch <> " FROM PUBLIC;"
        ]
          <> [ "GRANT " <> T.intercalate ", " (g ^. #privileges) <> " ON DATABASE " <> pgIdent scratch <> " TO " <> pgIdent runtime <> ";"
             | g <- appDatabaseDatabaseGrants engine RuntimeRole
             , g ^. #objectClass == "database"
             ]
      | (_, scratch) <- scratches
      ]

-- Observation ---------------------------------------------------------------

-- | PostgreSQL server-wide facts: the users with their connection limits and
-- server-wide role settings, the declared databases with
-- their effective ACLs, whether PUBLIC may still connect to a system
-- database, and the app's grants on any other database.
renderObserveServer :: [Text] -> [Text] -> Text -> Text
renderObserveServer users databases initialDatabase =
  T.unlines
    [ "SELECT json_build_object("
    , "  'roles', (SELECT coalesce(json_agg(json_build_object('name', r.rolname, 'oid', r.oid::text, 'login', r.rolcanlogin, 'elevated', array_remove(ARRAY[CASE WHEN r.rolsuper THEN 'SUPERUSER' END, CASE WHEN r.rolcreaterole THEN 'CREATEROLE' END, CASE WHEN r.rolcreatedb THEN 'CREATEDB' END, CASE WHEN r.rolreplication THEN 'REPLICATION' END, CASE WHEN r.rolbypassrls THEN 'BYPASSRLS' END], NULL), 'connectionLimit', r.rolconnlimit, 'settings', coalesce((SELECT array_to_json(s.setconfig) FROM pg_db_role_setting s WHERE s.setrole = r.oid AND s.setdatabase = 0), '[]')) ORDER BY r.rolname), '[]') FROM pg_roles r WHERE r.rolname IN (" <> userList <> ")),"
    , "  'memberships', (SELECT coalesce(json_agg(json_build_object('role', r.rolname, 'member', m.rolname) ORDER BY r.rolname, m.rolname), '[]') FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member WHERE r.rolname IN (" <> userList <> ") OR m.rolname IN (" <> userList <> ")),"
    , "  'databases', (SELECT coalesce(json_agg(json_build_object('name', d.datname, 'oid', d.oid::text, 'owner', pg_get_userbyid(d.datdba), 'grants', " <> grants "coalesce(d.datacl, acldefault('d', d.datdba))" <> ") ORDER BY d.datname), '[]') FROM pg_database d WHERE d.datname IN (" <> databaseList <> ")),"
    , "  'publicSystemAccess', (SELECT count(*) > 0 FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE d.datname IN ('postgres', 'template1', " <> literal initialDatabase <> ") AND a.grantee = 0 AND a.privilege_type IN ('CONNECT', 'TEMPORARY')),"
    , "  'foreignAccess', (SELECT coalesce(json_agg(DISTINCT pg_get_userbyid(a.grantee) || ' on ' || d.datname), '[]') FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE a.grantee IN (SELECT oid FROM pg_roles WHERE rolname IN (" <> userList <> ")) AND d.datname NOT IN (" <> databaseList <> "))"
    , ");"
    ]
  where
    userList = literals users
    databaseList = literals databases

-- | PostgreSQL facts inside one existing database: schema ACLs and default
-- privileges.
renderObserveDatabase :: Text
renderObserveDatabase =
  T.unlines
    [ "SELECT json_build_object("
    , "  'schemas', (SELECT coalesce(json_agg(json_build_object('name', n.nspname, 'owner', pg_get_userbyid(n.nspowner), 'grants', " <> grants "coalesce(n.nspacl, acldefault('n', n.nspowner))" <> ") ORDER BY n.nspname), '[]') FROM pg_namespace n WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema'),"
    , "  'defaultAcl', (SELECT coalesce(json_agg(json_build_object('role', pg_get_userbyid(d.defaclrole), 'type', d.defaclobjtype::text, 'global', d.defaclnamespace = 0, 'grants', " <> grants "d.defaclacl" <> ") ORDER BY d.defaclobjtype), '[]') FROM pg_default_acl d)"
    , ");"
    ]

-- | The stored verifier, or an empty line when the role has none.
renderObservePassword :: Text -> Text
renderObservePassword user = "SELECT coalesce((SELECT rolpassword FROM pg_authid WHERE rolname = " <> literal user <> "), '');\n"

grants :: Text -> Text
grants acl =
  "(SELECT coalesce(json_agg(json_build_object('grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END, 'privilege', a.privilege_type, 'grantable', a.is_grantable) ORDER BY 1), '[]') FROM aclexplode("
    <> acl
    <> ") a)"

-- | ClickHouse facts as tagged JSONEachRow rows: the users, the grants of the
-- app's users anywhere and of anyone on the app's databases, role grants,
-- the users' own settings elements, and the databases.
renderObserveClickHouse :: [Text] -> [Text] -> Text
renderObserveClickHouse users databases =
  T.unlines
    [ "SELECT 'user' AS kind, name, toString(id) AS physical, host_ip, host_names, host_names_regexp, host_names_like, default_database FROM system.users WHERE name IN (" <> userList <> ") ORDER BY name FORMAT JSONEachRow;"
    , "SELECT 'grant' AS kind, user_name, access_type, database, table, column, is_partial_revoke, grant_option FROM system.grants WHERE user_name IN (" <> userList <> ") OR database IN (" <> databaseList <> ") ORDER BY ALL FORMAT JSONEachRow;"
    , "SELECT 'role' AS kind, user_name, granted_role_name FROM system.role_grants WHERE user_name IN (" <> userList <> ") ORDER BY ALL FORMAT JSONEachRow;"
    , "SELECT 'setting' AS kind, user_name, setting_name, value, min, max, writability, inherit_profile FROM system.settings_profile_elements WHERE user_name IN (" <> userList <> ") ORDER BY ALL FORMAT JSONEachRow;"
    , "SELECT 'database' AS kind, name, toString(uuid) AS physical, engine FROM system.databases WHERE name IN (" <> databaseList <> ") ORDER BY name FORMAT JSONEachRow;"
    ]
  where
    userList = literals users
    databaseList = literals databases

-- | End the blocked users' running work (EP-205 drain): ClickHouse kills
-- their queries, PostgreSQL terminates their sessions.
renderTerminateSessions :: Engine -> [Text] -> Text
renderTerminateSessions ClickHouse users = "KILL QUERY WHERE user IN (" <> literals users <> ") SYNC FORMAT Null;\n"
renderTerminateSessions _ users = "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename IN (" <> literals users <> ");\n"

-- | What a drain proves: the blocked users' running queries (ClickHouse) or
-- sessions (PostgreSQL), the app's unfinished mutations (ClickHouse), and
-- the server's identity.
renderObserveDrain :: Engine -> [Text] -> [Text] -> Text
renderObserveDrain ClickHouse users databases =
  T.unlines
    [ "SELECT 'session' AS kind, user, query_id FROM system.processes WHERE user IN (" <> literals users <> ") ORDER BY ALL FORMAT JSONEachRow;"
    , "SELECT 'mutation' AS kind, database, table, mutation_id, latest_fail_reason FROM system.mutations WHERE database IN (" <> literals databases <> ") AND is_done = 0 ORDER BY ALL FORMAT JSONEachRow;"
    , "SELECT 'server' AS kind, toString(serverUUID()) AS uuid, toString(now() - uptime()) AS started FORMAT JSONEachRow;"
    ]
renderObserveDrain _ users _ =
  "SELECT json_build_object('sessions', (SELECT count(*) FROM pg_stat_activity WHERE usename IN ("
    <> literals users
    <> ")), 'systemIdentifier', (SELECT system_identifier::text FROM pg_control_system()), 'started', pg_postmaster_start_time()::text);\n"

pgIdent :: Text -> Text
pgIdent name = "\"" <> name <> "\""

literal :: Text -> Text
literal value = "'" <> value <> "'"

literals :: [Text] -> Text
literals = T.intercalate ", " . map literal
