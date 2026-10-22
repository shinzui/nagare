---
id: 167
slug: prove-a-full-gcp-and-local-context-tears-down-to-zero-through-reviews
title: "Prove a full GCP and local context tears down to zero through reviews"
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
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:39:11Z
      mode: "update"
      note: "Cascade of MasterPlan 25's 2026-10-21 refresh: held as written, superseded by the destroy-to-zero shape at reopening"
---

# Prove a full GCP and local context tears down to zero through reviews

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current as work proceeds. It is a child of [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md).

Full plan before trimming: [167-prove-a-full-gcp-and-local-context-tears-down-to-zero-through-reviews.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/167-prove-a-full-gcp-and-local-context-tears-down-to-zero-through-reviews.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

This plan is the acceptance proof for the MasterPlan:
- A fresh, disposable, production-shaped Nagare context in GCP is torn down to zero through saved reviews only. That means every scope retired, the VM collected with its hosted workloads, cloud leaves collected in order, and protected data and authority destroyed by explicit intent.
- A local k3d context is likewise retired and its substrate removed by review.

The operator runbook then documents the sequence.

## Progress

- [ ] Milestone 1 (no dependency on EP-164–166; needs EP-173 M4's Pulumi cloud-foundation world, held and re-chartered under MasterPlan 25 at reopening): the teardown-to-zero model, the teardown runner and the target fixture.
  - The model runs the real planner, driver and adapters over the Pulumi and Kubernetes worlds, under these faults: lost acknowledgement on delete, transient read, interruption at every boundary, out-of-band deletion, and protected data without intent.
  - It asserts that every reachable stop reaches zero through supported commands, and that nothing protected is deleted without its intent.
  - The model is expected to fail until EP-164 to EP-166 land.
  - The runner is a `nagare-harness` command with its own preflight and evidence layout (MasterPlan 26 EP-168 was cancelled on 2026-10-14).
  - Acceptance: the model is green on the completed children, and each guard's mutation record fails it.
- [ ] Milestone 2, native run G1, the only cloud sequence (needs EP-164, EP-165, EP-166 and M1): a native GCP teardown to zero of a fresh disposable context that holds a revoked access grant. It follows the runbook section verbatim and closes F33's and F84's native proof.
- [ ] Milestone 3, native run L3 (needs a scripted fresh local context; `scripts/release-rehearse.sh` bootstraps one, since MasterPlan 26 EP-168 was cancelled on 2026-10-14): reviewed local teardown (retire, then substrate removal), run as the final stage of that bootstrap rather than as a separate run. Also the operator runbook section, written before G1.

## Surprises & Discoveries

(None yet.)

## Decision Log

- Decision (2026-10-09): The model comes first and has no dependency on the other children. There is exactly one cloud sequence (G1), and the local proof is a stage of EP-168's local acceptance.
  Rationale: [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md)'s fixed finish line, and [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md). MasterPlan 23's native runs were mostly discovery; here the model is red first and native runs only confirm.
  Date: 2026-10-09

- Decision (2026-10-21): Held as written. At reopening, [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md)'s destroy-to-zero shape (its Decision Log, 2026-10-21) supersedes this plan's milestones once the operator confirms it: the model, runner, L3 stage and G1 survive as the proof of that transaction.
  Rationale: the need is a context torn down to zero, and MasterPlan 26 closed on 2026-10-14 without the Pulumi world this plan assumed.
  Date: 2026-10-21

## Outcomes & Retrospective

(Not started.)

