---
id: 25
slug: reviewed-full-context-teardown-with-vm-workload-collection
title: "Reviewed full-context teardown with VM workload collection"
kind: master-plan
created_at: 2026-10-03T22:26:51Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-03T22:26:51Z
---

# Reviewed full-context teardown with VM workload collection

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

After this initiative, an operator can remove a whole Nagare context through saved, reviewed transactions, with no out-of-band provider command. That means a production-shaped GCP context (VM, cluster, data, buckets, DNS, IAM and its own state) or a local k3d context.

The sequence the operator runs:
1. Retire every scope; MP-23 already supports this natively.
2. Collect the VM together with the workloads it hosts in one review.
3. Collect the remaining cloud leaves in real dependency order.
4. Destroy protected data and the context's final authority, each only through an explicit, typed intent.

The scope boundary:
- **Included:** cloud and local contexts created by `nagarectl`.
- **Excluded:** resources shared with other contexts (the parent DNS zone, the reusable Nix builder); upgrades; any automatic or default deletion of data.

This initiative follows MasterPlan 23 ([`23-make-managed-resources-first-class-through-typed-scoped-inventories.md`](23-make-managed-resources-first-class-through-typed-scoped-inventories.md)). On 2026-10-03 the operator decided that MP-23 proves exact cleanup on a perimeter-only context plus full-context retirement. Full-context VM collection was deferred to this plan.


## Decomposition Strategy

The MP-23 C3 checkpoint teardown (`mp23-c3`, project `tan-ng-labs`) found three independent obstacles once every scope was retired. They are recorded in finding F40 of `docs/audits/mp23-findings.md`:
- retained workload consumers pin the VM;
- the collection assessment cannot observe retained cloud members, and Pulumi ordering is treated as consumption;
- protected data and authority have no reviewed deletion at all.

Each obstacle is a separate functional concern with its own regression surface, so each gets one child plan. A fourth child owns the native end-to-end proof, because it needs all three.

Alternatives considered:
- Collecting each Kubernetes object one review at a time before the VM. Rejected: hundreds of reviews, and host and artifact members still have no collection.
- Adding an unreviewed "destroy context" command. Rejected: it contradicts ADR 22's reviewed-transition principle and the fail-closed project guard.

Relevant ADRs:
- [0022](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): retirement, collection and identity rules.
- [0009](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md): the project guard.
- [0012](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md): data disk protection.
- [0013](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md): remote state.
- [0006](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md): an admitted context cannot change platform version, so acceptance uses a fresh context.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Collect a retained VM together with the workloads it hosts | [docs/plans/164-collect-a-retained-vm-together-with-the-workloads-it-hosts.md](../plans/164-collect-a-retained-vm-together-with-the-workloads-it-hosts.md) | None | EP-2 | Not Started |
| 2 | Observe retained cloud members and order cloud collection by real consumption | [docs/plans/165-observe-retained-cloud-members-and-order-cloud-collection-by-real-consumption.md](../plans/165-observe-retained-cloud-members-and-order-cloud-collection-by-real-consumption.md) | None | EP-1 | Not Started |
| 3 | Review deletion of protected cloud data and context authority | [docs/plans/166-review-deletion-of-protected-cloud-data-and-context-authority.md](../plans/166-review-deletion-of-protected-cloud-data-and-context-authority.md) | EP-1, EP-2 | None | Not Started |
| 4 | Prove a full GCP and local context tears down to zero through reviews | [docs/plans/167-prove-a-full-gcp-and-local-context-tears-down-to-zero-through-reviews.md](../plans/167-prove-a-full-gcp-and-local-context-tears-down-to-zero-through-reviews.md) | EP-1, EP-2, EP-3 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

- EP-1 (VM with hosted workloads) and EP-2 (observation and real consumption) can proceed in parallel. Both change teardown eligibility in `Runtime/CloudTeardown.hs` and `Status.consumersOf`, so they are soft-dependent and should land in either order with one shared regression.
- EP-3 (protected data and authority) needs EP-1, because the VM must be collectable before its disk and deletion protection matter, and EP-2, because protected leaves are reached only in real consumption order.
- EP-4 needs all three, because its acceptance is a teardown to zero.


## Integration Points

- **Teardown eligibility** (`cli/nagarectl/app/Nagare/Cli/Runtime/CloudTeardown.hs`, `Nagare.Inventory.Status.consumersOf`). EP-1 adds hosted-member exemption and EP-2 replaces ordering edges with consumption edges. EP-2 owns the consumption contract; EP-1 consumes it. Check early with one regression where a VM's only consumers are hosted members and the apex record has no consumers.
- **Collection proof and tombstones** (`Nagare.Inventory.Plan.Changes.buildCollectionProofs`, the journal and `RetainedIncarnation`). EP-1 defines hosted-member tombstones, and EP-3 reuses the same proof for destruction stages. This is a candidate for an ADR 22 amendment.
- **Cloud registration bundle** (`infra/pulumi/src/resourceDeclarations.ts`, `Nagare.Inventory.Cloud`). EP-2 owns the edge-kind change.
- **Destruction intent input.** EP-3 owns it. It deserves an ADR, because it is the only path by which Nagare deletes durable data.


## Progress

Created 2026-10-03 as the follow-up to MP-23's teardown decision. No child has started. The MP-23 C3 checkpoint already proved natively, on development builds of `24320d82`–`07d203ad`: policy, retirement of every platform scope, and cloud-scope retirement.


## Surprises & Discoveries

(None yet.)


## Decision Log

- 2026-10-03 (operator, via MP-23): MP-23 ships perimeter-only exact cleanup plus full-context retirement. Full-context VM collection and protected-data destruction move here. Rationale: they are new capabilities with design risk. The release's safety-use gate does not need them, because a disposable context can be removed with operator-approved, bounded provider commands, as the C3 checkpoint was.
- 2026-10-03: Decomposed by obstacle (hosted workloads, observation and consumption, protected data), plus one acceptance child. Rationale: each obstacle has an independent regression surface.


## Outcomes & Retrospective

(Not started.)
