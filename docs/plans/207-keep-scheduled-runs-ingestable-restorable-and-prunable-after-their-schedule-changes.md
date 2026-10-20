---
id: 207
slug: keep-scheduled-runs-ingestable-restorable-and-prunable-after-their-schedule-changes
title: "Keep scheduled runs ingestable, restorable and prunable after their schedule changes"
kind: exec-plan
created_at: 2026-10-20T04:27:40Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-20T04:27:40Z
---

# Keep scheduled runs ingestable, restorable and prunable after their schedule changes

## Purpose / Big Picture

A scheduled backup run signs its receipt with its schedule's metadata, which includes the
schedule revision (a digest of the job's inputs, including the server's client image) and, for
an app database, its logical databases and declaration digest. Ingest, freshness and prune
compare a receipt against the **current** accepted CronJob only. After any change to the
schedule:

- a run taken before it can no longer be ingested, so its recovery point cannot be restored
  through Nagare;
- prune refuses with "admitted under an older source or schedule" for every run ingested
  before it.

The schedule changes when an app database adds a logical database (the EP-203 finding), and
when its server's engine image changes. The latter also affects a direct database's schedule.

After this change, every run of a schedule that Nagare accepted at any point can be ingested,
restored and pruned. A restore of such a run uses the databases the run actually holds.

## Progress

- [x] M1 (interpreter and unit). Ingest accepts a receipt that matches any converged revision of
  its schedule, and records the run's own databases for an app database. Freshness and prune
  accept a run ingested under any converged revision. An app-database restore uses the run's
  databases. Tests cover these on both engines, for an added logical database and for a
  changed client image, and a receipt whose metadata no accepted revision names is still
  refused.
  Done 2026-10-20. Evidence: `AppDatabaseSpec` "a run signed under an earlier converged
  schedule revision ingests and restores its own databases" (both engines) and "only a
  converged transaction's review authorizes a schedule revision".
- [x] M2 (native). The app-database smoke ingests, restores and prunes runs taken before a
  schedule change, with the packaged CLI on a disposable local context.
  Done 2026-10-20: step 8a of `scripts/local-app-database-smoke.sh` passed with the packaged
  CLI at `5fc3bf7d` on the local context `transition`: a run of `zeta-s1020050714` taken
  before `z_extra` was declared ingested, restored only `z`, and the prune review refused only
  for having nothing past policy.
- [x] M3 (release). The change ships in the release that carries EP-204 to EP-206.
  Done 2026-10-20: v0.8.0, signed tag on `a6004f22`; the intranet runs it.

## Decision Log

- Decision: the authority for a receipt is the set of the schedule's **converged** revisions:
  the current accepted CronJob bytes, and the CronJob bytes of every review whose transaction
  converged (the journal's transaction-level `Completed` event names its review) and that
  created or updated the CronJob. A revision that was only reviewed, or whose transaction did
  not converge, authorizes nothing.
  Rationale: the receipt is signed with the schedule's accepted signing Secret, which does not
  change across revisions; what the expectation adds is that the receipt's metadata is metadata
  Nagare accepted. A converged revision is exactly a schedule that ran. `LineageHistory` already
  reads convergence this way.
  Date: 2026-10-20

- Decision: retention (`keep`) and the recovery-point objective are always the current
  revision's. A run ingested under an older revision is pruned by the current policy.
  Rationale: retention is the operator's current intent; an older run is still a run of the
  same schedule in the same key space.
  Date: 2026-10-20

- Decision: ingest records an app-database run's databases as `scheduled.backup.databases`.
  A restore uses them, and a receipt scope ingested before this change, which lacks the
  override, uses the declared databases, as today.
  Rationale: a run taken before a logical database was added does not hold it, and a
  ClickHouse `RESTORE` naming it fails. Runs ingested before this change were ingested under
  their own revision, so the declared databases are theirs. This is the reviewed transition
  for existing receipt scopes.
  Date: 2026-10-20

- Decision: prune no longer compares a run's schedule revision with the current one, and a
  direct database's run is current while taken from the current StatefulSet and claim
  incarnations, as an app database's and a volume's already were, rather than under the
  current source scope revision.
  Rationale: ingestion already verified the run against a converged revision, and a server
  declaration change (an image or a resize) moves the scope revision without changing what the
  run holds; the incarnation checks are what keep a run of a replaced server from being
  pruned as current.
  Date: 2026-10-20

## Context and Orientation

- `cli/nagarectl/src/Nagare/Inventory/BackupReceipt.hs`: `scheduledExpectationWith` and the
  per-kind `scheduled*ReceiptExpectationFromCronJob` build a `ScheduledReceiptExpectation` from
  CronJob bytes. `inspectScheduledReceipt` checks a receipt against one expectation, metadata
  digest included.
- `cli/nagarectl/src/Nagare/Inventory/ScheduledIngest.hs`: the pure ingest compile, which
  checks the receipt against the expectation from the accepted CronJob bytes.
- `cli/nagarectl/app/Nagare/Cli/Data/ScheduledReceipts.hs`: the ingest commands (one run or
  `--all`) and the freshness rows of `server status`.
- `cli/nagarectl/app/Nagare/Cli/Data/ScheduledPrune.hs`: the prune review, whose check on
  `scheduled.backup.schedule.revision` this plan widens.
- `cli/nagarectl/src/Nagare/Inventory/AppDatabaseRestore.hs`: the app-database restore.
- `cli/nagarectl/src/Nagare/Inventory/LineageHistory.hs`: reads convergence from the journal.
- ADR 27 (physical identity read through one checked accessor) is unaffected: the source
  incarnation checks stay as they are.

## Validation and Acceptance

- `just gate-fast` is green, with the M1 tests in `AppDatabaseSpec` and the scheduled-backup
  specs.
- The app-database smoke prints `app-database smoke: PASS` with the packaged CLI.
