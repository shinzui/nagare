---
id: 127
slug: execute-deadline-bound-cutover-rollback-cleanup-and-operator-drills
title: "Execute deadline-bound cutover rollback cleanup and operator drills"
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
      at: 2026-09-14T03:34:56Z
      mode: "implement"
      note: "Implement cutover executor, rollback, cleanup, drills, docs, and ADR distillation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:38:37Z
      mode: "update"
      note: "Record current adapter boundaries and a second successful validation pass"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T19:45:59Z
      mode: "update"
      note: "Refresh MP-21 as optional inventory-backed replacement after MP-23 upgrade drills"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Execute deadline-bound cutover rollback cleanup and operator drills

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [127-execute-deadline-bound-cutover-rollback-cleanup-and-operator-drills.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/127-execute-deadline-bound-cutover-rollback-cleanup-and-operator-drills.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

**Current scope (2026-10-09).** This child implements optional machine/cluster replacement after
MP-23, not a prerequisite for ordinary node or PostgreSQL upgrades. The
[production checklist](../releases/production-readiness-checklist.md) credits those completed drills.
MP-23's typed scopes, reviewed native effects, conditional shared history, receipt verification and
proof-based recovery are the implementation foundation. Replacement phase records never grant
mutation authority independently of inventory admission. Proposed replacement commands below remain
unavailable until their owned implementation and acceptance are complete.

Nagare turns a verified candidate into the active platform through one deadline-bound command.
The command rechecks drift, quiesces writes, performs the rehearsed final state transfer,
moves the existing static IP without changing DNS, verifies the real public path while writes
remain gated, and either commits the candidate or restores the old path before the rollback
reserve is consumed. The former active VM and disks remain available but stopped until the
operator explicitly finalizes.

The operator runs `nagarectl platform replacement cutover <transaction-id> --confirm
<context>/<transaction-suffix>`. Status shows a monotonic downtime counter, current phase,
hard forward-work cutoff, rollback eligibility, and final observed outage. `rollback` is
available until candidate writes are admitted; `finalize` removes only recorded former-active
resources after the retention gate and returns steady state to one VM.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-13 20:35 PDT) Audited the working tree and established that the hard-prerequisite
```text
  ExecPlans 122 through 126 have no implementation; added the missing prerequisite contract
  surface to this execution rather than pretending those APIs already exist.
```
- [x] (2026-09-13 20:58 PDT) Implemented the minimal replacement transaction, deadline, and state-transfer contract
```text
  surface required by this executor without claiming the prerequisite plans complete.
```
- [x] (2026-09-13 21:28 PDT) Implemented pre-cutover readiness, freshness/drift reconciliation,
```text
  exact confirmation, arming orchestration, and fail-closed maintenance/quiesce contracts.
```
- [x] (2026-09-13 21:28 PDT) Implemented the monotonic deadline executor and the journalled,
```text
  observable static-IP handoff sequence behind injected provider operations.
```
- [x] (2026-09-13 21:28 PDT) Implemented automatic/manual rollback reconciliation for every
```text
  pre-commit interruption point, plus the post-commit manual-recovery fence.
```
- [x] (2026-09-13 21:28 PDT) Implemented atomic promotion ordering, observed write admission,
```text
  stopped-old retention state, and exact-manifest guarded cleanup.
```
- [ ] Wire the executor to concrete GCE, Kubernetes, Pulumi, and state-transfer adapters after
```text
  ExecPlans 122 through 126 provide their owned implementations and evidence.
```
- [x] (2026-09-13 21:04 PDT) Added deterministic before/after fault-injection coverage and local
```text
  integrated tests for every pre-commit external-operation boundary.
```
- [ ] Run forward/rollback live drills that satisfy the selected budget after ExecPlan 122
```text
  supplies a disposable environment and measured address-handoff contract.
```
- [x] (2026-09-13 21:28 PDT) Completed the operator drill/recovery guidance and distilled durable
```text
  deadline, commit-point, rollback, and cleanup decisions into ADR 0019.
```
- [x] (2026-09-13 21:02 PDT) Validated the stopping point with 14 focused cutover tests, all 486
```text
  `nagarectl` tests, the Pulumi TypeScript build, strict user-documentation OKF validation,
  and the full native-system `nix flake check`.
```
- [x] (2026-09-15 PDT) Revalidated the provider-independent stopping point against Nagare 0.3.0:
```text
  all 14 focused cutover tests, the Pulumi TypeScript build, strict validation of 37 user-doc
  concepts, and the full native-system flake gate passed, including all 568 Haskell tests.
```

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: Stopping a GCE VM does not detach its static external IP; address movement needs
  an explicit access-config detach/attach sequence.
  Evidence: current `NagareInstance` places the reserved address in `accessConfigs`, and the
  disposable proof in ExecPlan 122 measures the required operations.
