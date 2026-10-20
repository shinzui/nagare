-- EP-202 M1 reference fixture, extended by EP-204, EP-205, EP-206 and EP-208 M1: the ClickHouse 26.8 statements for one app database.
--
-- App database "alpha-ch" on server "smoke-ch", logical databases "alpha" and
-- "alpha_ledger", users "alpha_runtime" and "alpha_migration". Proven by hand against
-- clickhouse/clickhouse-server:26.8 (26.8.29) on 2026-10-19 with
-- CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1. Each "-- operation:" block is one transport call:
-- SQL on stdin to
-- `clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery`
-- inside the server pod. SQL-created users and grants live under /var/lib/clickhouse/access
-- on the data PVC and survive a restart. The blocks are the member-level commands the
-- app-database adapter sends, in the order a first apply sends them.
--
-- Fixture passwords: runtime "pw-alpha_runtime", migration "pw-alpha_migration", rotated
-- runtime "pw2-alpha_runtime". The salt is the uppercase hex text of 16 fixed bytes, and
-- the hash is hex(SHA256(password || salt-text)): the salt is used as its text, not as
-- decoded bytes. The query log records the statement as "IDENTIFIED WITH sha256_password".
--
-- The grant lists are explicit leaf privileges. ALL ON db.* expands to a version-dependent
-- list (46 entries on 26.8), which observation could not compare across engine upgrades;
-- system.grants reports these lists back exactly as granted. DROP DATABASE and
-- ALTER DATABASE are deliberately absent.

-- operation: create-user alpha_migration
CREATE USER alpha_migration IDENTIFIED WITH sha256_hash BY '2DE186A428DCF728437A14575A7BE085AFE37509873C1CFA8A62AADB18A918D4' SALT '000102030405060708090A0B0C0D0E0F' HOST ANY DEFAULT DATABASE alpha;

-- operation: create-user alpha_runtime
CREATE USER alpha_runtime IDENTIFIED WITH sha256_hash BY 'CCC85116A7D5E75E1446E5E469AB134ED6821FF01237AE80EE61FADEAB87BDFC' SALT '000102030405060708090A0B0C0D0E0F' HOST ANY DEFAULT DATABASE alpha;

-- operation: user-access alpha_migration on
-- WRITE ON FILE is global but write-only: it lets BACKUP ... TO File(...) write under
-- backups.allowed_path and INSERT INTO FUNCTION file(...) write under user_files. Without
-- READ ON FILE nothing can be read back, RESTORE is refused, a path outside the allowed
-- one is refused, and an existing archive cannot be overwritten.
ALTER USER alpha_migration HOST ANY;
GRANT WRITE ON FILE TO alpha_migration;
REVOKE SELECT ON system.parts FROM alpha_migration;
REVOKE SELECT ON system.mutations FROM alpha_migration;
REVOKE SELECT ON system.disks FROM alpha_migration;
REVOKE SELECT ON system.storage_policies FROM alpha_migration;
REVOKE CREATE ARBITRARY TEMPORARY TABLE ON *.* FROM alpha_migration;
ALTER USER alpha_migration SETTINGS NONE;

-- operation: user-access alpha_migration off
-- HOST NONE refuses every login. Databases, data and Secrets are kept.
ALTER USER alpha_migration HOST NONE;
REVOKE WRITE ON FILE FROM alpha_migration;
REVOKE SELECT ON system.parts FROM alpha_migration;
REVOKE SELECT ON system.mutations FROM alpha_migration;
REVOKE SELECT ON system.disks FROM alpha_migration;
REVOKE SELECT ON system.storage_policies FROM alpha_migration;
REVOKE CREATE ARBITRARY TEMPORARY TABLE ON *.* FROM alpha_migration;
ALTER USER alpha_migration SETTINGS NONE;

-- operation: user-access alpha_runtime on
ALTER USER alpha_runtime HOST ANY;
REVOKE SELECT ON system.parts FROM alpha_runtime;
REVOKE SELECT ON system.mutations FROM alpha_runtime;
REVOKE SELECT ON system.disks FROM alpha_runtime;
REVOKE SELECT ON system.storage_policies FROM alpha_runtime;
REVOKE CREATE ARBITRARY TEMPORARY TABLE ON *.* FROM alpha_runtime;
ALTER USER alpha_runtime SETTINGS NONE;

