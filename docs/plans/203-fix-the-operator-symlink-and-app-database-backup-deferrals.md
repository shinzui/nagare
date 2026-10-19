---
id: 203
slug: fix-the-operator-symlink-and-app-database-backup-deferrals
title: "Fix the operator-symlink and app-database backup deferrals"
kind: exec-plan
created_at: 2026-10-19T14:53:25Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-19T14:53:25Z
---

# Fix the operator-symlink and app-database backup deferrals

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Four deferred findings cost something on every intranet change or will once app databases hold
real data. This plan fixes them and ships the fixes as v0.7.1, intranet first.

- **F127.** Every intranet upgrade stops at its second stage because the context kubeconfig is
  an agenix symlink. The operator then has to swap in a copy by hand.
- **F126.** `nagarectl context apply` refuses a context file that is a symlink, although
  [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
  keeps operator contexts as symlinks into the private repository.
- **F131.** A retired app database's backup schedule keeps running and fails at login on every
  recovery point.
- **F132.** `server status` and `doctor` never grade an app database's backup schedule, so a
  silent backup gap goes unreported. Its runs also have no reviewed prune.

After this plan:

- the intranet upgrades to v0.7.1 with its kubeconfig still a symlink;
- a reviewed context change applies through a symlinked context file;
- retiring an app database suspends its schedule;
- `server status` shows a recovery-point row and a retention row for every app database;
- `nagarectl db app-database prune-scheduled-backups NAME` reviews the deletion of runs past
  policy.

The other deferred findings stay deferred by design. F104, F108, F112, F115, F117 and F120 wait
for real use, as [priorities after v0.6.3](../releases/priorities-after-v0.6.3.md) ranks them.


## Progress

- [x] M1 (F127). The kubeconfig stage accepts a symlinked destination whose bytes, read through
  the link, match the accepted digest, and it writes nothing. A symlinked destination whose
  bytes differ still refuses, and the message names the link target. A test covers a matching
  link, a differing link and a dangling link. Done 2026-10-19 (`6953fd7c`, landed with
  `ee9bb365`): `kubeconfigStageDecision` in `cli/nagarectl/src/Nagare/Cluster/Kubeconfig.hs`;
  test "F127: the kubeconfig stage accepts a matching link and never writes through one"; the
  planning observation of the accepted projection also reads through the link (artifact adapter
  test). Fast gate green.
- [x] M2 (F126). Context control reads a symlinked context file and its `.reviews` directory
  through the link. It writes by renaming over the canonical target, so the link survives. A
  dangling link refuses. A test applies a reviewed profile change to a symlinked context in a
  temporary configuration root, then checks the link is still a link and its target holds the
  new bytes. Done 2026-10-19 (`ee9bb365`, landed): test "F126: a reviewed change applies through
  a linked context and keeps the link". Fast gate green.
- [x] M3 (F131). `db app-database retire` sets the backup CronJob's `spec.suspend: true` in the
  same reviewed revision. A later `db app-database plan` of the enabled declaration clears it.
  The schedule revision digest ignores `suspend`, so runs made before retirement can still be
  ingested and restored. Tests cover retire, re-enable and ingestion of a pre-retirement run.
  Done 2026-10-19 (`9d389cba`): test "F131: retirement suspends the schedule, re-planning resumes
  it, and earlier runs still ingest and restore". The revision lives in the receipt metadata,
  which `suspend` does not touch.
- [x] M4 (F132). `server status` and `doctor` emit a recovery-point row and a retention row
  labelled `<namespace>/<appdb>` for every accepted `nagare-appdb-*` schedule. A suspended
  (retired) schedule grades `retired`, not stale. `db app-database prune-scheduled-backups` and
  `db app-database recover-scheduled-prune` review deletions exactly as the database commands
  do. Both commands are registered in `scripts/audit-managed-commands.py`, and
  `docs/user/managed-databases.md` documents them. Done 2026-10-19 (`d480be02`): tests "F132:
  status grades every app database's schedule, and a retired one as retired" and "F132: an app
  database's scheduled run is pruned under its own prefix and scope names". Schedule selection
  is `Nagare.Inventory.ScheduledStatus`; the source resolution is `appDatabaseScheduleSource`,
  shared by status, ingestion and prune. Mutation record
  `EP183-volume-prune-prefix-ignores-volume` regenerated for the new constructor.
- [ ] M5. `just local-app-database-smoke CONTEXT` also asserts that retiring beta-ch suspends
  its CronJob, that `server status` lists the four app databases' recovery points, and that a
  prune review of alpha-pg has no runs past policy.
- [ ] M6. v0.7.1 is released intranet first. The intranet's transition runs with
  `~/.config/nagare/kubeconfigs/intranet.yaml` still a symlink to
  `/run/agenix/nagare-kubeconfig-intranet`, which is F127's real proof. F126, F127, F131 and
  F132 move to Verifying in `docs/audits/mp23-findings.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The scope is exactly F126, F127, F131 and F132. The rest of the deferral ledger
  stays deferred.
  Rationale: The operator asked for a plan for deferrals that are piling up. A MasterPlan was
  rejected because the four fixes are independent and small. The production-readiness
  checklist also forbids new boxes. These four are the ones that cost something on every
  intranet change, or will once Kansoku's app databases hold data.
  Date: 2026-10-19

- Decision: F127 never writes through the kubeconfig link. A matching link is accepted as is,
  and a differing link refuses.
  Rationale: The intranet's link targets an agenix secret under `/run/agenix`. agenix owns that
  file, it is read-only, and it is regenerated on activation. Writing through it would fail or be
  undone. A credential change on such a context goes through agenix, outside Nagare.
  Date: 2026-10-19

- Decision: F126 writes by renaming over the canonical target, never over the link.
  Rationale: ADR 13, decision point 2 requires this, and EP-116 already resolves the context
  file this way in `cli/nagarectl/src/Nagare/Target.hs`. Context control is the one writer that
  still refuses instead.
  Date: 2026-10-19


- Decision: Context control refuses a removal review of a linked context.
  Rationale: Removing the link's target would delete a file in the operator's private
  repository and leave a dangling link that restore then refuses. A linked context is removed
  in its private repository.
  Date: 2026-10-19

- Decision: An app-database prune treats a run as current while it was taken from the server's
  current StatefulSet and claim incarnations, not while the app-database scope revision is
  unchanged. Its policy pin is the scope revision, as a database's is.
  Rationale: The scope revision moves at every rotation and at retirement, so a revision check
  would make every earlier run unprunable after either, with no way to re-ingest it.
  Date: 2026-10-19


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare is a single-node PaaS operated through `nagarectl` (Haskell, `cli/nagarectl/`). Every
change is a saved, reviewed plan that `nagarectl inventory apply DIR --yes` executes. The
deferral ledger is the findings table in `docs/audits/mp23-findings.md`; F126, F127, F131 and
F132 are its rows.

**Operator material lives in a private repository** (ADR 13). For the work intranet that is
`mori://tan/tan-ng-labs`. Its files are wired into Nagare's XDG paths by symlink:

- `~/.config/nagare/contexts/intranet.env` links into that repository;
- `~/.config/nagare/kubeconfigs/intranet.yaml` links to `/run/agenix/nagare-kubeconfig-intranet`,
  a secret agenix decrypts on the workstation.

**F127, the kubeconfig stage.** `buildKubeconfigStageCandidateWithRecovery` in
`cli/nagarectl/app/Nagare/Cli/Bootstrap/Host.hs` builds the platform stage that records the
context kubeconfig as an artifact scope (`platform:kubeconfig`). It calls `pathIsSymbolicLink`
on the destination and dies with "context kubeconfig destination is a symlink" before
comparing contents. Right after that check, an accepted scope whose current bytes match the
digest already returns `Nothing`, which means no write. The fix moves the symlink refusal into
the branches that would write.

**F126, context control.** `cli/nagarectl/src/Nagare/Context/Review.hs` stores reviewed profile
changes. `readOptional` dies with "context control refuses symbolic links". `atomicWrite`
renames a temporary file over the location, which would replace a link with a regular file.
`receiptRoot` keeps receipts in `<location>.reviews/`; on the intranet that directory is also a
symlink. `cli/nagarectl/src/Nagare/Target.hs` around line 225 shows the EP-116 pattern:
`canonicalizePath`, then work on the real path.

**App databases (EP-202, ADR 30).** See
[EP-202](202-host-per-app-databases-on-shared-postgresql-and-clickhouse-servers.md) and
[ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md). Each app database
is a standalone scope `appdb-<key>`.

- **Schedule.** Its CronJob `nagare-appdb-<appdb>` is rendered by
  `renderInventoryAppDatabaseBackupCronJob` in
  `cli/nagarectl/src/Nagare/Database/AppDatabase/Backup.hs` through `renderScheduledCronJob` in
  `cli/nagarectl/src/Nagare/Database/Backup.hs`. It uploads under
  `app-databases/<ns>/<appdb>/`, and its receipt metadata carries a `scheduleRevision` digest.
- **Ingested runs.** Each becomes a scope `appdb-scheduled-receipt-<ns>-<appdb>-<run>`.
- **Retirement (F131).** `retireAppDatabaseScope` in
  `cli/nagarectl/src/Nagare/Inventory/AppDatabase.hs` only turns specs' `enabled` flags off.
- **Suspension precedents.** `cli/nagarectl/src/Nagare/Inventory/TaskLifecycle.hs` sets
  `spec.suspend` on a task's CronJob. `cli/nagarectl/src/Nagare/Inventory/DataFence/ScheduledWriter.hs`
  line 74 deletes `suspend` before computing a schedule's canonical bytes.

**F132, status and prune.**

- `scheduledRecoveryPointProbes` in `cli/nagarectl/app/Nagare/Cli/Data/ScheduledReceipts.hs`
  selects CronJobs whose names start with `nagare-dbbackup-` or `nagare-volbackup-`. It grades
  each with `recoveryPointProbe` and `retentionProbe` from `cli/nagarectl/src/Nagare/Ops/Probe.hs`.
- The same module already resolves an app database's schedule, server and claim in the
  `ReceiptAppDatabase` branch of `runReviewedScheduledSourceReceiptPlan`. The status probe should
  reuse that resolution rather than repeat it.
- Pruning is generic over `PruneSource` in `cli/nagarectl/src/Nagare/Inventory/ScheduledPrune.hs`,
  which has `DatabasePruneSource` and `VolumePruneSource`.
  - `pruneSourceOwner` names the receipt, prune and prune-recovery scopes.
  - `pruneSourceKeyPrefix` names the object prefix.
  - `runReviewedScheduledPrunePlan` and `runReviewedScheduledPruneRecoveryPlan` in
    `cli/nagarectl/app/Nagare/Cli/Data/ScheduledPrune.hs` drive the commands.
  - An app-database source needs owner kind `appdb` and stem `<appdb>`, which matches the
    receipt owners EP-202 writes, plus prefix `appDatabaseBackupKeyPrefix ns appdb`.

Relevant ADRs:

- [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md):
  operator material is linked in, and writers write through the link.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): defects
  are found in tests and interpreter worlds; native runs only confirm.
