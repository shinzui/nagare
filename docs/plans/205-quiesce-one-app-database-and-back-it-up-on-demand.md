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
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-20T00:05:19Z
      mode: "implement"
      note: "M1 onward: engine proof, quiesce/resume, on-demand backup, evidence"
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
   changing any grant, and ends their sessions within a grace period. It waits until no
   scheduled backup run is in flight and the app's ClickHouse databases have no unfinished
   mutations.
2. `nagarectl db app-database backup kansoku-ch --save-plan DIR`, then apply it. This takes a
   signed backup now, with the same receipt, ingestion and restore path as a scheduled run.
3. Run the app's own migrator as the migration user, which stays open.
4. `nagarectl db app-database resume kansoku-ch --save-plan DIR`, then apply it. This re-opens
   login for exactly the quiesced users and restores the schedule's accepted bytes.

`nagarectl db app-database evidence kansoku-ch` prints what the three steps recorded. That
includes the server's identity and process start time before and after, which shows the server
was not restarted. Other app databases on the server are not touched at any point.


## Progress

- [x] M1 (engine proof). The quiesce statements and observations are proven by hand against
  `postgres:18` and `clickhouse/clickhouse-server:26.8`. They are committed as `-- operation:`
  blocks in `cli/nagarectl/test/fixtures/app-database/clickhouse.sql` and `postgres.sql`. The
  ClickHouse existing-session question under M1 in Plan of Work is answered, and the chosen
  primitive is in the Decision Log.
  Done 2026-10-19 on 26.8.29.10 and 18. Open native ClickHouse sessions outlive every
  login-level change, so on ClickHouse grants are withheld (operator decision, Decision Log).
  The new blocks are `database-access alpha withheld alpha_runtime`, `drain alpha_runtime` and
  `user-access alpha_runtime quiesced`. The drain observations are captured in
  `observed/{clickhouse,postgres}-drain-{busy,idle}.*`.
- [x] M2 (quiesce and resume). `db app-database quiesce` and `resume` review a revision of the
  app-database scope:
  - the users' login state moves between `on` and `quiesced`, with grants untouched;
  - the backup CronJob is suspended and resumed;
  - a `drain` operation verifies no session, in-flight scheduled run or unfinished mutation
    remains, and a `resume` operation records the server identity again.

  While the app database is quiesced, `db app-database plan` leaves it out of the candidate and
  says so, and `rotate` refuses with `app-database-quiesced`. A workload binding still resolves.
  `server status` grades a quiesced schedule `quiesced`. `AppDatabaseWorldSpec` proves IR-31
  AC-1 to AC-4 on both engines, including resume after every fault and a scheduled tick that
  falls inside the window.
  Done 2026-10-19:
  - The login state is three-valued: v0.7 `true`/`false` plus `"quiesced"`.
  - `quiesce` and `resume` revise one scope, and the scope-wide planner ordering is in.
  - Drain and resume are selected by digest (`Nagare.Inventory.Adapters.AppDatabaseSessions`).
  - `plan` leaves out a quiesced app database, `rotate` refuses with `app-database-quiesced`,
    a quiesced app database still binds, and status grades it `quiesced`.
  - World tests on both engines: AC-1 and AC-2 (grants and limits identical after resume),
    AC-3 on ClickHouse, AC-4 (a run in flight, a timeout, and ordering after the
    suspension), a restarted server, and every fault placement acting across the whole cycle.
  - Each ordering and binding test fails without its fix.
  - The EP-202 repassword mutation record was regenerated and proven.
- [ ] M3 (on-demand backup). `db app-database backup NAME --save-plan DIR` reviews a Job built
  from the accepted schedule's `jobTemplate`. Its run is ingested by the existing
  `db app-database backup-receipts --backup-id` and restored by the existing `restore`. The
  backup is refused while the migration user is quiesced. Tests prove IR-31 AC-5 in render and
  ingestion.
