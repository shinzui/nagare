---
id: 205
slug: quiesce-one-app-database-and-back-it-up-on-demand
title: "Quiesce one app database and back it up on demand"
kind: exec-plan
created_at: 2026-10-19T19:58:14Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-19T19:58:14Z
---

# Quiesce one app database and back it up on demand

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This plan answers
[IR-31](../improvement-requests/quiesce-and-back-up-one-app-database-on-demand.md), filed from
the Kansoku deployment
(`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`).

Kansoku changes its ClickHouse schema only in a maintenance session that carries drain
evidence: proof that no Kansoku process can be sending queries. It also needs a consistent
backup before each migration. Today the tan-ng-labs ceremony gets both by running
`nagarectl db restart labs-clickhouse` twice. That interrupts every other app on the shared
server. Nagare v0.7.1 also has no on-demand backup for an app database, and no way to pause its
15-minute schedule.

After this plan, an operator can run this sequence without restarting the server:

1. `nagarectl db app-database quiesce kansoku-ch --users runtime --save-plan DIR`, then apply
   it. This pauses the app database's backup schedule, blocks login for the named users without
   changing any grant, and ends their sessions within a grace period. It waits until the app's
   ClickHouse databases have no unfinished mutations, then records evidence.
2. `nagarectl db app-database backup kansoku-ch --save-plan DIR`, then apply it. This takes a
   signed backup now, with the same receipt, ingestion and restore path as a scheduled run.
3. Run the app's own migrator as the migration user, which stays open.
4. `nagarectl db app-database resume kansoku-ch --save-plan DIR`, then apply it. This re-opens
   login for exactly the quiesced users and restores the schedule's accepted bytes.

`nagarectl db app-database evidence kansoku-ch` prints what the three steps recorded. That
includes the server identity before and after, which shows the server was not restarted. Other
app databases on the server are not touched at any point.


## Progress

- [ ] M1 (engine proof). The quiesce statements and observations are proven by hand against
  `postgres:18` and `clickhouse/clickhouse-server:26.8`. They are committed as `-- operation:`
  blocks in `cli/nagarectl/test/fixtures/app-database/clickhouse.sql` and `postgres.sql`. The
  ClickHouse existing-session question under M1 in Plan of Work is answered, and the chosen
  primitive is in the Decision Log.
- [ ] M2 (quiesce and resume). `db app-database quiesce` and `resume` review a revision of the
  app-database scope:
  - the users' login state moves between `on` and `quiesced`, with grants untouched;
  - the backup CronJob is suspended and resumed;
  - a drain operation verifies no session or unfinished mutation remains.

  `db app-database plan` and `rotate` refuse with `app-database-quiesced` while the app database
  is quiesced. `server status` grades a quiesced schedule `quiesced`.
  `AppDatabaseWorldSpec` proves IR-31 AC-1 to AC-4 on both engines, including resume after every
  fault and a scheduled tick that falls inside the window.
- [ ] M3 (on-demand backup). `db app-database backup NAME --save-plan DIR` reviews a Job built
  from the accepted schedule's `jobTemplate`. Its run is ingested by the existing
  `db app-database backup-receipts --backup-id` and restored by the existing `restore`. The
  backup is refused while the migration user is quiesced. Tests prove IR-31 AC-5 in render and
  ingestion.
- [ ] M4 (evidence and docs). The quiesce, backup and resume evidence fields required by IR-31
  AC-6 are recorded with their transactions, and `db app-database evidence NAME` prints them.
  The new commands are registered in `scripts/audit-managed-commands.py`. The "Sharing one
  server between apps" section of `docs/user/managed-databases.md` documents the ceremony. The
  change is landed with a green `just gate-fast`.
- [ ] M5 (native confirmation). `scripts/local-app-database-smoke.sh` proves AC-1 to AC-6 on a
  disposable local context with the packaged CLI. It quiesces `alpha` on each engine while
  `beta`'s long queries keep running, and confirms the server Pod's start time and the
  ClickHouse server UUID are unchanged.
