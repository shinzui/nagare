-- EP-257 M1 reference fixture: the PostgreSQL 18 rules an app-owned app database rests on.
--
-- Run by app-owned.sh against a disposable postgres:18 server. Each "-- step: USER DATABASE"
-- block is one psql session, `psql -X -a -v ON_ERROR_STOP=0 -U USER -d DATABASE`, over the
-- pod-local socket (trusted, so no passwords are needed). The server's own output for every
-- step is recorded in app-owned.expected; a step expected to fail shows its ERROR line there.
--
-- Tenants on one server (initial database "smoke_pg"):
--   alpha  app-owned, declared owning role "kotei_maintenance"; owner login "alpha_owner".
--   beta   app-owned, no declared owning role; owner login "beta_owner" owns "beta".
--   gamma  Nagare-managed; users "gamma_runtime" and "gamma_migration" (Nagare's users).
-- The alpha steps run a Kotei-shaped privilege script, modelled on
-- kotei-migrations/privileges/apply.sql in mori://shinzui/kotei (project-relative path;
-- artifact-level URI pending), twice; then the AC-2 attempts as alpha_owner and as a login
-- alpha created; then the catalog query that reads each app's roles.

-- step: postgres postgres
-- What Nagare renders for the three tenants, as the server administrator.
CREATE ROLE "gamma_migration" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE "gamma_runtime" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE DATABASE "gamma" OWNER "gamma_migration";
REVOKE ALL ON DATABASE "gamma" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE "gamma" TO "gamma_runtime";
-- alpha: the owner user, its setting, the declared owning role, the database.
CREATE ROLE "alpha_owner" LOGIN NOSUPERUSER NOCREATEDB CREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE "alpha_owner" SET createrole_self_grant = 'set, inherit';
CREATE ROLE "kotei_maintenance" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT "kotei_maintenance" TO "alpha_owner" WITH ADMIN TRUE, INHERIT TRUE, SET TRUE;
CREATE DATABASE "alpha" OWNER "kotei_maintenance";
REVOKE ALL ON DATABASE "alpha" FROM PUBLIC;
-- beta: the owner user owns its database directly.
CREATE ROLE "beta_owner" LOGIN NOSUPERUSER NOCREATEDB CREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE "beta_owner" SET createrole_self_grant = 'set, inherit';
CREATE DATABASE "beta" OWNER "beta_owner";
REVOKE ALL ON DATABASE "beta" FROM PUBLIC;
REVOKE CONNECT, TEMPORARY ON DATABASE "postgres", "template1", "smoke_pg" FROM PUBLIC;

-- step: beta_owner beta
-- beta's own roles and a login, made by its owner.
CREATE ROLE beta_reader NOLOGIN;
CREATE ROLE beta_app LOGIN IN ROLE beta_reader;
GRANT CONNECT ON DATABASE beta TO beta_reader;
CREATE TABLE beta_secret (v text);
INSERT INTO beta_secret VALUES ('beta only');

-- step: alpha_owner alpha
-- alpha's migrations, run as the owner: schemas, tables, a sequence and functions.
CREATE SCHEMA kiroku;
CREATE SCHEMA kotei;
CREATE TABLE kiroku.events (id bigserial PRIMARY KEY, body text);
CREATE TABLE kotei.erasure_window (active boolean NOT NULL DEFAULT false);
CREATE FUNCTION kotei.native_observation_publishable() RETURNS boolean LANGUAGE sql AS 'SELECT true';
CREATE FUNCTION kotei.begin_erasure_window(text) RETURNS void LANGUAGE sql AS 'SELECT';

-- step: alpha_owner alpha
-- The Kotei-shaped privilege script, first run.
DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'kotei_inspection') THEN
    CREATE ROLE kotei_inspection NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'kotei_runtime') THEN
    CREATE ROLE kotei_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'kotei_maintenance') THEN
    CREATE ROLE kotei_maintenance NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'kotei_erasure') THEN
    CREATE ROLE kotei_erasure NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
