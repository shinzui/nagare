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
---

# Rehearsed replacement upgrades with bounded downtime for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Nagare currently makes ordinary host activation self-reverting, but it still applies a platform
release to the one machine serving production. A NixOS, k3s, Knative, cert-manager, or database
upgrade can therefore discover a slow migration or an incompatibility only after the maintenance
window has started. A deliberate image replacement is more disruptive: it destroys the boot disk
that holds the k3s datastore even though the separate application-data disk survives.

After this initiative, an operator can ask Nagare to rehearse a replacement upgrade while the old
machine continues serving. Nagare creates a temporary candidate machine and independent data disk,
boots the target NixOS image, builds a fresh target-version k3s cluster, restores or seeds the
declared state, applies the complete target platform, and runs host, cluster, application, and
database verification against an IAP-only candidate endpoint. The candidate is fenced so cloned
scheduled work, webhooks, email, backup pruning, and other outward side effects cannot run merely
because rehearsal started.

The operator supplies a downtime budget, initially fifteen minutes. Nagare calls a rehearsal
`cutover-ready` only after it has measured every operation that must occur after production writes
stop, reserved time for rollback, found no unaccounted persistent state, and observed no disqualifying
drift since the rehearsal seed. Cutover puts the old platform into maintenance and quiesces writers
without stopping its VM, performs the rehearsed final state transfer, moves the already-reserved
regional external IP from the old machine to the candidate, and verifies the public path while
candidate writes remain fenced. It then either commits, admits candidate writes, and stops old, or
restores old before the rollback reserve is consumed. Cloud DNS never changes. The old boot and data
disks remain an untouched rollback anchor until the operator finalizes the transaction.

Steady-state cost remains one VM. The extra VM and the superseded slot's boot/data disks exist only
during an active replacement-upgrade transaction and its configurable rollback-retention period;
finalization deletes the former active slot and leaves the promoted candidate as the sole machine.
No load balancer, managed instance group, second permanent cluster, or always-on replica is
introduced.

This initiative includes the GCP feasibility proof; a persisted replacement-transaction model;
ephemeral candidate infrastructure; candidate host and kubeconfig identity; side-effect fencing;
release rehearsal and evidence; inventory and transfer contracts for retained volumes and managed
databases; an explicit PostgreSQL major-version path; deadline-enforced static-IP handoff, rollback,
and cleanup; local deterministic tests; and one live end-to-end drill. It preserves the existing
in-place `nagarectl platform upgrade` path for small changes.

It does not promise zero downtime, generic cross-cluster replication, or a fifteen-minute result for
every workload. If a final dump, restore, schema migration, or rollback cannot fit the requested
budget with margin, Nagare must refuse the bounded claim and explain what must change. Redis and
ClickHouse major-version migration automation, multi-node Kubernetes, cross-zone failover, and
continuous traffic splitting are deferred unless the feasibility work proves one is required for
the initial PostgreSQL acceptance scenario.


## Decomposition Strategy

The initiative is split into six user-observable capabilities. EP-122 is a live, disposable
feasibility gate: it proves that the reserved IP can be handed off and restored within a measured
deadline, that a candidate can be tested through IAP without public traffic, and that independent
disks preserve the old host as a rollback anchor. EP-123 turns those observations into a pure and
persisted transaction state machine. EP-124 adds the temporary cloud and host topology. EP-125
boots and verifies a fenced target platform on that topology. Once the candidate substrate exists,
EP-126 gives retained state and PostgreSQL major upgrades a budgetable seed/finalize contract.
EP-127 combines the prior contracts into the timed public cutover, automatic rollback, cleanup, and
operator-facing drill.

This ordering puts unknown GCP behavior ahead of a large implementation and assigns each shared
interface to one plan. It also permits EP-125's platform rehearsal and EP-126's state-transfer work
to proceed in parallel once EP-124 is complete. Six plans stay within the recommended two-to-seven
range while keeping the final safety-critical state machine separate from provisioning and database
logic.