- [ ] M6 (release). The change ships in a release, possibly shared with
  [EP-204](204-let-app-databases-declare-reviewed-grant-exceptions-and-resource-limits.md). The
  intranet is upgraded on the candidate before the tag. The tan-ng-labs plan replaces its two
  `db restart` steps with quiesce, backup and resume. IR-31 is completed in
  `docs/improvement-requests/log.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Quiesce is a reviewed revision of the app-database scope, like retirement, plus a
  declared drain operation. It is not a transient command outside the inventory.
  Rationale: Resume must restore exactly the reviewed users and the schedule's accepted bytes
  (IR-31 AC-4). That requires the quiesced state to be accepted history. Otherwise the next
  `plan` would re-open logins as convergence.
  Date: 2026-10-19

- Decision: The user spec's login flag becomes a three-valued login state: `on`, `quiesced`
  and `off`. It encodes as the v0.7 `true` and `false` for on and off, and as `"quiesced"` for
  the new state. The hand-written codec for `DatabaseUserSpec` is introduced by whichever of
  EP-204 or this plan lands first.
  Rationale: Retirement's `off` revokes server grants. On ClickHouse that includes the
  migration user's `WRITE ON FILE`, and after EP-204 the declared exceptions too. Quiesce must
  keep all grants: IR-31 AC-2 asks that definer views keep working and that observed grants be
  unchanged after resume. Accepted v0.7.1 history must still decode.
  Date: 2026-10-19

- Decision: `--users` defaults to `runtime`. `--users runtime,migration` is allowed. The
  on-demand backup is refused while the migration user is quiesced.
  Rationale: Kansoku runs its migrator as the migration user while its runtime is blocked, and
  IR-31 asks Nagare to pick one way to allow that and document it. The backup Job dumps with
  the migration credential (ADR 30), so it cannot run while that user is blocked.
  Date: 2026-10-19

- Decision: The on-demand backup is a reviewed Job scope whose pod template is the accepted
  CronJob's `spec.jobTemplate`, byte for byte, under a run-specific Job name. It works whether
  the schedule is suspended or not.
  Rationale: The receipt's run identity is the Job's `batch.kubernetes.io/controller-uid`
  label, which `scheduledAppDatabaseReceiptExpectationFromCronJob` in
  `cli/nagarectl/src/Nagare/Inventory/BackupReceipt.hs` checks, and every Job has that label.
  So a Job made from the template signs a receipt with the accepted `scheduleRevision`.
  Ingestion and restore then work without a second receipt kind. `cli/nagarectl/src/Nagare/Task/Run.hs`
  already starts task Jobs from a CronJob the same way (`--from=cronjob/…`).
  Date: 2026-10-19

- Decision: While quiesced, `db app-database plan` and `rotate` refuse with
  `app-database-quiesced`, and `retire` is allowed.
  Rationale: If `plan` re-opened login, quiesce would be silently undone. If `plan` carried the
  state forward, the app's declaration would compete with the operator's ceremony. Retiring a
  quiesced app database is a coherent stronger state.
  Date: 2026-10-19

- Decision: The evidence is the drain operation's verification proof. For the backup, it is the
  backup operation's proof. For resume, it is the resume operation's proof. All are stored with
  their transactions in the inventory journal. `db app-database evidence NAME` reads them back,
  and nothing else stores a copy.
  Rationale: IR-31 AC-6 accepts "stored with the transaction". The journal is already
  digest-chained, and the proof is what closes an operation
  ([ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md)).
  Date: 2026-10-19


## Outcomes & Retrospective

(None yet.)


## Context and Orientation

Nagare is a single-node PaaS driven by `nagarectl`, a Haskell CLI under `cli/nagarectl/`. Every
change is a saved, reviewed plan that `nagarectl inventory apply DIR --yes` executes. Read
[EP-202](202-host-per-app-databases-on-shared-postgresql-and-clickhouse-servers.md) and
[ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md) first.

An **app database** is a tenant of a shared server. It is the inventory scope `appdb-<key>`, and
its members are:

- the credential Secrets `<name>-runtime` and `<name>-migration`;
- users `<name>_runtime` and `<name>_migration`;
- one logical-database member per database;
- its backup schedule `nagare-appdb-<name>`, with a ServiceAccount, Role, RoleBinding and
  signing Secret.

**Quiesce** means blocking one app's users from the server while keeping the users, their
grants and the server untouched. **Drain** means ending or waiting out those users' sessions and,
on ClickHouse, the app's mutations. A **mutation** is ClickHouse's asynchronous
`ALTER … UPDATE/DELETE`, listed in `system.mutations`.

Existing pieces this plan reuses:

- **Login blocking.** `renderUserAccess` in
  `cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs` sends:
  - for ClickHouse, `ALTER USER u HOST NONE`, plus revoking the server grants;
  - for PostgreSQL, `ALTER ROLE "u" NOLOGIN` and
    `SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = 'u'`.

  Quiesce needs the login half without the grant half.
- **Retirement.** `retireAppDatabaseScope` in `cli/nagarectl/src/Nagare/Inventory/AppDatabase.hs`
  turns specs off. Its local `suspend` helper sets `spec.suspend: true` on the CronJob's native
  bytes. EP-203 M3 established that the schedule revision does not include `suspend`. So runs
  before and after a suspension share one revision, and resuming restores the accepted bytes.
  `scheduleSuspended` reads the flag.
- **Login flag.** `DatabaseUserSpec engine role enabled digest` and
  `LogicalDatabase … enabled digest` are in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`. They are encoded generically in
  `cli/nagare-dsl/src/Nagare/Resource/Wire.hs`.
  - `classifyUser` in `cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs` wants
    `LoginOn` or `LoginOff` from that flag.
  - `appDatabaseRows` reports `retired` when no user is enabled.
  - `Nagare.Inventory.Application.Bindings` reads the flag when it resolves a binding.