END
$roles$;
DO $membership$
BEGIN
  IF NOT pg_catalog.pg_has_role('kotei_erasure', 'kotei_runtime', 'MEMBER') THEN
    GRANT kotei_runtime TO kotei_erasure;
  END IF;
END
$membership$;
DO $database$
BEGIN
  IF EXISTS (SELECT 1 FROM kotei.erasure_window AS w WHERE w.active) THEN
    RAISE EXCEPTION 'finish or withdraw the active erasure before applying privileges';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database AS d
                 JOIN pg_catalog.pg_roles AS r ON r.oid = d.datdba
                 WHERE d.datname = pg_catalog.current_database() AND r.rolname = 'kotei_maintenance') THEN
    EXECUTE pg_catalog.format('ALTER DATABASE %I OWNER TO kotei_maintenance', pg_catalog.current_database());
  END IF;
  EXECUTE pg_catalog.format('REVOKE ALL ON DATABASE %I FROM PUBLIC', pg_catalog.current_database());
  EXECUTE pg_catalog.format('GRANT CONNECT ON DATABASE %I TO kotei_runtime, kotei_erasure, kotei_inspection', pg_catalog.current_database());
END
$database$;
REVOKE ALL ON SCHEMA kiroku, kotei FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA kiroku, kotei FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA kiroku, kotei FROM kotei_runtime;
GRANT USAGE ON SCHEMA kiroku, kotei TO kotei_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA kiroku, kotei TO kotei_runtime;
REVOKE UPDATE, DELETE, TRUNCATE ON TABLE kiroku.events FROM kotei_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA kiroku TO kotei_runtime;
GRANT EXECUTE ON FUNCTION kotei.native_observation_publishable() TO kotei_runtime;
GRANT USAGE, CREATE ON SCHEMA kiroku, kotei TO kotei_maintenance;
GRANT ALL ON ALL TABLES IN SCHEMA kiroku, kotei TO kotei_maintenance;
DO $ownership$
DECLARE
  object record;
BEGIN
  FOR object IN SELECT n.nspname FROM pg_catalog.pg_namespace AS n WHERE n.nspname IN ('kiroku', 'kotei')
  LOOP
    EXECUTE pg_catalog.format('ALTER SCHEMA %I OWNER TO kotei_maintenance', object.nspname);
  END LOOP;
  FOR object IN SELECT n.nspname, c.relname FROM pg_catalog.pg_class AS c
      JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname IN ('kiroku', 'kotei') AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  LOOP
    EXECUTE pg_catalog.format('ALTER TABLE %I.%I OWNER TO kotei_maintenance', object.nspname, object.relname);
  END LOOP;
  FOR object IN SELECT n.nspname, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid) AS arguments
      FROM pg_catalog.pg_proc AS p JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname IN ('kiroku', 'kotei') AND p.prokind = 'f'
  LOOP
    EXECUTE pg_catalog.format('ALTER FUNCTION %I.%I(%s) OWNER TO kotei_maintenance', object.nspname, object.proname, object.arguments);
  END LOOP;
END
$ownership$;
GRANT EXECUTE ON FUNCTION kotei.begin_erasure_window(pg_catalog.text) TO kotei_erasure;
REVOKE ALL ON SCHEMA kiroku, kotei FROM kotei_inspection;
GRANT USAGE ON SCHEMA kiroku, kotei TO kotei_inspection;
GRANT SELECT ON ALL TABLES IN SCHEMA kiroku, kotei TO kotei_inspection;
-- A login the app provisions, and a nested role creator: both reachable from alpha_owner.
DO $logins$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'kotei_app') THEN
    CREATE ROLE kotei_app LOGIN IN ROLE kotei_runtime;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'kotei_admin') THEN
    CREATE ROLE kotei_admin NOLOGIN CREATEROLE;
  END IF;
END
$logins$;

-- step: alpha_owner alpha
-- The same script, second run: every guarded statement is skipped and nothing fails.
DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'kotei_inspection') THEN
    CREATE ROLE kotei_inspection NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'kotei_maintenance') THEN
    CREATE ROLE kotei_maintenance NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
