-- EP-202 M1 reference fixture: the PostgreSQL 18 statements for one app database.
--
-- App database "alpha-pg" on server "smoke-pg" (initial database "smoke_pg"), logical
-- database "alpha", users "alpha_runtime" and "alpha_migration". Proven by hand against
-- postgres:18 on 2026-10-19. Each "-- operation:" block is one transport call: SQL on
-- stdin to `psql -v ON_ERROR_STOP=1 -X -q -U "$POSTGRES_USER" -d postgres` inside the
-- server pod, as the initdb superuser over the pod-local socket.
--
-- Fixture passwords: runtime "pw-alpha_runtime", migration "pw-alpha_migration",
-- rotated runtime "pw2-alpha_runtime". Salts are fixed (00..0f, 10..1f) so a renderer
-- given the same salt reproduces these verifiers byte for byte. A verifier is
-- SCRAM-SHA-256$4096:<b64 salt>$<b64 StoredKey>:<b64 ServerKey> (RFC 7677), computed
-- off the server, so plaintext never reaches the server or its logs.
--
-- The image trusts 127.0.0.1 and the socket (pg_hba "trust"); only non-loopback
-- connections authenticate. Password checks must therefore use the Service or pod IP.

-- operation: create-users
CREATE ROLE "alpha_migration" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD 'SCRAM-SHA-256$4096:AAECAwQFBgcICQoLDA0ODw==$gmxqu8Jd5O7hRWiZnaNbMPyhiMNp6qZ07DPcmAjwqiw=:D3heRF2d4KD71g5iPvzrmdIwRl2uldec2LBYSU1MDKo=';
CREATE ROLE "alpha_runtime" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD 'SCRAM-SHA-256$4096:AAECAwQFBgcICQoLDA0ODw==$o7ITE+DK/9AWGisEYEjtDsabO6iax3zSgS/SFI/LCwM=:hZWQeShnzHsLozOt+wxtxz1+objCZ3KrN1zNUVOhymA=';

-- operation: create-database
CREATE DATABASE "alpha" OWNER "alpha_migration";

-- operation: converge-grants
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

-- operation: observe-server
-- Run with -A -t; prints one JSON document. After converge-grants it reads:
--   roles: both with super/createrole/createdb/replication/bypassrls false, login true
--   memberships: []
--   databases: [{alpha, owner alpha_migration,
--                acl [alpha_migration=CTc/alpha_migration, alpha_runtime=Tc/alpha_migration]}]
--   system_databases: postgres, template1, smoke_pg each with acl [nagare=CTc/nagare]
SELECT json_build_object(
  'roles', (SELECT coalesce(json_agg(json_build_object('name', rolname, 'super', rolsuper, 'createrole', rolcreaterole, 'createdb', rolcreatedb, 'login', rolcanlogin, 'replication', rolreplication, 'bypassrls', rolbypassrls) ORDER BY rolname), '[]') FROM pg_roles WHERE rolname IN ('alpha_runtime', 'alpha_migration')),
  'memberships', (SELECT coalesce(json_agg(json_build_object('role', r.rolname, 'member', m.rolname) ORDER BY r.rolname, m.rolname), '[]') FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member WHERE r.rolname IN ('alpha_runtime', 'alpha_migration') OR m.rolname IN ('alpha_runtime', 'alpha_migration')),
  'databases', (SELECT coalesce(json_agg(json_build_object('name', datname, 'owner', pg_get_userbyid(datdba), 'acl', datacl::text[]) ORDER BY datname), '[]') FROM pg_database WHERE datname IN ('alpha')),
  'system_databases', (SELECT coalesce(json_agg(json_build_object('name', datname, 'acl', datacl::text[]) ORDER BY datname), '[]') FROM pg_database WHERE datname IN ('postgres', 'template1', 'smoke_pg'))
);

-- operation: observe-database
-- Run with -d alpha -A -t, only when observe-server shows the database. After
-- converge-grants (and before any migration) it reads:
--   schemas: [{public, owner alpha_migration,
--              acl [alpha_migration=UC/alpha_migration, alpha_runtime=U/alpha_migration]}]
--   default_acl (role alpha_migration, schema "-"):
--     S [alpha_migration=rwU/alpha_migration, alpha_runtime=rU/alpha_migration]
--     f [=X/alpha_migration, alpha_migration=X/alpha_migration, alpha_runtime=X/alpha_migration]
--     n [alpha_migration=UC/alpha_migration, alpha_runtime=U/alpha_migration]
--     r [alpha_migration=arwdDxtm/alpha_migration, alpha_runtime=arwd/alpha_migration]
-- Schemas the migration user creates later carry the "n" default ACL. A grant to any
-- other role, or a membership, is drift.
SELECT json_build_object(
  'schemas', (SELECT coalesce(json_agg(json_build_object('name', nspname, 'owner', pg_get_userbyid(nspowner), 'acl', nspacl::text[]) ORDER BY nspname), '[]') FROM pg_namespace WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema'),
  'default_acl', (SELECT coalesce(json_agg(json_build_object('role', pg_get_userbyid(defaclrole), 'schema', defaclnamespace::regnamespace::text, 'type', defaclobjtype, 'acl', defaclacl::text[]) ORDER BY defaclobjtype), '[]') FROM pg_default_acl)
);

-- operation: rotate
-- One user per call. The Secret is replaced after this succeeds.
ALTER ROLE "alpha_runtime" PASSWORD 'SCRAM-SHA-256$4096:EBESExQVFhcYGRobHB0eHw==$ZtyYF60jGslJuuvaRTEew6yw5T/TRbmjcdZZUlllpsg=:S3AIkYIuL7rc9rtR7Z4hrCa/TZf7dbUgnZWBM3jDNMI=';

-- operation: retire
-- The database, its data and the Secrets are kept. The owner keeps its implicit
-- privileges but cannot log in.
ALTER ROLE "alpha_runtime" NOLOGIN;
ALTER ROLE "alpha_migration" NOLOGIN;
REVOKE CONNECT, TEMPORARY ON DATABASE "alpha" FROM "alpha_runtime";
SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename IN ('alpha_runtime', 'alpha_migration');

-- operation: re-enable
ALTER ROLE "alpha_runtime" LOGIN;
ALTER ROLE "alpha_migration" LOGIN;
GRANT CONNECT, TEMPORARY ON DATABASE "alpha" TO "alpha_runtime";

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
-- After the server is rebuilt and the app-database scope is re-applied (create-users,
-- create-database, converge-grants with the retained Secrets' passwords), the dump loads
-- into the empty database as the administrator:
--   pg_restore --exit-on-error -U "$POSTGRES_USER" -d alpha "$DUMP"
-- Empty means: no relation outside pg_catalog and information_schema.
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_toast%';
