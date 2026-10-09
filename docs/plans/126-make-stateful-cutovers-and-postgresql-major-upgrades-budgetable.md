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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T19:45:59Z
      mode: "update"
      note: "Refresh MP-21 as optional inventory-backed replacement after MP-23 upgrade drills"
---

# Make stateful cutovers and PostgreSQL major upgrades budgetable

This ExecPlan is a living document. Keep its living sections current and promote durable decisions
into ADRs. It owns replacement-specific transfer over existing inventory and data primitives.


## Purpose / Big Picture

An operator can see every retained item that must move to a fresh candidate cluster, rehearse an
independent copy, and obtain measured evidence that a final copy after production writes stop fits
the requested replacement budget. Unknown or inconsistent state blocks cutover while old still serves.

MP-23 already supplies typed resource ownership, verified database/volume backups and isolated restore.
Its [PostgreSQL major-upgrade drill](../audits/mp23-independent-results-2026-10-07/section4-3b59bcb7/README.md)
proves a side-by-side 17 → 18 procedure with manual fencing/copy, reviewed binding switch and
pre-write rollback. Credit that outcome; this plan does not reinvent basic backup, restore or major
migration. The missing capability is resumable, measured transfer between two explicit clusters
under the replacement transaction's authority and deadline.


## Progress

- [x] (2026-09-13) Minimal `StateTransferItem`, `StateTransferPlan`, aggregate validation and
  `FinalStateEvidence` exist in `Nagare.Platform.StateTransfer` for the injected cutover core.
- [x] (2026-10-09, input credited from MP-23) PostgreSQL side-by-side major copy, reviewed switch,
  two pre-write failure recoveries and retain-only retirement proved by the section-4 drill above.
- [ ] M1: Derive a complete transfer plan from accepted inventory and exact live source identities.
- [ ] M2: Reuse verified receipts/restore to seed and verify independent candidate state.
- [ ] M3: Adapt the proved PostgreSQL procedure into reviewed cross-cluster transfer with compatibility checks.
- [ ] M4: Produce conservative timings, drift invalidation and cancellable final-transfer evidence.
- [ ] M5: Prove local integrated seed/final-copy/failure behavior and document the support matrix.

Credit for the procedure does not mark an automated adapter or global downtime guarantee complete.


## Surprises & Discoveries

The September plan's statement that PostgreSQL majors and all concrete data behavior were absent is
obsolete. MP-23 proved the operator procedure and backup recovery, but `StateTransfer.hs` still only
holds the cutover-facing contract. The [source-destruction recovery result](../audits/mp23-independent-results-2026-10-07/section2-drill-3ae20f8c/result.json)
measures a 20-second scratch database restore, not reconstruction of a complete live application.
Volumes remain outside MP-23's hourly recovery-point objective; no replacement claim may count a
manual archive as an unattended data-protection guarantee.


## Decision Log

2026-10-09: Derive state coverage from accepted inventory plus bounded live observations, and reuse
current `Nagare.Inventory` data primitives. No parallel editable state inventory or receipt format.
Known ownership does not prove transfer support or application consistency. Unmatched retained
objects remain blockers.

Retained rules: independent target storage; fresh final copy rather than promoting stale seed data;
source never a restore destination; full-copy transfer first; unsupported broker/hot-volume state
blocks readiness; the global clock starts at the first denied source write. Basic PostgreSQL
upgrade acceptance is credited to MP-23, while automated cross-cluster timing/recovery remains here.


## Outcomes & Retrospective

The cutover-facing contract and reusable data/major-upgrade inputs exist. Complete transfer coverage,
explicit cross-cluster adapters, measurements and deadline-aware finalization remain. This refresh
claims no new implementation; EP-126 remains In Progress.


## Context and Orientation

