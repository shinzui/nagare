-- | The SQL the app-database adapter sends (EP-202), one rendering per
-- member-level command. Every rendering is pinned byte for byte to the blocks
-- proven against the real engines in @test/fixtures/app-database/@.
--
-- Passwords never reach the server as plaintext: PostgreSQL receives a
-- SCRAM-SHA-256 verifier (RFC 7677) and ClickHouse a salted SHA-256 hash, both
-- computed here. Every name is a validated identifier
-- ("Nagare.Dsl.AppDatabase"), so quoting needs no escaping; a name an app
-- created itself (EP-257) goes through 'quoteIdent' and 'quoteLiteral'.
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
  , clickHouseDatabaseGrants
  , renderScratchRestore

    -- * App-owned databases (EP-257)
  , quoteIdent
  , quoteLiteral
  , ownerAttributes
  , ownerSetting
  , renderCreateOwner
  , renderOwnerAccess
  , renderCreateOwnedDatabase
  , renderOwnedDatabaseAccess
  , renderObserveOwned
  , renderRoleFile
  , RoleRestore (..)
  , renderRestoreRoles

    -- * Observation
  , renderObserveServer
  , renderObserveDatabase
  , renderObservePassword
  , renderObserveClickHouse
  , renderTerminateSessions
  , renderObserveDrain
  , ResolvedObject (..)
  , ReaderAccess (..)
  , renderReaderAccess
  , renderObserveRelations
  )
where

