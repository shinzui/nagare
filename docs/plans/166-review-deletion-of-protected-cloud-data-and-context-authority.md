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


## Context and Orientation

Retention and collection policy live in `cli/nagarectl/src/Nagare/Inventory/CollectionPolicy.hs`, with cloud collection eligibility in `Nagare.Inventory.CloudCollection` and the teardown entrypoint in `cli/nagarectl/app/Nagare/Cli/Runtime/CloudTeardown.hs`.

The user guide's teardown section (`docs/user/provisioning-with-pulumi.md`, "Deliberate teardown") states that data disks, snapshot protection, buckets, objects, registry artifacts, credentials, IAM, provider state and foundation ownership stay protected or retained. It also says VM collection needs a separate accepted native configuration with `deletionProtection=false`. ADR [0012](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) explains the disk's protection. ADR [0013](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) places remote state, and ADR [0022](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires explicit deletion authority.

The exact resource list of a real context is recorded in the C3 checkpoint deletion log. Those resources are what this plan must be able to remove through reviews; the deletion script is retained in the MP-23 results.


## Plan of Work

Milestone 1:
- Add a typed, per-member data-destruction intent (for example `DestroyRetainedData`). An operator supplies it as a separate input bound to exact physical identities, the latest receipt or backup evidence, and a confirmation phrase.
- It never comes from a default.
- Planning refuses it unless every named member is retained and policy-protected, and every consumer is already collected.

Milestone 2:
- Disk: review the protection change (Pulumi `protect` off) and the delete as one bound sequence.
- VM: do the same for GCE deletion protection.
- Buckets: delete all object versions with an exact object-count and generation proof.
- GCE images.

Milestone 3:
- IAM bindings, the service account and the registry repository.
- Finally, a last-authority stage that exports the inventory history, records a final tombstone in the export, then deletes the state bucket. After that the context is gone and its local context file is marked removed.
- Recovery must work from the export alone.


## Concrete Steps

Work in `cli/nagarectl`. Gate with `cabal test nagarectl-test`, `just haskell-style-check` and `python3 scripts/check-haskell-architecture.py`. Native proof is with EP-167 on a disposable context.


## Validation and Acceptance

Accepted when, on a disposable context:
- every protected member is deleted only through its explicit destruction review;
- a missing or stale intent refuses before any provider call;
- after the last-authority stage, no resource of the context remains in the project, and the exported history verifies.


## Idempotence and Recovery

Each destruction stage is a saved review with exact identities. Re-applying a converged one is a no-op. An interrupted bucket deletion resumes by proving the remaining versions, never by guessing.


## Interfaces and Dependencies

This plan owns the destruction-intent input and the last-authority stage. It depends on EP-164 for the VM's own collection and on EP-165's consumption edges for ordering.
