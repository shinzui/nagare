---
id: 164
slug: collect-a-retained-vm-together-with-the-workloads-it-hosts
title: "Collect a retained VM together with the workloads it hosts"
kind: exec-plan
created_at: 2026-10-03T22:27:20Z
master_plan: "docs/masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-03T22:27:20Z
---

# Collect a retained VM together with the workloads it hosts

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current as work proceeds. It is a child of [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md).


## Purpose / Big Picture

Today an operator can retire every scope of a Nagare cloud context, but cannot collect, through reviews, the virtual machine that runs the cluster. Every retained workload member still consumes it: Kubernetes objects, Helm releases, the NixOS host system, the context kubeconfig and the published controller image. Kubernetes members can be collected one review at a time, which is impractical for hundreds of objects. Host and artifact members have no collection at all. After this plan, one reviewed collection can delete a retained VM and, in the same transaction, tombstone every retained member whose only physical home was that VM. The VM's proven absence is the evidence. Remote resources the workloads created stay out of scope: buckets, registry images and DNS are the subject of EP-166.

To see it working: on a disposable context with every scope retired, `nagarectl infra destroy --save-plan DIR` offers the VM as the next leaf. Its review names the VM collection plus the exact set of hosted members it will tombstone. `inventory apply DIR --yes` deletes the VM, and `inventory status` then shows those members as collected, not retained.


## Progress

- [ ] Milestone 1: define the hosted-member relation and its proof, with pure regressions.
- [ ] Milestone 2: plan and admit a VM collection with hosted descendants.
- [ ] Milestone 3: execute, recover and tombstone; native proof on a disposable context.


## Surprises & Discoveries

(None yet.)


## Decision Log

(None yet.)


## Outcomes & Retrospective

(Not started.)


## Context and Orientation

Nagare records cloud and cluster state in a typed inventory (ADR [0022](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)). Each owner *scope* declares managed resources. A *review* binds exact native inputs; `inventory apply` executes only a saved review. *Retirement* (`RetireScope` with `RetainResources`) removes a scope from the desired inventory without deleting anything. Its members become *retained incarnations*, keyed by owner, scope revision and observed physical identity (`RetainedIncarnation` in `cli/nagarectl/src/Nagare/Inventory/Store.hs`). *Collection* (`CollectRetained`) is the separate reviewed deletion of one retained member. ADR 22 requires exact identity, dependency checks and explicit deletion authority for it.

Where the relevant code lives:
- `cli/nagarectl/app/Nagare/Cli/Runtime/CloudTeardown.hs`: the staged teardown entrypoint (`infra destroy --save-plan`). It does policy verification, then cloud-scope retirement, then one eligible exact leaf collection per invocation. Eligibility uses `cloudCollectionEligible`, `supportsRetainedCollection` and `consumersOf` (`Nagare.Inventory.Status`).
- `cli/nagarectl/src/Nagare/Inventory/Plan/Lifecycle.hs`: validates `ApproveCollection` decisions.
- `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs`: builds collection proofs (`buildCollectionProofs`).
- `cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`: re-observes retained and collected members before admission.
- `cli/nagarectl/app/Nagare/Cli/Inventory/Execution.hs` and `CloudHistory.hs`: build the execution adapters for retained cloud members.
- `cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs`: the Knative controller-descendant collection (`inventory collect --controller-descendants`). It is the closest existing precedent, collecting an owner and its exclusive descendants in one review.

Native evidence that motivates this plan comes from the MP-23 C3 checkpoint, recorded in MP-23 finding F40 (`docs/audits/mp23-findings.md#f40`). After every scope was retired, `inventory gc --plan` reported each of the 26 cloud members as blocked by `dependent-consumers`. The retained `bootstrap-stamp` ConfigMap consumes every cloud member, and the retained host system consumes the VM.


## Plan of Work

Milestone 1. Define a pure relation, *hosted by*, from a retained VM incarnation to the retained members whose physical existence is wholly contained in that VM:
- Kubernetes and Helm members of the cluster whose node runs on that instance.
- The host system (`HostExecutor`) bound to that instance.
- Artifacts whose only physical location is the VM or its cluster.

The relation comes from accepted history, not from live observation. Each member's scope and address bind it to the cluster, and the cluster's kubeconfig and host scopes bind it to the instance URN. Workstation-local artifacts, such as the kubeconfig file, need a decision recorded here: collect the file with the context, or leave it to EP-166's authority stage. Regressions: a member of another cluster, or a member that also consumes a non-hosted producer, is not hosted.

Milestone 2. Extend teardown eligibility so a retained VM whose only consumers are its hosted members is a leaf. Its review carries one `RetireResource` on the instance plus a hosted-member set bound into the collection proof (owner, revision, physical). Admission re-observes the VM's exact incarnation. It does not demand provider observation of hosted members, which may already be unreachable. It binds the hosted set to the accepted history digest instead, so a later change to that history refuses the review.

Milestone 3. Execution deletes the instance through the saved Pulumi plan, as today. Completion requires the instance's proven absence. Then the journal records collection tombstones for every hosted member, with the instance absence proof as their evidence. Recovery of an ambiguous delete must prove absence and never resubmit the delete. Prove natively on a disposable GCP context (with EP-167). The VM collection removes the VM and tombstones its hosted members; a repeated apply is a no-op; the next teardown invocation offers the network leaves.


## Concrete Steps

Work in `cli/nagarectl`. Build with `cabal build exe:nagarectl` and test with `cabal test nagarectl-test`. Before each commit, run `just haskell-style-check` and `python3 scripts/check-haskell-architecture.py` from the repository root. Native checks use the isolated operator-root harness in [`docs/runbooks/native-verification-harness.md`](../runbooks/native-verification-harness.md).


## Validation and Acceptance

Accepted when a reviewed VM collection on a disposable context:
- deletes exactly the instance;
- tombstones exactly the hosted set, which `inventory status` reports as collected;
- refuses when the hosted set or history changed after review;
- recovers an interrupted delete by proving absence;
- leaves every non-hosted retained member untouched.


## Idempotence and Recovery

Planning is read-only. A saved review that already converged is a no-op on re-apply. An interrupted collection is recovered only through `inventory resume` with its recorded transaction identity.


## Interfaces and Dependencies

This plan defines the hosted-member relation and the VM collection proof shape. EP-165 consumes the collection-eligibility changes, and EP-167 runs the native acceptance. No hard dependencies.