The existing architecture decisions constrain the design. Immutable release assets and mutable
context workspaces stay separated by
[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md). Candidate host
inputs must be transaction-owned derivatives of the context host flake without overwriting operator
secrets, following [ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md).
The new transaction extends rather than silently changes the version and final-commit contract in
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md). Every
cloud mutation remains confined to the active context's project under
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md), and every
host activation retains the recovery expectations of
[ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md). Protected data, remote
Pulumi state, explicit VM shape, and upgrade-phase guard parity remain governed by
[ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md),
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md),
[ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md), and
[ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md).
EP-122 owns the new ADR that will record the proven replacement topology, cost boundary, and
downtime-budget semantics; later plans amend it if live evidence changes those decisions.

`mori show --full` identifies this repository as `mori://shinzui/nagare`, but its ADR directory is
not a Mori OKF bundle. Searches for cross-repository decisions about upgrade rehearsal, static-IP
handoff, and PostgreSQL migration returned no relevant records, so this initiative cites only local
ADRs. Mori also had no registered Pulumi provider source. The research therefore used the locked
local `@pulumi/gcp` 8.41.1 declarations after Mori lookup, and EP-122 must verify the actual provider
and GCP behavior before setting implementation bounds.

A permanent load balancer was rejected because it violates the platform's cost requirement. A DNS
flip was rejected because the existing reserved IP already provides a faster stable frontend and DNS
caches cannot enforce a hard deadline. Cloning the old boot disk as the production successor was
rejected as the default because it carries machine identity, historical k3s state, and every cloned
workload side effect into rehearsal; a fresh target cluster plus explicit restore proves the
disaster-recovery contract and leaves the old machine intact. Moving the live data disk into the
candidate before commit was rejected because any irreversible migration would destroy the rollback
anchor. Treating one successful rehearsal as an unconditional guarantee was rejected: state size,
production drift, and rollback time must be part of the readiness calculation.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 122 | Prove isolated replacement rehearsal and static-IP handoff | docs/plans/122-prove-isolated-replacement-rehearsal-and-static-ip-handoff.md | None | None | Not Started |
| 123 | Model resumable replacement-upgrade transactions and downtime budgets | docs/plans/123-model-resumable-replacement-upgrade-transactions-and-downtime-budgets.md | EP-122 | None | Not Started |
| 124 | Provision ephemeral candidate hosts and promotable infrastructure slots | docs/plans/124-provision-ephemeral-candidate-hosts-and-promotable-infrastructure-slots.md | EP-122, EP-123 | None | Not Started |
| 125 | Rehearse target platform releases in a side-effect-fenced candidate cluster | docs/plans/125-rehearse-target-platform-releases-in-a-side-effect-fenced-candidate-cluster.md | EP-124 | EP-126 | Not Started |
| 126 | Make stateful cutovers and PostgreSQL major upgrades budgetable | docs/plans/126-make-stateful-cutovers-and-postgresql-major-upgrades-budgetable.md | EP-123, EP-124 | EP-125 | Not Started |
| 127 | Execute deadline-bound cutover rollback cleanup and operator drills | docs/plans/127-execute-deadline-bound-cutover-rollback-cleanup-and-operator-drills.md | EP-125, EP-126 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-122 has no child-plan dependency. It is deliberately first because the rest of the initiative
must not encode an unmeasured assumption about static-IP reassignment, candidate reachability,
provider convergence, shutdown time, or rollback time.

EP-123 hard-depends on EP-122 because its phase vocabulary, deadline reserve, evidence fields, and
retry boundaries must describe the workflow the live spike actually proved. It delivers a versioned
transaction schema and pure transition rules without creating cloud resources.

