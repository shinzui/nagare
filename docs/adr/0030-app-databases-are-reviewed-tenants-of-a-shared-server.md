---
title: "App databases are reviewed tenants of a shared server"
status: accepted
date: 2026-10-19
authors: [shinzui]
related:
  - docs/plans/202-host-per-app-databases-on-shared-postgresql-and-clickhouse-servers.md
  - docs/improvement-requests/shared-database-servers-with-per-app-databases.md
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md
  - docs/adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md
  - docs/adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md
---

# ADR 30 — App databases are reviewed tenants of a shared server

## Status

Accepted on 2026-10-19 with [EP-202](../plans/202-host-per-app-databases-on-shared-postgresql-and-clickhouse-servers.md),
which answers [IR-29](../improvement-requests/shared-database-servers-with-per-app-databases.md).

## Context

Until v0.6.6 each managed database was its own server: one StatefulSet, volume, Service and one
shared administrator credential, bound directly by every app that named it. Its scheduled backup
covered only the server's initial database. An intranet with many small apps needs one PostgreSQL
and one ClickHouse server shared between them, with each app confined to its own data and its
backups restorable on their own.

## Decision

- **An app database is its own standalone scope**, `appdb-<key>`, that references an accepted
  server scope ([ADR 22](0022-compose-independent-resource-scopes-through-a-typed-inventory.md)).
  It holds two credential Secrets (`<name>-runtime`, `<name>-migration`), two database users,
  one member per logical database, and its own backup bundle. It is provisioned, rotated and
  retired without revising the server or any app.
- **A server is direct or shared, never both.** A workload binds an app database through
  `appDatabases`, which injects only `<name>-runtime`; planning refuses to bind a shared server
  directly and to place an app database on a directly bound server.
- **The declaration is the authority for users and grants.** Grants are explicit lists (never
  `ALL`, whose expansion varies by engine version) and belong to the logical-database member.
  Observation classifies the catalog; access Nagare never grants is refused as drift, not
  revoked. Passwords live only in the retained Secrets: PostgreSQL SCRAM verifiers and ClickHouse
  `sha256_hash` values are computed client-side, so no password reaches a server log.
- **Credential changes are forward-only reviewed operations.** Rotation writes the Secret first,
  then the user, and runs once per review. An existing user whose password differs from its
  Secret is never re-passworded silently; rotation is the reviewed exit. Retirement is a revision
  that turns logins and grants off and keeps databases and Secrets; dropping them is not offered.
- **Backups belong to the app database.** Its signed schedule `nagare-appdb-<name>` dumps with
  the migration credential into `app-databases/<namespace>/<name>/`. Backups hold data and
  object ACLs, never roles or password hashes; the receipt's signed metadata binds the
  declaration digest. A restore runs as the server administrator into scratch names, or, after a
  server rebuild, into the re-applied empty databases, refusing any database that holds data.

## Consequences

- One server per engine serves many apps, and an app's compromise is confined to its own
  databases on that server.
- The server's own backup still covers only its initial database. Recovering a shared server is
  three steps: the server, then each app database re-applied (absent logical databases rebuilt
  `--fresh`), then each app database's backup restored with `--rebuilt`.
- A workload still binds at most one database per engine, since bindings inject fixed variable
  names.
- Turning on SQL access management changes the ClickHouse pod template, so existing ClickHouse
  servers restart once on their next reviewed apply.
- Moving an existing direct consumer onto an app database is an explicit data migration, not a
  rebinding.
- Backup and restore Job pods label themselves `nagare.dev/database-job`, never the
  `nagare.dev/database` label a server's Service selects, so no Job pod becomes a database
  endpoint while it runs.