- Observation: Rolling back after the candidate accepts writes can lose those new writes
  because the old and candidate use independent storage.
  Evidence: the low-cost design deliberately has no synchronous replica.
- Observation: Committing only the Pulumi active slot is insufficient; host, kubeconfig,
  platform version, and cluster stamps are context-owned identities used by later commands.
  Evidence: the existing upgrade transaction commits the context last under ADR 0006.
- Observation: Historical observation (2026-09-13): at the start of this slice, none of the
  hard-prerequisite replacement plans had been implemented, including the disposable address-handoff proof from ExecPlan 122.
  Evidence: `Nagare.Platform.Replacement`, `Nagare.Platform.StateTransfer`, candidate-slot,
  and rehearsal modules are absent, while every Progress item in ExecPlans 122 through 126 is
  unchecked at commit `f4953c1`.
- Observation: The plan's root-level Cabal command is not executable because this repository has
  no root `cabal.project`; the package project lives in `cli/nagarectl/`.
  Evidence: `nix develop -c cabal build nagarectl` from the repository root reports Cabal error
  7136, while the same build from `cli/nagarectl/` succeeds.
- Observation: Cabal compilation does not enforce the repository rule that every maintained Haskell
  source and test imports `Nagare.Dsl.Prelude`; only the flake style check reports it.
  Evidence: all 486 tests compiled and passed before `nix flake check` rejected the four new modules
  with `haskell-dsl-modules-import-custom-prelude`.
- Observation: A failed write-gate command cannot be treated as proof that writes stayed fenced;
  actual gate observation determines whether the irreversible commit point occurred.
  Evidence: the injected failpoint after the admission side effect observes admitted writes and
  completes the promotion without invoking old-context rollback.
- Observation: A persisted pre-admission transaction can still hide a completed external write-gate
  mutation if the process died before recording its observation.
  Evidence: rollback now observes the gate before any restore; the regression fixture presents a
  stale `CuttingOver` record with live candidate admission and verifies that neither old context nor
  old address is restored.
- Observation: Persisting the shrinking cleanup manifest after each deletion requires `finalizing`
  to be a resumable input state, including when the last deletion succeeded before Pulumi convergence.
  Evidence: the focused suite resumes a `Finalizing` transaction with an empty remaining manifest,
  performs convergence/pruning, and reaches `Complete` without deleting anything twice.
- Observation: later work strengthened the ordinary upgrade boundary without wiring replacement
  cutover to providers.
  Evidence: `Nagare.Infra.Plan` now retains reviewed Pulumi plans,
  `Nagare.Platform.PulumiReceipt` distinguishes verified, failed, and ambiguous applies,
  `Nagare.Cluster.Kubeconfig` provides explicit context-safe cluster identity, and
  `Nagare.Cluster.CertificatePolicy` rejects unintended public certificate issuance. The
  replacement executor still has only injected operations and exposes no mutating CLI command.

## Decision Log

Record every decision made while working on the plan.

- Decision: Keep the old VM running but application-quiesced during final transfer and address
  handoff; stop it only after candidate verification and context commit.
  Rationale: A running, detached old host is the fastest rollback target and consumes only a
  few extra compute minutes during the bounded window.
  Date: 2026-09-13
