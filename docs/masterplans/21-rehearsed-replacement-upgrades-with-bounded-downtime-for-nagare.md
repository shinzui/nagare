---
id: 21
slug: rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare
title: "Rehearsed replacement upgrades with bounded downtime for Nagare"
kind: master-plan
created_at: 2026-09-13T22:08:52Z
intention: "intention_01m2ecthzwek7t64p7wqn0x9wj"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T22:08:52Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:38:36Z
      mode: "update"
      note: "Refresh registry, shared boundaries, current repository state, and validation evidence"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:53:10Z
      mode: "update"
      note: "Record critical intranet upgrade readiness and backup recovery acceptance with a one-hour recovery-point objective"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T19:45:59Z
      mode: "update"
      note: "Refresh MP-21 as optional inventory-backed replacement after MP-23 upgrade drills"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "On hold except EP-122 measured IP-handoff spike and operator decision gate; consume MP-25/MP-26 primitives"
---

# Rehearsed replacement upgrades with bounded downtime for Nagare

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current. The registry owns child status; children own milestones.


## Vision & Scope

**Status (operator, 2026-10-09): on hold, except the EP-122 measurement spike.**
[MasterPlan 26](26-make-platform-changes-and-releases-routine-after-the-inventory-release.md) and
[MasterPlan 25](25-reviewed-full-context-teardown-with-vm-workload-collection.md) go first.
Replacement has the largest cloud surface of the three follow-up plans, so it is the most likely to
repeat MasterPlan 23's native-run loop, and checklist sections 3–4 no longer need it. The one cheap
thing worth learning now is whether the budget is physically plausible: how long a reserved regional
IP takes to move between two VMs and back. If a fifteen-minute window, including rollback, is not
plausible, most of this plan's remaining design is not worth building.

**Finish line for the current phase (fixed 2026-10-09):**
- [ ] 1. **Native run S1 (one bounded cloud sequence, disposable resources only).** The spike script
      runs under the project guard and creates two tiny VMs and a test reserved address, never the
      context's own. It moves the address forward and back at least five times, timing each step:
      detach, attach, first successful TCP and TLS connect through the address, and IAP reachability
      of the inactive host. Then it deletes everything it created, by exact name. The script's
      `--dry-run` output is reviewed before the operator approves the sequence (EP-122 M2).
- [ ] 2. The measured distribution and the topology it implies are recorded in EP-122 and in
      [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) (EP-122 M3).
- [ ] 3. **Operator decision gate.** With those numbers, the operator decides whether to resume
      EP-123 to EP-127 (scheduling MasterPlan 21 after MasterPlans 26 and 25), re-scope the budget, or
      cancel the remaining children.

Nothing else in this plan is scheduled until item 3 is decided. The text below describes the full
capability if it resumes.

**Current scope (2026-10-09): an optional replacement capability after MP-23.** Ordinary safe
node upgrades and the supported PostgreSQL major-upgrade procedure no longer require completion
of this initiative. The [production readiness checklist](../releases/production-readiness-checklist.md)
is the authoritative account of the operator's immediate goal. Its sections 2–4 credit MP-23's
off-cluster recovery, reviewed node upgrades with self-reversion, and side-by-side PostgreSQL
upgrade drills. This plan adds no boxes to that checklist and does not reopen its accepted drills.

Use the shortest supported path for a compatible change: a reviewed inventory operation for host
configuration, or the documented side-by-side database procedure. Use replacement when a fresh
machine or cluster is needed, or when an operator wants to test the target and its restored state
on independent infrastructure before interrupting production. An inventory-backed host upgrade is
not the legacy coarse `platform upgrade` runner; that runner remains blocked after admission.
Nor do the node drills establish arbitrary Nagare payload, context-pin or inventory-schema
transitions. Replacement must explicitly support or refuse each source/target release and schema
pair it accepts; a general in-place release/schema migration is outside this plan.

After this initiative, an operator can plan, prepare and rehearse a temporary candidate while the
old platform continues serving. The candidate boots the exact target image and a fresh k3s cluster
on independent boot and data disks, restores declared state, and verifies host, cluster, application,
and access behavior through an explicit IAP target. IAP is Google's authenticated TCP tunnel.
Candidate schedules, workers, webhooks, email, backup writes/pruning and production certificate
issuance remain fenced. A hidden public address alone is not a side-effect fence.