- **Rotation as an operation.** `rotateAppDatabaseScope` adds a `DeclaredOperation` with kind
  `RotateCredential` that affects one user member. The planner in
  `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs` orders a declared operation after
  changes to the members it affects (`addDeclaredDependencies`). It also treats some kinds as
  forward-only (`forwardOnly`), so they run once per review. The drain operation follows this
  pattern with a new `OperationKind`.
- **Adapter.** `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabase.hs`
  (`mkAppDatabaseAdapter`, `AppDatabaseOps`, `CatalogCommand`) runs SQL as the server
  administrator in the server pod through
  `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabaseRuntime.hs`. It checks recorded
  incarnations first
  ([ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)).
  The administrator can `KILL QUERY` and read `system.processes`, `system.mutations`,
  `pg_stat_activity` and `pg_control_system()`.
- **Server-wide connection counting.** For direct databases, the data fence's ClickHouse
  observation in `cli/nagarectl/src/Nagare/Inventory/DataFence/MaintenanceClickHouse.hs` counts
  connections in `system.metrics`. That count is for the whole server, so it is no use for one
  tenant. This is why M1 must settle the per-user question.
- **Schedule and receipts.**
  - `renderInventoryAppDatabaseBackupCronJob` in
    `cli/nagarectl/src/Nagare/Database/AppDatabase/Backup.hs` renders the CronJob.
  - `runReviewedScheduledSourceReceiptPlan`, in its `ReceiptAppDatabase` branch in
    `cli/nagarectl/app/Nagare/Cli/Data/ScheduledReceipts.hs`, ingests one run by Job UID into
    the scope `appdb-scheduled-receipt-<ns>-<appdb>-<run>`.
  - `cli/nagarectl/src/Nagare/Inventory/AppDatabaseRestore.hs` restores an ingested run.
  - `scheduledRecoveryPointProbes` in the same `ScheduledReceipts.hs` grades schedules. A
    suspended schedule grades `retired` (EP-203 M4), so it must learn `quiesced`.
