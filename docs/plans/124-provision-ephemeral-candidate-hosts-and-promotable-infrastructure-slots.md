---
id: 124
slug: provision-ephemeral-candidate-hosts-and-promotable-infrastructure-slots
title: "Provision ephemeral candidate hosts and promotable infrastructure slots"
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
      at: 2026-09-16T04:38:37Z
      mode: "update"
      note: "Refresh candidate provisioning against current guarded plan and identity boundaries"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T19:45:59Z
      mode: "update"
      note: "Refresh MP-21 as optional inventory-backed replacement after MP-23 upgrade drills"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Provision ephemeral candidate hosts and promotable infrastructure slots

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [124-provision-ephemeral-candidate-hosts-and-promotable-infrastructure-slots.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/124-provision-ephemeral-candidate-hosts-and-promotable-infrastructure-slots.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

**Current scope (2026-10-09).** This child implements optional machine/cluster replacement after
MP-23, not a prerequisite for ordinary node or PostgreSQL upgrades. The
[production checklist](../releases/production-readiness-checklist.md) credits those completed drills.
MP-23's typed scopes, reviewed native effects, conditional shared history, receipt verification and
proof-based recovery are the implementation foundation. Replacement phase records never grant
mutation authority independently of inventory admission. Proposed replacement commands below remain
unavailable until their owned implementation and acceptance are complete.

Nagare can temporarily provision a second, isolated machine beside the live machine without
adding a load balancer or changing wildcard DNS. The candidate boots the target NixOS image,
has its own boot and data disks and identity, is reachable by the operator through IAP, and
cannot receive public HTTP traffic. When no replacement is active, only the promoted machine
and its disks remain, preserving the one-machine steady-state cost model.

An operator sees this through `nagarectl platform replacement prepare <transaction-id>` and
`status`: preparation creates the inactive slot, reports its exact GCP resource identities,
and leaves the current reserved IP on the old slot. A Pulumi preview proves that adopting
the slot model does not replace the existing VM or disk.

Since this plan was drafted, Nagare 0.3.0 made reviewed Pulumi plans and apply receipts the guarded
infrastructure boundary, added explicit staged-host identity, and added context-safe kubeconfig
fetching. Candidate preparation must extend those mechanisms with replacement bindings; it must not
introduce a second direct `pulumi up`, ambient-host, or ambient-kubeconfig path.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Refactor the singleton Pulumi component into active and optional inactive host slots
```text
  while preserving existing resource URNs and physical names.
```
- [ ] Add candidate-only network tags, IAP access, independent protected storage, and
```text
  least-privilege candidate identity.
```
- [ ] Add candidate host-flake staging and explicit active/candidate Pulumi outputs.
- [ ] Implement idempotent prepare/reconcile operations behind the replacement transaction.
- [ ] Add mock-provider, preview, migration, and disposable-project verification.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: `NagareNetwork` currently opens ports 80 and 443 to every VM on the subnet;
  creating a candidate with an ephemeral external address would therefore expose it even
  though DNS still names the old machine.
  Evidence: `infra/pulumi/src/components/NagareNetwork.ts` declares `fw-web` without target
  tags, and `NagareInstance.ts` always creates an access configuration.
- Observation: The current VM service account can push images and administer backup objects.
  Reusing it on a rehearsal candidate would let candidate workloads overwrite backups or
  publish images.
  Evidence: `NagarePerimeter.ts` grants Artifact Registry writer and backup-bucket
  `roles/storage.objectAdmin` to `nagare-node`.
- Observation: The current k3s datastore lives on the boot disk while application persistent
  volumes live on the attached data disk.
  Evidence: the NixOS k3s module uses `/var/lib/rancher`, and the local-path provisioner is
  rooted at `/var/lib/nagare/local-path`.
- Observation: the current tree now has reusable guarded infrastructure and target-identity
  primitives that were absent at plan creation.
  Evidence: `Nagare.Infra.Plan` owns private retained plan bundles,
  `Nagare.Platform.PulumiReceipt` owns apply/recovery evidence, `Nagare.Host.Config` reads the staged
  host name used by an upgrade, and `Nagare.Cluster.Kubeconfig` fetches and normalizes an explicitly
  selected context kubeconfig.

## Decision Log

Record every decision made while working on the plan.

- Decision: Represent infrastructure as one active slot and at most one inactive candidate
  slot within the existing Pulumi stack.
  Rationale: Slots make promotion and the next replacement explicit while retaining one
  steady-state VM; a second stack would duplicate shared DNS, registry, buckets, and state.
  Date: 2026-09-13
- Decision: Give the candidate a fresh boot disk and an independent data disk; never attach
  the live data disk to it.
  Rationale: The candidate must be safe to destroy, and the old host must remain a complete
  rollback target until finalization.
  Date: 2026-09-13
- Decision: Give the candidate an ephemeral egress address but gate public web ingress by an
  `nagare-active` network tag; allow IAP SSH to both slot tags.
  Rationale: A fresh host needs outbound access during preparation, but no request should
  reach candidate ports 80/443 before the deadline-bound promotion.
  Date: 2026-09-13
- Decision: Use a candidate-specific service account with Artifact Registry and backup
  object read access only; add any narrowly scoped DNS challenge permission only if the
  fenced bootstrap plan proves it necessary.
  Rationale: Rehearsal must not be able to push images, overwrite backups, or mutate unrelated
  project state.
  Date: 2026-09-13
- Decision: Implement the exact static-IP attachment topology proven by ExecPlan 122 and do
  not encode a speculative provider sequence before that proof passes.
  Rationale: Pulumi ownership and GCE attachment behavior must be demonstrated with forward
  and reverse handoff before production infrastructure depends on it.
  Date: 2026-09-13
- Decision: Bind candidate preview/apply evidence to the replacement transaction by extending the
  existing reviewed-plan and Pulumi-receipt contracts.
  Rationale: provider execution and ambiguous crash recovery need the same private, immutable,
  operator-reviewable evidence already required by ADR 18; a parallel unchecked apply path would
  weaken the platform boundary.
  Date: 2026-09-15

- Decision (2026-10-09): On hold with [MasterPlan 21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md). If the plan resumes, candidate VM, disk and address identity binding reuses the cloud physical identity that [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md)'s EP-165 adds (recorded at creation, read through ADR 27's checked accessor). This plan does not build its own.
  Rationale: Build the primitive once, with a single owner.
  Date: 2026-10-09

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)