- [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md): the app-database
  model.

Repository rules that apply (`CLAUDE.md`):

- Per Haskell commit: `just haskell-style-check`, then `just gate-fast`.
- Land with `just land REV`.
- Modules stay under 1000 lines; `scripts/haskell-size-allowances.json` may only be lowered.
- `Nagare.Cli.Commands.*` modules may not import each other.
- The intranet upgrade is a cloud mutation and needs the operator's go-ahead.


## Plan of Work

**M1 (F127).** In `buildKubeconfigStageCandidateWithRecovery`, compute whether the destination
is a link, but don't die there.

- Read the current bytes with `BS.readFile`, which follows the link.
- If the scope is accepted and the bytes match the digest, return `Nothing` as today, link or
  not.
- On every branch that would write (recovery or a new scope), refuse a link with "context
  kubeconfig destination is a symlink to TARGET; update it outside Nagare".
- A dangling link refuses with the same message.
- Factor the decision into a pure function of `(accepted, linked, current bytes, digest,
  recover)` so the tests drive it without a cluster.

**M2 (F126).** In `Context/Review.hs`, resolve each controlled path once with
`canonicalizePath`, after checking that the target exists.

- `readOptional` and `atomicWrite` work on the canonical path. The temporary file is created
  in the canonical target's directory, so the rename stays on one filesystem and the link
  survives.
