---
id: 176
slug: record-physical-identity-at-creation-and-read-it-through-one-checked-accessor
title: "Record physical identity at creation and read it through one checked accessor"
kind: exec-plan
created_at: 2026-10-05T21:51:36Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-05T21:51:36Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T01:36:52Z
      mode: "implement"
      note: "EP-176 M1: provider identity journalled and bound at convergence"
---

# Record physical identity at creation and read it through one checked accessor

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare tells an object it created apart from a same-name object that someone recreated outside Nagare
by the object's *physical identity*. For Kubernetes that is the object's UID. The stamp Nagare puts
on its objects is a copyable annotation, so a `kubectl replace --force` or a restore from a saved
manifest produces an object that looks owned and present but holds none of the original data.

Today Nagare never keeps the UID the API server returns for its own create. It records an identity
only from a fresh observation when a transaction converges (F60), and four places read that record,
all of which pass when it is missing. Backup sources, restore targets, data fences, migration sources
(F62), collection deletes and adoption never read it at all. So an empty replacement can become a
recovery point, a restore target, a migration source or an accepted member. The exhaustive review
lists every path in `docs/audits/mp23-exhaustive-review-2026-10-05/C-identity.md`.

After this plan:
- **Records come from the provider.** Every reviewed create, adopt or update records the identity
  the provider returned, in the operation's journal completion event. Convergence binds the record
  from there, never from a later observation.
- **One checked accessor.** Every consumer reads a member's identity through one accessor. It refuses
  when the live object is not the recorded one, and it reports a member with no record as
  `unrecorded`, never as matching.
- **A reviewed way forward.** A replaced member has a reviewed *rebind* decision and a retirement that
  marks the record replaced, so a refusal is never the end of the road.

A reader sees it working in three places:
- the recovery model, with its F60 tolerance removed: a `Replaced` fault between create and
  convergence no longer launders the replacement into a recovery point;
- the rename model: a replaced rename source is refused (F62);
- focused tests for each consumer in C.

This plan implements
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md),
step 2 of MasterPlan 23's release line (b).


## Progress

- [x] M1 (2026-10-05): identity at the source.
  - **Result type.** `AdapterExecution` gains `AdapterEffectIdentified physical inner`: the
    provider returned this object, then the effect ended as `inner`. `effectIdentity` splits it
    into the identity and a flat `EffectOutcome`.
  - **Kubernetes runtime.** Every non-delete write (create, adoption patch, apply, Service patch)
    runs with `-o json`, and `identified` attaches the returned `metadata.uid`. The migration's
    `copySecret` does the same (N11).
  - **Journal.** `JournalEvent` gains an optional `physical`, omitted when absent so old events
    keep their bytes and digests. The driver records it on whichever event ends the operation
    (`appendEventWith`), so a readiness timeout still records the object it created.
  - **Convergence.** It binds from the journal through `runOperationsJournal`, which hands back the
    run's final events with no second journal read:
    - create, adopt and a migration's own write are established;
    - update is proved (bound only when nothing is recorded);
    - verify binds nothing;
    - a migration destination with no returned identity keeps F52's convergence observation.
  - **Tests.** The model's F60 tolerance is removed and the fast tier passes. New tests:
    - "convergence binds the object the create returned, not one that replaced it before
      convergence (F60)";
    - "a Kubernetes write's returned object names the identity the journal records".
  - **Fakes.** The rename spec's kubectl fake now returns the created object, as real `-o json`
    does, and the effectful model accepts the flag.
  - **Mutation records.** `ADR27-F60-binds-from-observation`, `ADR27-driver-drops-returned-identity`
    and `ADR27-runtime-ignores-returned-uid`.
- [ ] M2 (in progress): one checked accessor, used by every consumer C lists for in-line kinds.
  - Done (2026-10-05):
    - `Nagare.Inventory.Identity` (`checkedPhysical`, `requireAccepted`);
    - the four existing readers. Status also catches N21's replaced object that requires replacement. Retention proofs read through it. Receipt listing and ingestion now refuse an unrecorded source, not only a replaced one.
    - data-fence acquisition (N7). Targets must be the recorded incarnation, and captured writers must not replace a recorded one. This covers live restore and maintenance.
    - mutation records for each, plus regenerated F49 and F51 records.
    - the rename source (F62) and writer (A52), with focused tests and mutation records.
    - manual database backup (N3) and volume snapshot (N4) sources, checked where the backup scope is compiled; the requests carry the recorded incarnations.
    - restore targets, scratch and live (N6), through `restoreTargetPins`; a manual backup restores only against the incarnation it was taken from (N12).
    - the signing Secret (N5), in ingestion and receipt listing; live restore reads the ingested scope's checked signing UID.
    - collection (N8): admission reverifies each collection proof's retained incarnation, as it does retentions, before any DELETE. The native collection budget gains that one GET.
  - Remaining: adopt and update verification (N9), maintenance UIDs (N13) and the prune check (N22).
