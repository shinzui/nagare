-- EP-202 M1 reference fixture: the ClickHouse 26.8 statements for one app database.
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

-- operation: user-access alpha_migration off
-- HOST NONE refuses every login. Databases, data and Secrets are kept.
ALTER USER alpha_migration HOST NONE;
REVOKE WRITE ON FILE FROM alpha_migration;

-- operation: user-access alpha_runtime on
ALTER USER alpha_runtime HOST ANY;

-- operation: user-access alpha_runtime off
ALTER USER alpha_runtime HOST NONE;

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

-- operation: set-password alpha_runtime
-- Rotation: the Secret holds the new password first, then the user follows it.
ALTER USER alpha_runtime IDENTIFIED WITH sha256_hash BY 'BBC56EF6B104E2377EFF73C4C1544DE2B0181C5CDFA8FC99D26B62765BDFE443' SALT '101112131415161718191A1B1C1D1E1F';

-- operation: observe
-- One JSONEachRow row per fact, each tagged with its kind. Grants cover the app's users
-- anywhere and any user on the app's databases, so a grant to another app's user on
-- these databases is observed too.
SELECT 'user' AS kind, name, toString(id) AS physical, host_ip, host_names, host_names_regexp, host_names_like, default_database FROM system.users WHERE name IN ('alpha_migration', 'alpha_runtime') ORDER BY name FORMAT JSONEachRow;
SELECT 'grant' AS kind, user_name, access_type, database, table, column, is_partial_revoke, grant_option FROM system.grants WHERE user_name IN ('alpha_migration', 'alpha_runtime') OR database IN ('alpha', 'alpha_ledger') ORDER BY ALL FORMAT JSONEachRow;
SELECT 'role' AS kind, user_name, granted_role_name FROM system.role_grants WHERE user_name IN ('alpha_migration', 'alpha_runtime') ORDER BY ALL FORMAT JSONEachRow;
SELECT 'database' AS kind, name, toString(uuid) AS physical, engine FROM system.databases WHERE name IN ('alpha', 'alpha_ledger') ORDER BY name FORMAT JSONEachRow;

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
