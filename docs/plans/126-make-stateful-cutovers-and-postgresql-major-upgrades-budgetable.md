---
id: 126
slug: make-stateful-cutovers-and-postgresql-major-upgrades-budgetable
title: "Make stateful cutovers and PostgreSQL major upgrades budgetable"
kind: exec-plan
created_at: 2026-09-13T22:09:04Z
intention: "intention_01m2ecthzwek7t64p7wqn0x9wj"
master_plan: "docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T22:09:04Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:38:37Z
      mode: "update"
      note: "Adopt the existing state-transfer contract as the implementation baseline"
---

# Make stateful cutovers and PostgreSQL major upgrades budgetable

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare inventories every durable workload before a replacement, seeds an independent copy
on the candidate, restores and verifies it there, and measures the exact operations that
must be repeated after writes stop. PostgreSQL can move to a different major version through
a logical dump into a fresh target server rather than an in-place data-directory upgrade.

The user sees each state item, transfer strategy, measured duration, predicted final duration,
drift allowance, and compatibility result in replacement status. A requested 15-minute
window is accepted only if every required item is supported and the conservative predicted
final transfer fits alongside public verification and rollback reserve. Otherwise Nagare
refuses to begin downtime and explains which item exceeds or prevents the budget.

ExecPlan 127 has already introduced the small cutover-facing portion of this plan's API in
`Nagare.Platform.StateTransfer`: item support/quiesce flags, an aggregate prediction and drift
token, final evidence, and fail-closed validation. This plan owns evolving that existing module
into the complete inventory and adapter system while keeping the cutover executor compatible.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Add complete source-state discovery and fail-closed classification.
- [x] (2026-09-13 20:58 PDT) ExecPlan 127 supplied the minimal typed state-transfer plan,
      aggregate validation, JSON codecs, and final-evidence boundary required by its executor.
- [ ] Extend the existing types into the complete inventory, measurement, adapter, and evidence
      schema without breaking `Nagare.Platform.Cutover`.
- [ ] Adapt retained volumes and currently supported logical database backups for candidate
      seed/finalize/verify operations.
- [ ] Add PostgreSQL major-version preflight, seed, final restore, and compatibility checks.
- [ ] Add measurement, prediction, drift invalidation, deadline cancellation, and failure
      tests using realistic fixtures.
- [ ] Document supported and blocked state classes and PostgreSQL limitations.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: k3s state and application state have different homes: the k3s datastore is
  on the boot disk, while local-path PVCs are directories on `/var/lib/nagare`.
  Evidence: `nixos/hosts/nagare-01/k3s.nix` configures the local-path root, and host docs
  describe `/var/lib/rancher` as boot-disk state.
- Observation: Existing volume snapshots are tar archives and explicitly may be inconsistent
  for hot SQLite; existing database restores are scratch-first and major upgrades are
  documented as out of scope.
  Evidence: `Nagare.Storage.Snapshot`, `Nagare.Storage.Restore`,
  `Nagare.Database.Backup`, `Nagare.Database.Restore`, and
  `docs/user/managed-databases.md`.
- Observation: A second machine cannot attach the same zonal persistent disk read-write as an
  independent rollback copy under the current design.
  Evidence: the active VM has the protected disk attached `READ_WRITE`; the replacement
  topology therefore needs its own disk and application-level transfer.
- Observation: `Nagare.Platform.StateTransfer` now exists, but it is explicitly documented as only
  the cutover-facing contract and has no discovery, seed, volume, database, or PostgreSQL adapter.
  Evidence: the module defines `StateTransferItem`, `StateTransferPlan`, `FinalStateEvidence`, and
  `validateStateTransferPlan`; all concrete transfer operations remain absent.


## Decision Log

Record every decision made while working on the plan.

- Decision: Discover all state and block readiness on unknown or unsupported state rather
  than copying `/var/lib/nagare` wholesale.
  Rationale: Kubernetes local-path names, database consistency requirements, and application
  semantics cannot be recovered safely from an unclassified directory tree.
  Date: 2026-09-13
- Decision: Ship full logical/object-store transfer first, with conservative timing and a
  refusal path, rather than require replication infrastructure.
  Rationale: This preserves the low-cost architecture and supports small personal-platform
  data sets now. Large state may not meet 15 minutes and must be reported honestly; later
  adapters can add incremental transfer without changing the transaction contract.
  Date: 2026-09-13
- Decision: PostgreSQL major upgrades use target-version client tools to dump the old server
  and restore into a newly initialized target-major server.
  Rationale: PostgreSQL data directories are major-version specific; logical transfer also
  provides an isolated rehearsal and leaves the source untouched.
  Date: 2026-09-13
