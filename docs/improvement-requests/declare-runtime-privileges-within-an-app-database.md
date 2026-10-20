---
type: Improvement Request
title: Let an app database declare its runtime's privileges inside its own databases without a Nagare release
description: Replace the fixed DML-only runtime grant with a reviewed declaration of any privilege scoped to the app's own databases (PostgreSQL schema CREATE, ClickHouse database-level DDL, or an owner binding for apps that migrate at startup), so a common app pattern such as creating a PGMQ queue at startup needs only a config change, while cross-app isolation and server-wide allow-listing stay as they are.
timestamp: "2026-10-20T16:10:00Z"
generated:
  by: process:claude-code
  at: "2026-10-20T16:10:00Z"
requestId: IR-35
status: proposed
origin: mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps
acceptanceCriteria:
  - id: AC-1
    statement: A PostgreSQL app database can declare, per schema of its own database, extra runtime privileges (at least CREATE on a named schema, and CREATE on the database for apps that create their own schemas); the plan names each one, apply grants it, and an unchanged re-plan prints no operations.
    verification: On a local context, declare CREATE on schema pgmq for a Kansoku-like app database, apply, and assert has_schema_privilege(runtime, 'pgmq', 'CREATE') and a converged re-plan; assert the same grant made by hand without the declaration is still reported as drift.
  - id: AC-2
    statement: Whenever the runtime may own objects, the migration user is a member of the runtime role, so the scheduled pg_dump, the app's later migrations (ALTER on runtime-owned tables) and maintenance keep working; the membership is part of the declaration, never drift.
    verification: With AC-1's declaration, start a PGMQ app as the runtime so it creates its queue, then run the scheduled backup Job and an ALTER TABLE on the queue table as the migration user; assert both succeed and the backup restores into scratch with the runtime as owner and the rows intact.
  - id: AC-3
    statement: Objects the runtime creates inside declared schemas are expected by the catalog; runtime-owned objects anywhere else, and every grant outside the declaration, remain drift.
    verification: After AC-2, re-plan and assert no operations; create a table as the runtime in an undeclared schema via a temporary hand grant and assert planning refuses it as drift.
  - id: AC-4
    statement: A ClickHouse app database can declare any privilege scoped to its own databases for its runtime (for example CREATE TABLE, DROP TABLE, ALTER TABLE, CREATE VIEW) without a code change; the closed allow-list remains only for server-wide and system-table grants such as IR-30's exceptions.
    verification: Declare CREATE TABLE and DROP TABLE ON <own_db>.* for a runtime, apply, and assert the runtime can create and drop a table in its own database while the same statements against another app's database still fail with code 497.
  - id: AC-5
    statement: An app database can name the workloads that bind its owner (migration) credential instead of the runtime credential, for apps that run their own migrations at startup; the binding is reviewed, injects the same variable names, and the migration Secret is never exposed to undeclared workloads.
    verification: Declare one owner consumer, deploy it and an undeclared workload that both name the app database, and assert the first receives the migration user's credentials and the second still receives the runtime's; assert a third app's workload cannot bind it at all.
  - id: AC-6
    statement: Rotation, retirement, quiesce and resume, backup, scratch restore and rebuilt-server restore cover the declared privileges, membership and owner bindings; retirement and quiesce withhold them like the fixed grants, and resume restores exactly the declaration.
    verification: Run the existing app-database lifecycle suite with AC-1, AC-2, AC-4 and AC-5 declared and assert each step's observed grants equal the declaration before and after.
  - id: AC-7
    statement: The managed-databases guide states the rule (own-database privileges are declarable; server-wide and cross-app access are not) and shows the PGMQ startup-queue pattern as an example.
    verification: Review docs/user/managed-databases.md for the rule, the PostgreSQL and ClickHouse declaration syntax, the membership consequence and the PGMQ example.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-20T16:10:00Z"
    document_timestamp: "2026-10-20T16:10:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Nagare v0.8.0 (AppDatabase.hs grant sets, Sql.hs rendering,
      Catalog.hs drift, Backup.hs and AppDatabaseRestore.hs), pgmq's create function and a
      local PostgreSQL 18.6 rehearsal of every variant with Kansoku 9127c47's real binaries;
      no independent verification attestation is claimed.
---

# Let an app database declare its runtime's privileges inside its own databases

**Authored by:** a `claude-code` session implementing
`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`
on the `tan-ng-labs` intranet, running Nagare v0.8.0.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-20.


## Why

App databases give every app two users: a migration user that owns its databases and a
runtime user with a fixed grant set. On PostgreSQL that set is `CONNECT`/`TEMPORARY`, schema
`USAGE` and row DML; on ClickHouse it is `SELECT, INSERT, ALTER UPDATE, ALTER DELETE`. Any
other grant is drift. IR-30 widened this with a closed allow-list, which works for
server-wide and system-table grants. It does not fit privileges inside the app's own
databases, which cannot reach another app and so do not need platform-level gatekeeping.