The operator requests a downtime budget, initially fifteen minutes. Readiness requires a complete
account of retained state, supported transfer and quiesce contracts, fresh evidence bound to exact
source/target identities, and conservative timings for final transfer, address handoff, public
verification, rollback and margin. Quiesce means preventing and draining every declared production
writer. Unsupported state or a budget that cannot be proved is refused before downtime.

Cutover starts its monotonic clock at the first denied production write, makes the final state copy,
and moves the existing reserved regional IP to the candidate without changing DNS. Public TLS,
authentication, routing and data are verified while candidate writes remain fenced. Before write
admission, a failure restores the old address, workload/schedule state and context within the
reserved recovery window. After observed candidate write admission, automatic rollback is forbidden:
recovery must preserve candidate-only writes. The old VM is stopped after commit and its disks are
retained until explicit finalization. Retention is a recovery anchor, not permission for a stale
rollback after new writes.

Steady state remains one VM. The candidate and retained old disks exist only during replacement and
its visible retention period. No permanent load balancer, second cluster, DNS flip, managed instance
group, synchronous replica or daemon is introduced. A cloud control-plane outage can exceed the
budget; report the breach and continue recovery rather than claim an unconditional guarantee.

The first integrated acceptance uses a representative application with PostgreSQL and access
configuration. Support retained volumes and other existing engines by reusing their proven
backup/restore semantics where they meet consistency and deadline contracts; otherwise name them as
blockers. Redis/ClickHouse major migrations, broker replication, automatic live overwrite, generic
schema rollback, scheduled pruning, volume recovery-point guarantees and broad garbage collection
are not silently imported from MP-23's deferrals. Full-context teardown remains
[MP-25](25-reviewed-full-context-teardown-with-vm-workload-collection.md)'s responsibility.


## Decomposition Strategy

Retain the six child identities and useful partial code, but make each responsible only for the
replacement-specific delta. EP-122 proves address movement and rollback on disposable resources.
EP-123 binds the existing replacement model to inventory authority and evidence. EP-124 creates
optional candidate slots without replacing the active installation. EP-125 verifies a fenced,
explicitly targeted candidate. EP-126 turns existing backup/restore and PostgreSQL procedure into
measured cross-cluster seed/final-transfer adapters. EP-127 integrates deadline-bound cutover,
recovery, promotion and exact cleanup.

MP-23 already supplies typed scopes, ownership/conflict validation, reviewed native execution,
conditional shared history, identity checks, recovery policy, bootstrap and backup receipts.
Replacement extends those modules instead of creating another resource inventory, journal, writer
lock, receipt verifier or recovery allowlist. Existing native guards remain in force beneath them.
The preparation model can be developed against an abstract handoff contract before the cloud
spike; concrete candidate/provider operations wait for the spike's acceptance.

The existing `Nagare.Platform.Replacement`, `StateTransfer` and `Cutover` modules are a partial
provider-independent baseline. Their older standalone JSON persistence must be reconciled with the
inventory store before enabling production effects. Preserve schema compatibility through an
explicit import/migration or read-only legacy handling; do not keep two writable authorities.

[ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) owns deadline
and write-admission semantics; [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
owns inventory composition, reviewed effects and conditional history. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
requires explicit release identity and compatibility. [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md)
keeps host activation self-reverting. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md),
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
require interpreter-first validation, proof-based stopped-operation recovery and physical identity
recorded at creation. Candidate targeting also preserves active-project, private operator-material,
protected-disk and explicit VM-shape rules from ADRs 9, 13, 12 and 14. No new dependency version is
chosen by this refresh. Implementers must use Mori for dependency source/docs and verify registries
and upstream tags before changing bounds or pins; never traverse `/nix/store`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 122 | Prove isolated replacement rehearsal and static-IP handoff | docs/plans/122-prove-isolated-replacement-rehearsal-and-static-ip-handoff.md | None | None | Not Started (the only scheduled child: M2 spike, then M3) |
| 123 | Model resumable replacement-upgrade transactions and downtime budgets | docs/plans/123-model-resumable-replacement-upgrade-transactions-and-downtime-budgets.md | None | EP-122 | In Progress (on hold, operator 2026-10-09) |
| 124 | Provision ephemeral candidate hosts and promotable infrastructure slots | docs/plans/124-provision-ephemeral-candidate-hosts-and-promotable-infrastructure-slots.md | EP-122, EP-123 | MP-25 EP-165 (cloud identity) | Not Started (on hold) |
| 125 | Rehearse target platform releases in a side-effect-fenced candidate cluster | docs/plans/125-rehearse-target-platform-releases-in-a-side-effect-fenced-candidate-cluster.md | EP-124 | EP-126 | Not Started (on hold) |
| 126 | Make stateful cutovers and PostgreSQL major upgrades budgetable | docs/plans/126-make-stateful-cutovers-and-postgresql-major-upgrades-budgetable.md | EP-123, EP-124 | EP-125 | In Progress (on hold, operator 2026-10-09) |
| 127 | Execute deadline-bound cutover rollback cleanup and operator drills | docs/plans/127-execute-deadline-bound-cutover-rollback-cleanup-and-operator-drills.md | EP-125, EP-126 | MP-25 EP-164, EP-166 (collection, destruction) | In Progress (on hold, operator 2026-10-09) |

No child becomes Complete merely because an overlapping MP-23 primitive or drill exists.
EP-123, EP-126 and EP-127 retain credit for their partial provider-independent contracts.


## Dependency Graph

**Current phase (2026-10-09):** only EP-122 runs, with M2 (the measured spike) before M1. M1's
fake-`gcloud` contract tests are deferred until the operator resumes the plan, because the spike
exercises provider behaviour, not Nagare code: it is a first-principles measurement, not a native
run of an unmodelled Nagare path
([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)). The graph
below applies if the plan resumes.

EP-122 and EP-123 may proceed independently. EP-122 owns measured provider feasibility;
EP-123 owns the pure model, store binding and non-mutating plan/status surface. EP-123 can describe
abstract address movement without assuming a live sequence. It cannot authorize readiness without
accepted provider evidence. EP-124 owns reconciliation of their concrete phase/evidence contracts
at the join before any candidate mutation.

EP-124 requires both children complete and accepts that reconciliation in its first milestone. It must first prove an
existing active-only stack can adopt slots without replacement/deletion. EP-125 and EP-126 then
build against the same candidate identity. Their implementations can proceed independently, but
final rehearsal evidence requires matching fence, seed and verification reports from both.

EP-127 requires EP-125 and EP-126 complete. Its existing injected executor may be tested earlier,
but concrete cutover and live drills remain gated on the complete candidate, fence and state
contracts. All native runs follow `docs/runbooks/before-a-native-run.md`; cloud mutations require a
bounded operator-approved sequence. This document refresh authorizes no infrastructure mutation.


## Integration Points

**1. Replacement control record and inventory authority — EP-123.**
`cli/nagarectl/src/Nagare/Platform/Replacement.hs` owns phases, budget, evidence references and
source/target release/schema bindings. `Nagare.Inventory.Store`, `Plan`, `Execute`, `Journal` and
`Command` remain the authority for admission and effects. A replacement record describes workflow;
it never grants mutation authority by itself. Derived private workspace files are caches/evidence,
not an alternate head. EP-123 owns the producer/consumer test through real inventory admission,
interruption, fresh-root reload and resume before EP-124 expands provider effects.

**2. Candidate resources and identities — EP-124.** Cloud physical identity recorded at creation
(VM, disks, address) is built once by MasterPlan 25's EP-165 as an ADR 27 §4 amendment. EP-124 reuses
it rather than building its own binding. Release and schema compatibility pairs come from MasterPlan
26 EP-172's compatibility table. Cleanup (EP-127) reuses MasterPlan 25's reviewed collection and
destruction intent.
`infra/pulumi/src/components/NagareHostSlot.ts` is proposed, not implemented. The current
`NagareInstance.ts`, `NagarePerimeter.ts` and `NagareNetwork.ts` supply the singleton baseline.
EP-124 extends typed cloud/host declarations and native registration parity together. Candidate
resources are declared and reviewed before creation; returned creation identities bind their
incarnations. MP-23's ADR 27 guarantee is Kubernetes-only; exact GCE VM/disk identity binding is
remaining replacement work, not an inherited claim. Address claims include cluster/provider identity so active and candidate objects do
not collide accidentally. Exact old and candidate resource manifests, protected-disk policy and
shared-perimeter exclusions are consumed by EP-127.