- Decision: The first supported final transfer discards and recreates only the candidate's
  destination PVC/database before restoring the final snapshot.
  Rationale: Restoring on top of rehearsal data can duplicate or retain stale rows/files.
  Candidate state is disposable until promotion; source state is not.
  Date: 2026-09-13
- Decision: Begin the downtime clock when Nagare successfully quiesces production writes,
  not when the VM is stopped or the IP moves.
  Rationale: Users experience maintenance as soon as writes are unavailable.
  Date: 2026-09-13
- Decision: Preserve the minimal plan and evidence fields already consumed by the cutover engine,
  extending them through compatible records or an explicit schema migration.
  Rationale: EP-127's 14 deterministic tests now enforce the aggregate prediction, drift-token,
  quiesce, support, and verified-final-evidence boundary that concrete adapters must satisfy.
  Date: 2026-09-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The cutover-facing subset now exists: a typed item/plan shape, aggregate validation, JSON codecs,
and verified final-evidence boundary used by `Nagare.Platform.Cutover`. Discovery, seed/finalize
adapters, measurements, retained volumes, and PostgreSQL major-version work remain unimplemented, so
this plan is In Progress rather than complete.


## Context and Orientation

Managed databases are discovered by `Nagare.Database.Discover` and backed up/restored by
`Nagare.Database.Backup` and `Nagare.Database.Restore`. PostgreSQL backup uses `pg_dump
--no-owner --no-privileges`; restore currently targets a scratch database first. Retained
application volumes are discovered by `Nagare.Storage.Discover`, archived by
`Nagare.Storage.Snapshot`, and restored by `Nagare.Storage.Restore`. Both use the context's
object store. Managed databases are single replica and have no replication/failover path.

`cli/nagarectl/src/Nagare/Platform/StateTransfer.hs` is the current owned module, not a file to be
created. `Nagare.Platform.Cutover` validates its plan before downtime, checks the plan prediction and
drift token against `ReplacementTransaction`, passes a monotonic `Deadline` to finalization, and
accepts only verified `FinalStateEvidence`. Concrete adapters must populate this boundary rather
than bypass it.

The state inventory must also inspect managed brokers, platform PVCs, unlabelled PVC/PV
objects, host directories beneath `/var/lib/nagare`, Kubernetes Secrets required to recreate
credentials, and application-declared state. k3s control-plane state is intentionally not
copied: the candidate is a fresh target cluster whose declarative platform and workload
objects are reapplied. Secrets are transferred as explicit encrypted transaction artifacts
or regenerated according to ownership; they are never printed in the inventory report.

A state item has a retention class (`retained` or `throwaway`), consistency class, byte/row
measurement, source object identity, target identity, transfer adapter, quiesce/verify hooks,
and support status. `throwaway` is recreated empty and does not consume transfer budget.
Every `retained` item must have a supported adapter. A seed is a rehearsal copy made while
production continues. A final transfer is made after quiesce. Because v1 performs a complete
final dump/archive, the seed proves compatibility and measures cost but is not promoted as
the final data.

For a measured operation, predict seconds as `ceil(maxSuccessfulSeconds * 1.5)` and add its
declared startup/cleanup overhead. Use at least two successful seed/restore measurements,
the newest no older than 24 hours at cutover. Invalidate the estimate if source bytes or
PostgreSQL database size grew by more than 10 percent, the schema/extension inventory changed,
the backup tool digest changed, or candidate storage identity changed. These initial factors
are intentionally simple and visible; evidence may justify changing them later through an ADR.

Relevant local decisions are [ADR 0006](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md),
[ADR 0012](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md),
[ADR 0013](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md),
and [ADR 0018](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md). The replacement ADR created by
ExecPlan 122 must record that state is copied into independent candidate storage and source
storage remains the rollback authority. Mori found no cross-repository ADR that changes
these constraints.


## Plan of Work

### Milestone 1: Complete inventory and transfer planning

Extend `cli/nagarectl/src/Nagare/Platform/StateTransfer.hs`. Build a pure inventory from
explicitly candidate-targeted Kubernetes/GCP observations and typed application declarations.
Correlate PVCs to databases, brokers, application volumes, and platform components; list
unmatched PVCs and host directories as blockers. Redact Secret values while recording their
names, owners, and content digests. Compile inventory into `StateTransferPlan`, selecting an
adapter only for known combinations. Mark retained Redis/ClickHouse/database and volume
items supported only where existing backup/restore semantics are valid; mark Kafka/broker
state, unknown host paths, and application-consistency-required volumes unsupported until
an explicit adapter exists. This milestone is complete when fixtures prove no retained
object can disappear from the plan.

