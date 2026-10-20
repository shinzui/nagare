---
title: "Own-database privileges are declarable; server-wide access is not"
status: accepted
date: 2026-10-20
authors: [shinzui]
related:
  - docs/plans/208-let-an-app-database-declare-its-runtime-s-privileges-inside-its-own-databases.md
  - docs/improvement-requests/declare-runtime-privileges-within-an-app-database.md
  - docs/adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md
  - docs/adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md
---

# ADR 31 — Own-database privileges are declarable; server-wide access is not

## Status

Accepted on 2026-10-20 with [EP-208](../plans/208-let-an-app-database-declare-its-runtime-s-privileges-inside-its-own-databases.md),
which answers [IR-35](../improvement-requests/declare-runtime-privileges-within-an-app-database.md).

## Context

[ADR 30](0030-app-databases-are-reviewed-tenants-of-a-shared-server.md) gives every app database a
fixed grant set and treats any other grant as drift. EP-204 relaxed it with a closed allow-list,
which fits server-wide and system-table grants. The first real consumer, a PGMQ server that
creates its queue tables at startup as its runtime user, needed `CREATE` in one schema of its own
database, and the only exits were a change to every app or a Nagare release per pattern.

## Decision

- **The boundary is the app's own databases.** A privilege scoped to them is declarable in the app
  database's `access.privileges`, reviewed like the rest of the declaration: on PostgreSQL the
  runtime's `CREATE` on named schemas (`createIn`) or on the database (`createSchemas`); on
  ClickHouse any database-scoped privilege of either user, granted `ON <db>.*` for each of the
  app's databases. Server-wide and system access stays the closed allow-list; access to another
  app's databases is never declarable.
- **The engine owns the ClickHouse privilege list.** Nagare ships none. Observation reads
  `system.privileges`, and a declared token is accepted only when every leaf it stands for is at
  database, table, view, dictionary or column level; then it means exactly those leaves. A group
  with a global leaf refuses with `app-database-privilege-unknown`, because the server grants such
  a group partially without an error. Held and declared grants are compared as leaf sets, since
  `system.grants` reports the minimal cover.
- **Ownership needs a derived membership.** When the PostgreSQL runtime may own objects, the
  migration user is made a member of the runtime role, without the admin option, so backups and
  migrations reach runtime-owned objects. It is derived from the declaration, never declared, and
  observed as part of the logical database. A runtime-owned relation is expected only where the
  desired declaration lets the runtime create; elsewhere it is drift even after the grant is gone.
- **Nagare never creates an app's schema.** A declared schema that does not exist is pending: the
  plan prints a note and grants it after the app's migrations create it.
- **Revocations follow observation.** Grants depend only on the declaration; a revocation is sent
  only when the catalog shows it held and only the accepted declaration named it. An app database
  that declares nothing renders its pre-ADR statements byte for byte.
- **Owner bindings are decided by the app database.** Its `owners` list names the workloads that
  bind the migration credential; no workload field can request it.

## Consequences

- PGMQ-shaped apps run as their runtime user with one reviewed line of configuration.
- A ClickHouse upgrade that changes the privilege tree changes what a token means without a
  Nagare release; a token the new server cannot grant exactly refuses the next plan rather than
  drifting.
- Removing a PostgreSQL privilege while the runtime owns objects there refuses until the app
  reassigns or drops them, which the membership lets the migration user do.
- The migration user can act as the runtime role. It already owns the database, so this widens
  nothing beyond the app's own data.