**3. Candidate scope composition and targeting — EP-124/125.**
EP-124 owns host-flake, instance and kubeconfig identity; EP-125 consumes it for all operations.
Candidate declarations derive from accepted scopes and the exact target payload. They have
explicit candidate addresses and ownership; rehearsal overlays are inputs to reviewed inventory,
not mutations of a rendered bundle after review. Existing application scope revisions remain
unchanged unless an explicit reviewed migration selects them. No candidate action implicitly
rewrites the active context or uses ambient kubeconfig selection.

**4. Fence and rehearsal report — EP-125.**
One digest-bound, expiring report records exact target identities, policy, component checks,
application probes and state seed. EP-126 attaches state verification to it; EP-127 revalidates
it and any checks affected by production credential/TLS arming. Undeclared side effects and
unknown pod-bearing kinds block execution rather than escaping through a permissive overlay.

**5. Transfer coverage and evidence — EP-126.**
`Nagare.Platform.StateTransfer` derives transfer items from accepted inventory plus live
observations. Existing `Nagare.Inventory.Backup`, `Restore`, `VolumeRestore`, receipt, escrow and
freshness modules supply reusable primitives. Logical ownership, physical incarnation, consistency,
source and candidate location, measurement and support are recorded per item. Unmatched retained
state is a blocker. Seed, final copy and verification stay inside reviewed effects; ordinary backups
are independent and never pruned by replacement cleanup.

**6. Deadline, promotion and recovery — EP-127.**
`Nagare.Platform.Cutover` keeps an injected monotonic clock and the ADR 19 write-admission boundary.
The native adapters reconcile observed address, gate, host, store and context state after
interruption. Promotion coordinates accepted inventory bindings with context host/kubeconfig,
release identity and cluster stamp through recoverable reviewed steps; it never claims an atomic
cross-tool update. Post-admission recovery preserves all acknowledged writes. Cleanup uses exact
incarnations and reviewed collection, refusing unresolved dependents and shared resources.

**7. Validation and durable decisions — all children, final integration EP-127.**
Each child adds meaningful effect-interpreter regressions for its owned failure classes before
native confirmation. Follow current ADR 25 and release gates (`just gate`, zero-survivor
`just mutation-sweep`, validated-world fast tier, deep monitoring with triage). EP-122 supplies
provider measurements; EP-127 supplies forward and forced-rollback drills with public TLS/auth/data
verification and finalizes ADR 19. MP-23 HTTP-only fixture evidence is not substituted for these
replacement-specific public-path checks.


## Progress

2026-10-09: On hold except EP-122's spike (finish line above). No replacement work is scheduled
until the operator decides at the gate.

The initiative remains partially implemented and is optional follow-up work, not an initial
production-readiness prerequisite. EP-122/124/125 have no accepted replacement implementation;
EP-123/126/127 have the existing minimal model, state contract and injected safety core.
No live IP handoff, promotable candidate topology, automated cross-cluster final transfer or bounded
public replacement drill is accepted. Only EP-122's measurement spike is scheduled. EP-123's
inventory-authority binding is the first code to resume if the operator's gate decides to continue.

Accepted inputs to reuse, rather than rebuild:

| Existing result | Evidence | Remaining replacement delta |
|---|---|---|
| Typed inventory, reviewed effects, identity and conditional history | MP-23 and ADRs 22, 26, 27 | Candidate ownership, replacement phases and coordinated promotion |
| NixOS/k3s upgrades, reboot and failed-activation reversion | [Section 3, candidate 83124396](../audits/mp23-independent-results-2026-10-07/section3-83124396/README.md) | Independent target machine and cluster rehearsal |
| PostgreSQL 17 → 18 copy, reviewed switch-over, pre-write rollback and retain-only retirement | [Section 4, candidate 3b59bcb7](../audits/mp23-independent-results-2026-10-07/section4-3b59bcb7/README.md) | Measured, resumable cross-cluster transfer under the global deadline |
| Off-cluster database recovery after source destruction | [Section 2 result](../audits/mp23-independent-results-2026-10-07/section2-drill-3ae20f8c/result.json) | Complete replacement service/access rebuild; the 20-second scratch restore is not service recovery time |
| Replacement model and injected deadline/cutover/cleanup core | `Platform/Replacement.hs`, `StateTransfer.hs`, `Cutover.hs`, `test/PlatformCutoverSpec.hs` under `cli/nagarectl/` | Shared-store binding, concrete adapters and live drills |