END
$roles$;
DO $database$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database AS d
                 JOIN pg_catalog.pg_roles AS r ON r.oid = d.datdba
                 WHERE d.datname = pg_catalog.current_database() AND r.rolname = 'kotei_maintenance') THEN
    EXECUTE pg_catalog.format('ALTER DATABASE %I OWNER TO kotei_maintenance', pg_catalog.current_database());
  END IF;
  EXECUTE pg_catalog.format('REVOKE ALL ON DATABASE %I FROM PUBLIC', pg_catalog.current_database());
  EXECUTE pg_catalog.format('GRANT CONNECT ON DATABASE %I TO kotei_runtime, kotei_erasure, kotei_inspection', pg_catalog.current_database());
END
$database$;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA kiroku, kotei TO kotei_runtime;
REVOKE UPDATE, DELETE, TRUNCATE ON TABLE kiroku.events FROM kotei_runtime;
DO $ownership$
DECLARE
  object record;
BEGIN
  FOR object IN SELECT n.nspname FROM pg_catalog.pg_namespace AS n WHERE n.nspname IN ('kiroku', 'kotei')
  LOOP
    EXECUTE pg_catalog.format('ALTER SCHEMA %I OWNER TO kotei_maintenance', object.nspname);
  END LOOP;
  FOR object IN SELECT n.nspname, c.relname FROM pg_catalog.pg_class AS c
      JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname IN ('kiroku', 'kotei') AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  LOOP
    EXECUTE pg_catalog.format('ALTER TABLE %I.%I OWNER TO kotei_maintenance', object.nspname, object.relname);
  END LOOP;
END
$ownership$;
-- The owner keeps full use of what kotei_maintenance now owns.
INSERT INTO kiroku.events (body) VALUES ('owner writes after the ownership move');
CREATE TABLE kotei.added_later (id int);
DROP TABLE kotei.added_later;

-- step: alpha_owner alpha
-- AC-2 as alpha_owner. Every statement below fails.
ALTER ROLE beta_owner PASSWORD 'x';
ALTER ROLE beta_reader NOLOGIN;
DROP ROLE beta_reader;
GRANT beta_reader TO alpha_owner;
GRANT beta_reader TO kotei_runtime;
ALTER ROLE gamma_runtime PASSWORD 'x';
DROP ROLE gamma_migration;
GRANT gamma_migration TO kotei_runtime;
CREATE ROLE kotei_super SUPERUSER;
CREATE ROLE kotei_creator CREATEDB;
CREATE ROLE kotei_replica REPLICATION;
CREATE ROLE kotei_bypass BYPASSRLS;
ALTER ROLE kotei_runtime CREATEDB;
ALTER ROLE kotei_runtime BYPASSRLS;
ALTER ROLE alpha_owner CREATEDB;
GRANT pg_read_all_data TO kotei_runtime;
GRANT pg_signal_backend TO alpha_owner;
GRANT pg_monitor TO kotei_inspection;
ALTER DATABASE alpha OWNER TO kotei_runtime;
ALTER DATABASE alpha OWNER TO alpha_owner;
ALTER DATABASE beta OWNER TO kotei_runtime;
ALTER TABLE kiroku.events OWNER TO beta_owner;
GRANT CONNECT ON DATABASE beta TO kotei_runtime;
GRANT CONNECT ON DATABASE postgres TO kotei_runtime;
-- A role alpha_owner did not create and holds no admin option on cannot be renamed.
ALTER ROLE beta_app RENAME TO kotei_stolen;

-- step: alpha_owner alpha
-- alpha_owner cannot shed the admin option it received at creation, so no role it made
-- leaves the set reachable from it. Revoking only removes the self-grant (set, inherit).
REVOKE ADMIN OPTION FOR kotei_runtime FROM alpha_owner;
REVOKE ADMIN OPTION FOR kotei_runtime FROM alpha_owner GRANTED BY postgres;
REVOKE kotei_runtime FROM alpha_owner GRANTED BY postgres;
REVOKE kotei_maintenance FROM alpha_owner GRANTED BY postgres;
-- A role alpha made with CREATEROLE makes a role in turn; both stay reachable.
SET ROLE kotei_admin;
CREATE ROLE kotei_nested NOLOGIN;
RESET ROLE;

