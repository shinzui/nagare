---
type: Bug Report
title: A ClickHouse server restart widens every app database's migration FILE grant into drift
description: ClickHouse persists the migration user's WRITE ON FILE as FILE ON *.*, so after any server restart Nagare observes an undeclared server-wide READ and refuses every review of every ClickHouse app database.
generated:
  by: process:claude-code
  at: "2026-10-20T15:05:00Z"
bugId: BUG-7
status: reported
severity: unusable
origin: mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps
affects: mori://shinzui/nagare/packages/nagarectl
affectedVersion: 0.8.0
environment: >-
  tan-ng-labs intranet context, shared server labs-clickhouse on
  clickhouse/clickhouse-server:26.8.28.14 with SQL access management on, app
  databases kansoku-ch and isolation-probe-ch created on Nagare 0.7.0 and
  re-planned on 0.8.0.
observed: >-
  Before the restart both app databases planned to no operations and quiesced
  normally. After two reviewed `nagarectl db restart labs-clickhouse` runs, `db
  app-database resume` refuses for both with `observation-unavailable: ...
  app-database-grant-drift: kansoku_ch_migration: server-wide READ` (and the same
  for isolation_probe_ch_migration). The two app databases stay quiesced, with
  runtime logins off and backup schedules suspended, and no review of them can be
  saved.
expected: >-
  A grant Nagare made is observed identically before and after a server restart,
  so a restart never turns accepted access into drift. docs/user/managed-databases.md
  says app-database grants live on the data PVC and survive a restart, and
  `db restart` is itself a reviewed Nagare operation.
reproduction:
  - On a ClickHouse 26.8.28.14 managed server, create any ClickHouse app database with `db app-database plan --save-plan DIR` and apply it.
  - Re-plan the same config and observe `no operations`.
  - As the server's admin user, run `SHOW GRANTS FOR <app>_migration` and `SELECT access_type FROM system.grants WHERE user_name = '<app>_migration' AND database IS NULL`; observe the grant Nagare issued (`GRANT WRITE ON FILE` in system.query_log).
  - Save and apply `nagarectl db restart <server> --save-plan DIR`.
  - Re-plan the app database config, or save a quiesce or resume review for it.
  - "Observe `app-database-grant-drift: <app>_migration: server-wide READ`; system.grants now lists both READ and WRITE for that user, and SHOW GRANTS shows `GRANT FILE ON *.*`."
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-20T15:05:00Z"
    document_timestamp: "2026-10-20T15:05:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Nagare v0.8.0 source (AppDatabase.hs, Catalog.hs), the
      live labs-clickhouse access storage, system.grants and system.query_log;
      reproduced once on the tan-ng-labs intranet. No independent verification
      attestation is claimed.
---

# A ClickHouse server restart widens every app database's migration FILE grant into drift

**Reported by:** a `claude-code` session implementing
`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`
on Nagare v0.8.0 (`a6004f2292071f4587dc52b821f5c88edcb3eff2`).


## What happens

Nagare gives each ClickHouse migration user one server-wide grant so its backup can write
`BACKUP ... TO File(...)`:

```haskell
-- cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs
appDatabaseServerGrants ClickHouse MigrationRole = [Grant "file" ["WRITE"]]
```

`system.query_log` on `labs-clickhouse` shows the issued statements exactly:

```text
2026-10-19 14:24:39  GRANT WRITE ON FILE TO kansoku_ch_migration;
2026-10-19 14:29:22  GRANT WRITE ON FILE TO isolation_probe_ch_migration;
2026-10-20 13:51:14  GRANT WRITE ON FILE TO kansoku_ch_migration;
```

ClickHouse 26.8.28.14 does not persist that grant as written. The user's access entity in
`/var/lib/clickhouse/access/<uuid>.sql` holds the legacy form:

```sql
ATTACH GRANT FILE ON *.* TO kansoku_ch_migration;
```

While the server keeps running, the grant is used as issued, and Nagare's catalog sees only
`WRITE`. When the server reloads its access storage on startup, `FILE ON *.*` means read and
write on file sources. After the restart, `system.grants` lists both, server-wide:

```text
user_name                     access_type  database
kansoku_ch_migration          READ         NULL
kansoku_ch_migration          WRITE        NULL
isolation_probe_ch_migration  READ         NULL
isolation_probe_ch_migration  WRITE        NULL
```

`Nagare.Database.AppDatabase.Catalog` treats any server-wide grant that is not among
`revocableGrants`, which come from the fixed set plus declared exceptions, as drift. `READ` is
in neither, so the member is `observation-unavailable`. On the intranet this refused `db
app-database resume` for both ClickHouse app databases. It also refuses re-plan, rotation and
retirement. Every ClickHouse app database whose migration user predates the restart is
affected, whichever app's maintenance caused the restart.


## Consequences

- **Stuck maintenance windows.** An app database quiesced before the restart cannot be
  resumed. Its runtime login stays off, its grants stay withheld and its backup schedule stays
  suspended. A bound workload would keep failing to connect.
- **No reviewed recovery path.** The drift policy forbids fixing the grant by hand. A manual
  `REVOKE READ ON FILE` would also be undone by the next restart, because the persisted
  `FILE ON *.*` is reloaded again.
- **Any restart triggers it.** Nagare's own `db restart`, a node reboot, a server image
  upgrade or an OOM kill all reload access storage.
- **A real privilege widening.** After a reload the migration users hold `READ` on file
  sources, so `file()` can read the server's `user_files` path. Nagare's grant set intends
  write-only access for the backup.

The defect has been present since app databases shipped in 0.7.0; the reproduction above is on
0.8.0. It was not seen earlier because the server's last restart, when 0.7.0 turned on SQL
access management, came before any app database existed.


## Expected

A grant Nagare issues must round-trip through ClickHouse's access storage unchanged, or Nagare
must observe the persisted form it actually produces. `db restart` is a reviewed Nagare
operation and must not be able to invalidate reviews.

Possible directions, for the owning repository to choose:

- Enable ClickHouse's `access_control_improvements/enable_read_write_grants` in the server
  configuration, so `READ` and `WRITE` on sources are stored and reloaded distinctly. Check
  what this does to existing `FILE` entities and to the backup Job.
- Or grant and observe the form ClickHouse persists. This means accepting `READ` on `FILE` as
  part of the fixed migration set, which makes the widening explicit and reviewed, and
  documenting why.
- Either way, a migration path for app databases already on a server with the legacy entity,
  and a regression test that restarts a server between two plans and expects `no operations`.

Acceptance: on a server with at least one ClickHouse app database, a reviewed `db restart`
followed by `db app-database plan` prints `no operations`. A quiesce followed by a restart and
a resume completes. The migration user cannot read through `file()` unless that is declared.


## Current state on the reporter's cluster

`kansoku-ch` and `isolation-probe-ch` on `labs-clickhouse` are quiesced (`tx-59774ae2…`,
`tx-bfba5764…`) and cannot resume. No workload binds them, and Kansoku's databases were backed
up and scratch-restored just before. The operator has stopped restarting the server until this
is fixed.