The first case is a common one. Every project the operator runs uses the same PGMQ pattern:
the server calls `provisionQueue` at startup, which runs `pgmq.create`. On the intranet,
Kansoku's server cannot start as `kansoku_pg_runtime`:

```text
ERROR:  permission denied for schema pgmq
LINE 2:     CREATE TABLE IF NOT EXISTS pgmq.q_kansoku_events (
```

The only paths available today are to change every app so it never creates anything at
runtime (`mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-1`, which this request
makes unnecessary), or to wait for a Nagare release per pattern. The operator's requirement
for app databases is isolation between apps on a shared server. A DML-only runtime inside an
app's own database is a sensible default, not a requirement, and it should be relaxable by
declaration.


## What was verified

A local PostgreSQL 18.6 was set up exactly as Nagare's `renderDatabaseAccess` sets up an app
database: same role attributes, `REVOKE … FROM PUBLIC`, `public` owned by the migration user,
and the migration user's default privileges to the runtime. Kansoku 9127c47's schema was
installed with its own `kansoku-migrate` (14 migrations, including PGMQ). Results:

| Variant | Runtime `pgmq.create` | Migration `pg_dump -Fc` (the scheduled backup) | Migration `ALTER TABLE` on the queue (a later pgmq upgrade) |
| --- | --- | --- | --- |
| Fixed grants (today) | `permission denied for schema pgmq` | ok | ok |
| Queue pre-created by migration, runtime has `CREATE ON SCHEMA pgmq` | `must be owner of table q_kansoku_events` (its `CREATE INDEX IF NOT EXISTS` checks ownership first) | ok | ok |
| Runtime has `CREATE ON SCHEMA pgmq` | ok; the runtime owns the queue | `permission denied for table q_kansoku_events` | `must be owner` |
| Plus default privileges `FOR ROLE runtime IN SCHEMA pgmq` to migration | ok | ok | `must be owner` |
| Plus `GRANT runtime TO migration` | ok | ok | ok |

The last variant was also restored the way Nagare's scratch restore runs (`pg_restore` as the
administrator into a database owned by the migration user). Owners were kept, the queue's
rows were intact, and the real `kansoku-server` binary, run as the runtime user, created its
own queue and served `/health/live`. In every variant the runtime still could not create
anything in schema `kansoku`.

Two consequences shape the request:

- **Schema `CREATE` is the right granularity.** PostgreSQL has no privilege to "create only
  queues", so `CREATE ON SCHEMA pgmq` lets the runtime create any table in `pgmq`. That stays
  inside the app's own database.
- **A runtime that can own objects needs the migration user to be a member of it.** Default
  privileges fix backups but not later schema changes, which require ownership.


## Requested change

**A rule.** A privilege scoped to the app's own databases is declarable by the app and
reviewed like the rest of the app database. A server-wide privilege, a system-table grant, or
anything that reaches another app's database stays on the closed allow-list (IR-30) or stays
impossible.

**PostgreSQL** (AC-1 to AC-3):

- Per-schema runtime privileges, at least `CREATE` on a named schema, and `CREATE` on the
  database for apps that create their own schemas.
- When any declared privilege lets the runtime own objects, Nagare grants the migration user
  membership in the runtime role and observes it as declared.
- The catalog expects runtime-owned objects in declared schemas, and still reports everything
  else as drift.

**ClickHouse** (AC-4): any privilege `ON <own_db>.*` may be declared for the runtime. The
grant renderer already writes database-scoped grants for the fixed sets, so this is an open
list over the same shape.

**Owner binding** (AC-5): an app database names the workloads that bind its migration (owner)
credential instead of the runtime credential. This covers the other recurring pattern, an app
that runs its own migrations at startup, with no per-app Nagare change. It is reviewed and
visible in the plan, and other workloads keep receiving the runtime credential.

**Lifecycle and docs** (AC-6, AC-7): rotation, retirement, quiesce/resume and both restore
paths treat declared privileges, membership and owner bindings like the fixed grants. The
guide states the rule with the PGMQ example.

A sketch of the declaration, for illustration only:

```haskell
kansokuPg =
  AppDatabase
    { -- ... engine = Postgres, logicalDatabases = kansoku :| [] ...
      access =
        noAppDatabaseAccess
          & #monitoring .~ [PgMonitor]
          & #runtime . #schemaPrivileges .~ [SchemaPrivilege (ok (mkSchemaName "pgmq")) [CreateIn]]
    }
```


## Not requested

Any grant across apps, server-wide PostgreSQL role attributes (`CREATEDB`, `CREATEROLE`,
superuser), widening IR-30's server-wide ClickHouse allow-list, or removing the
runtime/migration split as the default. An app that declares nothing keeps today's behavior.
