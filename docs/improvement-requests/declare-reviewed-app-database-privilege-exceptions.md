---
type: Improvement Request
title: Let an app database declare reviewed exceptions to its fixed grant set
description: Let an app database opt into a small allow-list of extra ClickHouse privileges (own-row system tables, storage metadata, arbitrary temporary tables) and accept PostgreSQL grants to read-only predefined roles that app migrations install, so a real app can run without manual grants that v0.7.0 reports as drift.
generated:
  by: process:claude-code
  at: "2026-10-19T17:02:45Z"
requestId: IR-30
status: completed
completedAt: "2026-10-20T13:40:00Z"
resolution: "ExecPlan 204, released in 0.8.0: an app database's access declares, per user, ClickHouse exceptions from a closed allow-list and tolerated PGMQ grants to pg_monitor; anything else is refused at load, a declared change plans an update, and a hand change outside the declaration is drift. The app-database smoke proves it natively and the intranet runs it."
targetPlan: docs/plans/204-let-app-databases-declare-reviewed-grant-exceptions-and-resource-limits.md
origin: mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps
acceptanceCriteria:
  - id: AC-1
    statement: An app database declaration can name, per user (runtime or migration), extra ClickHouse privileges drawn only from a Nagare-owned allow-list, and planning shows them as reviewed members of that app database.
    verification: Declare the allow-listed privileges for one app database, plan, and assert the operations name each privilege and user; declare a privilege outside the allow-list and assert the configuration is refused before planning.
  - id: AC-2
    statement: The allow-list covers SELECT on system.parts and system.mutations (rows limited to the app's own tables), SELECT on system.disks and system.storage_policies, and the global CREATE ARBITRARY TEMPORARY TABLE privilege.
    verification: Grant each to one app's users on a shared server and assert the query succeeds; from that user assert another app's parts and mutations rows are invisible, and that a temporary table with a File, URL, S3 or remote engine is refused.
  - id: AC-3
    statement: Process visibility, if offered, shows an app's users only their own app's queries.
    verification: Run a query as another app's user and assert the first app's users cannot see its row or query text in system.processes; if this cannot be enforced, the allow-list omits system.processes and the documentation says so.
  - id: AC-4
    statement: A PostgreSQL app database can declare that grants to a named read-only predefined role (at least pg_monitor) on schemas, tables, sequences and default privileges its migration user owns are expected, and such grants are not drift.
    verification: Install PGMQ's SQL-only schema through the migration user (it grants USAGE, SELECT and default SELECT to pg_monitor), declare pg_monitor, and assert re-plan reports no operations and rotate and retire still plan; without the declaration the same grants still report app-database-grant-drift.
  - id: AC-5
    statement: Declared exceptions survive rotation, retirement, scratch restore and rebuilt restore, and removing a declaration revokes or reports them through review.
    verification: Rotate, retire and restore an app database with declared exceptions and assert the declared grants are present exactly when the declaration says so; remove one exception and assert the plan revokes it.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-19T17:02:45Z"
    document_timestamp: "2026-10-19T17:02:45Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Nagare v0.7.0 source (AppDatabase DSL grant sets and Catalog drift
      classification), Kansoku 9127c47 and live denials on the tan-ng-labs intranet; no
      independent verification attestation is claimed.
---

# Let an app database declare reviewed exceptions to its fixed grant set

**Authored by:** a `claude-code` session implementing
`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`
on the `tan-ng-labs` intranet, running Nagare v0.7.0.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-19.

This is one of a set filed together after a full privilege audit of Kansoku against v0.7.0:
IR-30 (this request), IR-31 (quiesce and on-demand backup for one app database) and IR-32
(per-app resource limits) in this bundle, and
`mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-1` and
`mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-2` for the Kansoku side.
The privileges Kansoku can reasonably stop needing are assigned to Kansoku. This request
covers only the ones that are inherent to its design or to PGMQ.


## Why

IR-29 gave every app database a fixed grant set (`cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs`,
`appDatabaseServerGrants` and the per-engine grant lists) and made every other grant drift
(`cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs`). Drift is never repaired; it
blocks re-plan, rotation and retirement of that app database. The `AppDatabase` record has no
field for anything else. That is the right default, but Kansoku is a first real consumer and
cannot run inside it.

**ClickHouse.** The stock image enforces `select_from_system_db_requires_grant`, so only the
small public set of system tables is readable. The following were refused live with code 497
on `labs-clickhouse` (26.8.28.14):

