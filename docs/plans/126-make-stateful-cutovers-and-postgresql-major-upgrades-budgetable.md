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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:17:13Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Make stateful cutovers and PostgreSQL major upgrades budgetable

This ExecPlan is a living document. Keep its living sections current and promote durable decisions
into ADRs. It owns replacement-specific transfer over existing inventory and data primitives.

Full plan before trimming: [126-make-stateful-cutovers-and-postgresql-major-upgrades-budgetable.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/126-make-stateful-cutovers-and-postgresql-major-upgrades-budgetable.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

An operator can see every retained item that must move to a fresh candidate cluster, rehearse an
independent copy, and obtain measured evidence that a final copy after production writes stop fits
the requested replacement budget. Unknown or inconsistent state blocks cutover while old still serves.

MP-23 already supplies typed resource ownership, verified database/volume backups and isolated restore.
Its [PostgreSQL major-upgrade drill](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/section4-3b59bcb7/README.md)
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
holds the cutover-facing contract. The [source-destruction recovery result](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/section2-drill-3ae20f8c/result.json)
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

- Decision (operator, 2026-10-09): On hold. [MasterPlan 21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md) runs only EP-122's measured IP-handoff spike until the operator decides, from its numbers, whether to resume, re-scope or cancel the remaining children. Do not start this plan's remaining milestones before that decision. The PostgreSQL major-upgrade procedure credited from MasterPlan 23 checklist section 4 remains the supported path meanwhile.
  Rationale: Replacement has the largest cloud surface of the follow-up plans, and its downtime budget's feasibility is unmeasured.
  Date: 2026-10-09

## Outcomes & Retrospective

The cutover-facing contract and reusable data/major-upgrade inputs exist. Complete transfer coverage,
explicit cross-cluster adapters, measurements and deadline-aware finalization remain. This refresh
claims no new implementation; EP-126 remains In Progress.