- [ ] M4 (evidence and docs). `db app-database evidence NAME` assembles the IR-31 AC-6 fields
  from the store: the reviewed `drain` and `resume` plans, their journalled completions, and the
  ingested receipt. The new commands are registered in `scripts/audit-managed-commands.py`. The
  "Sharing one server between apps" section of `docs/user/managed-databases.md` documents the
  ceremony. The change is landed with a green `just gate-fast`.
- [ ] M5 (native confirmation). `scripts/local-app-database-smoke.sh` proves AC-1 to AC-6 on a
  disposable local context with the packaged CLI. In a new step before `beta-ch` is retired,
  it quiesces `alpha` on each engine while `beta`'s long queries keep running, and confirms the
  server Pods' UIDs and start times and the ClickHouse server UUID are unchanged.
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

- Decision: `--users` defaults to `runtime`, and `--users runtime,migration` is allowed. The
  runtime user is always included, so `--users migration` alone is refused. The on-demand backup
  is refused while the migration user is quiesced.
  Rationale: Kansoku runs its migrator as the migration user while its runtime is blocked, and
  IR-31 asks Nagare to pick one way to allow that and document it. The backup Job dumps with
  the migration credential (ADR 30), so it cannot run while that user is blocked. Always
  quiescing the runtime user also gives the drain and resume operations one fixed member to
  affect (next decision).
  Date: 2026-10-19

- Decision: The drain and resume steps are two declared operations, with new kinds
  `DrainSessions` and `ResumeSessions`. Each has a fixed identity, `drain` or `resume`, and
  affects only the runtime user member. The stamp goes in the inputs. A new quiesce replaces the
  old `drain`, as rotation replaces `rotate-<role>`. Both kinds are forward-only. The app-database
  adapter selects them by the operation's input digest, following `withVmPower` in
  `cli/nagarectl/src/Nagare/Inventory/VmPower.hs`. The planner orders both after every change in
  their own scope.
  Rationale: The adapter refuses an operation that affects more than one member, and
  `PlannedOperation` carries no operation kind. Today every `RunDeclaredOperation` in this
  adapter is a rotation. A stamped identity per cycle would pile up operations in the scope.
  `addDeclaredDependencies` orders an operation only after changes to the members it affects and
  to their dependencies. The CronJob is neither, so without the scope-wide rule the drain could
  finish before the schedule is suspended, and a tick in between would start a run.
  Date: 2026-10-19

- Decision: The on-demand backup is a reviewed Job scope whose pod template is the accepted
  CronJob's `spec.jobTemplate`, byte for byte. Its name is `<schedule>-<id>`, where the ID is at
  most 12 lowercase letters or digits (default: the UTC time as `yyyymmddhhmm`), so the name
  fits the 63-character `batch.kubernetes.io/job-name` label. It works whether the schedule is
  suspended or not. Its run lands in the schedule's key space and is retained and pruned under
  the schedule's `keep`, like any scheduled run.
  Rationale: The receipt's run identity is the Job's `batch.kubernetes.io/controller-uid`
  label, which the template reads through the downward API (`cli/nagarectl/src/Nagare/Database/Backup.hs`).
  Ingestion derives its expectation from the accepted CronJob bytes
  (`scheduledAppDatabaseReceiptExpectationFromCronJob`), and the schedule revision does not
  cover `suspend`. So a Job made from the template signs a receipt with the accepted
  `scheduleRevision`, and ingestion and restore work without a second receipt kind. Schedule
  names are at most 49 characters, and 49 + 1 + 12 = 62.
  Date: 2026-10-19

- Decision: While quiesced, `db app-database plan` leaves that app database out of the
  candidate and prints its name. `rotate` refuses with `app-database-quiesced`. `retire` is
  allowed. A workload binding to the app database still resolves.
  Rationale: `plan` compiles every app database in the config into one candidate, so a refusal
  would block every other app's changes during one app's window. Re-opening login would silently
  undo the quiesce. Carrying the state forward would make the app's declaration compete with the
  operator's ceremony. Retiring a quiesced app database is a coherent stronger state. Quiesce
  does not stop workloads, so the app's own deploy may roll during the window. Its pods fail to
  connect until resume, as running ones do.
  Date: 2026-10-19