- **Manual-backup precedent for direct databases.** `compileManualBackupScope` in
  `cli/nagarectl/src/Nagare/Inventory/Backup.hs` compiles a reviewed one-off Job scope, pinned
  to the source's accepted revision and incarnations. The on-demand app-database backup follows
  its shape, with the CronJob's template as the Job.
- **CLI.** Subcommands live in `cli/nagarectl/app/Nagare/Cli/Parser/AppDatabase.hs`, with
  options in `cli/nagarectl/app/Nagare/Cli/Options/AppDatabase.hs` and runners in
  `cli/nagarectl/app/Nagare/Cli/Data/AppDatabase.hs`. Every new managed command is registered in
  `scripts/audit-managed-commands.py`; refresh it with `--update-catalogue`.
- **Tests.**
  - `cli/nagarectl/test/AppDatabaseSqlSpec.hs` pins every rendering to the fixtures.
  - `cli/nagarectl/test/AppDatabaseSpec.hs` covers compile, retirement and schedules.
  - `cli/nagarectl/test/AppDatabaseWorldSpec.hs`, with the interpreter world in
    `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs`, runs the adapter under an adversary.
  - `scripts/local-app-database-smoke.sh` (`just local-app-database-smoke CONTEXT`) confirms
    natively.

Relevant ADRs:

- [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md): retirement is
  a revision that turns access off and keeps data; backups dump with the migration credential.
- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md): every operation
  closes by its own proof, which is where the evidence goes.
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md):
  the server identity in the evidence is read through the checked accessor.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): the
  interpreter world finds defects, and the smoke confirms.


## Plan of Work

**M1, engine proof.** Use containers with the server render's environment, as EP-202 M1 did.
Answer these questions and commit each statement as a fixture block.

ClickHouse, which decides the design:

- **Existing sessions.** Open a native `clickhouse-client` session as `alpha_runtime`, keep it
  open, then run `ALTER USER alpha_runtime HOST NONE` as the administrator. Can the open session
  still run `SELECT 1`, and a `SELECT` from `alpha`'s table? Repeat over HTTP with keep-alive.
  - If both are refused, `HOST NONE` plus `KILL QUERY WHERE user IN (…) SYNC` is the drain.
  - If an open session can still query, find the smallest grant-preserving way to stop it, and
    record it in the Decision Log. The first candidate is a quota limited to zero queries for
    the user. Zero-valued `max_*` settings mean unlimited, so they are not candidates. If none
    exists, record that the
    evidence must include an empty per-user session count. Find where ClickHouse 26.8 exposes
    that count per user (`system.session_log`, if the image enables it, or
    `system.user_processes`), and prove that count.
- **Definer views.** A `SQL SECURITY DEFINER` view and a materialized view owned by
  `alpha_migration` still work after `alpha_runtime` is blocked and unblocked. Insert into the
  materialized view's source as `alpha_migration`, and read it after unblocking.
- **Mutations.** Start `ALTER TABLE alpha.t UPDATE … WHERE …` with `mutations_sync = 0`. Then
  `SELECT database, table, mutation_id, is_done, latest_fail_reason FROM system.mutations WHERE
  database IN ('alpha', 'alpha_ledger') AND is_done = 0` shows it until it finishes. A failing
  mutation shows a non-empty `latest_fail_reason`.
- **Server identity.** `SELECT serverUUID(), uptime()` as the administrator.

PostgreSQL:

- **Termination.** `ALTER ROLE "alpha_runtime" NOLOGIN` followed by the terminate statement
  ends an idle session, and ends a session running `SELECT pg_sleep(600)`. A new login is
  refused.
