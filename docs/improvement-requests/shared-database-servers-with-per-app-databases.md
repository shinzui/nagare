---
type: Improvement Request
title: Host many app databases on one shared managed server per engine
description: Let one managed PostgreSQL server and one managed ClickHouse server each hold a separate logical database, user and grants per app, bind each app to only its own credentials, and back up every app database, instead of one server and one shared credential per database.
generated:
  by: process:claude-code
  at: "2026-10-19T03:25:58Z"
requestId: IR-29
status: completed
completedAt: "2026-10-19T15:41:36Z"
resolution: "ExecPlan 202 adds app databases: reviewed tenants of one shared PostgreSQL or ClickHouse server, each with its own databases, runtime and migration users, explicit grants, runtime-only workload bindings, rotation, retirement, signed per-app backups and scratch or rebuilt-server restore. `just local-app-database-smoke` proves AC-1 to AC-5 natively on a local context; ADR 30 records the model."
targetPlan: docs/plans/202-host-per-app-databases-on-shared-postgresql-and-clickhouse-servers.md
origin: mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps
acceptanceCriteria:
  - id: AC-1
    statement: One managed PostgreSQL server and one managed ClickHouse server each host a separate logical database for each of two or more apps, without a second StatefulSet, volume or Service per app.
    verification: Register two apps' databases on one server per engine and assert exactly one StatefulSet, PVC and Service per engine, with each app database present on that server.
  - id: AC-2
    statement: An app's deploy injects only that app's own database credentials, never the server's startup or administrator Secret.
    verification: Render and apply a two-app fixture and assert each workload's env and volume references name only its own app-database Secret.
  - id: AC-3
    statement: Each app user is confined to its own database on both engines.
    verification: From each app's runtime and migration credentials, assert PostgreSQL connections to the other app's database fail, and ClickHouse fully qualified SELECT, INSERT and DDL against the other app's database fail; assert neither runtime user can create users, grant privileges or control the server.
  - id: AC-4
    statement: Provisioning, credential rotation and app-database retirement are reviewed, repeatable inventory operations.
    verification: Re-plan an unchanged declaration and assert no operations; rotate one app's credential and retire one app's database binding, and assert the other app's credentials, grants, data and availability are unchanged.
  - id: AC-5
    statement: Scheduled backups cover every registered app database on a server, including its users and grants, and each can be restored on its own.
    verification: Populate two app databases per engine, take scheduled backups, restore one app into a scratch target, and assert its data and access restrictions are recovered while the other app is untouched.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-19T03:25:58Z"
    document_timestamp: "2026-10-19T03:25:58Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review of the v0.6.6 source evidence (Secret, Connection and Backup modules at
      tag v0.6.6) and acceptance criteria; no independent verification attestation is claimed.
---

# Host many app databases on one shared managed server per engine

**Authored by:** a `claude-code` session implementing
`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`
on the `tan-ng-labs` intranet, running Nagare v0.6.6.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-19.


## Why

The labs intranet runs every app on one n2-standard-4 VM. The operator wants **one** PostgreSQL
server and **one** ClickHouse server for the whole cluster, with each app getting its **own
database** on those servers and its own credentials. A server per app is explicitly not wanted:
each managed server is a StatefulSet with its own volume, memory budget and backup schedule, and
ClickHouse alone needs a 1.5–2 GiB cap. The local policy is recorded as
`mori://tan/tan-ng-labs` ADR `docs/adr/0001-shared-database-servers-with-isolated-app-databases.md`
(artifact-level URI pending).

Kansoku, the first consumer, needs PostgreSQL database `kansoku` and ClickHouse databases
`analytics` and `kansoku_migration_ledger`. A second app must not be able to read or write them.

Nagare v0.6.6 models a managed database as the server itself, with one credential:

- `cli/nagarectl/src/Nagare/Database/Secret.hs` generates one Secret, `nagare-db-<name>`, with
  the default user `nagare` (`defaultDbUser`).
- `cli/nagarectl/src/Nagare/Database/Connection.hs` injects that same Secret into every app that
  lists the database. Two apps sharing a server therefore share its only credential.
- `cli/nagarectl/src/Nagare/Database/Backup.hs` dumps only `POSTGRES_DB`, with
  `pg_dump --no-owner --no-privileges`, so other databases and all grants are missing from the
  backup. ClickHouse backups run exactly `BACKUP DATABASE default`, which misses every app
  database.
- `docs/user/managed-databases.md`, "Constraints and limits", lists multi-tenant users as out of
  scope.

So sharing a v0.6.6 server today means every app holds the server credential and most app data is
never backed up. The Kansoku deployment is blocked at its Milestone 2 until this exists.


## Requested change

Separate the **server** from the **app databases it hosts**, for PostgreSQL and ClickHouse (Redis
is not requested):

- **Server.** As today: one StatefulSet, volume, ClusterIP Service and an operator-only
  administrator Secret per engine. The administrator Secret is never bound to an app.
- **App database.** A new managed resource, declared by or for an app, that names its server and
  creates inside it a logical database (PostgreSQL `CREATE DATABASE`; ClickHouse
  `CREATE DATABASE`, possibly several per app), a runtime user and, where privileges differ, a
  migration user, plus the grants, and an app-scoped connection Secret per user. It is not another
  StatefulSet.
- **Grants.** PostgreSQL roles have no SUPERUSER, CREATEDB, CREATEROLE, REPLICATION or cross-app
  membership; PUBLIC CONNECT on each app database is revoked; schema, table, sequence, function and
  default privileges are scoped to the app's database. ClickHouse users have no global data,
  access-management or server-control privileges and are granted only on their own databases.
  A configured default database is not treated as an access boundary.
- **Binding.** An app's Deployment references its app database, and a deploy injects only that
  app's runtime Secret, keeping the conventional key names (`POSTGRES_*`, `DATABASE_URL`,
  `CLICKHOUSE_*`) with the URL selecting the app's database. Migration Secrets stay operator-held.
- **Lifecycle.** Provisioning, credential rotation and retirement of an app database are reviewed
  inventory operations. A retry must not reset passwords, widen grants or recreate a database.
  Retiring an app's database revokes its access and retains its data per policy; it never retires
  the server or touches another app.
- **Backups.** Every registered app database is backed up on schedule with its users and grants,
  and can be restored on its own into a scratch target without affecting other apps.

Do not satisfy this by provisioning a server per app, by sharing the administrator credential, or
by granting global privileges to make an app's migrations pass.


## Prior evidence

The constraints above are drawn from the Kansoku plan's Decision Log. The operator set the
shared-server requirement on 2026-10-18 and confirmed on 2026-10-19 that it means multiple
databases on one PostgreSQL server and one ClickHouse server, not multiple servers. Kansoku's ClickHouse
migrator creates its own native ledger in `kansoku_migration_ledger`, so app-database
registration must not pre-create tables inside an app's databases.