- Decision: Resume clears `spec.suspend` by deleting the key from the CronJob's native bytes.
  Rationale: `renderInventoryAppDatabaseBackupCronJob` never writes `suspend`, so deleting it
  gives back the accepted pre-quiesce canonical bytes exactly. No earlier revision has to be
  read.
  Date: 2026-10-19

- Decision: The evidence is assembled from what the store already keeps. Nothing new is stored.
  - The `drain` and `resume` operations each observe the server identity read-only when they
    are prepared, at planning, and write it into their private plan. The review publishes that
    plan.
  - Verification succeeds only if the live server identity still equals the planned one, and
    no blocked user's session, in-flight scheduled run or unfinished mutation remains. The proof
    digest commits to what was observed.
  - `db app-database evidence NAME` reads the two plans and their `Completed` journal events,
    plus the ingested receipt's scope.

  Rationale: The journal keeps only a proof digest and a fixed detail text for a completed
  operation (`JournalEvent` in `cli/nagarectl/src/Nagare/Inventory/Journal.hs`). Putting the
  fields there would change the journal schema and `adapterVerify` for every adapter. A review's
  private members are already content-addressed in the store (`publishReview`), and IR-31 AC-6
  accepts "stored with the transaction". The empty session and mutation state is a
  postcondition of the completed drain
  ([ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md)).
  Date: 2026-10-19

- Decision: The server identity is the StatefulSet incarnation, the server Pod's UID and its
  container's `startedAt`. On ClickHouse it adds `serverUUID()` and `now() - uptime()`. On
  PostgreSQL it adds `system_identifier` and `pg_postmaster_start_time()`.
  Rationale: IR-31 notes that the ClickHouse server UUID survived both restarts. The StatefulSet
  incarnation survives a restart too. Only the Pod and process start times show the server was
  not restarted.
  Date: 2026-10-19


- Decision (M1, operator, 2026-10-19): on ClickHouse, quiesce withholds the blocked users'
  grants and resume grants exactly the declared set again. On PostgreSQL quiesce keeps every
  grant. This supersedes "Quiesce must keep all grants" for ClickHouse.
  Rationale: M1 found that an open native ClickHouse session keeps querying after every
  login-level change: `HOST NONE`, a quota of `MAX queries = 0` or `1`, and `VALID UNTIL` a
  past date. ClickHouse 26.8 also exposes no per-user idle-session count: there is no
  `session_log`, `system.user_processes` lists users, and `TCPConnection` is server-wide. A
  grant change reaches an open session at its next query. The migration user keeps its grants,
  so its definer views and materialized views keep working (IR-31 AC-2). `system.grants` is
  byte-identical after resume. HTTP requests authenticate one by one, so `HOST NONE` already
  refuses them.
  - The quiesced ClickHouse user renders as the "off" user access (`HOST NONE`, server grants
    and exceptions revoked, limits kept).
  - Its logical databases withhold its grants (`REVOKE ALL ON db.* FROM u`). The other user's
    grants stay.
  - The withheld users are derived from the sibling user specs, so the logical-database spec
    and its encoding do not change.
  Date: 2026-10-19

- Decision (M1): on PostgreSQL the quiesced user access is `NOLOGIN` plus the declared limits,
  without the terminate statement. The drain terminates after the grace period.
  Date: 2026-10-19

- Decision (M1): the server identity that drain and resume compare is the server Pod's UID,
  its container's `startedAt`, and `serverUUID()` or `system_identifier` with
  `pg_postmaster_start_time()`. ClickHouse's `now() - uptime()` is whole seconds and may move
  by one between reads, so it is recorded but not compared.
  Date: 2026-10-19

- Decision (M1): the long-query probe is `SELECT sleepEachRow(1) FROM numbers(600) SETTINGS
  max_block_size = 1`. Without `max_block_size`, ClickHouse refuses it with code 160, because
  a block may sleep at most 3 s.
  Date: 2026-10-19

