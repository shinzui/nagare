---
id: 166
slug: review-deletion-of-protected-cloud-data-and-context-authority
title: "Review deletion of protected cloud data and context authority"
kind: exec-plan
created_at: 2026-10-03T22:27:20Z
master_plan: "docs/masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-03T22:27:20Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Review deletion of protected cloud data and context authority

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current as work proceeds. It is a child of [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md).

Full plan before trimming: [166-review-deletion-of-protected-cloud-data-and-context-authority.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/166-review-deletion-of-protected-cloud-data-and-context-authority.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Some cloud members are deliberately protected:
- the data disk (`protect: true`) and its snapshot policy;
- GCE deletion protection on the VM;
- the backup and image buckets, which hold versioned objects;
- the Artifact Registry repository, GCE images, the service account and its IAM bindings;
- the context's foundation: the state bucket that holds Pulumi state and the inventory history itself.

Teardown reports these as `retention-policy` and `unsupported-collection-transport` and never deletes them. That is correct by default. An operator who really wants a disposable context gone still has no reviewed way to remove them, so the MP-23 C3 checkpoint had to be deleted out of band (operator-approved, 2026-10-03). After this plan, an explicit, separately confirmed review can delete protected data and finally the context's own authority. Data deletion always requires a typed intent naming the data and evidence that it is unneeded or backed up elsewhere.

## Progress

- [ ] Milestone 1: typed data-destruction intent and its review shape, with its refusals (missing, stale or unbound intent; a live consumer). This is pure and may start at once. A new ADR records the intent as the only path by which Nagare deletes durable data.
- [ ] Milestone 2: protected disk, VM deletion protection, buckets and images.
- [ ] Milestone 3: IAM, service account and registry; the last-authority stage (state bucket and inventory history).

## Surprises & Discoveries

(None yet.)

## Decision Log

- Decision (2026-10-09): Milestones 2 and 3 are developed against EP-167's teardown-to-zero model, with a fault for protected data without intent. Their native proof is part of run G1 (EP-167 M2). Delete preconditions use EP-165's cloud identity accessor.
  Rationale: [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md)'s 2026-10-09 finish line.
  Date: 2026-10-09

## Outcomes & Retrospective

(Not started.)