### Milestone 2: Candidate seed and verification adapters

Refactor current backup/restore renderers so a caller can provide explicit source and target
kubeconfigs, transaction-scoped object keys, destination names, and no-prune behavior. Do not
change normal `db backup` or `storage snapshot` behavior. Implement adapters for retained
file volumes and currently restorable managed database engines. Each adapter creates a new
candidate PVC/database, copies credentials without logging values, restores from a unique
transaction object, and executes engine/file integrity checks. Candidate backups are
read-only; only the source uploads. Keep seed artifacts until finalization. Record source
bytes, destination bytes, checksums where meaningful, tool/image digests, and monotonic
backup/restore durations.

### Milestone 3: PostgreSQL major-version adapter

For each PostgreSQL item, inspect source `server_version_num`, database size, collations,
encodings, installed extensions and versions, roles/ownership requirements, and target image
major. Use the target release's pinned PostgreSQL client image to run a custom-format dump
against the source, adding the `pg_dump --quote-all-identifiers` cross-major compatibility
option. Restore into a fresh target-major candidate instance with
`pg_restore --no-owner --no-privileges`, then run `ANALYZE`, extension availability checks,
row/schema comparison, `pg_amcheck` where supported, and an application-supplied read-only
probe. Never point the target container at source data files and never run `pg_upgrade` on
the source disk. Treat missing target extensions, collation incompatibility, or failed probe
as a readiness blocker with the database name in the error.

### Milestone 4: Final-transfer primitive and budget evidence

Implement each adapter's final sequence as cancellable, deadline-aware operations: verify
quiesce, create a final unique source archive/dump without retention pruning, recreate only
the candidate destination, restore, verify, and return a commit token. Do not stop/delete the
source state. Persist progress around every destructive candidate step so retry knows whether
to recreate it. Combine at least two rehearsal measurements using the documented multiplier,
compare the prediction with the transaction budget from ExecPlan 123, and expose per-item and
aggregate blockers. ExecPlan 127 owns the global quiesce and deadline; this module stops
launching work when its passed deadline or rollback threshold is reached.

### Milestone 5: Scale tests, documentation, and support boundary

Generate deterministic PostgreSQL fixtures for same-major, major-version, missing-extension,
and corrupt/partial dump cases, plus retained volume fixtures including hot SQLite. Inject
slow operations and cancellation to prove the old state remains restartable when the budget
is exhausted. Add `scripts/test-replacement-state-finalize.sh` as the local end-to-end
seed/final restore test and an opt-in cloud-sized timing mode. Update
`docs/user/managed-databases.md`, `docs/user/persistent-storage.md`, and
`docs/user/backups-and-disaster-recovery.md` with the supported matrix, full-copy scaling
limit, and how to add an application quiesce/verification contract.


## Concrete Steps

Run focused Cabal commands from `cli/nagarectl/` because this monorepo has no root
`cabal.project`; run smoke and flake commands from the repository root:

    nix develop ../.. -c cabal test nagarectl-test --test-show-details=direct
    just local-smoke

Focused expected output includes:

    PlatformStateTransfer
      inventory blocks an unmatched retained PVC: OK
      predicts from the slowest sample with a 1.5 factor: OK
      invalidates evidence after ten-percent size drift: OK
      leaves source intact after deadline cancellation: OK
      restores PostgreSQL across supported majors: OK

On a candidate transaction with test state, run:

    nagarectl platform replacement rehearse <transaction-id> --json
    nagarectl platform replacement status <transaction-id> --json

The status output lists every state item and contains, for example, a PostgreSQL item with
source/target majors, two measurements, predicted final seconds, verification status, and no
secret values. Add a retained unknown PVC to the source fixture and rerun; status must become
blocked and name that PVC.

Exercise the exact final primitive only in a local/disposable environment:

    scripts/test-replacement-state-finalize.sh --deadline-seconds 900

Write a sentinel after the seed but before finalization. The candidate must contain the new
sentinel, proving final rather than seed data was restored. Then inject a deadline shorter
than restore time; the command cancels/cleans candidate work and the source still accepts
the original credentials and sentinel.

Finally run:

    nix flake check --print-build-logs


## Validation and Acceptance

Acceptance requires:

* Inventory accounts for every retained PVC, managed database, broker, application volume,
  platform volume, relevant host path, and owned Secret without exposing credentials.
* Any unknown retained item, hot-state item without quiesce/verify hooks, or unsupported
  engine blocks readiness before production is quiesced.
