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
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Fixed finish line; model-first EP-167; one cloud sequence G1; EP-165 owns cloud identity; local teardown as EP-168 stage"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:39:10Z
      mode: "update"
      note: "Refresh: EP-173 M3-M4 first at reopening, L3 stage on the release rehearsal, G1 outside tan-ng-labs, destroy-to-zero reopening shape recorded; stays Held"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:39:10Z
      verdict: "changes-requested"
      note: "Held plan depends on a Pulumi world MP-26 never built; item 7 names a cancelled command; G1 named the intranet's project; trigger not fired; four-child shape heavier than the to-zero need"
---

# Reviewed full-context teardown with VM workload collection

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [25-reviewed-full-context-teardown-with-vm-workload-collection.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Vision & Scope

After this initiative, an operator can remove a whole Nagare context through saved, reviewed
transactions, with no out-of-band provider command. That covers a production-shaped GCP context (VM,
cluster, data, buckets, DNS, IAM and its own state) and a local k3d context.

The sequence the operator runs:
1. Retire every scope. MP-23 already supports this natively, including a revoked access grant since
   F84's fix in v0.4.0.
2. Collect the VM together with the workloads it hosts, in one review.
3. Collect the remaining cloud leaves in real dependency order.
4. Destroy protected data and the context's final authority, each only through an explicit, typed
   intent.

The scope boundary:
- **Included:** cloud and local contexts created by `nagarectl`.
- **Excluded:** resources shared with other contexts (the parent DNS zone, the reusable Nix builder);
  upgrades; any automatic or default deletion of data.

**Order (operator, 2026-10-09; refreshed 2026-10-21).** The plan was to run after
[MasterPlan 26](26-make-platform-changes-and-releases-routine-after-the-inventory-release.md) had
delivered the Pulumi cloud-foundation world (EP-173 M4). MasterPlan 26 closed on 2026-10-14 without
it, and EP-173 M3–M4 are re-chartered when this plan reopens (its Decision Log, 2026-10-14). So the
world is this plan's first work at reopening, not a prerequisite another plan delivers. Nothing in
this plan is worked on while it is held.

Why it matters beyond tidiness:
- Every MP-23 acceptance context (`mp23-c3i` to `mp23-c3m`) was disposed by exact-name provider
  deletes from its stack export.
- F33 (the cloud-collection identity recheck) and F84 (retiring a revoked access grant) remain
  Verifying, because no staged teardown has reached them natively.
- Once local teardown is a reviewed stage of the release rehearsal, every release exercises it.

### Finish line (fixed 2026-10-09)

The rules of the [production readiness checklist](../releases/production-readiness-checklist.md)
apply:
- **Fixed scope.** No item is added. A new finding that does not risk data loss goes to the deferral
  ledger with the operator's approval.
- **Evidence ticks a box.**
- **Only the native runs listed here.** A defect found in one stops the run. Its fix lands with a
  model regression that fails on the pre-fix source, and then the run is repeated once.

- [ ] 1. Cloud consumption edges are distinct from Pulumi ordering edges. Regressions in the F40 shape
      pass: the apex DNS record has no consumers, firewalls are not consumers of DNS records, and a
      subnet still blocks its network (EP-165 M2).
- [ ] 2. The physical identities of cloud members (VM, disks, address, buckets, images) are recorded
      at creation and read through ADR 27's one checked accessor. ADR 27 §4 is amended (EP-165 M1).
- [ ] 3. The collection assessment observes retained cloud members exactly, over the Pulumi
      cloud-foundation world (EP-165 M1).
- [ ] 4. One review collects a retained VM and tombstones exactly its hosted members, and refuses when
      the hosted set or the accepted history changed after review (EP-164 M1–M2).
- [ ] 5. Protected data and the context's final authority are destroyed only through a typed,
      identity-bound destruction intent. A missing or stale intent refuses before any provider call.
      A new ADR records this as the only path by which Nagare deletes durable data (EP-166).
- [ ] 6. A teardown-to-zero model runs the real planner, driver and adapters over the Pulumi and
      Kubernetes worlds, under these faults: lost acknowledgement on delete, transient read,
      interruption at every boundary, an out-of-band deletion, and protected data without intent.
      Every reachable stop reaches zero through supported commands, and nothing protected is deleted
      without its intent. Mutation records show each guard is observed (EP-167 M1).
- [ ] 7. **Native run L3 (cp3).** A local context is torn down to zero by review, as the final stage
      of the release rehearsal's disposable local context (`scripts/release-rehearse.sh`; MasterPlan
      26's `nagare-harness local-acceptance` was cancelled on 2026-10-14). This adds a stage to an
      existing run, not a separate run (EP-167 M3).
- [ ] 8. **Native run G1 (one bounded cloud sequence).** A fresh disposable GCP context, holding a
      revoked access grant, is torn down to zero through saved reviews only. A read-only listing of
      the project filtered to the context's names is empty, and the exported history verifies and
      records every collection. The run also closes F33's and F84's native proof (EP-167 M2).
- [ ] 9. The runbook section "Tear down a context" in
      [`docs/runbooks/inventory-operations.md`](../runbooks/inventory-operations.md) is written before
      run G1, and G1 follows it verbatim.

G1 is the only cloud sequence. The operator approves it once, when item 8 is reached, after the
preflight has passed (MasterPlan 26 EP-168 was cancelled on 2026-10-14, so the runner carries its
own). G1 runs in a project that holds no context in real use. `tan-ng-labs` hosts the intranet
(`nagare-intranet`, in use since 2026-10-12), so it is excluded: the project guard is per project,
not per context. The operator names the project when item 8 is reached.

## Decomposition Strategy

The MP-23 C3 checkpoint teardown (`mp23-c3`, project `tan-ng-labs`) found three independent
obstacles once every scope was retired, recorded in finding F40 of `docs/audits/mp23-findings.md`:
- retained workload consumers pin the VM;
- the collection assessment cannot observe retained cloud members, and Pulumi ordering is treated as
  consumption;
- protected data and authority have no reviewed deletion at all.

Each obstacle is a separate concern with its own regression surface, so each gets one child plan.
A fourth child owns the teardown model, the local stage and the single cloud proof.

Revision 2026-10-09:
- **Interpreter-first ([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).**
  EP-167's model milestone has no dependency and is written early. It is expected to fail until
  EP-164 to EP-166 land, so the children are developed against it.
- **Shared cloud identity.** The cloud identity primitive, which MasterPlan 21's EP-124 also needs,
  is owned here by EP-165, and is built once.

Alternatives considered:
- Collecting each Kubernetes object one review at a time before the VM. Rejected: hundreds of
  reviews, and host and artifact members still have no collection.
- Adding an unreviewed "destroy context" command. Rejected: it contradicts ADR 22's
  reviewed-transition principle and the fail-closed project guard.
- A second, MP-25-specific Pulumi fake. Rejected: EP-173 M4's cloud-foundation world is extended
  instead.

**Reopening shape (2026-10-21, Decision Log).** When the trigger fires, the need is a context torn
down to zero, not a general per-leaf cloud collection. The plan is then re-chartered as one reviewed,
intent-bound destroy-to-zero transaction, which is not the unreviewed command rejected above. It
drops the leaf ordering, the VM as a separately collected leaf and identity at creation, and keeps
the typed destruction intent, the identity recheck before effect and one run of each kind. The four
children stay Held as written until the operator confirms that shape at reopening.

Relevant ADRs:
- [0022](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): retirement,
  collection and identity rules.
- [0027](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md):
  identity at creation, checked accessor. EP-165 lifts §4's cloud limit.
- [0009](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md): the project
  guard.
- [0012](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md): data disk
  protection.
- [0013](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md):
  remote state.
- [0025](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): interpreters
  find defects.
- [0006](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md): acceptance
  uses a fresh context.

## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 164 | Collect a retained VM together with the workloads it hosts | [docs/plans/164-collect-a-retained-vm-together-with-the-workloads-it-hosts.md](../plans/164-collect-a-retained-vm-together-with-the-workloads-it-hosts.md) | None | EP-165 | Held (operator, 2026-10-10); folded into the destroy-to-zero shape at reopening (Decision Log, 2026-10-21) |
| 165 | Observe retained cloud members and order cloud collection by real consumption | [docs/plans/165-observe-retained-cloud-members-and-order-cloud-collection-by-real-consumption.md](../plans/165-observe-retained-cloud-members-and-order-cloud-collection-by-real-consumption.md) | EP-173 M4 | EP-164 | Held (operator, 2026-10-10); folded into the destroy-to-zero shape at reopening (Decision Log, 2026-10-21) |
| 166 | Review deletion of protected cloud data and context authority | [docs/plans/166-review-deletion-of-protected-cloud-data-and-context-authority.md](../plans/166-review-deletion-of-protected-cloud-data-and-context-authority.md) | EP-164, EP-165 | None | Held (operator, 2026-10-10); M1's typed intent and ADR survive into the destroy-to-zero shape at reopening (Decision Log, 2026-10-21) |
| 167 | Prove a full GCP and local context tears down to zero through reviews | [docs/plans/167-prove-a-full-gcp-and-local-context-tears-down-to-zero-through-reviews.md](../plans/167-prove-a-full-gcp-and-local-context-tears-down-to-zero-through-reviews.md) | EP-173 M4, EP-164, EP-165, EP-166 | None | Held (operator, 2026-10-10); its model, runner, L3 stage and G1 become the proof of the destroy-to-zero shape at reopening (Decision Log, 2026-10-21) |

Milestone granularity: EP-165 needs EP-173 M4 for M1 only; EP-166 needs EP-164 and EP-165 for
M2–M3 only; EP-167 M1 needs EP-173 M4, M2 needs EP-164 to EP-166, and M3 needs only the release
rehearsal's disposable local context (`scripts/release-rehearse.sh`; MasterPlan 26 EP-168 was
cancelled on 2026-10-14). EP-173 M4 is the Pulumi cloud-foundation world, held since MasterPlan 26
closed without it on 2026-10-14 and re-chartered here at reopening.

Status values: Not Started, In Progress, Complete, Cancelled, Held. A held plan is not worked on
until the operator reopens it.

## Progress

2026-10-21: held since 2026-10-10. No child has started, and the trigger has not fired.
- **Trigger check.** A read-only listing of the active project `tan-ng-labs` on 2026-10-21 shows
  only the intranet: `nagare-intranet` and its data disk, the stopped `nix-builder-intranet`, the
  three intranet buckets and one address. No disposable cloud context exists, none was created since
  the hold, and EP-183's cloud run N2 has not run. The `tan-nb-exp` context is still configured on
  the workstation and is the foreseeable candidate; it was not inspected, because reads are scoped to
  the active project.
- **Premises re-checked in the tree.** Since the hold, the modules this plan touches changed only in
  `ea2304d6` (F113, F114). `cloudCollectionTypes` still names ten stateless types, so the data disk,
  buckets, images, registry, service account and IAM have no collection; `consumersOf` still counts
  `OrderedAfter` edges as consumption; a retained cloud finding still has no Pulumi observation.
- **Dependency.** The Pulumi cloud-foundation world does not exist. MasterPlan 26 closed on
  2026-10-14 with EP-173 M3–M4 re-chartered to this plan's reopening.
- **Already proven natively, and reused** (MP-23 C3 checkpoint, development builds
  `24320d82`–`07d203ad`): policy, retirement of every platform scope, and cloud-scope retirement.
  F84's fix (`b171712a`, in v0.4.0) unblocks retiring a context that holds a revoked access grant.
- **F33 and F84** stay Verifying. Both close on the first native cloud collection, and none is
  scheduled.

## Surprises & Discoveries

- 2026-10-09: All five MP-23 acceptance contexts (`mp23-c3i` to `mp23-c3m`) were disposed by
  exact-name provider deletes. F84 blocked their staged retirement until v0.4.0. As a result, F33's
  identity recheck and F84's fix still have no native proof, and run G1 owns both.
- 2026-10-09: ADR 27 §4 leaves the host VM, GCS buckets and Pulumi resources without recorded
  provider identity. Both this plan (delete preconditions) and MasterPlan 21 (candidate slots) need
  that identity, so it is built once, here.

## Decision Log

- 2026-10-21 (review and refresh): The plan stays Held; the trigger, a cloud context that actually
  needs disposing, has not fired. Three refreshes: EP-173 M3–M4 are this plan's first work at
  reopening, since MasterPlan 26 closed without the Pulumi world; item 7's stage runs on the release
  rehearsal's disposable local context, since `nagare-harness local-acceptance` was cancelled; and
  G1 runs outside `tan-ng-labs`, which now hosts the intranet. Reopening re-charters the plan as one
  reviewed destroy-to-zero transaction: a saved Pulumi destroy plan over the whole stack; a typed,
  identity-bound destruction intent with its ADR (EP-166 M1); a recheck of every stack entry's
  physical identity and protection against the review immediately before effect (F33's check over
  every entry); the versioned-bucket purge on EP-183's generation-pinned deletes; and a
  last-authority stage after the history is exported. It drops leaf ordering (Pulumi orders a
  destroy itself), the VM as a separately collected leaf (the one transaction tombstones every hosted
  member) and identity at creation (MasterPlan 21, its other consumer, is held). The to-zero world is
  sized like the bucket world, not like a general cloud-foundation world. The four children stay
  Held as written until the operator confirms this shape at reopening.
  Rationale: the need is a context torn down to zero; the five MP-23 disposals and the 2026-10-10
  entry below show a bounded provider delete covers it today; and the four-child shape, with EP-173
  M3–M4 in front of it, is the costliest open initiative while moving neither requirement.

- 2026-10-10 (operator): The whole plan is held. Nothing in it moves the requirement "developers
  deploy and log in; the operator changes and upgrades without losing data". A disposable context is
  still removed with bounded, operator-approved provider commands, as the MP-23 contexts were.
  Rationale: the 2026-10-10 review of the session logs; the operator cut the open plans to EP-184 and
  EP-172.

- 2026-10-03 (operator, via MP-23): MP-23 ships perimeter-only exact cleanup plus full-context
  retirement. Full-context VM collection and protected-data destruction move here. Rationale: they
  are new capabilities with design risk. The release's safety-use gate does not need them, because a
  disposable context can be removed with operator-approved, bounded provider commands, as the C3
  checkpoint was.
- 2026-10-03: Decomposed by obstacle (hosted workloads, observation and consumption, protected
  data), plus one acceptance child. Rationale: each obstacle has an independent regression surface.
- 2026-10-09 (operator): The plan runs after MasterPlan 26's lane A, with a fixed finish line and
  exactly one cloud sequence (G1). The local teardown is a stage of MasterPlan 26's local acceptance.
  Rationale: MasterPlan 23's cost came from native runs used as discovery. Here the model is written
  first and native runs only confirm.
- 2026-10-09: EP-165 owns cloud physical identity at creation (ADR 27 §4 amendment), for reuse by
  MasterPlan 21. The Pulumi world is MasterPlan 26 EP-173 M4's, extended here rather than duplicated.
  Rationale: each primitive is built once, with a single owner.
- 2026-10-09: The runbook section is written before G1, and G1 executes it. The separate independent
  re-execution of the runbook is dropped. Rationale: one cloud sequence proves both the capability
  and the procedure. A second execution would only repeat it.

## Outcomes & Retrospective

(Not started.)

