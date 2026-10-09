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
---

# Prove a full GCP and local context tears down to zero through reviews

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current as work proceeds. It is a child of [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md).


## Purpose / Big Picture

This plan is the acceptance proof for the MasterPlan:
- A fresh, disposable, production-shaped Nagare context in GCP is torn down to zero through saved reviews only. That means every scope retired, the VM collected with its hosted workloads, cloud leaves collected in order, and protected data and authority destroyed by explicit intent.
- A local k3d context is likewise retired and its substrate removed by review.

The operator runbook then documents the sequence.


## Progress

- [ ] Milestone 1 (no dependency on EP-164–166; needs MasterPlan 26 EP-173 M4's Pulumi cloud-foundation world): the teardown-to-zero model, the teardown runner and the target fixture.
  - The model runs the real planner, driver and adapters over the Pulumi and Kubernetes worlds, under these faults: lost acknowledgement on delete, transient read, interruption at every boundary, out-of-band deletion, and protected data without intent.
  - It asserts that every reachable stop reaches zero through supported commands, and that nothing protected is deleted without its intent.
  - The model is expected to fail until EP-164 to EP-166 land.
  - The runner is a `nagare-harness` command sharing EP-168's preflight and evidence layout.
  - Acceptance: the model is green on the completed children, and each guard's mutation record fails it.
- [ ] Milestone 2, native run G1, the only cloud sequence (needs EP-164, EP-165, EP-166 and M1): a native GCP teardown to zero of a fresh disposable context that holds a revoked access grant. It follows the runbook section verbatim and closes F33's and F84's native proof.
- [ ] Milestone 3, native run L3 (needs MasterPlan 26 EP-168 M1): reviewed local teardown (retire, then substrate removal), run as the final stage of `nagare-harness local-acceptance` rather than as a separate run. Also the operator runbook section, written before G1.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision (2026-10-09): The model comes first and has no dependency on the other children. There is exactly one cloud sequence (G1), and the local proof is a stage of EP-168's local acceptance.
  Rationale: [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md)'s fixed finish line, and [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md). MasterPlan 23's native runs were mostly discovery; here the model is red first and native runs only confirm.
  Date: 2026-10-09


## Outcomes & Retrospective

(Not started.)


## Context and Orientation

The isolated operator-root harness, the cloud context inputs, the builder key, the Grafana Secret and the stage list are documented in [`docs/runbooks/native-verification-harness.md`](../runbooks/native-verification-harness.md).

MP-23's C3 checkpoint (`mp23-c3`, names `*-c3-1003`, project `tan-ng-labs`) proved these teardown steps natively with the fixes in MP-23 F39 and F40:
- the policy stage;
- retirement of every platform scope, including cycles, contribution targets and host and artifact members;
- retirement of the cloud scope.

It then stopped at collection, where this MasterPlan begins. Its stage timings and evidence are in the runbook and in `docs/audits/mp23-findings.md` (F38–F40).

Cloud mutations need one operator approval for a bounded, rehearsed sequence (CLAUDE.md), and every stage must stay inside the active context's project (ADR [0009](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)).


## Plan of Work

Milestone 1:
- Write the teardown-to-zero model first, in the recovery model's style (`cli/nagarectl/test/Nagare/Test/World/`).
  - It seeds a context's accepted history from the resource list in `docs/audits/mp23-independent-results-2026-10-07/drivers-83124396/disposal/`.
  - It drives the real staged teardown over EP-173 M4's Pulumi cloud-foundation world and the Kubernetes world, with the faults listed in Progress.
- Add a disposable target fixture under `fixtures/inventory-release/gcp/` with its own names.
- Add the teardown runner as a `nagare-harness` command. It runs EP-168's preflight, then for each stage it saves the review, checks that the review names only the context's resources, applies it, and records evidence.
- Each stage gets a 15-minute diagnostic checkpoint.

Milestone 2:
- Bootstrap the fresh context through the cluster stage.
- Then run teardown: policy, retirement, VM collection (EP-164), ordered leaf collections (EP-165), protected-data and authority destruction (EP-166).
- Finish with a read-only inventory of the project filtered to the context's names, showing nothing left.

Milestone 3:
- On a local k3d context: retire, then a reviewed substrate removal (cluster and registry). Deliver it as the final stage of MasterPlan 26 EP-168's `local-acceptance`, so it runs every release.
- Write the operator runbook section "Tear down a context" in [`docs/runbooks/inventory-operations.md`](../runbooks/inventory-operations.md).


## Concrete Steps

Follow the harness runbook. Record every stage's plan and apply timings and exit codes. Never fall back to out-of-band deletion: a refusal stops the run for a report, per CLAUDE.md.


## Validation and Acceptance

Accepted when:
- the final read-only project listing for the context's names is empty;
- the exported history verifies and records every collection;
- run G1 followed the runbook section verbatim (the separate independent re-execution was dropped on 2026-10-09: one cloud sequence proves both);
- the local acceptance's final stage leaves no cluster, registry or store behind.


## Idempotence and Recovery

Each stage is a saved review. An interrupted stage is resumed by its transaction identity. The exported history allows a clean-root restore before the last-authority stage.


## Interfaces and Dependencies

Hard dependencies, by milestone:
- M1: MasterPlan 26 EP-173 M4 (the Pulumi cloud-foundation world).
- M2: EP-164, EP-165, EP-166 and this plan's M1.
- M3: MasterPlan 26 EP-168 M1.

M3 also hands EP-168 its final stage.
