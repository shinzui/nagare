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

Full plan before trimming: [123-model-resumable-replacement-upgrade-transactions-and-downtime-budgets.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/123-model-resumable-replacement-upgrade-transactions-and-downtime-budgets.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