- `receiptRoot` resolves `<location>.reviews` the same way.
- The lock file stays at `<location>.lock` beside the link: it guards the operator's view, not
  the target.
- Test in a temporary root: write a context file into `real/`, link it from `contexts/`, apply
  a reviewed change, and assert `pathIsSymbolicLink` still holds and the target has the new
  bytes.

**M3 (F131).** `retireAppDatabaseScope` gains the scope's native map and rewrites the backup
member's CronJob bytes with `spec.suspend: true`. The new native bytes go into the review, the
way `rotateAppDatabaseScope`'s callers pass native evidence. That makes the CronJob an
`UpdateResource` in the same review as the disabled users and databases.

- `db app-database plan` recompiles the declaration with `suspend` absent, so re-enabling is an
  update back.
- Make the schedule revision ignore `suspend`. If `renderScheduledCronJob` digests the job
  template only, this already holds; prove it with a test that ingests a pre-retirement run
  after retirement.
- `scheduledAppDatabaseReceiptExpectationFromCronJob` in
  `cli/nagarectl/src/Nagare/Inventory/BackupReceipt.hs` must accept the suspended bytes.

**M4 (F132).** Status:

- Add `nagare-appdb-` to the prefixes in `scheduledRecoveryPointProbes`.
- Label the rows `<namespace>/<appdb>`.
- Grade freshness with the app-database source resolution from the `ReceiptAppDatabase` branch,
  extracted into a function both callers use.
- A schedule whose accepted bytes have `suspend: true` grades `OK retired`.