EP-124 hard-depends on EP-122 and EP-123. It needs the proven topology and the transaction identity
used to name and retain candidate resources. It produces the inactive candidate VM, independent
disks, transaction-owned host flake and kubeconfig paths, stack outputs, and cleanup-safe resource
ownership.

After EP-124, EP-125 and EP-126 may proceed in parallel. EP-125 hard-depends on the candidate host
because it must bootstrap and inspect a real second cluster. EP-126 hard-depends on the transaction
and candidate because its state inventory, seed, final synchronization, and PostgreSQL upgrade
records attach evidence to that transaction and operate between two clusters. Their soft dependency
means each may define fixtures against the integration contract while the other is unfinished, but
they must reconcile readiness evidence and maintenance hooks before either is marked complete.

EP-127 hard-depends on EP-125 and EP-126. Only then are candidate health and state readiness truthful
inputs to the deadline state machine. It owns public-IP movement, maintenance timing, rollback,
promotion, cleanup, the integrated local fault-injection scenario, and the live fifteen-minute drill.

The implementation waves are therefore EP-122; EP-123; EP-124; EP-125 and EP-126 in parallel; then
EP-127.


## Integration Points

**1. Replacement transaction schema and phase engine (defined by EP-123; consumed by EP-124 through
EP-127).** `cli/nagarectl/src/Nagare/Platform/Replacement.hs` owns transaction identity, active and
candidate resource references, requested downtime, rollback reserve, phase state, evidence,
timestamps, and terminal states. Later plans add phase executors but do not invent parallel JSON
files or alternate clocks. Existing in-place `UpgradeTransaction` remains readable and unchanged.

**2. Candidate resource and slot contract (defined by EP-124; consumed by EP-125 through EP-127).**
`infra/pulumi/src/components/NagareHostSlot.ts`, Pulumi stack outputs, and the replacement
transaction agree on the old and candidate physical instance names, disk names, IP attachment state,
zone, image, and protection flags. The existing reserved `publicIp`, DNS zone, buckets, service
account boundary, and context stack remain the shared perimeter. EP-127 promotes or destroys only
resources recorded by EP-124; resource-name prefixes are not treated as authority.

**3. Candidate host and Kubernetes identity (defined by EP-124; consumed by EP-125, EP-126, and
EP-127).** Candidate host material lives beneath the transaction directory, not the context's active
host-flake directory. Candidate kubeconfig and IAP tunnel selection are explicit arguments, never an
ambient `KUBECONFIG`. Promotion atomically changes the context's active instance and kubeconfig
references only after public verification.

**4. Fencing and rehearsal evidence (defined by EP-125; consumed by EP-126 and EP-127).** A machine-
readable readiness report records fence state, exact release identities, cluster rollout checks,
application probes, source observation time, and expiry. EP-126 contributes state-specific checks to
the same report. EP-127 accepts no human-edited `ready=true` shortcut and rechecks expiring evidence
before downtime begins.

**5. Stateful cutover adapters (defined by EP-126; consumed by EP-125 and EP-127).**
`Nagare.Platform.StateTransfer` owns inventory classification, initial seed, read-only/quiesce,
final synchronization, candidate verification, rollback safety, measured duration, and cleanup for
each retained state item. PostgreSQL is the first version-aware adapter. Retained state without an
adapter or an explicit discard policy makes the transaction ineligible for bounded cutover.

**6. Deadline and rollback semantics (types defined by EP-123; execution owned by EP-127).** The
downtime clock starts at the first action that prevents the old platform from serving writes. EP-127
must reserve the rehearsed rollback duration plus a safety margin and start rollback before the hard
deadline, rather than merely reporting a late failure. Tests use an injected monotonic clock and
fake cloud operations; wall-clock timestamps are evidence only.

