-- EP-202 M1 reference fixture, extended by EP-204 M1 and EP-205 M1: the PostgreSQL 18 statements for one app database.
--
-- App database "alpha-pg" on server "smoke-pg" (initial database "smoke_pg"), logical
-- database "alpha", users "alpha_runtime" and "alpha_migration". Proven by hand against
-- postgres:18 on 2026-10-19. Each "-- operation:" block is one transport call: SQL on
-- stdin to `psql -v ON_ERROR_STOP=1 -X -q -A -t -U "$POSTGRES_USER" -d postgres` inside
-- the server pod, as the initdb superuser over the pod-local socket. The blocks are the
-- member-level commands the app-database adapter sends, in the order a first apply sends
-- them: both users, then the database and its access. Retirement is user-access with
-- login off for both users and database-access with access off; re-enabling is the same
-- two blocks with access on.
--
-- Fixture passwords: runtime "pw-alpha_runtime", migration "pw-alpha_migration",
-- rotated runtime "pw2-alpha_runtime". Salts are fixed (00..0f, 10..1f) so a renderer
-- given the same salt reproduces these verifiers byte for byte. A verifier is
-- SCRAM-SHA-256$4096:<b64 salt>$<b64 StoredKey>:<b64 ServerKey> (RFC 7677), computed
-- off the server, so plaintext never reaches the server or its logs.
--
-- The image trusts 127.0.0.1 and the socket (pg_hba "trust"); only non-loopback
-- connections authenticate. Password checks must therefore use the Service or pod IP,
-- or compare the stored verifier (observe-password).

-- operation: create-user alpha_migration
CREATE ROLE "alpha_migration" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD 'SCRAM-SHA-256$4096:AAECAwQFBgcICQoLDA0ODw==$gmxqu8Jd5O7hRWiZnaNbMPyhiMNp6qZ07DPcmAjwqiw=:D3heRF2d4KD71g5iPvzrmdIwRl2uldec2LBYSU1MDKo=';

-- operation: create-user alpha_runtime
CREATE ROLE "alpha_runtime" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD 'SCRAM-SHA-256$4096:AAECAwQFBgcICQoLDA0ODw==$o7ITE+DK/9AWGisEYEjtDsabO6iax3zSgS/SFI/LCwM=:hZWQeShnzHsLozOt+wxtxz1+objCZ3KrN1zNUVOhymA=';

-- operation: create-database alpha
CREATE DATABASE "alpha" OWNER "alpha_migration";

-- operation: database-access alpha on
-- PUBLIC keeps CONNECT on the system and initial databases by default; a shared server
-- hosts no direct consumer, so app users are shut out of them too.
REVOKE CONNECT, TEMPORARY ON DATABASE "postgres", "template1", "smoke_pg" FROM PUBLIC;
REVOKE ALL ON DATABASE "alpha" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE "alpha" TO "alpha_runtime";
\connect "alpha"
ALTER SCHEMA public OWNER TO "alpha_migration";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO "alpha_runtime";
ALTER DEFAULT PRIVILEGES FOR ROLE "alpha_migration" GRANT USAGE ON SCHEMAS TO "alpha_runtime";
ALTER DEFAULT PRIVILEGES FOR ROLE "alpha_migration" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "alpha_runtime";
ALTER DEFAULT PRIVILEGES FOR ROLE "alpha_migration" GRANT USAGE, SELECT ON SEQUENCES TO "alpha_runtime";
ALTER DEFAULT PRIVILEGES FOR ROLE "alpha_migration" GRANT EXECUTE ON FUNCTIONS TO "alpha_runtime";

-- operation: database-access alpha off
-- The database, its data and the Secrets are kept. The owner keeps its implicit
-- privileges but cannot log in once user-access is off.
REVOKE CONNECT, TEMPORARY ON DATABASE "alpha" FROM "alpha_runtime";

-- operation: user-access alpha_runtime on
ALTER ROLE "alpha_runtime" LOGIN CONNECTION LIMIT -1;
ALTER ROLE "alpha_runtime" RESET statement_timeout;

-- operation: user-access alpha_runtime off
ALTER ROLE "alpha_runtime" NOLOGIN CONNECTION LIMIT -1;
ALTER ROLE "alpha_runtime" RESET statement_timeout;
SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = 'alpha_runtime';

-- operation: user-access alpha_migration on
ALTER ROLE "alpha_migration" LOGIN CONNECTION LIMIT -1;
ALTER ROLE "alpha_migration" RESET statement_timeout;