* A seed changes only transaction-scoped object keys and candidate storage. Existing backup
  objects, source PVCs, source databases, and retention policies are unchanged.
* PostgreSQL same-major and supported cross-major transfers restore into a newly initialized
  target, pass extension/schema/row/integrity/application checks, and report tool versions.
  An unavailable extension or incompatible collation is discovered during rehearsal.
* At least two representative full transfers are timed. The prediction uses the maximum
  duration times 1.5, includes overhead, and becomes stale after 24 hours or more than 10
  percent size drift.
* The replacement transaction cannot be ready unless aggregate final transfer plus public
  verification, rollback reserve, and safety margin fits its budget. A one-second excess is
  blocked.
* Deadline cancellation never overwrites, detaches, upgrades in place, or deletes the old
  data. Starting the old workloads again restores the pre-attempt service.


## Idempotence and Recovery

Inventory is read-only and repeatable. Seed object keys include transaction and attempt IDs,
so a retry never overwrites a previously verified artifact. Candidate scratch destinations
are disposable and may be recreated after confirming their ownership labels and transaction
ID. The source is never a restore destination.

If a seed or restore fails, keep its logs and artifact digest, mark the item failed, delete
only the transaction-labelled candidate Job/scratch PVC, and retry. If final transfer fails
or reaches its cancellation threshold, terminate its source backup Job if safe, delete only
the incomplete candidate destination, unquiesce source workloads through ExecPlan 127, and
invalidate the final commit tokens. Object artifacts are retained until explicit
finalization. Never prune ordinary backups as part of replacement cleanup.


## Interfaces and Dependencies

Reuse `Nagare.Database.Discover`, `Backup`, and `Restore`, plus
`Nagare.Storage.Discover`, `Snapshot`, and `Restore`, by extracting pure renderers and
injectable Kubernetes/object-store operations rather than shelling through their public CLI.
Use PostgreSQL's official tools from the target release's pinned image. Before changing any
image or package version, use Mori for local dependency material and verify the authoritative
registry/upstream tag under repository policy. No replication service or new standing cloud
resource is introduced.

The module owns interfaces equivalent to:

    data StateKind
      = ManagedPostgres | ManagedRedis | ManagedClickHouse | ManagedBroker
      | RetainedVolume | ThrowawayVolume | PlatformState | UnknownState

    data Support = Supported AdapterName | Unsupported NonEmptyReason

    data StateItem = StateItem
      { id :: StateItemId, kind :: StateKind, retention :: RetentionClass
      , consistency :: ConsistencyClass, source :: StateLocation
      , target :: StateLocation, bytes :: Maybe Natural, support :: Support
      , quiesceContract :: Maybe QuiesceContract
      , verificationContract :: VerificationContract
      }

    data TransferMeasurement = TransferMeasurement
      { item :: StateItemId, sourceBytes :: Natural
      , backupSeconds :: Natural, restoreSeconds :: Natural
      , verifySeconds :: Natural, measuredAt :: UTCTime
      , inputDigest :: Text
      }

    data StateTransferAdapter = StateTransferAdapter
      { seed :: TransferContext -> StateItem -> IO TransferEvidence
      , verifySeed :: TransferContext -> StateItem -> IO VerificationEvidence
      , predictFinal :: NonEmpty TransferMeasurement -> Either StateError Natural
      , finalize :: Deadline -> TransferContext -> StateItem -> IO FinalTransferResult
      }

    discoverState :: StateOps -> SourceTarget -> IO (Either StateError StateInventory)
    compileStatePlan :: StateInventory -> Either (NonEmpty StateBlocker) StateTransferPlan
    predictedFinalSeconds :: StateTransferPlan -> Either StateError Natural

ExecPlans 123 and 124 are hard prerequisites. This plan and ExecPlan 125 coordinate through
the state allowlist and verification evidence but can implement their pure layers in parallel.
ExecPlan 127 calls `finalize` only after global quiesce and combines its duration with the
address/verification budget. The initial unsupported result for broker state is an explicit
product limitation, not permission to omit it from inventory.

The existing `StateTransferItem`, `StateTransferPlan`, `FinalStateEvidence`, and
`validateStateTransferPlan` definitions are compatibility inputs. Expand or version them; do not
replace them with an unrelated plan that forces EP-127 to maintain a second adapter boundary.


Revision note (2026-09-15): Refreshed the plan against the minimal state-transfer contract already
landed by EP-127, clarified compatibility ownership, corrected the package-local Cabal working
directory, and retained all concrete inventory, transfer, and PostgreSQL work as incomplete.
