---
id: 123
slug: model-resumable-replacement-upgrade-transactions-and-downtime-budgets
title: "Model resumable replacement-upgrade transactions and downtime budgets"
kind: exec-plan
created_at: 2026-09-13T22:09:03Z
intention: "intention_01m2ecthzwek7t64p7wqn0x9wj"
master_plan: "docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T22:09:03Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:38:36Z
      mode: "update"
      note: "Adopt the existing replacement core as a compatibility-preserving implementation baseline"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T19:45:59Z
      mode: "update"
      note: "Refresh MP-21 as optional inventory-backed replacement after MP-23 upgrade drills"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:17:13Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Model resumable replacement-upgrade transactions and downtime budgets

This ExecPlan is a living document. Keep its living sections current and promote durable decisions
into ADRs. It implements the model/authority boundary of the refreshed MP-21; it does not enable
cloud mutation or restore the coarse legacy upgrade runner for inventory-backed contexts.


## Purpose / Big Picture

An operator can plan an optional machine replacement, inspect why cutover is blocked, and recover
its control record from the context's authoritative inventory history. Planning changes only private
control/history material; it creates no cloud or cluster resources. The default requested downtime
is fifteen minutes, but the model accepts no readiness claim without measured transfer, handoff,
verification and rollback evidence.

`Nagare.Platform.Replacement` already contains the minimal transaction/deadline/checkpoint contract
used by `Nagare.Platform.Cutover`. Extend that contract and bind it to MP-23 admission and history;
do not build another inventory, writable journal or lock. The future commands are
`nagarectl platform replacement plan --to VERSION --downtime-budget 15m --json` and
`nagarectl platform replacement status TRANSACTION_ID --json`. They are proposed, not available.
Ordinary reviewed node upgrades and the supported PostgreSQL procedure remain separate.


## Progress

- [x] (2026-09-13) Minimal version-1 transaction, readiness/deadline arithmetic, persistence and
  cutover checkpoints exist; `cli/nagarectl/test/PlatformCutoverSpec.hs` records the injected proof.
- [ ] M1: Complete preparation, evidence and compatibility model with deterministic refusal tests.
- [ ] M2: Bind replacement control and effects to the conditional inventory store; prove fresh-root
  interruption/resume and legacy-record handling without two writable authorities.
- [ ] M3: Expose non-mutating plan/status with exact source/target and readiness diagnostics.
- [ ] M4: Prove the abstract handoff-evidence consumer contract for the EP-124 integration join.

The historical atomic JSON writer is partial progress, not the final authority for real operations.


## Surprises & Discoveries

The existing core predates MP-23. `Nagare.Inventory.Plan`, `Execute`, `Journal`, `Store` and `Command`
now provide reviewed admission, conditional history and proof-based recovery. A second writable
transaction directory would split authority, especially on fresh-root recovery or another machine.
The live address sequence need not block pure model and store work; it still blocks provider enablement.


## Decision Log

2026-10-09: Reuse the existing replacement domain model but persist its authoritative control/evidence
through inventory history. Private workspace files are derived artifacts. Preserve readable old
records with an explicit versioned import or read-only compatibility boundary; never silently accept
old JSON as mutation authority. Keep `UpgradeTransaction` legacy semantics unchanged.

2026-10-09: EP-122 is a soft dependency for model work. EP-124 owns the join between the accepted
model/evidence schema and EP-122's complete measured contract before concrete candidate mutations.
Missing provider evidence always blocks readiness.

Retained rules: monotonic downtime arithmetic, explicit rollback reserve/margin, exact confirmation,
source/target identity binding and observed candidate write admission as the irreversible boundary.

- Decision (operator, 2026-10-09): On hold. [MasterPlan 21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md) runs only EP-122's measured IP-handoff spike until the operator decides, from its numbers, whether to resume, re-scope or cancel the remaining children. Do not start this plan's remaining milestones before that decision. If it resumes, its source/target release and store-wire compatibility comes from [MasterPlan 26](../masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md) EP-172's compatibility table, rather than a separate binding defined here.
  Rationale: Replacement has the largest cloud surface of the follow-up plans, and its downtime budget's feasibility is unmeasured.
  Date: 2026-10-09


## Outcomes & Retrospective

Only the minimal cutover-facing model exists. Full preparation/evidence, store authority, CLI and
provider reconciliation remain. This refresh claims no new implementation and preserves In Progress.


## Context and Orientation

Work in `cli/nagarectl/src/Nagare/Platform/Replacement.hs`, with consumers `Platform/Cutover.hs`
and `Platform/StateTransfer.hs`. `Platform/Paths.hs` and `Platform/Workspace.hs` organize private
context material. The current command owner is
`cli/nagarectl/app/Nagare/Cli/Commands/Platform.hs`; parser and dispatch ownership is in
`app/Nagare/Cli/Parser/Platform.hs` and `app/Nagare/Cli/Dispatch.hs`. The legacy coarse runner is
`app/Nagare/Cli/Platform/Upgrade.hs`; do not bypass its inventory guard or put new orchestration in
`app/Main.hs`.

`Nagare.Inventory.Command` owns apply/resume/recover/close entrypoints, `Plan` owns digest-bound
reviews, `Execute` owns admission and execution, `Journal` owns durable operation history, and `Store`
plus `Store/ObjectOps.hs` own conditional publication/head replacement. Inspect these contracts before
selecting representation. A replacement control record describes workflow and evidence, not authority
to mutate. Any necessary store/journal extension is versioned and retains current single-writer,
conditional-head and fresh-root semantics.

[ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) defines the
rollback threshold and write-admission boundary. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
requires owned declarations, reviewed effects and one conditional history. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
requires release identity and refuses unsupported admitted-context transitions. ADRs
[25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md),
[26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and
[27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
require interpreter-first tests, proof-based recovery and creation-bound identity. These are local
contracts; this plan chooses no dependency version or new external API.


## Plan of Work

### M1: Complete the pure model

Add preparation/rehearsal/ready/terminal transitions, evidence references and exact source/target
release, payload, inventory-wire and transaction-schema compatibility to `Replacement.hs`.
Evidence includes canonical content digest, producer, source and candidate incarnation, scope/base
binding, observation time, expiry and drift inputs. Unknown schemas or unsupported release pairs
produce explicit blockers. No decoded boolean or edited `ready` field grants authority.

Compute readiness from conservative final-transfer, handoff and public-verification predictions plus
rollback reserve and margin. Exactly 900 seconds fits a 900-second request; 901 is refused. Missing,
expired or mismatched evidence blocks readiness. Preserve existing JSON tokens/fixtures where
compatible; incompatible fields require an explicit version and migration. Add model tests beside
`PlatformCutoverSpec.hs`, and keep its existing safety cases.

### M2: Prove the store/admission boundary before provider variants

Represent replacement control in the context-owned conditional history using existing content/member
and journal conventions. Any externally mutating phase requires a reviewed inventory operation and
admission under its writer lock. Bind native completion and phase progress to that admitted operation;
never invoke an entrypoint that reacquires the same lock from an adapter. Extend the common protocol
only where the workflow cannot be represented, with explicit versioned readers and regression fixtures.

Implement one representative prepare-phase effect with an injected provider and run real review,
admission, interruption after effect, fresh-root reload, observed recovery and resume. Verify exact
identity, no replay of proven completion, refusal of a second writer/stale head, and no active-context
promotion from a derived file. This is the required producer/consumer check before EP-124 expands
provider variants. Specify old standalone JSON import as an explicit action or read-only inspection;
conflicting control records fail closed and cannot be selected by newest timestamp.

### M3: Plan and status

Add the proposed command group through `Nagare.Cli.Commands.Platform` and its parser. Plan resolves
source and immutable target metadata, validates compatibility and budget, and creates/reuses one
nonterminal replacement control record. It can publish control intent under the store lock but
invokes no mutating Pulumi, host, Kubernetes or GCP operation. Status reads authoritative history and
reports source/candidate identities, missing evidence, scope revisions, budget/headroom, temporary
cost and rollback eligibility. Stored reports never substitute for current authority.

### M4: Prove the provider-evidence consumer contract

Define the abstract handoff-evidence schema and test its producer/consumer boundary, including
forward/reverse timing, topology, exact resource identities, observation time and expiry. Consume
EP-122's report when available; otherwise use clearly marked interpreter fixtures that cannot make
a real transaction ready. This child can complete its model/store/CLI contract without a native
run. EP-124's first milestone joins both completed children, binds the actual measured sequence to
the model and rejects another topology or missing reverse timing before candidate effects. Update
user documentation only for commands that actually exist, preserving the distinction between node
configuration and Nagare release transitions.


## Concrete Steps

For implementation, run from the repository root; REV is the exact implementation commit:

```bash
just test-remote REV Platform
just gate
just mutation-sweep
```

Follow current ADR 25 for the validated-world fast tier and deep monitoring/triage. Verify the
new CLI against local fixture stores with fake provider operations and capture argv to prove no
external mutation. The anticipated command surface after implementation is:

```bash
nagarectl platform replacement plan --to VERSION --downtime-budget 15m --json
nagarectl platform replacement status TRANSACTION_ID --json
```

Use an actually supported release pair; VERSION is not a promise that any historical release works.
No native/cloud run is required to accept M1–M3.


## Validation and Acceptance

Planning defaults to 900 seconds and causes no external effects. A duplicate plan returns the same
nonterminal workflow. Status explains every readiness blocker, including schema incompatibility.
The real inventory admission/store path survives an interrupted injected operation and fresh-root
reload, refuses stale heads and second writers, and skips completion only with valid evidence.
Old JSON remains inspectable or explicitly migrated; it cannot bypass inventory authority. Invalid
phase transitions fail before effects. Post-admission state never becomes eligible for automatic
rollback. EP-122 evidence is a required input before provider readiness, not a fake default timing.


## Idempotence and Recovery

Control members/evidence are immutable and published conditionally; head/progress changes follow the
same writer protocol as other inventory operations. Local material may be regenerated from history.
On interruption, inspect admitted operation proof and actual provider state; use existing resume,
proof-based close and explicit takeover policy. An unknown effect is not assumed absent. A restarted
monotonic clock cannot inherit a serialized number as remaining time: reconcile conservatively and
choose pre-write recovery when a trustworthy budget cannot be established.


## Interfaces and Dependencies

EP-123 owns replacement states, budget, evidence references, release/schema compatibility and store
binding. EP-124 owns concrete candidate resources; EP-125/126 attach fence/state evidence; EP-127
executes production deadline and terminal effects. Preserve existing `ReplacementTransaction`,
`readiness`, `beginDeadline` and cutover consumers through compatible extension or explicit migration.
Use existing canonical inventory encoding/digests; add no competing digest implementation. Before
using a dependency API or changing bounds, locate its source/docs with Mori and verify release
versions against registry/tags as required by repository instructions.


## Revision Notes

2026-10-09: Replaced the pre-inventory persistence design with one conditional authority, retained
minimal-core compatibility credit, updated command ownership and validation, and made live feasibility
a soft model dependency with an explicit join before candidate provisioning.