- **Session count.** `SELECT count(*) FROM pg_stat_activity WHERE usename IN (…)` is then 0.
- **Server identity.** `SELECT system_identifier FROM pg_control_system()` and
  `pg_postmaster_start_time()`.
- **Migration user.** `alpha_migration` can still log in and run DDL while `alpha_runtime` is
  blocked.

**M2, quiesce and resume.**

- **Login state.** Replace the user spec's `Bool` with
  `UserLogin = LoginOpen | LoginQuiesced | LoginClosed` in
  `Nagare.Resource.Inventory.Types`, with the codec in the Decision Log.
  - `classifyUser` maps `LoginQuiesced` to wanting `LoginOff`, with the declared server grants
    still held.
  - `renderUserAccess` gains the quiesce rendering: the login half only, plus the M1 drain
    statements.
  - `appDatabaseRows` gains `quiesced`.
- **Scope revisions.** In `Nagare.Inventory.AppDatabase`, add
  `quiesceAppDatabaseScope snapshot native scope users stamp`. It:
  - refuses an already quiesced or retired scope;
  - sets the chosen users to `LoginQuiesced`;
  - suspends the CronJob through the `suspend` helper, extracted from `retireAppDatabaseScope`
    so both use it;
  - adds a `DeclaredOperation` `drain-<stamp>` with a new `OperationKind`, `DrainSessions`,
    affecting the quiesced user members and the logical databases. Add the kind to
    `forwardOnly` in `Plan/Changes.hs`.

  Add `resumeAppDatabaseScope` as the inverse. It sets those users back to `LoginOpen`,
  restores the CronJob's bytes as they were accepted before the quiesce (read from the accepted
  revision before it), and adds a `resume-<stamp>` operation that records the server identity.
- **Drain operation.** The adapter executes `DrainSessions`:
  1. Wait up to `--grace` (default 30 s) for the blocked users' running queries to end, then
     terminate them with the M1 statements.
  2. On ClickHouse, wait up to `--timeout` (default 300 s) for the app's unfinished mutations.
     A failed mutation fails the operation and names `database.table mutation_id`.
  3. If the migration user is quiesced, wait within the same bound for an active
     `nagare-appdb-<name>` Job to finish.
  4. Verify by re-observing:
     - no session of a blocked user;
     - no unfinished mutation;
     - both users' grants equal the declared set;
     - the server identity.

  The proof carries the evidence fields listed in Validation. Recovery after a lost
  acknowledgement re-observes and either proves the drain or retries. A drain repeated after
  login is blocked is harmless.
- **Refusals.** In `cli/nagarectl/app/Nagare/Cli/Data/AppDatabase.hs`, the `plan` and `rotate`
  runners refuse with `app-database-quiesced` when the accepted scope has a quiesced user.
- **Status.** `scheduledRecoveryPointProbes` grades a suspended schedule whose scope has a
  quiesced user as `OK quiesced`, and a retired one as before.
- **World.** Extend the interpreter world with sessions per user, a running query, and a
  mutation that finishes after N observations or fails. Its scheduler starts a Job at a tick
  unless the CronJob is suspended.

**M3, on-demand backup.** Add `compileAppDatabaseOnDemandBackupScope`. From the accepted
`appdb-*` scope and its CronJob's native bytes, it builds one Job:

- the Job is named `nagare-appdb-<name>-od-<stamp>`;
- its `spec` is the CronJob's `spec.jobTemplate.spec`, with labels from
  `spec.jobTemplate.metadata`;
- it is pinned, like `compileManualBackupScope`, to the server StatefulSet and PVC
  incarnations.

The scope is `appdb-backup-<ns>-<appdb>-<stamp>`. The command is
`db app-database backup NAME [-n NS] --save-plan DIR`, with `--backup-stamp` defaulting to a
UTC timestamp. It refuses when the scope's migration user is quiesced or retired. After apply,
the operator ingests the run with the existing `db app-database backup-receipts NAME
--backup-id <Job UID>`. Tests:

- the rendered Job's pod spec equals the CronJob template;
- `scheduledAppDatabaseReceiptExpectationFromCronJob` accepts the run;
- an ingested on-demand run restores into scratch in the existing restore test.

**M4, evidence and docs.** `db app-database evidence NAME [-n NS] [--json]` reads, from the
inventory store, the proofs of the latest `drain-*`, `appdb-backup-*` and `resume-*`
operations for that app database, and prints one record. A missing step prints as `absent`, not
as an error.

Document the ceremony in `docs/user/managed-databases.md`: quiesce, backup, ingest, migrate as
the migration user, resume, evidence. Say what quiesce does not do: it does not stop workloads,
so a bound workload fails to connect and restarts until resume. Register `quiesce`, `resume`,
`backup` and `evidence` in `scripts/audit-managed-commands.py`.

**M5, native confirmation.** Extend the smoke after its F132 step:

1. Start a long query as each `alpha` and `beta` user on both engines: `SELECT
   sleepEachRow(1) FROM numbers(600)` and `SELECT pg_sleep(600)`.
2. Quiesce `alpha-ch` and `alpha-pg`, then apply.
3. Assert that `alpha`'s queries ended and its new logins fail; that `beta`'s queries are still
   running; that the CronJobs are suspended; and that the server Pods' `status.startTime` and
   `serverUUID()` are unchanged.
4. Take an on-demand backup of each, ingest it, and restore it into scratch.
5. Resume, and assert:
   - the CronJob bytes equal their accepted pre-quiesce bytes;
   - `alpha` logs in again;
   - a definer view still reads;
   - `db app-database evidence` prints every field.

**M6, release.** Follow `docs/runbooks/releases.md`: upgrade the intranet on the candidate,
then tag. Hand the tan-ng-labs plan the new ceremony. Record the resolution and `targetPlan` in
IR-31's frontmatter, and add a line to `docs/improvement-requests/log.md`.


## Concrete Steps

M1, from the repository root, with Colima or Docker running:

```bash
docker run -d --name ep205-pg -e POSTGRES_USER=nagare -e POSTGRES_PASSWORD=pw postgres:18
docker run -d --name ep205-ch -e CLICKHOUSE_USER=nagare -e CLICKHOUSE_PASSWORD=pw \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 clickhouse/clickhouse-server:26.8
```

Replay the existing fixture blocks to create `alpha` and `beta`, run the questions above, and
append the proven blocks. Remove the containers with `docker rm -f ep205-pg ep205-ch`.

For each Haskell commit:

```bash
cd cli/nagarectl
for p in AppDatabase ScheduledReceipts; do cabal test nagarectl-test --test-options="-p $p"; done
cd ../.. && just haskell-style-check && just gate-fast HEAD
```

Land with `just land HEAD`.

The operator flow M5 exercises, against a local context:

```bash
n db app-database quiesce alpha-ch -n personal --users runtime --save-plan "$R/q"
n inventory apply "$R/q" --yes
n db app-database backup alpha-ch -n personal --save-plan "$R/b"
n inventory apply "$R/b" --yes
n db app-database backup-receipts alpha-ch -n personal --backup-id "$UID" --save-plan "$R/i"
n inventory apply "$R/i" --yes
n db app-database resume alpha-ch -n personal --save-plan "$R/r"
n inventory apply "$R/r" --yes
n db app-database evidence alpha-ch -n personal
```

Run M5 with the packaged CLI, from an empty environment:

```bash
nix build --no-link --print-out-paths "git+file://$PWD?rev=$(git rev-parse HEAD)#nagarectl"
NAGARE_SMOKE_CONTEXT=transition NAGARECTL=<out>/bin/nagarectl scripts/local-app-database-smoke.sh
```