- Original M2 text: one checked accessor, used by every consumer C lists for in-line kinds. Each consumer's
  mismatch case has a test that fails without the accessor; F62's rename-source replacement is
  refused in the rename model.
- [ ] M3: the reviewed rebind and replaced retirement. A replaced database scope can be retired (N1)
  or rebound through review; status reports `unrecorded` and `replaced-incarnation` members
  explicitly.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The identity record stays keyed by resource ID, with the provider address it was recorded
  at stored beside it (`headIncarnations :: Map ResourceId (PhysicalIdentity, ProviderAddress)` in a
  compatible encoding).
  Rationale: F52 came from comparing a record with an object at a different address. Storing the
  address lets the accessor compare only like with like. The existing JSON field keeps decoding: a
  bare identity is read as "address unknown" and compared as before.
  Date: 2026-10-05

- Decision: A member with no record (stores from before this change, or members bound by the old
  `Proved` path) is `unrecorded`. Consumers that move or certify data refuse an unrecorded member
  until a reviewed rebind records it: backup, restore, ingestion, migration source, fences and
  collection deletes. Status and planning report it and proceed.
  Rationale: ADR 27 §2 forbids treating "no record" as matching. Refusing only where data is at stake
  keeps ordinary updates of stateless members working.
  Date: 2026-10-05


- Decision: The identity is a wrapper constructor, not a field on `AdapterEffectCompleted`.
  Rationale: 256 constructions in 70 files build `AdapterEffectCompleted`, almost all in fakes. A
  wrapper leaves them unchanged and lets the identity accompany an ambiguous outcome too. The two
  consumers that match on outcomes use the total `EffectOutcome`.
  Date: 2026-10-05

- Decision: The identity is an optional event-level field (`physical`) rather than a change to
  `Completed`'s payload, and it is recorded on whichever event ends the operation.
  Rationale: a readiness wait that times out after a successful create journals `Ambiguous`, and
  that operation's later `Completed` comes from recovery, which has no response to read. Recording
  on the ending event keeps the provider's answer in both cases. Matching on `Completed _` stays
  unchanged everywhere.
  Date: 2026-10-05

- Decision (correction): The plan's claim that an older binary "ignores the new optional fields"
  is wrong. The journal decoder refuses unknown fields. No released reader predates the inventory
  store (ADR 22), so nothing is lost; newer journals are not readable by binaries built before
  this plan.
  Date: 2026-10-05

- Decision: A verification binds nothing, and members are recorded at every Kubernetes create,
  not only for durable members and StatefulSets.
  Rationale: a verification writes nothing, so its only source would be a later observation, the
  path ADR 27 removes. A member that was never recorded stays `unrecorded` until M3's rebind. N10
  (a create completed in a closed transaction) is therefore still unrecorded at the next
  convergence. M2's accessor handles it as `unrecorded`; reading earlier transactions' completions
  is not done.
  Date: 2026-10-05


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root; the package is `cli/nagarectl`. The production Haskell
standard of [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) applies, and
incomplete patterns are compile errors.

