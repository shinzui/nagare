---
type: Improvement Request
title: Quiesce one app database and back it up on demand, without restarting the shared server
description: Give an app database a reviewed maintenance window that pauses its backup schedule, blocks and drains only that app's sessions, takes an on-demand signed backup, records evidence, and resumes, so an app's schema maintenance no longer needs a restart of a server other apps share.
generated:
  by: process:claude-code
  at: "2026-10-19T17:02:45Z"
requestId: IR-31
status: accepted
targetPlan: docs/plans/205-quiesce-one-app-database-and-back-it-up-on-demand.md
origin: mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps
acceptanceCriteria:
  - id: AC-1
    statement: A reviewed quiesce operation on one app database stops new sessions for its users, ends or waits out their running queries, and reports when none remain, without touching other apps' users or restarting the server.
    verification: With two app databases on one server per engine and long-running queries from both, quiesce one and assert its users' sessions end and new logins fail, while the other app's queries continue and the server process start time is unchanged.
  - id: AC-2
    statement: Quiesce keeps the app's privileges intact, so views and materialized views whose SQL security definer is the app's migration user keep working after resume.
    verification: Create a SQL SECURITY DEFINER view and a materialized view owned by the migration user, quiesce and resume, and assert both work and the grants observed are unchanged.
  - id: AC-3
    statement: For ClickHouse, quiesce also waits until the app's databases have no unfinished mutations, and reports any that failed.
    verification: Start a mutation on the app's table, quiesce, and assert the operation waits for it, or reports a failed mutation by name.
  - id: AC-4
    statement: While quiesced, the app database's scheduled backup does not start, and resume restores the schedule exactly as reviewed.
    verification: Quiesce across a scheduled run time and assert no backup Job starts; resume and assert the CronJob matches its accepted revision and the next run succeeds.
  - id: AC-5
    statement: An operator can take a reviewed on-demand signed backup of an app database, quiesced or not, with the same receipt and restore path as scheduled runs.
    verification: Run the on-demand backup for a PostgreSQL and a ClickHouse app database, ingest both receipts, and restore each into scratch.
  - id: AC-6
    statement: Quiesce, backup and resume emit an evidence record that names the server identity (including the ClickHouse server UUID), the app database, the blocked users, the observed empty session and mutation state, and the backup receipt.
    verification: Inspect the evidence after a quiesce-backup-resume cycle and assert every field is present and the record is signed or stored with the transaction.
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
      Author review against Nagare v0.7.0 CLI (no app-database backup or pause subcommand),
      the tan-ng-labs Milestone 3 ceremony and Kansoku's drain guidance; no independent
      verification attestation is claimed.
---

# Quiesce one app database and back it up on demand, without restarting the shared server

**Authored by:** a `claude-code` session implementing
`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`
on the `tan-ng-labs` intranet, running Nagare v0.7.0.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-19.

This is part of the set filed with IR-30; that request lists the others.


## Why

Kansoku changes its ClickHouse schema only inside a maintenance session that comes with *drain
evidence*: proof that no Kansoku process could be sending queries. Its guidance
(`mori://shinzui/kansoku/okf/guides/concepts/DOC-13`, ADR-0022) produces that evidence by
stopping clients and **restarting the ClickHouse server**. Kansoku says an empty
`system.processes` alone is not proof. Its migration guidance also wants a consistent backup of
the PostgreSQL coordinator and both ClickHouse databases before each migration.

Since IR-29 the server is shared. The tan-ng-labs plan therefore restarts `labs-clickhouse`
twice per ceremony (`nagarectl db restart`). That interrupts every other app and only works
while Kansoku is effectively alone on the server. Nagare v0.7.0 also lacks the other two pieces:

- `db app-database` offers only `plan`, `rotate`, `retire`, `backup-receipts`, `restore` and
  `list` (`cli/nagarectl/app/Nagare/Cli/Parser/AppDatabase.hs`). There is no on-demand backup.
  `db backup NAME` backs up a server's initial database, not its app databases.
- Each `nagare-appdb-<name>` schedule runs every 15 minutes as a SQL client of the server using
  the app's migration user. It cannot be paused, so a ceremony longer than the gap between runs
  overlaps a backup. The plan currently says to "arrange a reviewed pause", but none exists.
  F131 (retired schedules keep failing, planned in EP-203) is related but covers retirement
  only.

A tenant-scoped quiesce gives Kansoku the same guarantee as a restart, only for its own users:

- block login (ClickHouse `HOST NONE`, PostgreSQL `NOLOGIN`);
- end that app's sessions;
- wait for its mutations;
- confirm nothing remains.

Nagare already has both login-blocking primitives in its disable path
(`cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs`). The disable path also revokes
privileges, but quiesce must not: Kansoku's ClickHouse views are `SQL SECURITY DEFINER` with
the migration user as definer, and revoking would break writer inserts and reads.


## Requested change

- **Quiesce, as a reviewed inventory operation on one app database.** It:
  - pauses that app database's backup schedule;
  - blocks new logins for both of its users without changing their grants;
  - ends or waits out their sessions within a bound;
  - for ClickHouse, waits for unfinished mutations in its databases;
  - records an evidence record (AC-6).

  Quiescing does not touch other app databases or the server.
- **On-demand backup.** A reviewed, signed backup of an app database, usable quiesced or not,
  with the same receipt, ingest and restore path as scheduled runs.
- **Resume.** Re-enables login exactly for the reviewed users and restores the schedule's
  accepted revision.
- **Operator access while quiesced.** A tenant may need to run its own migrator while its
  runtime is blocked. Either quiesce one user while leaving the other open, or let the operator
  run a migration as the migration user under the quiesce; document the choice. Kansoku needs
  its migration user available while its runtime user is blocked.


## Prior evidence

- **Ceremony.** The current restart-based ceremony is in the tan-ng-labs plan, Concrete Steps,
  Milestone 3.
- **Server UUID.** The UUID survived both restarts so far.
- **Definer views.** Kansoku's definer views are created in its native ClickHouse steps
  0023 and 0025 (`kansoku-server/migrations/clickhouse/steps`).