- `kansoku-ch-migrate`, built on `mori://shinzui/clickhouse-migrate` v0.1.0.0, checks that the
  ledger sits on durable local storage. It does this every time it loads its ledger, by reading
  `system.storage_policies` and `system.disks` (`ClickHouseMigrate/Internal/LedgerStore.hs:115,118`).
  No migration can start.
- `kansoku-server`'s identity-resolved and cohort metrics do two things:
  - check a revision through `system.tables JOIN system.parts`
    (`kansoku-core/src/Kansoku/Identity/Cache.hs:57-66`);
  - rebuild four session-scoped `ENGINE = Join` temporary tables (`Cache.hs:78-113`), which
    need the global `CREATE ARBITRARY TEMPORARY TABLE`.
- `kansoku-admin` verifies retention and erasure mutations through `system.mutations`
  (`kansoku-core/src/Kansoku/Admin/ClickHouse.hs:122`).

`system.parts` and `system.mutations` only return rows for tables the user can see, so granting
them is low-risk. `system.disks` and `system.storage_policies` describe server storage, not
tenant data. Temporary tables are session-local. A manual `GRANT` for any of these is drift
twice over: it is table-level, and on database `system`.

**PostgreSQL.** PGMQ's install script, which `mori://shinzui/pgmq-hs` ports unchanged as
`pgmq-migration` (`0001-install-v1.11.0.sql`), runs:

```sql
GRANT USAGE ON SCHEMA pgmq TO pg_monitor;
GRANT SELECT ON ALL TABLES IN SCHEMA pgmq TO pg_monitor;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA pgmq TO pg_monitor;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmq GRANT SELECT ON TABLES TO pg_monitor;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmq GRANT SELECT ON SEQUENCES TO pg_monitor;
```

Catalog tolerates only the two app users, `PUBLIC` and `pg_database_owner` as grantees. So
after `kansoku-migrate up`, `kansoku-pg` re-plans to
`observation-unavailable … app-database-grant-drift … database-kansoku`. It is wedged today.
Every app that installs PGMQ through its migrations, which includes most event-driven apps
built on `mori://shinzui/shibuya-pgmq-adapter`, will hit the same thing.

These grants carry no extra risk here: Nagare already forbids role membership for app users
and never grants `pg_monitor` to an app role.


## Requested change

Add an optional, reviewed declaration of exceptions to an app database, validated against a
Nagare-owned allow-list:

- **ClickHouse, per user.** Allow-list:
  - `SELECT ON system.parts`, `SELECT ON system.mutations`, `SELECT ON system.disks` and
    `SELECT ON system.storage_policies`, with column-level grants where that suffices;
  - the global `CREATE ARBITRARY TEMPORARY TABLE`.

  Grant no source privileges (`URL`, `FILE`, `S3`, `REMOTE`), so a temporary table cannot reach
  the network or filesystem. Add `system.processes` only if Nagare can limit its rows to the
  app's own users, for example with a row policy; otherwise leave it out and document why.
- **PostgreSQL.** Allow-list read-only predefined roles, starting with `pg_monitor`, as declared
  grantees on objects the app's migration user owns, including that user's default privileges.
  Never grant membership in those roles to app users.
- **Drift.** Catalog classifies declared exceptions as declared members. Undeclared ones remain
  drift exactly as today.
- **Lifecycle.**
  - Rotation, retirement, scratch restore and rebuilt restore keep the declaration in force.
  - A scratch restore must apply the same exceptions to the scratch names.
  - Removing a declaration revokes the exception through review.


## Not requested

Arbitrary extra grants, `system.query_log`, access management, `SYSTEM` or `KILL` privileges,
and grants on another app's databases. Kansoku will stop reading other users' processes (see
`mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-2`), so `system.processes` is
optional here.


## Prior evidence

- **Live denials.** Recorded in the tan-ng-labs plan, Surprises & Discoveries, 2026-10-19,
  together with the `kansoku-pg` drift observation.
- **Privilege set.** The full Kansoku privilege inventory (all binaries, `clickhouse-migrate`,
  `pgmq-migration` 0.6.1.1) was collected the same day. Kansoku's runtime fits v0.7.0's
  PostgreSQL grant set once it stops creating its queue at startup.
- **ClickHouse migration user.** Kansoku's migration DDL fits v0.7.0's migration grant set. The
  steps use `CREATE DATABASE IF NOT EXISTS`, `EXCHANGE TABLES`, `MODIFY SQL SECURITY` and
  `ALTER … MATERIALIZE COLUMN`. Only the storage probes above fall outside it.
