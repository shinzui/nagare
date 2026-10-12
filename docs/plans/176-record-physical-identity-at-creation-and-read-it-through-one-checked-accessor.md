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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T04:05:23Z
      mode: "implement"
      note: "EP-176 M1-M3: journalled identity, checked accessor, rebind, replaced retirement"
---

# Record physical identity at creation and read it through one checked accessor

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [176-record-physical-identity-at-creation-and-read-it-through-one-checked-accessor.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/176-record-physical-identity-at-creation-and-read-it-through-one-checked-accessor.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] M2 (2026-10-05): one checked accessor, used by every consumer C lists for in-line kinds.
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
    - adopt and update verification and recovery (N9): `completionProof` accepts only the object the operation wrote. A survived mutant showed that no existing test covered this; a focused test now does.
    - maintenance UIDs (N13): covered by N7. `MaintenanceFence` requires the request's StatefulSet and PVC UIDs to equal the fence's, and the fence's targets must be their recorded incarnations.
    - the prune in-flight check (N22): a scheduled prune refuses when the live producer CronJob replaced the recorded one, since its Jobs would be invisible. This is app code (`PruneEvidence.hs`) that no test harness reaches, so it has no mutation record; ADR 25's rule is not met for this guard.
  - Not done: the rename recovery model has no `Replaced` fault on the source yet; F62 is pinned by focused tests.
- Original M2 text: one checked accessor, used by every consumer C lists for in-line kinds. Each consumer's
  mismatch case has a test that fails without the accessor; F62's rename-source replacement is
  refused in the rename model.
- [x] M3 (2026-10-05): the reviewed rebind and replaced retirement.
  - Done (2026-10-05): replaced retirement (N1).
    - `RetentionProof` and `RetainedIncarnation` gain an optional `replacedBy`. Their encodings omit it when absent.
    - Admission verifies the named replacement.
    - The recovery model's N1 tolerance is removed. A replacement made after review is now taken through a fresh review, at most once per step.
    - Mutation record `ADR27-N1-replaced-retirement-unnamed`.
  - **Rebind.**
    - An adoption input target with `"rebind": true` becomes an `ApproveRebind` decision. It is
      valid for an accepted Kubernetes member that stays declared, whose live object is not its
      recorded incarnation.
    - The review records each rebind (`reviewRebinds`: the recorded identity if any, and the live
      identity), and saving it prints the data consequence.
    - Admission requires the reviewed live object, now with its specific reason rather than a
      generic one. Convergence establishes it.
    - Test: "a reviewed rebind records a replacement, after which it is the accepted incarnation".
      It covers refusal of a rebind of the recorded object, and refusal at admission when the
      object changed after review.
  - **Status.** It reports `unrecorded` for a Kubernetes member observed present with no record.
  - **Mutation records.** Four rebind and status records, and three regenerated older ones.
  - **Docs.** The runbook gains "Replaced and unrecorded members", and ADR 22 is amended.
- Original M3 text: the reviewed rebind and replaced retirement. A replaced database scope can be retired (N1)
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

Completed 2026-10-05: release line (b) step 2.

- **What changed.**
  - A Kubernetes member's incarnation is now the identity its own reviewed write returned,
    journalled on the event that ends the operation. It is no longer a later observation (F60).
  - Every consumer that moves or certifies data reads identity through one checked accessor and
    never reads a missing record as a match. That covers ingestion and listing, fences, rename
    sources and writers, backups, snapshots, restores, the signing Secret, collections, and update
    and adoption proofs.
  - A replaced member can be retired (N1) or rebound through review.
  - The recovery model has no identity tolerances left.
- **Survived mutants.** Three found missing checks:
  - the update proof (N9), which the whole suite and model passed without;
  - two new rule-level records whose first tests were too weak.

  Focused tests now kill each.
- **What remains.**
  - **N2 (update or verify of a replaced member).** Planning and prepare proceed onto the
    replacement, and status reports it. ADR 27's decision "status and planning report it and
    proceed" keeps this deliberately. It moves or certifies no data, but an update writes the
    reviewed spec onto the replacement.
  - **N22.** The prune guard is app code with no harness, so it has no mutation record.
  - **N10.** Creates completed in a closed transaction stay unrecorded until rebind.
  - **N15–N20.** Non-Kubernetes identities remain ADR 27 §4 limits.
  - **Fresh-review exit.** The rename model has no `Replaced` source fault yet, and a replacement
    after review is resolved by a fresh review.
- **Release consequence.** Stores written before this plan have no records. Data operations on
  their members refuse until each member is rebound through review. The runbook section says how.