No new implementation or native proof is claimed by this refresh. Child status remains separate
from evidence credited as an input. General payload/schema upgrades and complete service rebuild
after disaster remain outside the accepted ordinary node/database drills.


## Surprises & Discoveries

2026-10-09: The October 8–9 MP-23 drills invalidated the October 2 assumption that safe node and
PostgreSQL upgrades required the full replacement initiative. The checklist explicitly chooses
reviewed self-reverting in-place node activation and makes candidate/IP handoff a later improvement.
The database major path is a documented operator procedure with manual fencing and copy commands;
it is not an automated `StateTransfer` adapter or a measured replacement guarantee.

The early replacement core predates inventory admission, conditional remote history, creation-bound
identity and proof-based close. Its useful safety invariants survive; standalone persistence and
provider-specific recovery must be brought under current authority before real effects are enabled.

The k3s datastore and application PVC bytes have different homes. A surviving data disk is not a
complete cluster backup. A fresh candidate must reconstruct declarations and restore explicit state;
cloning or moving the active disk would consume the independent rollback anchor.


## Decision Log

2026-10-09 (operator-authorized refresh): Narrow MP-21 to optional rehearsed machine/cluster
replacement with a bounded cutover. Supersede the October 2 requirement that full replacement
completion precede critical adoption; readiness follows the current production checklist and its
accepted drills. Keep the existing six child identities/statuses, credit MP-23 inputs, and remove
greenfield duplication of inventory, journal, backup and basic PostgreSQL migration work.

2026-10-09: EP-123 no longer hard-depends on the live spike. Its model/store work is independently
verifiable with abstract provider effects; EP-124 remains the join requiring the complete model
and measured EP-122 contract. No production readiness or provider assumption is weakened.

2026-10-09 (operator): Hold MasterPlan 21 behind MasterPlans 26 and 25, except EP-122's measured
IP-handoff spike, which runs as one bounded, disposable cloud sequence before any further replacement
code. Ownership changes:
- MasterPlan 26 EP-172 owns in-place release transitions and their compatibility table;
- MasterPlan 25 EP-165 owns cloud physical identity;
- this plan consumes both rather than building them.
Rationale: MasterPlan 23's cost was native runs used as discovery. Replacement's cloud surface is the
largest, and its budget's feasibility is unmeasured. A cheap measurement decides whether the rest is
worth building.

Decisions retained from September: one temporary candidate; independent fresh boot/data disks;
reserved-IP handoff without DNS change or permanent load balancer; rollback reserve and margin
before downtime; old authoritative state untouched until commit; observed write admission disables
automatic rollback; explicit, guarded retention/finalization. Candidate native operations extend
existing project, Pulumi, host and Kubernetes guards instead of bypassing them.


## Outcomes & Retrospective

The plan now describes the remaining capability rather than treating all safe upgrades as new work.
MP-23 delivered the ordinary node and PostgreSQL upgrade outcomes and substantial reusable safety
infrastructure. MP-21's distinctive replacement outcome remains incomplete. Complete it only after
inventory-authorized candidate/rehearsal/transfer adapters and successful forward plus forced-rollback
public drills meet the requested budget. At completion reconcile every child outcome and distill
replacement decisions into ADR 19; do not reopen the fixed production checklist.


## Revision Notes

2026-10-09 (second revision): Put the plan on hold except EP-122's spike, with a three-item finish
line and an operator decision gate. Redirected cloud identity to MasterPlan 25 EP-165, release
compatibility to MasterPlan 26 EP-172, and cleanup to MasterPlan 25's collection.

2026-10-09: Rewrote coordination around optional replacement after MP-23, credited October upgrade
and recovery evidence, removed duplicate foundations and the stale production prerequisite, relaxed
only the model's spike dependency, and made inventory authority, release/schema limits, interpreter
validation and exact promotion/cleanup ownership explicit. Earlier implementation evidence remains
in child plans and git history.