-- operation: user-access alpha_migration off
ALTER ROLE "alpha_migration" NOLOGIN CONNECTION LIMIT -1;
ALTER ROLE "alpha_migration" RESET statement_timeout;
SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = 'alpha_migration';

-- operation: user-access alpha_runtime on with declared access
-- EP-204 M1. The connection limit is a ceiling: with CONNECTION LIMIT 3 and three sessions
-- open a fourth is refused with FATAL "too many connections for role "alpha_runtime"",
-- and pg_roles.rolconnlimit reports it (-1 when none is declared). statement_timeout is a
-- role default, not a ceiling: pg_db_role_setting holds it at setdatabase = 0 as the text
-- "statement_timeout=30s", RESET removes it, and a session may still SET
-- statement_timeout = 0. Both statements are sent on every converge, so a hand change is
-- restored and a retry needs no history.
ALTER ROLE "alpha_runtime" LOGIN CONNECTION LIMIT 3;
ALTER ROLE "alpha_runtime" SET statement_timeout = '30s';

-- operation: user-access alpha_runtime off with declared access
-- The limits follow the declaration whether or not the user can log in.
ALTER ROLE "alpha_runtime" NOLOGIN CONNECTION LIMIT 3;
ALTER ROLE "alpha_runtime" SET statement_timeout = '30s';
SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = 'alpha_runtime';

-- operation: pgmq-install
-- Not sent by Nagare: PGMQ's 0001-install-v1.11.0.sql grants, run by the app as
-- alpha_migration after it creates schema pgmq. observe-database then reports three
-- pg_monitor rows: USAGE on schema:pgmq (owned by alpha_migration), and SELECT in
-- alpha_migration's per-schema default privileges on tables and on sequences. The
-- per-table and per-sequence SELECT grants are not observed. With pg_monitor declared these
-- are tolerated, never granted by Nagare. pg_dump keeps them (ACL and DEFAULT ACL entries),
-- so a restore brings them back. As alpha_migration with CONNECTION LIMIT 1 and
-- statement_timeout = '1ms', pg_dump -Fc still completes: it opens one connection and sets
-- statement_timeout = 0 in its own session.
GRANT USAGE ON SCHEMA pgmq TO pg_monitor;
GRANT SELECT ON ALL TABLES IN SCHEMA pgmq TO pg_monitor;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA pgmq TO pg_monitor;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmq GRANT SELECT ON TABLES TO pg_monitor;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmq GRANT SELECT ON SEQUENCES TO pg_monitor;

