---
type: Improvement Request
title: Give each app database reviewed resource limits on its shared server
description: Let an app database declare per-user ClickHouse query limits and PostgreSQL connection limits, enforced by the server and observed for drift, so one app cannot exhaust the memory, concurrency or connections of a server other apps share.
generated:
  by: process:claude-code
  at: "2026-10-19T17:02:45Z"
requestId: IR-32
status: proposed
origin: mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps
acceptanceCriteria:
  - id: AC-1
    statement: A ClickHouse app database can declare, per user, a ceiling on memory per query, execution time and concurrent queries, enforced by the server.
    verification: Declare limits, plan and apply, then run a query exceeding each limit as that user and assert the server refuses or stops it while another app's user is unaffected.
  - id: AC-2
    statement: An app may lower declared ceilings per query or session but cannot raise them, and settings it does not declare stay changeable.
    verification: As the runtime user, SET max_memory_usage below and above the ceiling and assert the lower value is accepted and the higher one refused; assert an undeclared setting such as enable_analyzer can still be changed.
  - id: AC-3
    statement: A PostgreSQL app database can declare a connection limit per user.
    verification: Declare a limit, open one connection more than the limit as that user, and assert the extra connection is refused with the role connection-limit error.
  - id: AC-4
    statement: Limits are part of the app database's reviewed members, and an out-of-band change is reported as drift.
    verification: Change a declared limit by hand and assert re-plan reports drift; change the declaration and assert the plan shows the update.
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
      Author review against Nagare v0.7.0 app-database SQL (no settings profile, quota or
      connection limit) and Kansoku 9127c47 session settings and pool sizes; no independent
      verification attestation is claimed.
---

# Give each app database reviewed resource limits on its shared server

**Authored by:** a `claude-code` session implementing
`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`
on the `tan-ng-labs` intranet, running Nagare v0.7.0.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-19.

This is part of the set filed with IR-30; that request lists the others.


## Why

Shared servers trade resource isolation for density. The consuming deployment's policy
(`mori://tan/tan-ng-labs`, `docs/adr/0001-shared-database-servers-with-isolated-app-databases.md`,
artifact-level URI pending) accepts that app databases do not separate CPU, memory or uptime.
But v0.7.0 has no limit an operator can set per app:

- ClickHouse users are created without a settings profile, constraint or quota
  (`cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs`), and the server's only memory bound
  is `max_server_memory_usage` from `low-memory.xml`.
- PostgreSQL roles get no `CONNECTION LIMIT`.

Kansoku shows the risk:

- Each `kansoku-server` process opens about 42 PostgreSQL connections: a pool of 20, a
  maintenance pool of up to 20, and short-lived extras. The server's `max_connections` is
  PostgreSQL's default of 100 (Nagare does not set it) and is shared by every app.
- Its own ClickHouse limits are client-side `SET max_memory_usage` and `max_execution_time` on
  each query (`kansoku-core/src/Kansoku/ClickHouse.hs:177-186`). A misconfigured or other app's
  query can still take the whole 2 GiB server budget.

The tan-ng-labs plan requires "per-user query limits and aggregate server capacity" before
Kansoku goes live, and v0.7.0 cannot provide the per-user part.


## Requested change

- **ClickHouse.** An optional per-user settings profile or constraints, managed by Nagare,
  declaring:
  - maximum `max_memory_usage`;
  - maximum `max_execution_time`;
  - `max_concurrent_queries_for_user`.

  Use constraints with `max`, not readonly, so apps keep setting their own lower values per
  query. Kansoku sets `max_execution_time`, `max_memory_usage`, overflow modes, `async_insert`,
  `mutations_sync`, `alter_sync`, `fsync_metadata` and related settings per request and needs
  them to stay changeable.
- **PostgreSQL.** An optional `CONNECTION LIMIT` per user, and optionally a role-level
  `statement_timeout`.
- **Observation.** Limits are observed and reviewed like grants. Hand edits are drift.