The run should end with these two lines (the first is a new log line) and `PASS`:

```text
… app-database smoke: IR-31: alpha quiesced and drained on both engines while beta ran; on-demand backups ingested and restored; resumed with schedules as accepted; servers not restarted
app-database smoke: PASS
```


## Validation and Acceptance

- **AC-1.**
  - In the world on both engines, with sessions and running queries for `alpha` and `beta`,
    quiescing `alpha` ends its sessions and blocks its logins.
  - `beta`'s sessions and the world's server incarnation are unchanged.
  - The smoke repeats this with real queries and Pod start times.
- **AC-2.** After quiesce and resume:
  - the world's grant sets for both users equal the pre-quiesce sets;
  - in the smoke, `alpha`'s definer view and materialized view read after resume;
  - `system.grants` for `alpha` is identical before and after (md5 of the sorted rows).
- **AC-3.**
  - A world mutation that finishes after three observations makes the drain wait, then
    complete.
  - A failing mutation fails the operation with `alpha.t mutation_…` in the reason.
- **AC-4.**
  - In the world, a schedule tick inside the quiesce window starts no Job.
  - After resume, the CronJob's native bytes equal the accepted pre-quiesce bytes, and the next
    tick starts a Job.
  - The smoke asserts the suspend flag and the byte equality.
- **AC-5.**
  - The on-demand Job's pod spec equals the CronJob template.
  - Its run ingests with the existing command, and restores into scratch on both engines.
  - It is refused while the migration user is quiesced.
- **AC-6.** `db app-database evidence alpha-ch --json` prints:
  - `server` (StatefulSet incarnation, plus `serverUUID` for ClickHouse or `system_identifier`
    and postmaster start time for PostgreSQL);
  - `appDatabase`, `blockedUsers`, `sessionsObserved: 0`, `unfinishedMutations: []`, and the
    transaction IDs of quiesce, backup and resume;
  - the backup's `backupId` and receipt object path.

  The server identity is equal in the quiesce and resume records.

Required gates per commit and landing are in Concrete Steps. The interpreter-world tests are
the required acceptance. The smoke confirms.


## Idempotence and Recovery

Quiesce, backup and resume are each one reviewed transaction.

- **Re-runs.** Quiescing an already quiesced app database is refused, and so is resuming an
  open one. So a repeated command cannot stack states.
- **Interruptions.** A drain interrupted after login was blocked resumes with
  `nagarectl inventory resume TX --yes`. It re-observes and either proves the drain or retries,
  and blocking login again has no further effect.
- **Stuck mutation.** If a mutation will not finish, the drain fails and the app database stays
  quiesced. The operator investigates, then either resumes or retries the drain by quiescing
  again after a resume.
- **Interrupted backup.** An interrupted on-demand backup is a Job that either produced a
  verified receipt or did not. Ingestion verifies stored bytes, so a partial run is never
  ingested.
- **Last resort.** Resume is always available while quiesced. If the scope cannot be read,
  stop and report rather than editing users by hand.


## Interfaces and Dependencies

- `Nagare.Resource.Inventory.Types`: the user spec's login becomes `UserLogin`, with the codec
  in the Decision Log. `OperationKind` gains `DrainSessions`, which is additive in the generic
  encoding.
- `Nagare.Inventory.AppDatabase` gains `quiesceAppDatabaseScope`, `resumeAppDatabaseScope` and
  the shared `suspendSchedule` helper. `AppDatabaseRow` gains `quiesced`.
- `Nagare.Inventory.Adapters.AppDatabase`: `AppDatabaseOps` gains `observeSessions`,
  `observeMutations`, `observeServerIdentity` and `terminateSessions`. The kubectl runtime and
  the world implement them.
- New CLI subcommands: `quiesce`, `resume`, `backup` and `evidence`.
- No new libraries. Coordinate with EP-204 on the `DatabaseUserSpec` codec, since both change
  that constructor.