-- operation: user-access alpha_runtime quiesced
-- EP-205 M1. Quiesce on PostgreSQL keeps every grant: NOLOGIN refuses a new login ("role
-- "alpha_runtime" is not permitted to log in") and the drain ends what is open. The limits
-- follow the declaration as when off. alpha_migration still logs in and runs DDL.
ALTER ROLE "alpha_runtime" NOLOGIN CONNECTION LIMIT -1;
ALTER ROLE "alpha_runtime" RESET statement_timeout;

-- operation: drain alpha_runtime
-- After the grace period: pg_terminate_backend ends an idle session and one running
-- pg_sleep(600) (2 terminated); beta_runtime's session keeps running. Then the blocked
-- users have no session, and the server identity is read.
SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename IN ('alpha_runtime');
SELECT json_build_object('sessions', (SELECT count(*) FROM pg_stat_activity WHERE usename IN ('alpha_runtime')), 'systemIdentifier', (SELECT system_identifier::text FROM pg_control_system()), 'started', pg_postmaster_start_time()::text);

-- operation: set-password alpha_runtime
-- Rotation: the Secret holds the new password first, then the role follows it.
ALTER ROLE "alpha_runtime" PASSWORD 'SCRAM-SHA-256$4096:EBESExQVFhcYGRobHB0eHw==$ZtyYF60jGslJuuvaRTEew6yw5T/TRbmjcdZZUlllpsg=:S3AIkYIuL7rc9rtR7Z4hrCa/TZf7dbUgnZWBM3jDNMI=';

-- operation: observe-server
-- Run with -A -t; prints one JSON document. Grants are aclexplode rows over the
-- effective ACL (a NULL ACL means the built-in default, so acldefault fills it in);
-- grantee 0 is PUBLIC. publicSystemAccess is whether PUBLIC may still connect to the
-- system or initial databases; foreignAccess lists "<user> on <database>" for each grant to the
-- app's users on any other database. Each role carries its connection limit and its
-- server-wide role settings (EP-204).
SELECT json_build_object(
  'roles', (SELECT coalesce(json_agg(json_build_object('name', r.rolname, 'oid', r.oid::text, 'login', r.rolcanlogin, 'elevated', array_remove(ARRAY[CASE WHEN r.rolsuper THEN 'SUPERUSER' END, CASE WHEN r.rolcreaterole THEN 'CREATEROLE' END, CASE WHEN r.rolcreatedb THEN 'CREATEDB' END, CASE WHEN r.rolreplication THEN 'REPLICATION' END, CASE WHEN r.rolbypassrls THEN 'BYPASSRLS' END], NULL), 'connectionLimit', r.rolconnlimit, 'settings', coalesce((SELECT array_to_json(s.setconfig) FROM pg_db_role_setting s WHERE s.setrole = r.oid AND s.setdatabase = 0), '[]')) ORDER BY r.rolname), '[]') FROM pg_roles r WHERE r.rolname IN ('alpha_migration', 'alpha_runtime')),
  'memberships', (SELECT coalesce(json_agg(json_build_object('role', r.rolname, 'member', m.rolname) ORDER BY r.rolname, m.rolname), '[]') FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member WHERE r.rolname IN ('alpha_migration', 'alpha_runtime') OR m.rolname IN ('alpha_migration', 'alpha_runtime')),
  'databases', (SELECT coalesce(json_agg(json_build_object('name', d.datname, 'oid', d.oid::text, 'owner', pg_get_userbyid(d.datdba), 'grants', (SELECT coalesce(json_agg(json_build_object('grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END, 'privilege', a.privilege_type, 'grantable', a.is_grantable) ORDER BY 1), '[]') FROM aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a)) ORDER BY d.datname), '[]') FROM pg_database d WHERE d.datname IN ('alpha')),
  'publicSystemAccess', (SELECT count(*) > 0 FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE d.datname IN ('postgres', 'template1', 'smoke_pg') AND a.grantee = 0 AND a.privilege_type IN ('CONNECT', 'TEMPORARY')),
  'foreignAccess', (SELECT coalesce(json_agg(DISTINCT pg_get_userbyid(a.grantee) || ' on ' || d.datname), '[]') FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE a.grantee IN (SELECT oid FROM pg_roles WHERE rolname IN ('alpha_migration', 'alpha_runtime')) AND d.datname NOT IN ('alpha'))
);

-- operation: observe-database alpha
-- Run with -d alpha -A -t, only when observe-server shows the database.
SELECT json_build_object(
  'schemas', (SELECT coalesce(json_agg(json_build_object('name', n.nspname, 'owner', pg_get_userbyid(n.nspowner), 'grants', (SELECT coalesce(json_agg(json_build_object('grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END, 'privilege', a.privilege_type, 'grantable', a.is_grantable) ORDER BY 1), '[]') FROM aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a)) ORDER BY n.nspname), '[]') FROM pg_namespace n WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'),
  'defaultAcl', (SELECT coalesce(json_agg(json_build_object('role', pg_get_userbyid(d.defaclrole), 'type', d.defaclobjtype::text, 'global', d.defaclnamespace = 0, 'grants', (SELECT coalesce(json_agg(json_build_object('grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END, 'privilege', a.privilege_type, 'grantable', a.is_grantable) ORDER BY 1), '[]') FROM aclexplode(d.defaclacl) a)) ORDER BY d.defaclobjtype), '[]') FROM pg_default_acl d)
);

-- operation: observe-password alpha_runtime
-- The stored SCRAM verifier; the adapter checks it against the Secret's password.
SELECT coalesce((SELECT rolpassword FROM pg_authid WHERE rolname = 'alpha_runtime'), '');

-- operation: backup
-- Shell, in the backup job, with the alpha-pg-migration Secret's env. The migration user
-- owns every object, so the dump is complete and keeps owners, ACLs and default
-- privileges (no --no-owner, no --no-privileges):
--   pg_dump -Fc "$DATABASE_URL" > "$DUMP"

-- operation: restore-scratch
-- As the administrator. The scratch database is created owned by the migration user with
-- the declared database-level ACL, then loaded:
--   pg_restore --exit-on-error -U "$POSTGRES_USER" -d alpha_restore_r1 "$DUMP"
-- Schema, table, sequence and function ACLs and the default privileges come back from the
-- dump. The other app's runtime user is refused CONNECT on the scratch database.
CREATE DATABASE "alpha_restore_r1" OWNER "alpha_migration";
REVOKE ALL ON DATABASE "alpha_restore_r1" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE "alpha_restore_r1" TO "alpha_runtime";

-- operation: restore-rebuilt
-- After the server is rebuilt and the app-database scope is re-applied (users, database
-- and access with the retained Secrets' passwords), the dump loads into the empty
-- database as the administrator:
--   pg_restore --exit-on-error -U "$POSTGRES_USER" -d alpha "$DUMP"
-- Empty means: no relation outside pg_catalog and information_schema.
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_toast%';

-- operation: reader-access alpha_reader_dash on
-- EP-206 M1. The read-only boundary is grants: CONNECT, USAGE on the objects' schemas and
-- SELECT on each declared object. With default_transaction_read_only = off and
-- statement_timeout = 0 set in the session, INSERT, UPDATE, DELETE (permission denied for
-- table base), INSERT into a view, CREATE TABLE (permission denied for schema public) and
-- CREATE TEMPORARY TABLE are still refused; the role defaults are advisory and stored as
-- default_transaction_read_only=on and statement_timeout=30s. The reader reads the
-- migration-owned views and is refused on their base table; a security_invoker=true view
-- fails with permission denied for table base. A migration-owned SECURITY DEFINER function
-- that inserts is callable through PUBLIC EXECUTE and writes; after REVOKE EXECUTE ... FROM
-- PUBLIC it is refused. CONNECTION LIMIT + 1 is refused (too many connections for role).
ALTER ROLE "alpha_reader_dash" LOGIN CONNECTION LIMIT 5;
ALTER ROLE "alpha_reader_dash" SET statement_timeout = '30s';
ALTER ROLE "alpha_reader_dash" SET default_transaction_read_only = on;
GRANT CONNECT ON DATABASE "alpha" TO "alpha_reader_dash";
\connect "alpha"
GRANT USAGE ON SCHEMA "public" TO "alpha_reader_dash";
GRANT SELECT ON "public"."v1" TO "alpha_reader_dash";
GRANT SELECT ON "public"."v2" TO "alpha_reader_dash";
REVOKE SELECT ON "public"."vi" FROM "alpha_reader_dash";
-- operation: reader-access alpha_reader_dash off
ALTER ROLE "alpha_reader_dash" NOLOGIN CONNECTION LIMIT 5;
ALTER ROLE "alpha_reader_dash" SET statement_timeout = '30s';
ALTER ROLE "alpha_reader_dash" SET default_transaction_read_only = on;
SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = 'alpha_reader_dash';
REVOKE CONNECT ON DATABASE "alpha" FROM "alpha_reader_dash";
\connect "alpha"
REVOKE USAGE ON SCHEMA "public" FROM "alpha_reader_dash";
REVOKE SELECT ON "public"."v1" FROM "alpha_reader_dash";
REVOKE SELECT ON "public"."v2" FROM "alpha_reader_dash";

-- operation: observe-relations alpha
-- Run with -d alpha. Every table, partitioned table, view and materialized view outside the
-- system schemas, its reloptions (security_invoker=true marks an invoker view) and the
-- given users' grants on it, and every SECURITY DEFINER function with the grantees among
-- PUBLIC and the users that may execute it.
SELECT json_build_object(
  'relations', (SELECT coalesce(json_agg(json_build_object('schema', n.nspname, 'name', c.relname, 'kind', c.relkind::text, 'options', coalesce(to_json(c.reloptions), '[]'), 'grants', (SELECT coalesce(json_agg(json_build_object('grantee', pg_get_userbyid(a.grantee), 'privilege', a.privilege_type, 'grantable', a.is_grantable) ORDER BY 1), '[]') FROM aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a WHERE a.grantee IN (SELECT oid FROM pg_roles WHERE rolname IN ('alpha_reader_dash')))) ORDER BY n.nspname, c.relname), '[]') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema' AND c.relkind IN ('r', 'p', 'v', 'm')),
  'definerFunctions', (SELECT coalesce(json_agg(json_build_object('schema', n.nspname, 'name', p.proname, 'signature', pg_get_function_identity_arguments(p.oid), 'executors', (SELECT coalesce(json_agg(CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END ORDER BY 1), '[]') FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.privilege_type = 'EXECUTE' AND (a.grantee = 0 OR a.grantee IN (SELECT oid FROM pg_roles WHERE rolname IN ('alpha_reader_dash'))))) ORDER BY n.nspname, p.proname), '[]') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema' AND p.prosecdef)
);