**7. Durable architecture record (created by EP-122; amended by later plans).** The new ADR records
that bounded replacement upgrades use a temporary fresh cluster, independent state, a stable-IP
handoff, explicit side-effect fencing, and refusal when the budget is unprovable. EP-127 performs the
final ADR distillation pass across all child plans.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-122: Build a disposable two-host spike with no load balancer or DNS change.
- [ ] EP-122: Measure forward and reverse IP handoff, record failure behavior, and fix the replacement ADR.
- [ ] EP-123: Add the versioned replacement transaction, deadline arithmetic, transitions, and CLI planning/status surface.
- [ ] EP-123: Prove persistence, resume, expiry, drift, and rollback-deadline behavior with deterministic tests.
- [ ] EP-124: Add optional transaction-owned candidate infrastructure and migrate the singleton stack without replacement.
- [ ] EP-124: Generate candidate host/kubeconfig identity, provision and destroy it idempotently, and preserve protected resources.
- [ ] EP-125: Fence the candidate against external side effects and bootstrap the exact target release.
- [ ] EP-125: Produce expiring machine-readable host, cluster, application, and cost-readiness evidence.
- [ ] EP-126: Inventory every retained state item and implement measured seed/finalize adapter contracts.
- [ ] EP-126: Rehearse and verify a PostgreSQL major-version transfer or refuse the downtime claim.
- [ ] EP-127: Execute the timed maintenance, final state transfer, static-IP handoff, verification, commit, and automatic rollback.
- [ ] EP-127: Finalize cleanup, documentation, local fault injection, live fifteen-minute drill, and ADR distillation.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Observation: the reserved regional address and wildcard DNS record already live independently of
  `nagare-01`, but `NagareInstance` embeds that address in its sole network interface. The initiative
  needs a two-phase detach/attach operation or another provider shape; it does not need a new DNS
  mechanism.
  Evidence: `infra/pulumi/src/components/NagarePerimeter.ts` creates the address and record, while
  `infra/pulumi/src/components/NagareInstance.ts` consumes the address in `accessConfigs`.
- Observation: a replacement cannot preserve the cluster by moving only `nagare-data`.
  Evidence: local-path PVC bytes are under `/var/lib/nagare/local-path`, while the Kubernetes
  datastore is under `/var/lib/rancher` on the disposable boot disk. This is why the plan chooses a
  fresh candidate cluster and explicit state restore rather than treating the data disk as a full
  machine image.
- Observation: managed PostgreSQL declares a version but explicitly documents major upgrades and
  replication as out of scope. The fifteen-minute claim therefore needs new database behavior, not
  just faster VM switching.
  Evidence: `docs/user/managed-databases.md` names both exclusions.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: use an ephemeral replacement candidate and the existing reserved static IP; introduce
  no load balancer and perform no DNS change.
  Rationale: this preserves Nagare's steady-state cost model and removes DNS cache propagation from
  the downtime budget.
  Date: 2026-09-13.
- Decision: build a fresh target-version cluster on independent disks and move state through explicit
  adapters; keep the old machine and disks unchanged until finalization.
  Rationale: a fresh cluster rehearses the disposable-machine recovery promise, prevents an
  irreversible migration from consuming the rollback anchor, and avoids cloning machine identity as
  the default operating model.
  Date: 2026-09-13.
- Decision: interpret the requested downtime as a deadline containing both promotion and rollback,
  not as an estimated maintenance duration; stop forward work at the rollback threshold and report
  a provider control-plane outage as an SLO breach rather than success.
  Rationale: a fifteen-minute promise is useful only when Nagare begins rollback early enough to
  restore service before the deadline and refuses plans whose evidence cannot support that reserve.
  No single-node design can absolutely bound a cloud control-plane outage, so the external condition
  must remain visible.
  Date: 2026-09-13.
- Decision: keep the current in-place upgrade workflow and add an explicit replacement/rehearsal
  workflow.
  Rationale: small compatible changes should not pay for duplicate disks or a second VM, while risky
  releases need a stronger path whose state and rollback semantics differ materially.
  Date: 2026-09-13.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)