**Terms.**
- A **member** is one managed resource in a scope (for example a database's PVC).
- Its **incarnation** is the physical identity of the object Nagare accepted for it: a Kubernetes
  UID, or a provider ID.
- **Laundering** is a path where an out-of-band replacement's identity becomes accepted, retained,
  backed up, restored from or into, ingested, or fenced. **Fail-open** is a path where a missing
  record lets anything pass.

**Where identity lives today.**
- **The record.** `headIncarnations` in the store head (`cli/nagarectl/src/Nagare/Inventory/Store.hs`)
  is the accepted-incarnation record. Retained and collected members carry identities in
  `headRetained` and `headCollected`.
- **Its only writer.** `convergedIncarnations` in
  `cli/nagarectl/src/Nagare/Inventory/Execute/Incarnations.hs` observes members at convergence. It is
  called from `Execute/Transaction.hs` and bound by `releaseClaimWith` in `Execute/Claims.hs`. It
  records only Kubernetes members that are durable or StatefulSets. An unavailable observation records
  nothing.
- **What creates return.** `AdapterExecution` (`cli/nagarectl/src/Nagare/Inventory/Adapter.hs`)
  carries no identity, and the journal's `Completed` event (`Journal.hs`) carries only a digest. The
  runtime discards `kubectl create` output (`Adapters/KubernetesRuntime.hs`). The rename's
  `copySecret` (`Adapters/KubernetesMigration.hs`) is a second create path that also discards it.
- **The readers.**
  - status (`Status.hs`, `statusIncarnations` and `classifyDriftWith`);
  - retention proofs (`Plan/Changes.hs`, `buildRetentionProofs`);
  - receipt listing and freshness
    (`cli/nagarectl/app/Nagare/Cli/Data/ScheduledReceipts.hs`);
  - ingestion (`ScheduledIngest.hs`).

  All four pass when there is no record.

**C's inventory.** `docs/audits/mp23-exhaustive-review-2026-10-05/C-identity.md` lists every
identity-bearing site with file and line, and the untracked paths N1–N22. For this plan's in-line
kinds the consumers to route through the accessor are:
- migration sources (F62, the rename planner `Plan/Migration.hs` and `Plan/Lifecycle.hs`, and the
  writer StatefulSet pin in `KubernetesMigration.hs`);
- manual backup sources (N3, `app/Nagare/Cli/Data/Backup.hs`, `Backup.hs`);
- volume snapshot sources (N4);
- the backup signing Secret (N5);
- restore targets, scratch and live (N6, `app/Nagare/Cli/Data/Restore.hs`, `LiveRestore.hs`);
- data-fence capture (N7, `DataFence/KubernetesCapture.hs`, `DataFence.hs`);
- the Kubernetes collection DELETE precondition (N8, `KubernetesRuntime.hs`, `Collection/Adapter.hs`);
- adopt and update verification (N9);
- stopped applications' unrecorded durable members (N10);
- `copySecret` (N11);
- restore source-to-target comparison (N12);
- caller-supplied maintenance UIDs (N13);
- the PVC and credential of `retention = Delete` databases (N14);
- status replacement-required and health (N21);
- the scheduled-prune in-flight check (N22).

N1 is the retirement of a replaced recorded member. Since F51's fix it is always refused at admission
(`Execute/Admission.hs`), and nothing offers another way forward.

**Out of scope by the release line** (documented limits, ADR 27 §4): non-Kubernetes kinds without
provider identities. These are the host VM, GCS buckets, Pulumi resources, broker topics, the cache
key and artifacts (N15–N20).

**Relevant ADRs.**
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
  is the decision.
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) documents
  the incarnation record and its "Known limits" (fail-open recording, unrecorded members pass), which
  this plan removes. Amend it.
- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) defines `TargetGone` and
  close, which must bind nothing.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires a
  failing-without-fix regression for each guard.


## Plan of Work

### Milestone 1: identity at the source

Extend `AdapterExecution` with the identity of the object the effect produced or changed
(`AdapterEffectCompleted (Maybe PhysicalIdentity)` or an equivalent field). Thread it through every
adapter. Non-Kubernetes adapters answer `Nothing`.

In `Adapters/KubernetesRuntime.hs`, capture the UID from the API server's response:
- run `kubectl create`, `apply` and `replace` with `-o json` and parse `metadata.uid`;
- capture it from `copySecret` in `KubernetesMigration.hs`;
- capture it from the adoption patch.

Extend the journal's `Completed` event with an optional identity in a compatible JSON encoding, so
older journals decode as "no creation record". Have the driver (`Execute/Driver.hs`) record it.

Rewrite `convergedIncarnations` to bind from the journal's completion identities for creates, adopts,
updates and migration destinations, not from a fresh observation. Widen the set of recorded members
to every Kubernetes member Nagare creates, not only durable members and StatefulSets. Also bind at a
close's head release (N10): a close binds nothing new, so it must not call this path. Instead, a
member completed in a closed transaction keeps its completion record in the journal for the next
convergence to read.

At convergence, an observed object that differs from the journal record is not bound. Report it
through `adapterSettle` as `SettledTargetGone`, defined in
`docs/plans/175-close-stopped-inventory-transactions-by-per-operation-proof.md`.