- Decision: Keep candidate writes disabled until all public verification and durable context
  commit steps succeed; admitting candidate writes is the commit point.
  Rationale: Before that point, rollback can restore the old state without discarding accepted
  writes. After it, automatic rollback is unsafe without reverse state transfer.
  Date: 2026-09-13
- Decision: Stop forward progress when remaining time equals the measured rollback reserve
  plus safety margin, not when the total budget expires.
  Rationale: The budget must contain recovery, not merely detect that the attempt ran late.
  Date: 2026-09-13
- Decision: Use the proven direct GCE address operation for the short handoff and then
  reconcile Pulumi state/config to the promoted slot.
  Rationale: A single Pulumi update cannot safely express every intermediate failure boundary;
  the executor needs observable, reversible steps, followed by declarative convergence.
  Date: 2026-09-13
- Decision: Default former-active retention to 24 hours but show its disk cost and allow a
  shorter explicit retention or immediate finalization after acceptance.
  Rationale: Stopped VMs do not need ongoing compute, while a short rollback window is valuable;
  retained disks still cost money and must not become unnoticed permanent infrastructure.
  Date: 2026-09-13
- Decision: Implement the smallest prerequisite transaction/deadline/state-transfer contracts
  needed by the cutover executor in this plan, but leave infrastructure provisioning,
  rehearsal, and state-adapter delivery attributed to their owning plans.
  Rationale: The cutover module cannot compile or prove its safety invariants against nonexistent
  types. Supplying the pure shared boundary here permits deterministic executor work without
  falsely marking ExecPlans 122 through 126 complete or performing their cloud mutations.
  Date: 2026-09-13
- Decision: Do not expose a mutating `platform replacement cutover` command until its provider,
  quiesce, rehearsal, and state-transfer adapters exist and have live evidence.
  Rationale: A command assembled from guessed `gcloud` or generic `kubectl` operations could deny
  production writes without a proven final-transfer or recovery path. ADR 0019 requires the command
  to remain unavailable or fail closed at this boundary.
  Date: 2026-09-13
- Decision: Concrete EP-127 adapters must consume the reviewed-plan/receipt, staged-host,
  context-safe kubeconfig, cluster-guard, and certificate-policy boundaries now present in 0.3.0.
  Rationale: promotion and recovery are not allowed to bypass safeguards added after the original
  plan; replacement-specific evidence should add transaction bindings to those mechanisms instead
  of creating parallel unguarded execution paths.
  Date: 2026-09-15

- Decision (2026-10-09): On hold with [MasterPlan 21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md). If the plan resumes, exact cleanup and retained-disk finalization use [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md)'s reviewed collection (EP-164, EP-165) and typed destruction intent (EP-166), rather than a replacement-specific manifest cleanup. Source and target release pairs come from [MasterPlan 26](../masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md) EP-172's compatibility table.
  Rationale: Single owners for collection, destruction and release compatibility.
  Date: 2026-10-09

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)

The provider-independent safety core is implemented and locally proven: transactions persist
intent and observation, forward work stops before rollback reserve, every pre-commit failpoint
restores old service, write admission is observed as the irreversible boundary, and cleanup accepts
only transaction-owned resource IDs. Operator-facing documentation and ADR 0019 now preserve these
rules. Concrete cloud/cluster adapters and both live drills remain blocked by incomplete prerequisite
ExecPlans 122 through 126. EP-123 and EP-126 contain only the minimal contracts this early slice
needed. MP-23 now supplies the common inventory and backup/restore foundation; replacement-specific
feasibility, store/model/CLI binding, candidate, fenced rehearsal and concrete final-transfer adapters
remain incomplete, so this plan is not complete and no production
cutover command is advertised as available. A fresh 2026-09-15 validation pass preserved the 14
focused cutover tests and passed the current Pulumi TypeScript build, strict validation of 37 user
documentation concepts, and the full native-system flake gate with all 568 Haskell tests.