Extend `cli/nagarectl/src/Nagare/Platform/StateTransfer.hs`; `Platform/Cutover.hs` consumes its validated
plan, drift token, prediction and final evidence. Existing reusable modules are
`Nagare.Inventory.Backup`, `Restore`, `RestoreNative`, `VolumeRestore`, `BackupReceipt`,
`ManualReceipt`, `ScheduledReceipt`, `SigningKeyEscrow` and `BackupFreshness`.
Do not invent a second key verifier. `Nagare.Inventory.Plan`, `Command`, `Execute`
and `Store` provide review, admission and history. The documented major procedure is in
`docs/user/managed-databases.md` under “Upgrade PostgreSQL to a new major version”.

EP-123's [transaction plan](123-model-resumable-replacement-upgrade-transactions-and-downtime-budgets.md)
and EP-124's [candidate plan](124-provision-ephemeral-candidate-hosts-and-promotable-infrastructure-slots.md)
are hard prerequisites. They supply the inventory-bound control record and distinct source/target
instance, cluster, storage and history identity. Source observations must target old explicitly;
candidate restore operations must target candidate explicitly. EP-125 consumes seed/probe results;
EP-127 alone owns global quiesce, address movement and writer release.

[ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) requires rollback
reserve and no stale rollback after candidate writes. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
requires typed ownership and reviewed effects. [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
binds incarnations at creation. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
and [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) govern tests and
recovery. Data disks remain protected and forward-only under ADR 12.


## Plan of Work

### M1: Coverage before adapter expansion

Derive a typed transfer view from accepted scope declarations, retained incarnations and exact live
observations. Account for application/platform PVCs, databases, broker state, owned credential material
and relevant host state. Compare this view with live PVC/PV and bounded host observations; a missing
observation is unknown, not absence. Unexpected retained state blocks readiness. Do not copy the
k3s datastore: the candidate is a fresh cluster reconstructed from declarations.

Each item records logical owner, physical source incarnation, destination, retention, consistency,
transfer strategy, required quiesce/verify hooks and support reason. Secrets stay in private encrypted
material with redacted references in public output. Support only existing engine/volume semantics
that preserve consistency; hot SQLite, unknown host directories and unsupported broker state are
explicit blockers. Unknown items may not disappear through inventory filtering or a generic discard
flag. A discard policy requires an explicit reviewed lifecycle decision for that exact item.

### M2: One representative producer/consumer path

Use current backup receipt creation, exact stored-byte/generation verification and isolated restore
through reviewed inventory operations. Add explicit source/candidate targets and transaction-owned
object/destination identities below the native adapters. A candidate can read selected backup objects
but cannot mutate ordinary backup history. Source upload uses its reviewed owned destination.

First prove one PostgreSQL seed through the real review/admission/journal path: backup, verified
receipt, candidate restore, verification, interruption after restore and fresh-root resume. Check
source untouched, exact candidate incarnation and no duplicate restore. Only then expand to supported
volumes/engines. Use existing signing-key escrow and source-unavailable verification where needed;
an unaccepted pending upload is freshness evidence, not restore authority.

### M3: PostgreSQL compatibility and transfer

Adapt the documented procedure to the same reviewed native effect boundary. Record source and target
server/client versions, encodings/collations, extensions, ownership/roles requirements and application
verification. The first cross-major fixture reuses the proved 17 → 18 scenario; it does not promise
all future majors. Use target-compatible pinned client tools after Mori lookup and authoritative
registry/tag verification. Preserve the documented format unless a tested adapter requires a change;
no unverified custom-format/client flags are chosen by this plan.

Restore into a newly initialized independent target; never mount target-major containers on old data
files. Verify schema/data fingerprints, extension availability and application read-only probes.
Missing extensions/collation incompatibility or failed checks block readiness. The old instance
remains authoritative until EP-127 admits candidate writes; later major pairs need explicit evidence.

### M4: Final transfer and conservative prediction

Time at least two successful representative full copy/restore/verify sequences with monotonic clocks.
Initially predict `ceil(maxSuccessfulSeconds * 1.5)` plus declared overhead, with evidence at most
24 hours old. More than 10 percent source size growth, schema/extensions, tool/image, scope revision,
source/candidate incarnation or storage changes invalidate it. These are explicit conservative
initial settings, not a statistical guarantee; tune only with evidence and a recorded decision.

After EP-127 verifies global quiesce, run final backup, exact verification, recreation of only
transaction-owned candidate destinations, restore and final probes. Include a post-seed sentinel.
Admitted operations persist intent and observed completion and inspect actual state after interruption.
The injected deadline includes the rollback cutoff: stop launching work at that cutoff and cancel or
fence active work before returning control for rollback. Return item-bound verified final tokens,
measured duration and a complete aggregate; failure cannot produce success tokens.

### M5: Support and integrated proof

Add interpreter regressions for unknown retained items, wrong source/target identities, corrupt
receipts, partial restore, source replacement, size/schema drift, cancellation and candidate UID
replacement. Rehearse on local k3d only after model tests pass and the native-run preflight is met.
Prove same-major and the selected PostgreSQL cross-major transfer, post-seed writes in the final copy,
and source service/data intact after deadline cancellation. Document supported and blocked classes
in managed-database, storage and disaster-recovery docs. Broader major engines, automated pruning,
live overwrite and durable-data garbage collection remain outside this delivery.


## Concrete Steps

Run from the repository root; REV names the exact implementation commit:

```bash
just test-remote REV Platform
just gate
just mutation-sweep
```

Follow the current validated-world fast tier and deep monitoring/triage requirements. The proposed
public check after EP-125 integration is:

```bash
nagarectl platform replacement rehearse TRANSACTION_ID --json
nagarectl platform replacement status TRANSACTION_ID --json
```

Status must list every transfer item, exact source/target identities, two measured samples, predicted
seconds and blockers without secrets. A local fixture with an unmatched retained PVC becomes blocked
before source quiesce. A final-copy fixture includes the post-seed sentinel; a deadline failure leaves
old service recoverable. Native/cloud confirmation follows `docs/runbooks/before-a-native-run.md`
and a bounded operator-approved cloud sequence, rather than being authorized by these examples.


## Validation and Acceptance

Every retained item is covered or named as a blocker. A supported seed is independent, verified and
resumable under real inventory admission/history. PostgreSQL transfer verifies the selected version
pair, data, extensions and application reads; unsupported pairs refuse. Final copy contains all
acknowledged pre-quiesce writes including the post-seed sentinel. Conservative measurements and
headroom include handoff/public verification/rollback from the other children. Cancellation touches
no old destination, preserves old data/credentials and returns control before the rollback reserve
is spent. Reusing MP-23 evidence does not claim automated major upgrades or generic service recovery.


## Idempotence and Recovery

Use immutable attempt keys and exact destination incarnations. Only a verified transaction-owned
candidate destination may be recreated; source is never a restore target. Unknown completion is
resolved with current operation proof and observation, not a generic rerun. Preserve failed logs and
verified artifacts. EP-127 controls unfencing source writers on pre-admission failure; adapters may
not independently release both clusters. Ordinary backups remain independent of seed retention and
are never pruned by transfer cleanup.


## Interfaces and Dependencies

Preserve or explicitly version `StateTransferItem`, `StateTransferPlan`, `FinalStateEvidence` and
`validateStateTransferPlan`. Add item-bound source/target, coverage, measurement and verification
records rather than replacing the cutover-facing boundary with a competing inventory. EP-126 owns
seed/final-copy/verify operations; EP-125 owns candidate fence/report and EP-127 global timing and
writer admission. Reuse native format and receipt helpers; consult Mori for dependency sources/docs
before relying on APIs and verify authoritative releases before changing images or packages.


## Revision Notes

2026-10-09: Credited MP-23's backup/restore and PostgreSQL major procedure, replaced duplicate discovery
with inventory-derived coverage, and focused unfinished work on exact cross-cluster targets,
reviewed resumable transfer, conservative timings and deadline cancellation.