In the recovery model (`cli/nagarectl/test/InventoryRecoveryModelSpec.hs`), remove the F60 tolerance
in `ingestReceipt` and make the world (`test/Nagare/Test/World/Kubernetes.hs`) return the UID from
its writes. The scenario "create a database, then ingest a scheduled receipt" must pass with no
tolerance. Record a mutation that restores observation-based binding, and show that it fails.

### Milestone 2: one checked accessor

Add `Nagare.Inventory.Identity` (new module, `cli/nagarectl/src/Nagare/Inventory/Identity.hs`). Its
function `checkedIncarnation :: HeadManifest -> ResourceId -> ResourceObservation -> IdentityCheck`
answers one of:
- `IdentityMatches physical`;
- `IdentityReplaced recorded live`;
- `IdentityUnrecorded live`;
- `IdentityAbsent`.

Route every consumer listed in Context and Orientation through it, and delete each consumer's own
comparison. In particular:
- F62's migration-source path: the rename planner refuses a source whose live UID is not the record;
- the writer StatefulSet pin;
- data-fence capture. Comparing there closes the fence-based restore and maintenance paths together
  (N7 is the cheapest single point for N6 and maintenance);
- the collection DELETE precondition, taken from the retained record (N8).

For each consumer, add a test that fails when the consumer bypasses the accessor. In the rename
model (`InventoryRenameRecoveryModelSpec.hs`), add a `Replaced` fault on the rename source and
expect a refusal at planning, not I3.

### Milestone 3: reviewed rebind and replaced retirement

Add a reviewed rebind lifecycle decision. It records the current live object as a member's
incarnation and shows the old and new identities and the data consequence ("the recovery points of
the old incarnation no longer describe this object"). It is planned like an adoption and admitted
under the same review discipline.

Change retirement of a replaced member to retain the record marked `replaced` (N1), instead of
refusing at admission.

Status gains explicit `unrecorded` and `replaced-incarnation` categories for every recorded kind,
including the replacement-required case (N21). The model's retire scenario then retires a replaced
database successfully; today it is counted as `Done` only because admission refused it. That needs
the model to stop counting refusals as success, which
`docs/plans/175-close-stopped-inventory-transactions-by-per-operation-proof.md` M2 does.


## Concrete Steps

From `cli/nagarectl`:

```bash
cabal build nagarectl-test
cabal test nagarectl-test --test-options='-p "/fast tier/ || /rename recovery model/ || /accepted incarnations/"'
```

Before each commit, from the repository root: `just gate-fast`, then `nix flake check`, then
`git diff --numstat`. Mutation proofs go in a scratch worktree, with the applied diff checked before
the run.


## Validation and Acceptance

Required acceptance:
- **Recovery model.** The fast tier passes without the F60 tolerance. A mutation restoring
  observation-based binding fails it.
- **Rename model.** It refuses a replaced source at planning.
- **Consumers.** Every in-line consumer listed above refuses a replaced member through the accessor,
  each with a test that fails when that consumer bypasses the accessor.
- **Rebind.** A rebind review records a replacement, after which ingestion accepts its receipts.
- **Replaced retirement.** Retiring a replaced database converges, with the record retained as
  replaced.
- **Old journals.** Journals and heads written before this plan still decode, and their members
  report `unrecorded`.
- **Gates.** `just gate-fast` and `nix flake check` pass at each commit.


## Idempotence and Recovery

The journal and head changes are compatible extensions, so a binary from before this plan reading a
newer store ignores the new optional fields. Each milestone lands behind passing tests; if one breaks
the model, revert that commit. Rebind is a reviewed operation and never edits the store by hand.


## Interfaces and Dependencies

This plan depends on
`docs/plans/175-close-stopped-inventory-transactions-by-per-operation-proof.md`. It needs that plan's
`Settlement` type (`SettledTargetGone`) and its change that stops the model counting refusals as
exits. Start once 175's M2 is accepted.

It provides:
- `Nagare.Inventory.Identity.checkedIncarnation`;
- the identity field on `AdapterExecution`;
- the optional identity on the journal's `Completed` event.

Plan 177 (`docs/plans/177-generate-recovery-model-coverage-from-a-resource-kind-table.md`) declares
each kind's identity in its kind table from these.

The design reference is `docs/audits/mp23-exhaustive-review-2026-10-05/C-identity.md`.
