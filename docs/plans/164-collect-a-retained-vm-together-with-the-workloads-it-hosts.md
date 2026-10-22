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
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:39:10Z
      mode: "update"
      note: "Cascade of MasterPlan 25's 2026-10-21 refresh: held as written, superseded by the destroy-to-zero shape at reopening"
---

# Collect a retained VM together with the workloads it hosts

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current as work proceeds. It is a child of [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md).

Full plan before trimming: [164-collect-a-retained-vm-together-with-the-workloads-it-hosts.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/164-collect-a-retained-vm-together-with-the-workloads-it-hosts.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today an operator can retire every scope of a Nagare cloud context, but cannot collect, through reviews, the virtual machine that runs the cluster. Every retained workload member still consumes it: Kubernetes objects, Helm releases, the NixOS host system, the context kubeconfig and the published controller image. Kubernetes members can be collected one review at a time, which is impractical for hundreds of objects. Host and artifact members have no collection at all. After this plan, one reviewed collection can delete a retained VM and, in the same transaction, tombstone every retained member whose only physical home was that VM. The VM's proven absence is the evidence. Remote resources the workloads created stay out of scope: buckets, registry images and DNS are the subject of EP-166.

To see it working: on a disposable context with every scope retired, `nagarectl infra destroy --save-plan DIR` offers the VM as the next leaf. Its review names the VM collection plus the exact set of hosted members it will tombstone. `inventory apply DIR --yes` deletes the VM, and `inventory status` then shows those members as collected, not retained.

## Progress

- [ ] Milestone 1: define the hosted-member relation and its proof, with pure regressions.
- [ ] Milestone 2: plan and admit a VM collection with hosted descendants.
- [ ] Milestone 3: execute, recover and tombstone, proven first in EP-167's teardown-to-zero model. The native proof is part of MasterPlan 25's single cloud sequence (run G1, EP-167 M2), not a separate run.

## Surprises & Discoveries

(None yet.)

## Decision Log

- Decision (2026-10-09): Milestones 1 and 2 are pure and may start before the Pulumi cloud-foundation world exists. Milestone 3 is developed against EP-167's teardown-to-zero model. The VM's delete precondition reads the VM's identity through the checked accessor that EP-165 adds for cloud members.
  Rationale: [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md)'s 2026-10-09 finish line. Interpreters find defects, and the only cloud run is G1.
  Date: 2026-10-09

- Decision (2026-10-21): Held as written. At reopening, [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md)'s destroy-to-zero shape (its Decision Log, 2026-10-21) supersedes this plan's milestones once the operator confirms it: the one transaction tombstones every hosted member with the VM, so no milestone of this plan is implemented separately.
  Rationale: the need is a context torn down to zero, and MasterPlan 26 closed on 2026-10-14 without the Pulumi world this plan assumed.
  Date: 2026-10-21

## Outcomes & Retrospective

(Not started.)

