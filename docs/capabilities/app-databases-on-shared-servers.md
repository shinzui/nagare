---
title: "App databases on shared servers"
type: Capability
description: "Give many apps their own databases, users, grants, credentials and backups on one shared PostgreSQL or ClickHouse server, with reviewed access, a per-app maintenance window and read-only readers."
generated:
  by: process:claude-code
  at: "2026-10-20T13:46:54Z"
capabilityId: CAP-26
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.7.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Dsl.AppDatabase"
  - "emitAppDatabases"
  - "appDatabases"
  - "appDatabaseReaders"
  - "nagarectl db app-database plan|list|rotate|retire"
  - "nagarectl db app-database backup|backup-receipts|restore|prune-scheduled-backups|recover-scheduled-prune"
  - "nagarectl db app-database quiesce|resume|evidence"
requires:
  - CAP-12
  - CAP-22
evidence:
  - kind: module
    resource: cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs
    proves: An app database declares its logical databases, migration and runtime users, access exceptions and limits, and readers with their consumers.
  - kind: module
    resource: cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs
    proves: PostgreSQL and ClickHouse commands create, grant, observe and revoke exactly the declared users and objects.
  - kind: test
    resource: cli/nagarectl/test/AppDatabaseSpec.hs
    proves: Declarations round-trip and refuse invalid input before planning; quiesce, resume, on-demand backup, reader bindings and scratch restores keep their boundaries.
  - kind: test
    resource: cli/nagarectl/test/AppDatabaseSqlSpec.hs
    proves: Generated SQL matches the proven fixtures, and observed grants, exceptions, ceilings, drains and readers classify as converged, pending or drift.
  - kind: test
    resource: cli/nagarectl/test/AppDatabaseWorldSpec.hs
    proves: Against a world model, a first apply converges, every interruption resumes, access Nagare never grants is drift, and a reader reads exactly its declared objects within its ceilings.
  - kind: example
    resource: scripts/local-app-database-smoke.sh
    proves: On a local context apps share one server per engine, are denied each other's data, keep their exceptions, ceilings and readers, and are quiesced, backed up, restored, rotated and retired without restarting the server or affecting the other apps.
  - kind: guide
    resource: docs/user/managed-databases.md
    proves: Sharing one server between apps, reviewed exceptions and limits, the maintenance window and read-only readers are documented.
  - kind: guide
    resource: docs/adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md
    proves: The tenancy decision and its isolation boundary are recorded.
  - kind: test
    resource: cli/nagarectl/test/AppDatabasePrivilegeSpec.hs
    proves: Own-database privileges and owner bindings load, bind and converge in a world model; a PGMQ queue is pending, granted, owned by the runtime and reachable by the migration user.
  - kind: guide
    resource: docs/adr/0031-own-database-privileges-are-declarable-server-wide-access-is-not.md
    proves: The rule that own-database privileges are declarable and server-wide access is not is recorded.
---

# App databases on shared servers

An app database is a reviewed tenant of an accepted
[managed database](managed-databases-and-backups.md) (CAP-12) server: one or more logical
databases (exactly one on PostgreSQL), a migration user that owns them and a runtime user that
reads and writes rows, with explicit grant lists and no access to another app or to the server's
own databases. A config that calls `emitAppDatabases` declares them, `db app-database plan`
provisions them through a saved review, and a workload binds one with `appDatabases`, receiving
only its runtime Secret. A server either hosts app databases or is bound directly, never both.

Since 0.8.0, an app database's `access` names reviewed exceptions from a closed allow-list
(ClickHouse system tables and temporary tables, PostgreSQL `pg_monitor` tolerance), per-user
ceilings an app may lower but never raise, and read-only readers: users with `SELECT` on named
objects that other apps in the namespace bind with `appDatabaseReaders`. Anything outside the
declaration is refused when the config loads, and a hand change on the server is drift.
An app database also declares privileges inside its own databases (PostgreSQL `CREATE` in named
schemas or on the database, with a derived membership of the migration user in the runtime role;
any database-scoped ClickHouse privilege the running server knows), and the workloads that bind
its migration credential.

Each app database has its own signed backup schedule, graded against the recovery-point objective
and pruned under the retention policy through review, and restores into scratch databases or the
empty databases of a rebuilt server. `db app-database quiesce` closes chosen logins, pauses the
schedule and drains the app's sessions and mutations without restarting the shared server;
`backup` takes an on-demand run, `resume` reopens exactly the quiesced users, and `evidence` prints
the window. Changes execute through the [reviewed operation ledger](reviewed-operation-ledger.md)
(CAP-22).

## Limits

- A reader's consumers are apps in the app database's own namespace.
- A reader stays declared once accepted; retire it instead of dropping it.
- A PostgreSQL reader's role defaults are advisory; its boundary is its grants.
- A workload binds at most one credential per engine across `databases`, `appDatabases` and
  `appDatabaseReaders`.
- Retirement turns logins and grants off and keeps the data; dropping a retired app database is not
  offered.
- The shared server is still single-replica and non-HA, so one server's outage affects every app on
  it.