Prune:

- Add `AppDatabasePruneSource !Text` to `PruneSource`, handled in `pruneSourceOwner` and
  `pruneSourceKeyPrefix`.
- Add `db app-database prune-scheduled-backups NAME [-n NS] [--bucket B] --save-plan DIR` and
  `db app-database recover-scheduled-prune` to `cli/nagarectl/app/Nagare/Cli/Parser/AppDatabase.hs`,
  `.../Options/AppDatabase.hs` and `.../Data/AppDatabase.hs`, calling the existing runners.
- Register both in `scripts/audit-managed-commands.py`, then refresh the catalogue with
  `--update-catalogue`.
- Add the retention probe's command hint `db app-database prune-scheduled-backups`.
- Document both in the "Sharing one server between apps" section of
  `docs/user/managed-databases.md`.

**M5.** Extend `scripts/local-app-database-smoke.sh` after the retirement step:

- `kubectl get cronjob nagare-appdb-beta-ch -o jsonpath='{.spec.suspend}'` prints `true`;
- `n server status` contains `recovery point` rows for `personal/alpha-pg` and `personal/alpha-ch`;
- `n db app-database prune-scheduled-backups alpha-pg -n personal --save-plan DIR` reports no
  runs past policy.

Run it on a disposable local context with the packaged CLI, as EP-202 M7 did.

**M6.** Release v0.7.1 per `docs/runbooks/releases.md`.

- Upgrade the intranet on the candidate before the tag, with the operator's go-ahead.
- Keep the kubeconfig symlink in place throughout.
- Then publish, and move the four findings to Verifying.


## Concrete Steps

From the repository root, for each Haskell milestone:

```bash
cd cli/nagarectl
for p in kubeconfig context AppDatabase ScheduledPrune; do cabal test nagarectl-test --test-options="-p $p"; done
cd ../.. && just haskell-style-check && just gate-fast HEAD && just land HEAD
```

Native confirmation (M5), from an empty environment against a `mode=local` context. Use the
packaged CLI built from the landed revision:

```bash
nix build --no-link --print-out-paths "git+file://$PWD?rev=$(git rev-parse HEAD)#nagarectl"
NAGARE_SMOKE_CONTEXT=transition NAGARECTL=<out>/bin/nagarectl scripts/local-app-database-smoke.sh
```

The run should end with:

```text
… app-database smoke: AC-4: rotation changed only alpha-pg runtime; beta-ch retired with its data kept; alpha unaffected
… app-database smoke: AC-5: scheduled runs of alpha-pg and alpha-ch ingested and restored into scratch with their access
app-database smoke: PASS
```

Release (M6): `just release-candidate 0.7.1`, the intranet upgrade from
`mori://tan/tan-ng-labs` per its `docs/runbooks/operations.md` "Host changes and upgrades",
then `just release-publish 0.7.1`.


## Validation and Acceptance

- **F127.** Unit tests cover the stage decision: a matching link gives no write, a differing
  link refuses naming its target, a dangling link refuses, and a regular file behaves as before.
  Natively, the intranet's 0.7.1 transition passes stage 2 while
  `readlink ~/.config/nagare/kubeconfigs/intranet.yaml` prints
  `/run/agenix/nagare-kubeconfig-intranet`.
- **F126.** The temporary-root test passes: the link survives, the target is updated, and a
  dangling link refuses.
- **F131.** Tests show retire produces an `UpdateResource` on the CronJob with `suspend: true`;
  re-plan clears it; a pre-retirement run is ingested afterwards. The smoke prints the CronJob
  suspended.
- **F132.**
  - A test renders `scheduledRecoveryPointProbes` input for an app-database schedule and gets
    both rows.
  - A prune test selects runs past policy for an `AppDatabasePruneSource` with owners
    `appdb-scheduled-prune-<ns>-<appdb>-<run>`.
  - The smoke sees the rows and an empty prune review.


## Idempotence and Recovery

Every change is a reviewed plan. Re-planning an unchanged declaration prints `no operations`.
A failed apply resumes with `nagarectl inventory resume TX --yes`.

For M6, if the intranet transition refuses at the kubeconfig stage anyway, stop and report. The
manual copy workaround from the v0.7.0 upgrade (an identical regular file, restored afterwards)
remains available with the operator's approval.


## Interfaces and Dependencies

- `Nagare.Inventory.ScheduledPrune.PruneSource` gains `AppDatabasePruneSource !Text`. Every
  `case` over it must handle the new constructor.
- `Nagare.Inventory.AppDatabase.retireAppDatabaseScope` gains the scope's native map and
  returns the revised native bytes alongside the scope.
- The context-control and kubeconfig-stage changes are internal; no command's flags change.
- No new libraries.