-- step: alpha_owner postgres
-- alpha_owner cannot connect to a database it was not granted.

-- step: alpha_owner beta
-- Nor to beta.

-- step: kotei_app beta
-- A login alpha created cannot connect to beta.

-- step: kotei_app gamma
-- Nor to a Nagare-managed database.

-- step: kotei_app alpha
-- AC-2 as a login alpha created. Every statement below fails except the read and the write.
SELECT count(*) FROM kiroku.events;
INSERT INTO kiroku.events (body) VALUES ('runtime writes');
CREATE ROLE kotei_x;
ALTER ROLE beta_reader NOLOGIN;
ALTER ROLE kotei_runtime NOLOGIN;
GRANT beta_reader TO kotei_app;
GRANT pg_read_all_data TO kotei_app;
GRANT CONNECT ON DATABASE beta TO kotei_app;
ALTER ROLE gamma_runtime PASSWORD 'x';
SET ROLE beta_reader;
SET ROLE alpha_owner;
DELETE FROM kiroku.events;

-- step: postgres alpha
-- The reading of an app's roles: alpha_owner, then every role reachable through
-- admin-option memberships. Run for each tenant; the sets do not overlap.
WITH RECURSIVE app(oid) AS (
  SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'alpha_owner'
  UNION
  SELECT m.roleid FROM pg_catalog.pg_auth_members AS m JOIN app ON m.member = app.oid
  WHERE m.admin_option
)
SELECT r.rolname FROM pg_catalog.pg_roles AS r JOIN app USING (oid) ORDER BY 1;
WITH RECURSIVE app(oid) AS (
  SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'beta_owner'
  UNION
  SELECT m.roleid FROM pg_catalog.pg_auth_members AS m JOIN app ON m.member = app.oid
  WHERE m.admin_option
)
SELECT r.rolname FROM pg_catalog.pg_roles AS r JOIN app USING (oid) ORDER BY 1;
-- Memberships alpha holds, with their grantor and options.
SELECT r.rolname AS role, m2.rolname AS member, g.rolname AS grantor,
       a.admin_option, a.inherit_option, a.set_option
FROM pg_catalog.pg_auth_members AS a
JOIN pg_catalog.pg_roles AS r ON r.oid = a.roleid
JOIN pg_catalog.pg_roles AS m2 ON m2.oid = a.member
JOIN pg_catalog.pg_roles AS g ON g.oid = a.grantor
WHERE r.rolname LIKE 'kotei%' OR m2.rolname LIKE 'kotei%' OR m2.rolname = 'alpha_owner'
ORDER BY 1, 2, 3;
-- Ownership and the database's grants after the script.
SELECT d.datname, pg_catalog.pg_get_userbyid(d.datdba) AS owner, d.datacl
FROM pg_catalog.pg_database AS d WHERE d.datname IN ('alpha', 'beta', 'gamma') ORDER BY 1;
SELECT n.nspname, pg_catalog.pg_get_userbyid(n.nspowner) AS owner
FROM pg_catalog.pg_namespace AS n WHERE n.nspname IN ('kiroku', 'kotei') ORDER BY 1;
SELECT c.relname, pg_catalog.pg_get_userbyid(c.relowner) AS owner
FROM pg_catalog.pg_class AS c JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname IN ('kiroku', 'kotei') AND c.relkind = 'r' ORDER BY 1;

-- step: alpha_owner alpha
-- Reaches alpha's SQL can make, which the server allows and Nagare must report as drift
-- (EP-257 M3): sharing its own database or role with another app.
GRANT CONNECT ON DATABASE alpha TO beta_reader;
GRANT kotei_inspection TO beta_owner;

-- step: beta_owner alpha
-- After that grant, beta's owner reaches alpha: the reason it is drift.
SELECT count(*) FROM kiroku.events;