- Decision: the drain's bounds are fixed at a 30 s grace and a 300 s timeout, with no
  `--grace` or `--timeout` options. The drain operation's inputs are the stamp alone. The
  blocked users are the scope's quiesced users.
  Rationale: `OperationInput` has no constructor for bounds, and Kansoku's ceremony needs
  none. A drain that times out leaves the app database quiesced: resume, then quiesce again.
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
grants and the server untouched. **Drain** means ending or waiting out those users' sessions
and any in-flight scheduled backup run, and, on ClickHouse, the app's mutations. A **mutation**
is ClickHouse's asynchronous `ALTER … UPDATE/DELETE`, listed in `system.mutations`.

Existing pieces this plan reuses:

- **Login blocking.** `renderUserAccess` in
  `cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs` sends:
  - for ClickHouse, `ALTER USER u HOST NONE`, plus revoking the server grants;
  - for PostgreSQL, `ALTER ROLE "u" NOLOGIN` and
    `SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = 'u'`.

  Quiesce needs the login half without the grant half. Retirement also sends
  `renderDatabaseAccess` with `enabled = False`, which revokes database access. Quiesce must
  leave the logical-database members alone.
- **Retirement.** `retireAppDatabaseScope` in `cli/nagarectl/src/Nagare/Inventory/AppDatabase.hs`
  turns specs off. It refuses with `app-database-in-use` while a workload binds the app
  database; quiesce must not. Its local `suspend` helper sets `spec.suspend: true` on the
  CronJob's native bytes. EP-203 M3 established that the schedule revision does not include
  `suspend`. So runs before and after a suspension share one revision. `scheduleSuspended` reads
  the flag.
