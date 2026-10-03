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
---

# Prove a full GCP and local context tears down to zero through reviews

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current as work proceeds. It is a child of [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md).


## Purpose / Big Picture

This plan is the acceptance proof for the MasterPlan:
- A fresh, disposable, production-shaped Nagare context in GCP is torn down to zero through saved reviews only. That means every scope retired, the VM collected with its hosted workloads, cloud leaves collected in order, and protected data and authority destroyed by explicit intent.
- A local k3d context is likewise retired and its substrate removed by review.

The operator runbook then documents the sequence.


## Progress

- [ ] Milestone 1: rehearsal harness and target fixture.
- [ ] Milestone 2: native GCP teardown to zero.
- [ ] Milestone 3: native local teardown and the operator runbook.


## Surprises & Discoveries

(None yet.)


## Decision Log

(None yet.)


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
- Add a disposable target fixture under `fixtures/inventory-release/gcp/` with its own names.
- Extend the runbook harness with a teardown runner that saves each stage, checks that it names only the context's resources, applies it, and records evidence.
- Each stage gets a 15-minute diagnostic checkpoint.

Milestone 2:
- Bootstrap the fresh context through the cluster stage.
- Then run teardown: policy, retirement, VM collection (EP-164), ordered leaf collections (EP-165), protected-data and authority destruction (EP-166).
- Finish with a read-only inventory of the project filtered to the context's names, showing nothing left.

Milestone 3:
- Repeat on a local k3d context: retire, then a reviewed substrate removal (cluster and registry).
- Write the operator runbook section "Tear down a context" in [`docs/runbooks/inventory-operations.md`](../runbooks/inventory-operations.md).


## Concrete Steps

Follow the harness runbook. Record every stage's plan and apply timings and exit codes. Never fall back to out-of-band deletion: a refusal stops the run for a report, per CLAUDE.md.


## Validation and Acceptance

Accepted when:
- the final read-only project listing for the context's names is empty;
- the exported history verifies and records every collection;
- the runbook has been executed by an independent reviewer.


## Idempotence and Recovery

Each stage is a saved review. An interrupted stage is resumed by its transaction identity. The exported history allows a clean-root restore before the last-authority stage.


## Interfaces and Dependencies

Hard dependencies: EP-164, EP-165 and EP-166 (the whole child plans).