import Crypto.Hash (Digest, SHA256 (..), hash)
import Crypto.KDF.PBKDF2 qualified as PBKDF2
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.ByteArray.Encoding (Base (Base16, Base64), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.AppDatabase (AppDatabaseRole (..), DatabasePrivileges, Grant (..), GrantException, MonitoringRole, UserAccess, UserLimits, appDatabaseDatabaseGrants, appDatabaseServerGrants, appDatabaseServerRevokedGrants, clickHousePrivilegeText, grantExceptionGrant, runtimeOwnsObjects)
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

-- | Login on or off, with the user's server-wide grants, the privileges the
-- engine derives from them on reload (always revoked, BUG-7), its reviewed
-- grant exceptions and its limits (EP-204). The statements depend only on the
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
          <> [ "REVOKE " <> privilege <> " ON " <> T.toUpper (g ^. #objectClass) <> " FROM " <> user <> ";"
             | g <- appDatabaseServerRevokedGrants ClickHouse role
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
      , ("max_result_rows", limits ^. #maxResultRows)
      , ("max_result_bytes", limits ^. #maxResultBytes)
      , ("max_threads", limits ^. #maxThreads)
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
  , readers :: ![Text]
  -- ^ declared readers, whose grants their own members judge (EP-206)
  , privileges :: !DatabasePrivileges
  -- ^ the desired privileges inside the app's own databases (EP-208)
  , createIn :: ![Text]
  -- ^ PostgreSQL: the declared schemas that exist; the others are pending
  , revokedCreateIn :: ![Text]
  -- ^ PostgreSQL: schemas where the runtime holds CREATE the declaration no
  -- longer names
  , revokeDatabaseCreate :: !Bool
  -- ^ PostgreSQL: the runtime holds CREATE on the database and may not
  , revokeMembership :: !Bool
  -- ^ PostgreSQL: the migration user is a member of the runtime role and
  -- the declaration no longer implies it
  , revoked :: ![(Text, Text)]
  -- ^ ClickHouse: (user, token) held beyond the fixed and declared sets, as
  -- observation reported it
  }
  deriving stock (Generic, Eq, Show)

-- | A ClickHouse user's grant list on one of the app's databases: the fixed
-- set, then its declared privileges (EP-208).
clickHouseDatabaseGrants :: AppDatabaseRole -> DatabasePrivileges -> [Text]
clickHouseDatabaseGrants role declared =
  concatMap (^. #privileges) (appDatabaseDatabaseGrants ClickHouse role)
    <> map clickHousePrivilegeText (own ^. #clickhouse)
  where
    own = case role of
      MigrationRole -> declared ^. #migration
      _ -> declared ^. #runtime

-- | Grants depend only on the declaration; each revocation is sent only when
-- the catalog just read shows it held (EP-208), so an app database without
-- privileges renders its v0.8.0 statements.
renderDatabaseAccess :: DatabaseAccess -> Text
renderDatabaseAccess access = case (access ^. #engine, access ^. #enabled) of
  (ClickHouse, True) ->
    T.unlines $
      concat
        [ if user `elem` access ^. #withheld
            then ["REVOKE ALL ON " <> db <> ".* FROM " <> user <> ";"]
            else
              ["REVOKE " <> token <> " ON " <> db <> ".* FROM " <> user <> ";" | (who, token) <- access ^. #revoked, who == user]
                <> ["GRANT " <> T.intercalate ", " (clickHouseDatabaseGrants role (access ^. #privileges)) <> " ON " <> db <> ".* TO " <> user <> ";"]
        | (role, user) <- [(MigrationRole, access ^. #migration), (RuntimeRole, access ^. #runtime)]
        ]
  (ClickHouse, False) ->
    T.unlines ["REVOKE ALL ON " <> db <> ".* FROM " <> user <> ";" | user <- [access ^. #migration, access ^. #runtime]]
  (_, True) ->
    T.unlines $
      [ "REVOKE CONNECT, TEMPORARY ON DATABASE \"postgres\", \"template1\", " <> pgIdent (access ^. #initialDatabase) <> " FROM PUBLIC;"
      , "REVOKE ALL ON DATABASE " <> pgIdent db <> " FROM PUBLIC;"
      ]
        <> ["GRANT " <> T.intercalate ", " (databasePrivileges g <> ["CREATE" | createSchemas]) <> " ON DATABASE " <> pgIdent db <> " TO " <> runtimeUser <> ";" | g <- runtimeGrants, g ^. #objectClass == "database"]
        <> ["REVOKE CREATE ON DATABASE " <> pgIdent db <> " FROM " <> runtimeUser <> ";" | access ^. #revokeDatabaseCreate]
        <> ["GRANT " <> runtimeUser <> " TO " <> migrationUser <> ";" | runtimeOwnsObjects (access ^. #privileges)]
        <> membershipRevoke
        <> [ "\\connect " <> pgIdent db
           , "ALTER SCHEMA public OWNER TO " <> migrationUser <> ";"
           , "REVOKE ALL ON SCHEMA public FROM PUBLIC;"
           ]
        <> ["GRANT " <> privileges g <> " ON SCHEMA public TO " <> runtimeUser <> ";" | g <- runtimeGrants, g ^. #objectClass == "schema"]
        <> [ "ALTER DEFAULT PRIVILEGES FOR ROLE " <> migrationUser <> " GRANT " <> privileges g <> " ON " <> objects <> " TO " <> runtimeUser <> ";"
           | g <- runtimeGrants
           , Just objects <- [T.toUpper <$> T.stripPrefix "default-" (g ^. #objectClass)]
           ]
        <> ["GRANT CREATE ON SCHEMA " <> pgIdent schema <> " TO " <> runtimeUser <> ";" | schema <- access ^. #createIn]
        <> schemaRevokes
  -- Retirement withholds the database's privileges; schema CREATE and the
  -- membership stay, unreachable without CONNECT, as schema USAGE does.
  (_, False) ->
    T.unlines $
      [ "REVOKE " <> T.intercalate ", " (databasePrivileges g <> ["CREATE" | access ^. #revokeDatabaseCreate]) <> " ON DATABASE " <> pgIdent db <> " FROM " <> runtimeUser <> ";"
      | g <- runtimeGrants
      , g ^. #objectClass == "database"
      ]
        <> membershipRevoke
        <> ["\\connect " <> pgIdent db | not (null (access ^. #revokedCreateIn))]
        <> schemaRevokes
  where
    db = access ^. #database
    runtimeGrants = appDatabaseDatabaseGrants (access ^. #engine) RuntimeRole
    runtimeUser = pgIdent (access ^. #runtime)
    migrationUser = pgIdent (access ^. #migration)
    privileges g = T.intercalate ", " (g ^. #privileges)
    databasePrivileges g = g ^. #privileges
    createSchemas = access ^. #privileges . #runtime . #createSchemas
    membershipRevoke = ["REVOKE " <> runtimeUser <> " FROM " <> migrationUser <> ";" | access ^. #revokeMembership]
    schemaRevokes = ["REVOKE CREATE ON SCHEMA " <> pgIdent schema <> " FROM " <> runtimeUser <> ";" | schema <- access ^. #revokedCreateIn]

-- | Restore into scratch names, as the administrator, with the declared
-- access on them: PostgreSQL creates the one scratch database owned by the
-- migration user (pg_restore then loads it), ClickHouse restores every
-- database of the archive under its scratch name. The declared own-database
-- privileges come too (EP-208): on ClickHouse each user's, on PostgreSQL
-- CREATE on the database under @createSchemas@; schema grants and owners
-- come from the dump.
renderScratchRestore :: Engine -> DatabasePrivileges -> [(Text, Text)] -> Text -> Text -> Text -> Text
renderScratchRestore ClickHouse declared scratches archive migration runtime =
  T.unlines $
    ("RESTORE " <> T.intercalate ", " ["DATABASE " <> db <> " AS " <> scratch | (db, scratch) <- scratches] <> " FROM File(" <> literal archive <> ");")
      : [ "GRANT " <> T.intercalate ", " (clickHouseDatabaseGrants role declared) <> " ON " <> scratch <> ".* TO " <> user <> ";"
        | (role, user) <- [(MigrationRole, migration), (RuntimeRole, runtime)]
        , (_, scratch) <- scratches
        ]
renderScratchRestore engine declared scratches _ migration runtime =
  T.unlines $
    concat
      [ [ "CREATE DATABASE " <> pgIdent scratch <> " OWNER " <> pgIdent migration <> ";"
        , "REVOKE ALL ON DATABASE " <> pgIdent scratch <> " FROM PUBLIC;"
        ]
          <> [ "GRANT " <> T.intercalate ", " ((g ^. #privileges) <> ["CREATE" | declared ^. #runtime . #createSchemas]) <> " ON DATABASE " <> pgIdent scratch <> " TO " <> pgIdent runtime <> ";"
             | g <- appDatabaseDatabaseGrants engine RuntimeRole
             , g ^. #objectClass == "database"
             ]
      | (_, scratch) <- scratches
      ]

-- App-owned databases (EP-257) ---------------------------------------------

-- | A PostgreSQL identifier for a name Nagare did not validate: wrapped in
-- double quotes with every double quote doubled.
quoteIdent :: Text -> Text
quoteIdent name = "\"" <> T.replace "\"" "\"\"" name <> "\""

-- | A PostgreSQL string literal for text Nagare did not validate: wrapped in
-- single quotes with every single quote doubled, as the server reads it with
-- @standard_conforming_strings@ on (its default since 9.1).
quoteLiteral :: Text -> Text
quoteLiteral value = "'" <> T.replace "'" "''" value <> "'"

-- | The owner user's attributes: it may log in and create roles, nothing
-- server-wide beyond that.
ownerAttributes :: Text
ownerAttributes = "NOSUPERUSER NOCREATEDB CREATEROLE NOREPLICATION NOBYPASSRLS"

-- | The owner holds every role it creates with the set and inherit options,
-- so it can give its objects to them as a superuser-run migration would. As
-- @pg_db_role_setting@ stores it.
ownerSetting :: Text
ownerSetting = "createrole_self_grant=set, inherit"

renderCreateOwner :: Text -> PasswordHash -> Text
renderCreateOwner user hash' =
  T.unlines
    [ "CREATE ROLE " <> pgIdent user <> " LOGIN " <> ownerAttributes <> " PASSWORD " <> literal (passwordText hash') <> ";"
    , "ALTER ROLE " <> pgIdent user <> " SET createrole_self_grant = 'set, inherit';"
    ]

-- | The owner's login, attributes and setting; a closed login ends its
-- sessions, as a retired user's does.
renderOwnerAccess :: Text -> UserLogin -> Text
renderOwnerAccess user login =
  T.unlines $
    [ "ALTER ROLE " <> pgIdent user <> (if login == LoginOpen then " LOGIN " else " NOLOGIN ") <> ownerAttributes <> " CONNECTION LIMIT -1;"
    , "ALTER ROLE " <> pgIdent user <> " SET createrole_self_grant = 'set, inherit';"
    ]
      <> ["SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = " <> literal user <> ";" | login == LoginClosed]

-- | The declared owning role, created without login when absent and given to
-- the owner with the admin, inherit and set options, then the database owned
-- by it, or by the owner when none is declared.
renderCreateOwnedDatabase :: Text -> Text -> Maybe Text -> Text
renderCreateOwnedDatabase database owner owningRole =
  T.unlines $
    concat
      [ [ "DO $owning$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = " <> literal role <> ") THEN CREATE ROLE " <> pgIdent role <> " NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS; END IF; END $owning$;"
        , grantOwningRole role owner
        ]
      | Just role <- [owningRole]
      ]
      <> ["CREATE DATABASE " <> pgIdent database <> " OWNER " <> pgIdent (fromMaybe owner owningRole) <> ";"]

-- | The boundary Nagare keeps: PUBLIC out of the database and the system
-- databases, and the owner holding the owning role. Nothing inside, except
-- the logins of the app a reviewed quiesce or retirement closes, whose
-- sessions end, and those it reopens (EP-258); their names are the app's,
-- so they are escaped.
renderOwnedDatabaseAccess :: Text -> Text -> Text -> Maybe Text -> [Text] -> [Text] -> Text
renderOwnedDatabaseAccess initialDatabase database owner owningRole closed reopened =
  T.unlines $
    [ "REVOKE CONNECT, TEMPORARY ON DATABASE \"postgres\", \"template1\", " <> pgIdent initialDatabase <> " FROM PUBLIC;"
    , "REVOKE ALL ON DATABASE " <> pgIdent database <> " FROM PUBLIC;"
    ]
      <> [grantOwningRole role owner | Just role <- [owningRole]]
      <> ["ALTER ROLE " <> quoteIdent login <> " NOLOGIN;" | login <- closed]
      <> ["SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename IN (" <> T.intercalate ", " (map quoteLiteral closed) <> ");" | not (null closed)]
      <> ["ALTER ROLE " <> quoteIdent login <> " LOGIN;" | login <- reopened]

grantOwningRole :: Text -> Text -> Text
grantOwningRole role owner = "GRANT " <> pgIdent role <> " TO " <> pgIdent owner <> " WITH ADMIN TRUE, INHERIT TRUE, SET TRUE;"

passwordText :: PasswordHash -> Text
passwordText = \case
  PostgresVerifier verifier -> verifier
  ClickHouseSha256 digest _ -> digest

-- | Everything an app-owned database's members are judged on, in one read
-- as the administrator: the app's roles (the owner and every role reachable
-- from it through admin-option memberships, as EP-257 M1 proved), each of
-- them and the declared owning role with its attributes and settings, every
-- membership naming one of the app's roles with its grantor and options,
-- every database the app's roles own or hold a privilege on, and the app's
-- own database, and whether PUBLIC may still connect to a system database.
renderObserveOwned :: Text -> Maybe Text -> Text -> Text -> Text
renderObserveOwned owner owningRole database initialDatabase =
  T.unlines
    [ "WITH RECURSIVE app(oid) AS ("
    , "  SELECT oid FROM pg_catalog.pg_roles WHERE rolname = " <> literal owner
    , "  UNION"
    , "  SELECT m.roleid FROM pg_catalog.pg_auth_members AS m JOIN app ON m.member = app.oid WHERE m.admin_option"
    , ")"
    , "SELECT json_build_object("
    , "  'app', (SELECT coalesce(json_agg(r.rolname ORDER BY r.rolname), '[]') FROM pg_roles r WHERE r.oid IN (SELECT oid FROM app)),"
    , "  'roles', (SELECT coalesce(json_agg(json_build_object('name', r.rolname, 'oid', r.oid::text, 'login', r.rolcanlogin, 'elevated', array_remove(ARRAY[CASE WHEN r.rolsuper THEN 'SUPERUSER' END, CASE WHEN r.rolcreaterole THEN 'CREATEROLE' END, CASE WHEN r.rolcreatedb THEN 'CREATEDB' END, CASE WHEN r.rolreplication THEN 'REPLICATION' END, CASE WHEN r.rolbypassrls THEN 'BYPASSRLS' END], NULL), 'connectionLimit', r.rolconnlimit, 'settings', coalesce((SELECT array_to_json(s.setconfig) FROM pg_db_role_setting s WHERE s.setrole = r.oid AND s.setdatabase = 0), '[]')) ORDER BY r.rolname), '[]') FROM pg_roles r WHERE r.oid IN (SELECT oid FROM app) OR r.rolname IN (" <> literals (owner : maybe [] pure owningRole) <> ")),"
    , "  'memberships', (SELECT coalesce(json_agg(json_build_object('role', r.rolname, 'member', m.rolname, 'grantor', g.rolname, 'admin', a.admin_option, 'inherit', a.inherit_option, 'set', a.set_option) ORDER BY r.rolname, m.rolname, g.rolname), '[]') FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member JOIN pg_roles g ON g.oid = a.grantor WHERE a.roleid IN (SELECT oid FROM app) OR a.member IN (SELECT oid FROM app)),"
    , "  'databases', (SELECT coalesce(json_agg(json_build_object('name', d.datname, 'oid', d.oid::text, 'owner', pg_get_userbyid(d.datdba), 'grants', " <> grants "coalesce(d.datacl, acldefault('d', d.datdba))" <> ") ORDER BY d.datname), '[]') FROM pg_database d WHERE d.datname = " <> literal database <> " OR d.datdba IN (SELECT oid FROM app) OR EXISTS (SELECT 1 FROM aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) x WHERE x.grantee IN (SELECT oid FROM app))),"
    , "  'publicSystemAccess', (SELECT count(*) > 0 FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE d.datname IN ('postgres', 'template1', " <> literal initialDatabase <> ") AND a.grantee = 0 AND a.privilege_type IN ('CONNECT', 'TEMPORARY'))"
    , ");"
    ]

-- | The role file an app-owned database's backup carries (EP-258), as one
-- JSON document read as the administrator: every role of the app but the
-- owner with its attributes, its SCRAM verifier when it may log in, and its
-- server-wide settings; every membership among the app's roles with its
-- grantor and options; and the database's owner, grants and settings,
-- including the app's roles' settings in it. The owner takes its password
-- from its Secret on re-apply, so its verifier is left out.
renderRoleFile :: Text -> Text -> Text
renderRoleFile owner database =
  T.unlines
    [ "WITH RECURSIVE app(oid) AS ("
    , "  SELECT oid FROM pg_catalog.pg_roles WHERE rolname = " <> literal owner
    , "  UNION"
    , "  SELECT m.roleid FROM pg_catalog.pg_auth_members AS m JOIN app ON m.member = app.oid WHERE m.admin_option"
    , ")"
    , "SELECT json_build_object("
    , "  'version', 1,"
    , "  'owner', " <> literal owner <> ","
    , "  'database', " <> literal database <> ","
    , "  'roles', (SELECT coalesce(json_agg(json_build_object('name', a.rolname, 'login', a.rolcanlogin, 'createrole', a.rolcreaterole, 'inherit', a.rolinherit, 'elevated', a.rolsuper OR a.rolcreatedb OR a.rolreplication OR a.rolbypassrls, 'connectionLimit', a.rolconnlimit, 'validUntil', a.rolvaliduntil::text, 'verifier', CASE WHEN a.rolcanlogin THEN a.rolpassword END, 'settings', coalesce((SELECT array_to_json(s.setconfig) FROM pg_db_role_setting s WHERE s.setrole = a.oid AND s.setdatabase = 0), '[]')) ORDER BY a.rolname), '[]') FROM pg_authid a WHERE a.oid IN (SELECT oid FROM app) AND a.rolname <> " <> literal owner <> "),"
    , "  'memberships', (SELECT coalesce(json_agg(json_build_object('role', r.rolname, 'member', m.rolname, 'grantor', g.rolname, 'admin', x.admin_option, 'inherit', x.inherit_option, 'set', x.set_option) ORDER BY r.rolname, m.rolname, g.rolname), '[]') FROM pg_auth_members x JOIN pg_roles r ON r.oid = x.roleid JOIN pg_roles m ON m.oid = x.member JOIN pg_roles g ON g.oid = x.grantor WHERE x.roleid IN (SELECT oid FROM app) AND x.member IN (SELECT oid FROM app)),"
    , "  'databaseOwner', (SELECT pg_get_userbyid(d.datdba) FROM pg_database d WHERE d.datname = " <> literal database <> "),"
    , "  'databaseGrants', (SELECT coalesce(json_agg(json_build_object('grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END, 'grantor', pg_get_userbyid(a.grantor), 'privilege', a.privilege_type, 'grantable', a.is_grantable) ORDER BY CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END, a.privilege_type), '[]') FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE d.datname = " <> literal database <> "),"
    , "  'databaseSettings', coalesce((SELECT array_to_json(s.setconfig) FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase WHERE d.datname = " <> literal database <> " AND s.setrole = 0), '[]'),"
    , "  'roleDatabaseSettings', (SELECT coalesce(json_agg(json_build_object('role', pg_get_userbyid(s.setrole), 'settings', array_to_json(s.setconfig)) ORDER BY pg_get_userbyid(s.setrole)), '[]') FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase WHERE d.datname = " <> literal database <> " AND s.setrole IN (SELECT oid FROM app))"
    , ");"
    ]

-- | Where a role file is applied (EP-258): onto a rebuilt server, where the
-- app's roles are created first, or onto a scratch database beside the live
-- one, where they exist.
data RoleRestore = RoleRestore
  { owner :: !Text
  -- ^ the owner user the file must name
  , databaseOwner :: !Text
  -- ^ the declared owner of the database: the owning role or the owner
  , target :: !Text
  -- ^ the database that receives the file's grants and settings
  , createRoles :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Apply a role file read by psql from @file@ as the administrator. The file
-- is data: it is validated and every statement is built by the server's own
-- @format@ with @%I@ and @%L@, so nothing read from a bucket runs as SQL. It
-- refuses, before any change, an unknown key or version, another app's owner
-- or database owner, an elevated attribute, a @pg_@ name, a verifier that is
-- not SCRAM-SHA-256, a setting name that is not one, a membership or grant
-- naming a role outside the file, and a role that exists and is not this
-- app's. It runs in one transaction, so a failure changes nothing.
renderRestoreRoles :: Text -> RoleRestore -> Text
renderRestoreRoles file restore =
  T.unlines
    [ "\\set roles `cat " <> file <> "`"
    , "SELECT set_config('nagare.roles', :'roles', false);"
    , "DO $restore$"
    , "DECLARE"
    , "  doc jsonb := current_setting('nagare.roles')::jsonb;"
    , "  expected_owner text := " <> literal (restore ^. #owner) <> ";"
    , "  database_owner text := " <> literal (restore ^. #databaseOwner) <> ";"
    , "  target text := " <> literal (restore ^. #target) <> ";"
    , "  create_roles boolean := " <> (if restore ^. #createRoles then "true" else "false") <> ";"
    , "  names text[];"
    , "  app text[];"
    , "  r jsonb;"
    , "  m jsonb;"
    , "  g jsonb;"
    , "  setting text;"
    , "BEGIN"
    , "  IF doc->>'version' IS DISTINCT FROM '1' THEN RAISE EXCEPTION 'the role file has an unknown version'; END IF;"
    , "  IF EXISTS (SELECT 1 FROM jsonb_object_keys(doc) k WHERE k NOT IN ('version', 'owner', 'database', 'roles', 'memberships', 'databaseOwner', 'databaseGrants', 'databaseSettings', 'roleDatabaseSettings')) THEN RAISE EXCEPTION 'the role file has an unknown key'; END IF;"
    , "  IF doc->>'owner' IS DISTINCT FROM expected_owner THEN RAISE EXCEPTION 'the role file names owner %, not %', doc->>'owner', expected_owner; END IF;"
    , "  IF doc->>'databaseOwner' IS DISTINCT FROM database_owner THEN RAISE EXCEPTION 'the role file names database owner %, not %', doc->>'databaseOwner', database_owner; END IF;"
    , "  SELECT coalesce(array_agg(x->>'name'), '{}') || expected_owner INTO names FROM jsonb_array_elements(doc->'roles') x;"
    , "  FOR r IN SELECT x FROM jsonb_array_elements(doc->'roles') x LOOP"
    , "    IF EXISTS (SELECT 1 FROM jsonb_object_keys(r) k WHERE k NOT IN ('name', 'login', 'createrole', 'inherit', 'elevated', 'connectionLimit', 'validUntil', 'verifier', 'settings')) THEN RAISE EXCEPTION 'role % has an unknown key', r->>'name'; END IF;"
    , "    IF (r->>'elevated')::boolean THEN RAISE EXCEPTION 'role % holds an elevated attribute', r->>'name'; END IF;"
    , "    IF r->>'name' LIKE 'pg\\_%' THEN RAISE EXCEPTION 'role % has a predefined role name', r->>'name'; END IF;"
    , "    IF r->>'verifier' IS NOT NULL AND r->>'verifier' !~ '^SCRAM-SHA-256[$][0-9]+:[A-Za-z0-9+/=]+[$][A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+$' THEN RAISE EXCEPTION 'role % has a verifier that is not SCRAM-SHA-256', r->>'name'; END IF;"
    , "    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(r->'settings') e WHERE e !~ '^[A-Za-z_][A-Za-z0-9_.]*=') THEN RAISE EXCEPTION 'role % has a setting whose name is not a setting name', r->>'name'; END IF;"
    , "  END LOOP;"
    , "  FOR m IN SELECT x FROM jsonb_array_elements(doc->'memberships') x LOOP"
    , "    IF NOT (m->>'role' = ANY (names) AND m->>'member' = ANY (names)) THEN RAISE EXCEPTION 'membership % > % names a role outside the app', m->>'role', m->>'member'; END IF;"
    , "  END LOOP;"
    , "  FOR g IN SELECT x FROM jsonb_array_elements(doc->'databaseGrants') x LOOP"
    , "    IF g->>'grantee' <> 'PUBLIC' AND NOT (g->>'grantee' = ANY (names) AND g->>'grantor' = ANY (names) AND g->>'privilege' IN ('CONNECT', 'CREATE', 'TEMPORARY')) THEN RAISE EXCEPTION 'database grant to % names a role outside the app', g->>'grantee'; END IF;"
    , "  END LOOP;"
    , "  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(doc->'databaseSettings') e WHERE e !~ '^[A-Za-z_][A-Za-z0-9_.]*=') OR EXISTS (SELECT 1 FROM jsonb_array_elements(doc->'roleDatabaseSettings') x, jsonb_array_elements_text(x->'settings') e WHERE NOT (x->>'role' = ANY (names)) OR e !~ '^[A-Za-z_][A-Za-z0-9_.]*=') THEN RAISE EXCEPTION 'the role file has a setting outside the app or a name that is not a setting name'; END IF;"
    , "  WITH RECURSIVE a(oid) AS (SELECT oid FROM pg_roles WHERE rolname = expected_owner UNION SELECT x.roleid FROM pg_auth_members x JOIN a ON x.member = a.oid WHERE x.admin_option)"
    , "  SELECT array_agg(rolname) INTO app FROM pg_roles WHERE oid IN (SELECT oid FROM a);"
    , "  IF app IS NULL THEN RAISE EXCEPTION 'owner % does not exist; apply the app database first', expected_owner; END IF;"
    , "  FOR r IN SELECT x FROM jsonb_array_elements(doc->'roles') x LOOP"
    , "    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r->>'name') THEN"
    , "      IF NOT (r->>'name' = ANY (app)) THEN RAISE EXCEPTION 'role % exists on this server and is not this app''s', r->>'name'; END IF;"
    , "    ELSIF NOT create_roles THEN"
    , "      RAISE EXCEPTION 'role % is absent; restore onto a rebuilt server with --rebuilt', r->>'name';"
    , "    ELSE"
    , "      EXECUTE format('CREATE ROLE %I %s %s %s CONNECTION LIMIT %s', r->>'name', CASE WHEN (r->>'login')::boolean THEN 'LOGIN' ELSE 'NOLOGIN' END, CASE WHEN (r->>'createrole')::boolean THEN 'CREATEROLE' ELSE 'NOCREATEROLE' END, CASE WHEN (r->>'inherit')::boolean THEN 'INHERIT' ELSE 'NOINHERIT' END, (r->>'connectionLimit')::int);"
    , "      IF r->>'verifier' IS NOT NULL THEN EXECUTE format('ALTER ROLE %I PASSWORD %L', r->>'name', r->>'verifier'); END IF;"
    , "      IF r->>'validUntil' IS NOT NULL THEN EXECUTE format('ALTER ROLE %I VALID UNTIL %L', r->>'name', r->>'validUntil'); END IF;"
    , "      FOR setting IN SELECT jsonb_array_elements_text(r->'settings') LOOP"
    , "        EXECUTE format('ALTER ROLE %I SET %s TO %L', r->>'name', split_part(setting, '=', 1), substr(setting, strpos(setting, '=') + 1));"
    , "      END LOOP;"
    , "    END IF;"
    , "  END LOOP;"
    , "  IF create_roles THEN"
    , "    FOR m IN SELECT x FROM jsonb_array_elements(doc->'memberships') x ORDER BY x->>'grantor' = ANY (names), x->>'role', x->>'member' LOOP"
    , "      EXECUTE format('GRANT %I TO %I WITH ADMIN %s, INHERIT %s, SET %s GRANTED BY %I', m->>'role', m->>'member', CASE WHEN (m->>'admin')::boolean THEN 'TRUE' ELSE 'FALSE' END, CASE WHEN (m->>'inherit')::boolean THEN 'TRUE' ELSE 'FALSE' END, CASE WHEN (m->>'set')::boolean THEN 'TRUE' ELSE 'FALSE' END, CASE WHEN m->>'grantor' = ANY (names) THEN m->>'grantor' ELSE current_user END);"
    , "    END LOOP;"
    , "    FOR r IN SELECT x FROM jsonb_array_elements(doc->'roleDatabaseSettings') x LOOP"
    , "      FOR setting IN SELECT jsonb_array_elements_text(r->'settings') LOOP"
    , "        EXECUTE format('ALTER ROLE %I IN DATABASE %I SET %s TO %L', r->>'role', target, split_part(setting, '=', 1), substr(setting, strpos(setting, '=') + 1));"
    , "      END LOOP;"
    , "    END LOOP;"
    , "  END IF;"
    , "  FOR g IN SELECT x FROM jsonb_array_elements(doc->'databaseGrants') x WHERE x->>'grantee' <> 'PUBLIC' AND NOT (x->>'grantee' = database_owner AND x->>'grantor' = database_owner) LOOP"
    , "    -- An object grant is recorded as its grantor's only when made as it."
    , "    EXECUTE format('SET ROLE %I', g->>'grantor');"
    , "    EXECUTE format('GRANT %s ON DATABASE %I TO %I%s', g->>'privilege', target, g->>'grantee', CASE WHEN (g->>'grantable')::boolean THEN ' WITH GRANT OPTION' ELSE '' END);"
    , "    RESET ROLE;"
    , "  END LOOP;"
    , "  FOR setting IN SELECT jsonb_array_elements_text(doc->'databaseSettings') LOOP"
    , "    EXECUTE format('ALTER DATABASE %I SET %s TO %L', target, split_part(setting, '=', 1), substr(setting, strpos(setting, '=') + 1));"
    , "  END LOOP;"
    , "END"
    , "$restore$;"
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
    , "  'memberships', (SELECT coalesce(json_agg(json_build_object('role', r.rolname, 'member', m.rolname, 'admin', a.admin_option) ORDER BY r.rolname, m.rolname), '[]') FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member WHERE r.rolname IN (" <> userList <> ") OR m.rolname IN (" <> userList <> ")),"
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
-- the users' own settings elements, the databases, and the server's
-- privilege tree (EP-208).
renderObserveClickHouse :: [Text] -> [Text] -> Text
renderObserveClickHouse users databases =
  T.unlines
    [ "SELECT 'user' AS kind, name, toString(id) AS physical, host_ip, host_names, host_names_regexp, host_names_like, default_database FROM system.users WHERE name IN (" <> userList <> ") ORDER BY name FORMAT JSONEachRow;"
    , "SELECT 'grant' AS kind, user_name, access_type, database, table, column, is_partial_revoke, grant_option FROM system.grants WHERE user_name IN (" <> userList <> ") OR database IN (" <> databaseList <> ") ORDER BY ALL FORMAT JSONEachRow;"
    , "SELECT 'role' AS kind, user_name, granted_role_name FROM system.role_grants WHERE user_name IN (" <> userList <> ") ORDER BY ALL FORMAT JSONEachRow;"
    , "SELECT 'setting' AS kind, user_name, setting_name, value, min, max, writability, inherit_profile FROM system.settings_profile_elements WHERE user_name IN (" <> userList <> ") ORDER BY ALL FORMAT JSONEachRow;"
    , "SELECT 'database' AS kind, name, toString(uuid) AS physical, engine FROM system.databases WHERE name IN (" <> databaseList <> ") ORDER BY name FORMAT JSONEachRow;"
    , "SELECT 'privilege' AS kind, privilege, parent_group, level FROM system.privileges ORDER BY privilege FORMAT JSONEachRow;"
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

-- Readers (EP-206) ----------------------------------------------------------

-- | A declared object as the server names it: ClickHouse @db.table@,
-- PostgreSQL @schema.relation@ in a database.
data ResolvedObject = ResolvedObject
  { database :: !Text
  , schema :: !(Maybe Text)
  , relation :: !Text
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | A reader's access as one command renders it: login, SELECT on the
-- resolved objects, the revocation of what only the accepted declaration
-- named, and its limits; on PostgreSQL also CONNECT on its databases and
-- USAGE on their existing schemas, as (database, schema). A reader that may
-- not log in holds none of its grants and keeps its limits.
data ReaderAccess = ReaderAccess
  { user :: !Text
  , login :: !UserLogin
  , limits :: !UserLimits
  , granted :: ![ResolvedObject]
  , revoked :: ![ResolvedObject]
  , databases :: ![Text]
  , revokedDatabases :: ![Text]
  , schemas :: ![(Text, Text)]
  , revokedSchemas :: ![(Text, Text)]
  , exceptions :: ![GrantException]
  , revokedExceptions :: ![GrantException]
  }
  deriving stock (Generic, Eq, Show)

renderReaderAccess :: Engine -> ReaderAccess -> Text
renderReaderAccess ClickHouse access =
  T.unlines $
    [("ALTER USER " <> user' <> (if enabled then " HOST ANY;" else " HOST NONE;"))]
      <> [ (if enabled then "GRANT SELECT ON " <> o ^. #database <> "." <> o ^. #relation <> " TO " else "REVOKE SELECT ON " <> o ^. #database <> "." <> o ^. #relation <> " FROM ") <> user' <> ";"
         | o <- access ^. #granted
         ]
      <> ["REVOKE SELECT ON " <> o ^. #database <> "." <> o ^. #relation <> " FROM " <> user' <> ";" | o <- access ^. #revoked]
      <> [ (if enabled then "GRANT " else "REVOKE ") <> privilege <> " ON " <> object' <> (if enabled then " TO " else " FROM ") <> user' <> ";"
         | exception <- access ^. #exceptions
         , let (privilege, object') = grantExceptionGrant exception
         ]
      <> [ "REVOKE " <> privilege <> " ON " <> object' <> " FROM " <> user' <> ";"
         | exception <- access ^. #revokedExceptions
         , let (privilege, object') = grantExceptionGrant exception
         ]
      <> ["ALTER USER " <> user' <> " SETTINGS readonly = 2 CONST, result_overflow_mode = 'throw' CONST" <> T.concat [", " <> n <> " = " <> v <> " MIN 1 MAX " <> v | (n, v) <- clickHouseCeilings (access ^. #limits)] <> ";"]
  where
    user' = access ^. #user
    enabled = access ^. #login == LoginOpen
renderReaderAccess _ access =
  T.unlines $
    [ "ALTER ROLE " <> pgIdent user' <> (if enabled then " LOGIN" else " NOLOGIN") <> " CONNECTION LIMIT " <> T.show (fromMaybe (-1) (access ^. #limits . #connectionLimit)) <> ";"
    , "ALTER ROLE " <> pgIdent user' <> maybe " RESET statement_timeout;" (\seconds -> " SET statement_timeout = " <> literal (postgresTimeout seconds) <> ";") (access ^. #limits . #statementTimeoutSeconds)
    , "ALTER ROLE " <> pgIdent user' <> " SET default_transaction_read_only = on;"
    ]
      <> ["SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = " <> literal user' <> ";" | not enabled]
      <> concat
        [ [ (if enabled && db `elem` access ^. #databases then "GRANT CONNECT ON DATABASE " <> pgIdent db <> " TO " else "REVOKE CONNECT ON DATABASE " <> pgIdent db <> " FROM ") <> pgIdent user' <> ";"
          , "\\connect " <> pgIdent db
          ]
            <> [(if enabled then "GRANT USAGE ON SCHEMA " <> pgIdent sc <> " TO " else "REVOKE USAGE ON SCHEMA " <> pgIdent sc <> " FROM ") <> pgIdent user' <> ";" | (db', sc) <- access ^. #schemas, db' == db]
            <> ["REVOKE USAGE ON SCHEMA " <> pgIdent sc <> " FROM " <> pgIdent user' <> ";" | (db', sc) <- access ^. #revokedSchemas, db' == db]
            <> [ (if enabled then "GRANT SELECT ON " <> qualified o <> " TO " else "REVOKE SELECT ON " <> qualified o <> " FROM ") <> pgIdent user' <> ";"
               | o <- access ^. #granted
               , o ^. #database == db
               ]
            <> ["REVOKE SELECT ON " <> qualified o <> " FROM " <> pgIdent user' <> ";" | o <- access ^. #revoked, o ^. #database == db]
        | db <- nub (access ^. #databases <> access ^. #revokedDatabases <> map (^. #database) (access ^. #granted <> access ^. #revoked))
        ]
  where
    user' = access ^. #user
    enabled = access ^. #login == LoginOpen
    qualified o = pgIdent (fromMaybe "public" (o ^. #schema)) <> "." <> pgIdent (o ^. #relation)

-- | PostgreSQL facts inside one database for readers: every table and view
-- outside the system schemas with the given users' grants, and every
-- SECURITY DEFINER function with who among PUBLIC and the users may run it.
renderObserveRelations :: [Text] -> Text
renderObserveRelations users =
  T.unlines
    [ "SELECT json_build_object("
    , "  'relations', (SELECT coalesce(json_agg(json_build_object('schema', n.nspname, 'name', c.relname, 'kind', c.relkind::text, 'owner', pg_get_userbyid(c.relowner), 'options', coalesce(to_json(c.reloptions), '[]'), 'grants', (SELECT coalesce(json_agg(json_build_object('grantee', pg_get_userbyid(a.grantee), 'privilege', a.privilege_type, 'grantable', a.is_grantable) ORDER BY 1), '[]') FROM aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a WHERE a.grantee IN (SELECT oid FROM pg_roles WHERE rolname IN (" <> userList <> ")))) ORDER BY n.nspname, c.relname), '[]') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema' AND c.relkind IN ('r', 'p', 'v', 'm')),"
    , "  'definerFunctions', (SELECT coalesce(json_agg(json_build_object('schema', n.nspname, 'name', p.proname, 'signature', pg_get_function_identity_arguments(p.oid), 'executors', (SELECT coalesce(json_agg(CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END ORDER BY 1), '[]') FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.privilege_type = 'EXECUTE' AND (a.grantee = 0 OR a.grantee IN (SELECT oid FROM pg_roles WHERE rolname IN (" <> userList <> "))))) ORDER BY n.nspname, p.proname), '[]') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema' AND p.prosecdef)"
    , ");"
    ]
  where
    userList = literals users

pgIdent :: Text -> Text
pgIdent name = "\"" <> name <> "\""

literal :: Text -> Text
literal value = "'" <> value <> "'"

literals :: [Text] -> Text
literals = T.intercalate ", " . map literal