- **Login flag.** `DatabaseUserSpec engine role enabled digest` and
  `LogicalDatabase … enabled digest` are in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`. They are encoded generically in
  `cli/nagare-dsl/src/Nagare/Resource/Wire.hs`. Readers of the user flag:
  - `classifyUser` in `cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs` wants
    `LoginOn` or `LoginOff` from it. A disabled user must also hold no server grants.
  - `appDatabaseMembersFromDeclarations` copies it into `AppDatabaseMember`'s `enabled`, which
    picks the `SetUserAccess` rendering and the "(retired: access off)" summary.
  - `appDatabaseRows` reports `retired` when no user is enabled.
  - `Nagare.Inventory.Application.Bindings` refuses a binding unless every user is enabled
    ("app database … is retired").
- **Rotation as an operation.** `rotateAppDatabaseScope` adds a `DeclaredOperation` with the
  fixed identity `rotate-<role>`, kind `RotateCredential` and the stamp as a `ContentInput`. It
  affects one user member. The planner in
  `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs` orders a declared operation after
  changes to the members it affects and to their dependencies (`addDeclaredDependencies`). It
  also treats some kinds as forward-only (`forwardOnly`), so they run once per review.
- **Adapter.** `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabase.hs`
  (`mkAppDatabaseAdapter`, `AppDatabaseOps`, `CatalogCommand`) runs SQL as the server
  administrator in the server pod through
  `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabaseRuntime.hs`. It checks recorded
  incarnations first
  ([ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)).
  The administrator can `KILL QUERY` and read `system.processes`, `system.mutations`,
  `pg_stat_activity` and `pg_control_system()`. Constraints the new operations must meet:
  - `planFor` refuses an operation that affects more than one member.
  - `planFor` maps every `RunDeclaredOperation` to `rotate`. `PlannedOperation` carries no
    operation kind, only `plannedInputDigest`, the digest of the declared operation's JSON.
    `withVmPower` in `cli/nagarectl/src/Nagare/Inventory/VmPower.hs` shows how to select
    operations by that digest.
  - `adapterVerify` returns a `ContentDigest`. The journal stores it as `Completed digest`, with
    the detail "operation completion verified".
  - The private plan returned by `adapterPrepare` is published with the review
    (`publishReview` in `cli/nagarectl/src/Nagare/Inventory/Plan/Publication.hs`).
- **Server-wide connection counting.** For direct databases, the data fence's ClickHouse
  observation in `cli/nagarectl/src/Nagare/Inventory/DataFence/MaintenanceClickHouse.hs` counts
  connections in `system.metrics`. That count is for the whole server, so it is no use for one
  tenant. This is why M1 must settle the per-user question. Interactive maintenance sessions
  for direct databases are deferred, so their fence is not a precedent to extend.
- **Schedule and receipts.**
  - `renderInventoryAppDatabaseBackupCronJob` in
    `cli/nagarectl/src/Nagare/Database/AppDatabase/Backup.hs` renders the CronJob. It never
    writes `suspend`.
  - `runReviewedScheduledSourceReceiptPlan`, in its `ReceiptAppDatabase` branch in
    `cli/nagarectl/app/Nagare/Cli/Data/ScheduledReceipts.hs`, ingests one run by Job UID into
    the scope `appdb-scheduled-receipt-<ns>-<appdb>-<run>`. That scope's overrides
    `scheduled.backup.id` and `scheduled.backup.source.scope` name the run and its app database.
  - `cli/nagarectl/src/Nagare/Inventory/AppDatabaseRestore.hs` restores an ingested run.
  - `scheduledRecoveryPointProbes` in the same `ScheduledReceipts.hs` grades schedules. A
    suspended schedule grades `retired` (EP-203 M4), so it must learn `quiesced`.
- **Manual-backup precedent for direct databases.** `compileManualBackupScope` in
  `cli/nagarectl/src/Nagare/Inventory/Backup.hs` compiles a reviewed one-off Job scope, pinned
  to the source's accepted revision and incarnations. The on-demand app-database backup follows
  its shape, with the CronJob's template as the Job.
- **CLI.** Subcommands live in `cli/nagarectl/app/Nagare/Cli/Parser/AppDatabase.hs`, with
  options in `cli/nagarectl/app/Nagare/Cli/Options/AppDatabase.hs` and runners in
  `cli/nagarectl/app/Nagare/Cli/Data/AppDatabase.hs`. `runPlan` compiles every app database
  in the config into one candidate. `retire` and `rotate` revise one accepted scope and review
  only that. Every new managed command is registered in `scripts/audit-managed-commands.py`;
  refresh it with `--update-catalogue`.
- **Tests.**
  - `cli/nagarectl/test/AppDatabaseSqlSpec.hs` pins every rendering to the fixtures.
  - `cli/nagarectl/test/AppDatabaseSpec.hs` covers compile, retirement and schedules.
  - `cli/nagarectl/test/AppDatabaseWorldSpec.hs`, with the interpreter world in
    `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs`, runs the adapter under an adversary.
  - `scripts/local-app-database-smoke.sh` (`just local-app-database-smoke CONTEXT`) confirms
    natively. Its step 6 retires `beta-ch`, so after that step only `beta-pg` can still run
    queries.

Relevant ADRs:

- [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md): retirement is
  a revision that turns access off and keeps data; backups dump with the migration credential.
- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md): every operation
  closes by its own proof, so a completed drain proves its postconditions held.
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
  still run `SELECT 1`, and a `SELECT` from `alpha`'s table? Repeat over HTTP, both with
  keep-alive and with a `session_id` session.
  - If all are refused, `HOST NONE` plus `KILL QUERY WHERE user IN (…) SYNC` is the drain.
  - If an open session can still query, find the smallest grant-preserving way to stop it, and
    record it in the Decision Log. The first candidate is a quota of zero queries for the user.
    Prove that first: a zero in a ClickHouse limit often means unlimited, and that is why
    zero-valued `max_*` settings are not candidates. If nothing works, record that the evidence
    must include an empty per-user session count. Find where ClickHouse 26.8 exposes that count
    per user (`system.session_log`, if the image enables it, or `system.user_processes`), and
    prove that count.
- **Definer views.** A `SQL SECURITY DEFINER` view and a materialized view owned by
  `alpha_migration` still work after `alpha_runtime` is blocked and unblocked. Insert into the
  materialized view's source as `alpha_migration`, and read it after unblocking.
- **Mutations.** Start `ALTER TABLE alpha.t UPDATE … WHERE …` with `mutations_sync = 0`. Then
  `SELECT database, table, mutation_id, is_done, latest_fail_reason FROM system.mutations WHERE
  database IN ('alpha', 'alpha_ledger') AND is_done = 0` shows it until it finishes. A failing
  mutation shows a non-empty `latest_fail_reason`.
- **Server identity.** `SELECT serverUUID(), now() - uptime()` as the administrator.

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
  `Nagare.Resource.Inventory.Types`, with the codec in the Decision Log. Follow it through every
  reader listed under Context:
  - `classifyUser` maps `LoginQuiesced` to wanting `LoginOff` while still holding the declared
    server grants.
  - `AppDatabaseMember` carries the login state. `SetUserAccess` gains the quiesce rendering:
    the login half only, plus the M1 drain statements. Its summary says "(quiesced: login off,
    grants kept)".
  - `appDatabaseRows` replaces `retired` with a state of `active`, `quiesced` or `retired`.
  - `Bindings` treats `LoginQuiesced` as bound and keeps refusing `LoginClosed`.
  - Logical-database members are not changed by quiesce or resume.
- **Scope revisions.** In `Nagare.Inventory.AppDatabase`, add
  `quiesceAppDatabaseScope native scope users stamp grace timeout`. It:
  - refuses an already quiesced or retired scope, and a user set without `runtime`;
  - sets the chosen users to `LoginQuiesced`;
  - suspends the CronJob through the `suspend` helper, extracted from `retireAppDatabaseScope`
    so both use it;
  - replaces the `drain` operation (kind `DrainSessions`, affecting the runtime user) with one
    whose inputs are the stamp, the users, `--grace` (default 30 s) and `--timeout` (default
    300 s).

  Add `resumeAppDatabaseScope native scope stamp` as the inverse. It refuses a scope that is not
  quiesced. It sets the quiesced users back to `LoginOpen` and deletes `suspend` from the
  CronJob's bytes. It replaces the `resume` operation (kind `ResumeSessions`) the same way.
  Add both kinds to `forwardOnly`. In `addDeclaredDependencies`, order an operation of either
  kind after every change to a member of its own scope.
- **Adapter.** In `mkAppDatabaseAdapter`, select `drain` and `resume` by input digest, as
  `withVmPower` does, and leave every other `RunDeclaredOperation` a rotation.
  - Prepare observes the server identity read-only and writes it into the private plan, with
    the users, databases and bounds.
  - Drain execution:
    1. Wait up to the grace period for the blocked users' running queries to end, then
       terminate them with the M1 statements.
    2. Wait, within the timeout, until the CronJob has no active Job. This covers a run that
       started before the suspension.
    3. On ClickHouse, wait within the timeout for the app's unfinished mutations. A failed
       mutation fails the operation and names `database.table mutation_id`.
  - Drain verification re-observes and requires all of these:
    - no session of a blocked user;
    - no active scheduled Job;
    - no unfinished mutation;
    - both users' grants equal to the declared set;
    - the server identity equal to the planned one.

    Recovery after a lost acknowledgement re-observes and either proves the drain or retries. A
    drain repeated after login is blocked is harmless.
  - Resume execution does nothing beyond the member changes it is ordered after. Resume
    verification requires the server identity to equal its planned one and the users to log in.
  - `AppDatabaseOps` gains `observeSessions`, `observeMutations`, `observeActiveRuns`,
    `observeServerIdentity` and `terminateSessions`.
- **CLI.** Add `quiesce NAME [-n NS] [--users runtime[,migration]] [--grace S] [--timeout S]
  --save-plan DIR` and `resume NAME [-n NS] --save-plan DIR`. Each revises one accepted scope
  and reviews only that, like `retire`. In `runPlan`, leave out every app database whose
  accepted scope has a quiesced user, and print one line naming it. The `rotate` runner refuses
  with `app-database-quiesced`.
- **Status.** `scheduledRecoveryPointProbes` grades a suspended schedule whose scope has a
  quiesced user as `OK quiesced`, and a retired one as before.
- **World.** Extend the interpreter world with sessions per user, a running query, a scheduled
  Job that is still running, and a mutation that finishes after N observations or fails. Its
  scheduler starts a Job at a tick unless the CronJob is suspended.

**M3, on-demand backup.** Add `compileAppDatabaseOnDemandBackupScope`. From the accepted
`appdb-*` scope and its CronJob's native bytes, it builds one Job:

- the Job is named `nagare-appdb-<name>-<id>`, with the ID from the Decision Log;
- its `spec` is the CronJob's `spec.jobTemplate.spec`, with labels from
  `spec.jobTemplate.metadata`;
- it is pinned, like `compileManualBackupScope`, to the server StatefulSet and PVC
  incarnations.

The scope is `appdb-backup-<ns>-<appdb>-<id>`. The command is
`db app-database backup NAME [-n NS] [--backup-id ID] --save-plan DIR`. It refuses when the
scope's migration user is quiesced or retired. After apply, the operator ingests the run with
the existing `db app-database backup-receipts NAME --backup-id <Job UID>`. Tests:

- the rendered Job's pod spec equals the CronJob template;
- the longest schedule name with the longest ID gives a Job name of at most 63 characters;
- `scheduledAppDatabaseReceiptExpectationFromCronJob` accepts the run against the suspended
  CronJob's bytes;
- an ingested on-demand run restores into scratch in the existing restore test.

**M4, evidence and docs.** `db app-database evidence NAME [-n NS] [--json]` reads from the
inventory store, for that app database:

- the latest accepted `drain` and `resume` operations, their private plans from the review, and
  their `Completed` journal events (transaction, sequence, timestamp, proof digest);
- the newest ingested receipt scope whose `scheduled.backup.source.scope` is this app database
  and whose run is newer than the drain, with its backup ID and receipt object.

It prints one record. A missing step prints as `absent`, not as an error.

Document the ceremony in `docs/user/managed-databases.md`: quiesce, backup, ingest, migrate as
the migration user, resume, evidence. Say what quiesce does not do: it does not stop workloads,
so a bound workload fails to connect and restarts until resume. Say that `plan` skips a quiesced
app database, and that the on-demand backup is pruned under the schedule's `keep`. Register
`quiesce`, `resume`, `backup` and `evidence` in `scripts/audit-managed-commands.py`.

**M5, native confirmation.** Add a new step to the smoke between step 5 (access denials) and
step 6 (rotate and retire), while both `beta` app databases are still active:

1. Start a long query as each `alpha` and `beta` user on both engines: `SELECT
   sleepEachRow(1) FROM numbers(600)` and `SELECT pg_sleep(600)`.
2. Quiesce `alpha-ch` and `alpha-pg`, then apply.
3. Assert that `alpha`'s queries ended and its new logins fail, and that `beta`'s queries are
   still running. Assert that the CronJobs are suspended, and that the server Pods' UIDs and
   `status.startTime` and `serverUUID()` are unchanged.
4. Take an on-demand backup of each, ingest it, and restore it into scratch.
5. Resume, and assert:
   - the CronJob bytes equal their accepted pre-quiesce bytes;
   - `alpha` logs in again;
   - a definer view still reads;
   - `db app-database evidence` prints every field.
6. Cancel `beta`'s long queries.

**M6, release.** Follow `docs/runbooks/releases.md`: the full gate, the EP-172 upgrade
rehearsal (which shows v0.7.1 history decodes under the new login codec), and the intranet
upgrade on the candidate, then the tag. Hand the tan-ng-labs plan the new ceremony. Record the
resolution and `targetPlan` in IR-31's frontmatter, and add a line to
`docs/improvement-requests/log.md`.


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

The run should log this new line and end with `PASS`:

```text
… app-database smoke: IR-31: alpha quiesced and drained on both engines while beta ran; on-demand backups ingested and restored; resumed with schedules as accepted; servers not restarted
app-database smoke: PASS
```


## Validation and Acceptance

- **AC-1.**
  - In the world on both engines, with sessions and running queries for `alpha` and `beta`,
    quiescing `alpha` ends its sessions and blocks its logins.
  - `beta`'s sessions and the world's server identity are unchanged.
  - The smoke repeats this with real queries, Pod UIDs and start times.
- **AC-2.** After quiesce and resume:
  - the world's grant sets for both users equal the pre-quiesce sets;
  - in the smoke, `alpha`'s definer view and materialized view read after resume;
  - `system.grants` for `alpha` is identical before and after (md5 of the sorted rows).
- **AC-3.**
  - A world mutation that finishes after three observations makes the drain wait, then
    complete.
  - A failing mutation fails the operation with `alpha.t mutation_…` in the reason.
- **AC-4.**
  - In the world, a schedule tick inside the quiesce window starts no Job, and a Job that was
    running when quiesce was applied makes the drain wait.
  - The drain is ordered after the CronJob suspension in the reviewed plan.
  - After resume, the CronJob's native bytes equal the accepted pre-quiesce bytes, and the next
    tick starts a Job.
  - The smoke asserts the suspend flag and the byte equality.
- **AC-5.**
  - The on-demand Job's pod spec equals the CronJob template.
  - Its run ingests with the existing command, and restores into scratch on both engines.
  - It is refused while the migration user is quiesced.
- **AC-6.** `db app-database evidence alpha-ch --json` prints:
  - `server`: StatefulSet incarnation, Pod UID and start time, plus `serverUUID` and process
    start time for ClickHouse, or `system_identifier` and postmaster start time for PostgreSQL;
  - `appDatabase`, `blockedUsers`, `sessionsObserved: 0`, `activeRuns: 0` and
    `unfinishedMutations: []`, each as the completed drain's verified postcondition;
  - the transaction IDs and proof digests of quiesce, backup and resume;
  - the backup's `backupId` and receipt object path.

  The server identity is equal in the drain and resume records.
- **Other app databases.** While `alpha` is quiesced, `db app-database plan` still reviews
  `beta`'s changes and names `alpha` as left out. `rotate alpha-ch` refuses with
  `app-database-quiesced`.

Required gates per commit and landing are in Concrete Steps. The interpreter-world tests are
the required acceptance. The smoke confirms.


## Idempotence and Recovery

Quiesce, backup and resume are each one reviewed transaction.

- **Re-runs.** Quiescing an already quiesced app database is refused, and so is resuming an
  open one. So a repeated command cannot stack states.
- **Interruptions.** A drain interrupted after login was blocked resumes with
  `nagarectl inventory resume TX --yes`. It re-observes and either proves the drain or retries,
  and blocking login again has no further effect.
- **Stuck mutation or run.** If a mutation will not finish, or a scheduled run outlasts the
  timeout, the drain fails and the app database stays quiesced. The operator investigates, then
  either resumes, or retries the drain by resuming and quiescing again.
- **Interrupted backup.** An interrupted on-demand backup is a Job that either produced a
  verified receipt or did not. Ingestion verifies stored bytes, so a partial run is never
  ingested.
- **Last resort.** Resume is always available while quiesced. If the scope cannot be read,
  stop and report rather than editing users by hand.


## Interfaces and Dependencies

- `Nagare.Resource.Inventory.Types`: the user spec's login becomes `UserLogin`, with the codec
  in the Decision Log. `OperationKind` gains `DrainSessions` and `ResumeSessions`, which is
  additive in the generic encoding.
- `Nagare.Inventory.Plan.Changes`: both kinds are forward-only and are ordered after every
  change in their own scope.
- `Nagare.Inventory.AppDatabase` gains `quiesceAppDatabaseScope`, `resumeAppDatabaseScope` and
  the shared `suspendSchedule` helper. `AppDatabaseRow` gains a three-valued state.
- `Nagare.Inventory.Adapters.AppDatabase`: `AppDatabaseMember` carries the login state, and
  drain and resume are selected by input digest. `AppDatabaseOps` gains `observeSessions`,
  `observeMutations`, `observeActiveRuns`, `observeServerIdentity` and `terminateSessions`.
  The kubectl runtime and the world implement them.
- `Nagare.Inventory.Application.Bindings`: a quiesced app database still binds.
- New CLI subcommands: `quiesce`, `resume`, `backup` and `evidence`.
- No new libraries, and no journal or adapter-interface change. Coordinate with EP-204 on the
  `DatabaseUserSpec` codec, since both change that constructor.