-- operation: user-access alpha_runtime off
ALTER USER alpha_runtime HOST NONE;
REVOKE SELECT ON system.parts FROM alpha_runtime;
REVOKE SELECT ON system.mutations FROM alpha_runtime;
REVOKE SELECT ON system.disks FROM alpha_runtime;
REVOKE SELECT ON system.storage_policies FROM alpha_runtime;
REVOKE CREATE ARBITRARY TEMPORARY TABLE ON *.* FROM alpha_runtime;
ALTER USER alpha_runtime SETTINGS NONE;

-- operation: user-access alpha_runtime on with declared access
-- EP-204 M1. Every allow-listed exception is granted when declared and revoked otherwise,
-- so the rendering depends only on the declaration and a retry needs no history. Revoking
-- a grant the user does not hold succeeds and leaves no partial-revoke row. system.grants
-- reports the four system tables as table-level SELECT rows on database "system" and the
-- temporary-table privilege as one global row; no implied privilege rows appear.
--   SELECT on system.parts and system.mutations shows only the rows of tables the user can
--   SHOW: alpha_runtime saw alpha's parts and mutations and none of beta's.
--   CREATE ARBITRARY TEMPORARY TABLE allows ENGINE = Join(ANY, LEFT, k) and Memory; without
--   it both are refused (497, CREATE [ARBITRARY] TEMPORARY TABLE ON *.*). With it a
--   temporary table on URL(...), File(...) or S3(...) is still refused with 497 (TABLE
--   ENGINE ON URL / File / S3).
-- The one SETTINGS statement replaces the user's whole settings list (a second ALTER USER
-- ... SETTINGS leaves only its own elements; SETTINGS NONE leaves none). Each ceiling is
-- also the default, so an app that sets nothing gets it:
--   SET max_memory_usage = 134217728 is accepted; = 536870912 is refused (452, "shouldn't
--   be greater than 268435456"); = 0, max_execution_time = 0 and
--   max_concurrent_queries_for_user = 0 are each refused (452, "shouldn't be less than 1"),
--   also as a per-query SETTINGS clause. enable_analyzer, async_insert and mutations_sync
--   stay settable.
--   Enforcement, alpha_runtime against beta_runtime on the same server:
--   SELECT sum(cityHash64(number)) FROM numbers(100000000000) SETTINGS max_threads = 1
--   stops at 5000 ms (159, TIMEOUT_EXCEEDED); beta ran it until its own per-query 7 s cap.
--   SELECT length(groupArray(number)) FROM numbers(30000000) is refused (241,
--   MEMORY_LIMIT_EXCEEDED, "would use 384.62 MiB"); beta completed it with a 512.14 MiB peak
--   in system.query_log. The third concurrent SELECT sleep(3) is refused (202, "Too many
--   simultaneous queries for user alpha_runtime"); beta ran three.
ALTER USER alpha_runtime HOST ANY;
GRANT SELECT ON system.parts TO alpha_runtime;
GRANT SELECT ON system.mutations TO alpha_runtime;
GRANT SELECT ON system.disks TO alpha_runtime;
GRANT SELECT ON system.storage_policies TO alpha_runtime;
GRANT CREATE ARBITRARY TEMPORARY TABLE ON *.* TO alpha_runtime;
ALTER USER alpha_runtime SETTINGS max_memory_usage = 268435456 MIN 1 MAX 268435456, max_execution_time = 5 MIN 1 MAX 5, max_concurrent_queries_for_user = 2 MIN 1 MAX 2;

-- operation: user-access alpha_runtime off with declared access
-- Retirement revokes the exceptions with the other server grants; the limits follow the
-- declaration whether or not the user can log in.
ALTER USER alpha_runtime HOST NONE;
REVOKE SELECT ON system.parts FROM alpha_runtime;
REVOKE SELECT ON system.mutations FROM alpha_runtime;
REVOKE SELECT ON system.disks FROM alpha_runtime;
REVOKE SELECT ON system.storage_policies FROM alpha_runtime;
REVOKE CREATE ARBITRARY TEMPORARY TABLE ON *.* FROM alpha_runtime;
ALTER USER alpha_runtime SETTINGS max_memory_usage = 268435456 MIN 1 MAX 268435456, max_execution_time = 5 MIN 1 MAX 5, max_concurrent_queries_for_user = 2 MIN 1 MAX 2;

-- operation: user-access alpha_migration on with declared access
-- The scheduled backup is one BACKUP query as the migration user, so its ceilings bound it:
-- with max_execution_time = 1 a 3.8 GiB BACKUP failed with 159 (BACKUP_FAILED in
-- system.backups; the check fired after 22 s, not at 1 s), and with two sleep(3) queries
-- running a BACKUP was refused with 202 under max_concurrent_queries_for_user = 2. Its
-- tracked memory stayed at 5.49 MiB, so max_memory_usage = 268435456 did not stop the same
-- backup (it completed in 76 s).
ALTER USER alpha_migration HOST ANY;
GRANT WRITE ON FILE TO alpha_migration;
REVOKE SELECT ON system.parts FROM alpha_migration;
REVOKE SELECT ON system.mutations FROM alpha_migration;
GRANT SELECT ON system.disks TO alpha_migration;
GRANT SELECT ON system.storage_policies TO alpha_migration;
REVOKE CREATE ARBITRARY TEMPORARY TABLE ON *.* FROM alpha_migration;
ALTER USER alpha_migration SETTINGS max_memory_usage = 1073741824 MIN 1 MAX 1073741824, max_execution_time = 600 MIN 1 MAX 600;

-- operation: create-database alpha
-- Empty databases only; registration never creates tables. The migration user can also
-- run CREATE DATABASE IF NOT EXISTS on its own names (clickhouse-migrate does this).
CREATE DATABASE IF NOT EXISTS alpha ENGINE = Atomic;

-- operation: database-access alpha on
GRANT SHOW TABLES, SHOW COLUMNS, SHOW DICTIONARIES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW, DROP DICTIONARY, TRUNCATE, OPTIMIZE, BACKUP, dictGet ON alpha.* TO alpha_migration;
GRANT SHOW TABLES, SHOW COLUMNS, SELECT, INSERT, ALTER UPDATE, ALTER DELETE, dictGet ON alpha.* TO alpha_runtime;

-- operation: database-access alpha off
REVOKE ALL ON alpha.* FROM alpha_migration;
REVOKE ALL ON alpha.* FROM alpha_runtime;

-- operation: create-database alpha_ledger
CREATE DATABASE IF NOT EXISTS alpha_ledger ENGINE = Atomic;

-- operation: database-access alpha_ledger on
GRANT SHOW TABLES, SHOW COLUMNS, SHOW DICTIONARIES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW, DROP DICTIONARY, TRUNCATE, OPTIMIZE, BACKUP, dictGet ON alpha_ledger.* TO alpha_migration;
GRANT SHOW TABLES, SHOW COLUMNS, SELECT, INSERT, ALTER UPDATE, ALTER DELETE, dictGet ON alpha_ledger.* TO alpha_runtime;

-- operation: database-access alpha_ledger off
REVOKE ALL ON alpha_ledger.* FROM alpha_migration;
REVOKE ALL ON alpha_ledger.* FROM alpha_runtime;

-- operation: database-access alpha withheld alpha_runtime
-- EP-205 M1. Quiesce on ClickHouse: an open native session survives every login-level
-- change (ALTER USER ... HOST NONE, a quota of MAX queries = 0 or 1, VALID UNTIL a past
-- date) and keeps querying; ClickHouse 26.8 has no per-user idle-session view (no
-- session_log; system.user_processes lists users, not sessions; TCPConnection is
-- server-wide). A grant change reaches an open session at its next query, so a quiesced
-- user's database grants are withheld here and its server grants and exceptions by
-- user-access off; resume grants them again and system.grants is byte-identical after
-- (md5 of the sorted rows). HTTP requests authenticate one by one, session_id or not, so
-- HOST NONE refuses them. The migration user keeps its grants: its SQL SECURITY DEFINER
-- view and materialized view keep working, and it can still run DDL.
GRANT SHOW TABLES, SHOW COLUMNS, SHOW DICTIONARIES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW, DROP DICTIONARY, TRUNCATE, OPTIMIZE, BACKUP, dictGet ON alpha.* TO alpha_migration;
REVOKE ALL ON alpha.* FROM alpha_runtime;

-- operation: drain alpha_runtime
-- A running query survives the revoke and ends at KILL QUERY ... SYNC (code 394 "Query was
-- cancelled" in its client); beta_runtime's query keeps running. The drain then observes
-- the blocked users' running queries, the app's unfinished mutations (a failing one keeps
-- is_done = 0 with latest_fail_reason set, and stalls the mutations queued before it), and
-- the server identity. now() - uptime() is whole seconds and may move by one between
-- reads, so it is reported, not compared.
--   Probe: SELECT sleepEachRow(1) FROM numbers(600) SETTINGS max_block_size = 1; without
--   max_block_size the block sleeps 600 s and is refused (code 160, at most 3 s per block).
KILL QUERY WHERE user IN ('alpha_runtime') SYNC FORMAT Null;
SELECT 'session' AS kind, user, query_id FROM system.processes WHERE user IN ('alpha_runtime') ORDER BY ALL FORMAT JSONEachRow;
SELECT 'mutation' AS kind, database, table, mutation_id, latest_fail_reason FROM system.mutations WHERE database IN ('alpha', 'alpha_ledger') AND is_done = 0 ORDER BY ALL FORMAT JSONEachRow;
SELECT 'server' AS kind, toString(serverUUID()) AS uuid, toString(now() - uptime()) AS started FORMAT JSONEachRow;

-- operation: set-password alpha_runtime
-- Rotation: the Secret holds the new password first, then the user follows it.
ALTER USER alpha_runtime IDENTIFIED WITH sha256_hash BY 'BBC56EF6B104E2377EFF73C4C1544DE2B0181C5CDFA8FC99D26B62765BDFE443' SALT '101112131415161718191A1B1C1D1E1F';

-- operation: observe
-- One JSONEachRow row per fact, each tagged with its kind. Grants cover the app's users
-- anywhere and any user on the app's databases, so a grant to another app's user on
-- these databases is observed too. Settings rows (EP-204) are the user's own settings
-- elements: a declared ceiling is value = min-of-1 = max with no writability; an inherited
-- profile is a row with only inherit_profile set; a CONST setting has writability CONST.
-- Privilege rows (EP-208) are the server's own privilege tree: each privilege, its parent
-- group and its level, so a declared own-database privilege is judged by the running engine.
SELECT 'user' AS kind, name, toString(id) AS physical, host_ip, host_names, host_names_regexp, host_names_like, default_database FROM system.users WHERE name IN ('alpha_migration', 'alpha_runtime') ORDER BY name FORMAT JSONEachRow;
SELECT 'grant' AS kind, user_name, access_type, database, table, column, is_partial_revoke, grant_option FROM system.grants WHERE user_name IN ('alpha_migration', 'alpha_runtime') OR database IN ('alpha', 'alpha_ledger') ORDER BY ALL FORMAT JSONEachRow;
SELECT 'role' AS kind, user_name, granted_role_name FROM system.role_grants WHERE user_name IN ('alpha_migration', 'alpha_runtime') ORDER BY ALL FORMAT JSONEachRow;
SELECT 'setting' AS kind, user_name, setting_name, value, min, max, writability, inherit_profile FROM system.settings_profile_elements WHERE user_name IN ('alpha_migration', 'alpha_runtime') ORDER BY ALL FORMAT JSONEachRow;
SELECT 'database' AS kind, name, toString(uuid) AS physical, engine FROM system.databases WHERE name IN ('alpha', 'alpha_ledger') ORDER BY name FORMAT JSONEachRow;
SELECT 'privilege' AS kind, privilege, parent_group, level FROM system.privileges ORDER BY privilege FORMAT JSONEachRow;

-- operation: backup
-- In the backup job, with the alpha-ch-migration Secret's env, against the server Service.
-- One archive covers every logical database of the app database consistently:
BACKUP DATABASE alpha, DATABASE alpha_ledger TO File('alpha-ch-backup-r1.zip');

-- operation: restore-scratch
-- As the administrator, followed by the declared grant set on the scratch names.
RESTORE DATABASE alpha AS alpha_restore_r1, DATABASE alpha_ledger AS alpha_ledger_restore_r1 FROM File('alpha-ch-backup-r1.zip');
GRANT SHOW TABLES, SHOW COLUMNS, SHOW DICTIONARIES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW, DROP DICTIONARY, TRUNCATE, OPTIMIZE, BACKUP, dictGet ON alpha_restore_r1.* TO alpha_migration;
GRANT SHOW TABLES, SHOW COLUMNS, SHOW DICTIONARIES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW, DROP DICTIONARY, TRUNCATE, OPTIMIZE, BACKUP, dictGet ON alpha_ledger_restore_r1.* TO alpha_migration;
GRANT SHOW TABLES, SHOW COLUMNS, SELECT, INSERT, ALTER UPDATE, ALTER DELETE, dictGet ON alpha_restore_r1.* TO alpha_runtime;
GRANT SHOW TABLES, SHOW COLUMNS, SELECT, INSERT, ALTER UPDATE, ALTER DELETE, dictGet ON alpha_ledger_restore_r1.* TO alpha_runtime;

-- operation: restore-rebuilt
-- After the server is rebuilt and the app-database scope is re-applied, the declared
-- databases exist and are empty. RESTORE loads into the existing empty databases under
-- their own names, so no DROP DATABASE is needed; grants are keyed by name and stay.
-- The block is refused unless the first query returns 0.
SELECT count() FROM system.tables WHERE database IN ('alpha', 'alpha_ledger');
RESTORE DATABASE alpha, DATABASE alpha_ledger FROM File('alpha-ch-backup-r1.zip');

-- operation: reader-access alpha_reader_dash on
-- EP-206 M1. A reader is a third user with one SELECT per declared object and the reader
-- settings: readonly = 2 and result_overflow_mode = 'throw' CONST, five ceilings MIN 1 MAX.
-- It reads its definer views (alpha.v1, alpha.v2, the parameterized alpha.pv(x = 1)); the
-- base table, an undeclared table, INSERT, ALTER ... UPDATE, CREATE TABLE, CREATE TEMPORARY
-- TABLE, CREATE USER, system.parts and beta.t are refused with 497, SET readonly = 0 with
-- 164, and each ceiling's SET above it or to 0 with 452. Enforced: max_execution_time
-- (159 at 30000 ms), max_memory_usage (241), max_result_rows (396), max_result_bytes (396,
-- on rows sent to the client; a FORMAT Null probe does not count bytes). A grant on a table
-- that does not exist yet is accepted and reported exactly in system.grants, so ClickHouse
-- grants up front and has nothing pending. A grant the accepted declaration named and the
-- desired one does not is revoked; revoking one not held is a no-op.
ALTER USER alpha_reader_dash HOST ANY;
GRANT SELECT ON alpha.v1 TO alpha_reader_dash;
GRANT SELECT ON alpha.v2 TO alpha_reader_dash;
GRANT SELECT ON alpha.pv TO alpha_reader_dash;
REVOKE SELECT ON alpha.not_yet FROM alpha_reader_dash;
ALTER USER alpha_reader_dash SETTINGS readonly = 2 CONST, result_overflow_mode = 'throw' CONST, max_memory_usage = 536870912 MIN 1 MAX 536870912, max_execution_time = 30 MIN 1 MAX 30, max_result_rows = 10000 MIN 1 MAX 10000, max_result_bytes = 10485760 MIN 1 MAX 10485760, max_threads = 4 MIN 1 MAX 4;
-- operation: reader-access alpha_reader_dash off
ALTER USER alpha_reader_dash HOST NONE;
REVOKE SELECT ON alpha.v1 FROM alpha_reader_dash;
REVOKE SELECT ON alpha.v2 FROM alpha_reader_dash;
REVOKE SELECT ON alpha.pv FROM alpha_reader_dash;
ALTER USER alpha_reader_dash SETTINGS readonly = 2 CONST, result_overflow_mode = 'throw' CONST, max_memory_usage = 536870912 MIN 1 MAX 536870912, max_execution_time = 30 MIN 1 MAX 30, max_result_rows = 10000 MIN 1 MAX 10000, max_result_bytes = 10485760 MIN 1 MAX 10485760, max_threads = 4 MIN 1 MAX 4;

-- operation: database-access alpha on with privileges
-- EP-208 M1. The runtime declares CREATE TABLE and DROP TABLE, granted on each of the app's
-- databases with the fixed set in one GRANT. As alpha_runtime it then creates, inserts into
-- and drops a MergeTree table in alpha and in alpha_ledger; in beta CREATE TABLE is refused
-- (497), as are an ENGINE = URL(...) table in alpha (497, no source privilege) and CREATE
-- DATABASE alpha_x (497). ClickHouse 26.8 also lets CREATE TABLE create a view and DROP TABLE
-- drop one in the same database.
-- system.privileges has 248 rows: a privilege, its parent group and its level (GLOBAL,
-- DATABASE, TABLE, DICTIONARY, VIEW, COLUMN, NAMED_COLLECTION, USER_NAME, TABLE_ENGINE,
-- DEFINER, SOURCE, or NULL for most groups; CREATE ARBITRARY TEMPORARY TABLE is a group at
-- GLOBAL). GRANT <t> ON alpha.* is refused with 509 INVALID_GRANT ("CREATE FUNCTION cannot be
-- granted on the database level") for a GLOBAL privilege (CREATE FUNCTION, URL, CREATE
-- TEMPORARY TABLE, INTROSPECTION, KILL QUERY); TABLE ENGINE is a syntax error (62) without
-- its engine. A group is accepted and grants only its leaves that fit a database: ACCESS
-- MANAGEMENT grants the four row-policy privileges, CREATE grants CREATE DATABASE, TABLE,
-- VIEW and DICTIONARY, ALTER grants ALTER TABLE, ALTER DATABASE and ALTER VIEW, SYSTEM grants
-- 23 SYSTEM leaves, and SHOW FILESYSTEM CACHES (a NULL-level leaf) grants nothing. So a
-- declared token is accepted only when every leaf it stands for is at DATABASE, TABLE, VIEW,
-- DICTIONARY or COLUMN level, and then means exactly those leaves.
-- system.grants reports the minimal cover of what is held: the six CREATE TABLE, DROP TABLE,
-- CREATE VIEW, DROP VIEW, TRUNCATE and OPTIMIZE come back as six rows under their own names;
-- with the fixed ALTER UPDATE and ALTER DELETE held, a further ALTER TABLE is one ALTER TABLE
-- row and no ALTER UPDATE or ALTER DELETE row; SHOW over SHOW TABLES and SHOW COLUMNS is one
-- SHOW row. A restart reports the same database-level rows (only BUG-7's READ ON FILE row
-- appears). After REVOKE ALL ON alpha.* (quiesce) the one GRANT below restores exactly the
-- rows above.
GRANT SHOW TABLES, SHOW COLUMNS, SHOW DICTIONARIES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW, DROP DICTIONARY, TRUNCATE, OPTIMIZE, BACKUP, dictGet ON alpha.* TO alpha_migration;
GRANT SHOW TABLES, SHOW COLUMNS, SELECT, INSERT, ALTER UPDATE, ALTER DELETE, dictGet, CREATE TABLE, DROP TABLE ON alpha.* TO alpha_runtime;

-- operation: database-access alpha on with privileges removed
-- The accepted declaration also named ALTER TABLE, which the runtime holds as one row. Each
-- held token not covered by the fixed and desired sets is revoked as observation reported
-- it, which also drops the fixed ALTER UPDATE and ALTER DELETE under it; the GRANT restores
-- them. A revoke of a grant not held is a no-op, so a retry ends in the same rows: SHOW
-- TABLES, SHOW COLUMNS, SELECT, INSERT, ALTER UPDATE, ALTER DELETE, CREATE TABLE, DROP TABLE,
-- dictGet.
GRANT SHOW TABLES, SHOW COLUMNS, SHOW DICTIONARIES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW, DROP DICTIONARY, TRUNCATE, OPTIMIZE, BACKUP, dictGet ON alpha.* TO alpha_migration;
REVOKE ALTER TABLE ON alpha.* FROM alpha_runtime;
GRANT SHOW TABLES, SHOW COLUMNS, SELECT, INSERT, ALTER UPDATE, ALTER DELETE, dictGet, CREATE TABLE, DROP TABLE ON alpha.* TO alpha_runtime;

-- operation: restore-scratch with privileges
-- The scratch names get each user's fixed set and its declared privileges.
RESTORE DATABASE alpha AS alpha_restore_r1, DATABASE alpha_ledger AS alpha_ledger_restore_r1 FROM File('alpha-ch-backup-r1.zip');
GRANT SHOW TABLES, SHOW COLUMNS, SHOW DICTIONARIES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW, DROP DICTIONARY, TRUNCATE, OPTIMIZE, BACKUP, dictGet ON alpha_restore_r1.* TO alpha_migration;
GRANT SHOW TABLES, SHOW COLUMNS, SHOW DICTIONARIES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE DATABASE, CREATE TABLE, CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW, DROP DICTIONARY, TRUNCATE, OPTIMIZE, BACKUP, dictGet ON alpha_ledger_restore_r1.* TO alpha_migration;
GRANT SHOW TABLES, SHOW COLUMNS, SELECT, INSERT, ALTER UPDATE, ALTER DELETE, dictGet, CREATE TABLE, DROP TABLE ON alpha_restore_r1.* TO alpha_runtime;
GRANT SHOW TABLES, SHOW COLUMNS, SELECT, INSERT, ALTER UPDATE, ALTER DELETE, dictGet, CREATE TABLE, DROP TABLE ON alpha_ledger_restore_r1.* TO alpha_runtime;
