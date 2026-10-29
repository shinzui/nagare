---
id: 227
slug: commit-verification-proofs-without-per-resource-remote-transactions
title: "Commit verification proofs without per-resource remote transactions"
kind: exec-plan
created_at: 2026-10-29T14:39:34Z
intention: "intention_01m641jy1vem4rk38mpvk6ksp8"
master_plan: "docs/masterplans/30-make-nagare-rollouts-fast-incremental-and-recoverable.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T14:39:34Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-29T16:27:26Z
      mode: "update"
      note: "Add MasterPlan 29 follow-ups: gcloud ownership stall (EP-226 M4) and journal catch-up bound (EP-227 M2)"
---

# Commit verification proofs without per-resource remote transactions

This ExecPlan is a living document. Keep the proof and crash model explicit as implementation evolves.


## Purpose / Big Picture


Verifying hundreds of unchanged objects must not require hundreds of serial remote journal-head
transactions. The result must still explain every resource's proof, recover after a crash, and
never mark an unknown or unready resource complete. Changed provider effects retain durable intent
before submission and exact receipts afterward. The optimization is to serialized coordination,
not to the safety obligations or the amount of evidence retained.


## Progress


- [ ] M1: A single-writer batch append protocol commits only validated contiguous journal prefixes
  and survives partial uploads, lost replies, orphan suffixes and competing claims.
- [ ] M2: Read-only verification uses fresh grouped evidence and batched proof publication, with
  per-resource outcomes, bounded memory and no adapter execute calls.
  Pass also: after an unchanged-release transition, the next reviewed command on another
  workstation catches up a journal tail that does not grow with the number of verified resources
  (2026-10-29: 429 events, 22 s, after v0.11.1's 205 verifies;
  [`docs/audits/mp29-latency-2026-10-29/baseline.json`](../audits/mp29-latency-2026-10-29/baseline.json)).
- [ ] M3: Legacy and new reviews recover under the compatibility contract; model faults and
  structural request budgets pass without weakening mutation or data-fence invariants.


## Surprises & Discoveries


2026-10-29: `Execute/Driver.hs` already skips `adapterExecute` for `VerifyResource`, but still
records an intent, checks the claim, verifies and records completion. `Execute/Journal.hs`
observes the head and reads the predecessor event on each append, uploads the new event, then
conditionally advances the head. Its orphan recovery handles an event whose upload succeeded
but head advancement failed. Batched publication must generalize that rule, not bypass it.


## Decision Log


- 2026-10-29: Retain the version-one event representation initially. Upload bounded contiguous
  event batches and commit them through one conditional head replacement. Immutable event uploads
  remain linear; serialized head coordination should scale with batches.
- 2026-10-29: Keep one coordinator and the remote writer claim. Process-local locks and cached
  heads do not replace remote compare-and-swap, which means “replace only if the observed version
  still matches.” No concurrent worker advances the head independently.
- 2026-10-29: Batch only actions certified effect-free and validation requirements. Mutation
  intent/receipt boundaries and fenced data operations keep their established ordering.


## Outcomes & Retrospective


Planning only. No journal semantics or storage layout have changed.


## Context and Orientation


`cli/nagarectl/src/Nagare/Inventory/Execute/Driver.hs` sequences operations.
`cli/nagarectl/src/Nagare/Inventory/Execute/Journal.hs` owns `appendEventWith`, predecessor
digests, orphan handling and head replacement retries. `cli/nagarectl/src/Nagare/Inventory/Journal.hs`
defines events and validates their sequence/hash chain. `cli/nagarectl/src/Nagare/Inventory/Store.hs`
and `Store/ObjectOps.hs` implement immutable writes and conditional control-object updates.
`cli/nagarectl/src/Nagare/Inventory/Execute/Claims.hs` verifies executor ownership.
`cli/nagarectl/src/Nagare/Inventory/OperationStep.hs` chooses dependency-ready operations.

The committed prefix is the events below the head's next sequence number; uploaded files beyond
it are not proof of completion. The predecessor digest links each event to the previous one.
An observation epoch from `Inventory/ClusterSession.hs`/`KubernetesSnapshot.hs` is a phase-local
set of fresh reads, not a transaction across Kubernetes and the object store.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) defines
conditional inventory authority and accepted/converged state.
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) closes interrupted
work by per-operation proof and makes verify effect-free.
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
requires receipts to retain exact physical identity.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires
faults at production interpreter boundaries; its latest amendment makes the deep tier optional,
not a release gate. Extend the fast fault product and mutation checks appropriate to this change.


## Plan of Work


### M1 — Commit a contiguous batch under one authority


Add `cli/nagarectl/src/Nagare/Inventory/Execute/JournalBatch.hs` and a test module
`cli/nagarectl/test/InventoryVerificationBatchSpec.hs`. A bracketed coordinator carries the
claimed transaction, observed remote head, validated predecessor digest and committed event prefix.
Bound a chunk to 64 resource outcomes and 1 MiB encoded journal data, whichever comes first;
oversized individual proof material is stored as an immutable digest-addressed object, with a
small reference in the event. Reuse existing events and state transitions for legacy verifies,
including their intent event where needed, constructing a deterministic per-resource order.

Prepare all bytes/digests locally. Upload immutable events create-only with at most eight requests
in flight, verify every required upload or identical preexisting object, then advance the head
over exactly that contiguous prefix with its observed generation/remote conditional token. One
successful batch has one initial head observation and one conditional commit, plus bounded claim
checks and immutable uploads. Cache predecessor bytes only when their digest is already validated
against the observed prefix. After a conditional failure or unknown reply, reread the head and
prove exactly which prefix committed; never assume success or blindly publish a later sequence.

Handle crashes after any subset of uploads, including a hole and an uploaded later event. On
resume, validate the maximal contiguous orphan prefix against transaction, predecessor, reviewed
operation identity and allowed meaning; incompatible bytes refuse. Commit proven old events before
allocating colliding sequences. A different outcome cannot overwrite an immutable event. If the
old chunk is incomplete, reconstruct its required original event bytes from the durable batch
descriptor, or close/recover through explicit evidence; do not invent replacement bytes to fill
a gap. Store that descriptor create-only before uploads, binding transaction, base head and every
event digest. Reference it through a versioned transaction metadata mechanism that all continuing
writers understand before enabling batched publication. Unsupported writers must refuse rather
than strand or skip suffix events. The descriptor does not itself commit outcomes.

Prove M1 with a tiny two-operation batch first. Fail each upload, descriptor publication, claim
check and head update both before effect and after effect with a lost reply. Reopen with a fresh
process and require exactly the same committed prefix as uninterrupted execution or an explicit
safe stop. Introduce a competing claim and forbid subsequent head advancement by the old writer.

### M2 — Verify as read-only proof work


Consume EP-226's fresh guarded apply epochs and EP-225's validation contract. A combined
read-only proof function performs the checks previously split between preflight and verify:
review binding, expected UID/incarnation, ownership stamp, desired fields, health and any source
requirements. Reuse one object body only when it proves both checks. Additional dependent-object
health reads remain explicit. Merely returning the preflight's Boolean is not enough.

Batch ready `VerifyResource` operations only when dependencies are satisfied and their adapters
declare the effect-free capability. Emit the same per-operation terminal evidence and physical
identity. Do not infer safety from an executor name or schedule a declared operation as a verify.
Legacy verification reviews keep their existing result interpretation. The new validation-only
requirements are recorded in an immutable proof capsule: a versioned object containing one result
per resource and binding review digest, accepted scope vector, session/epoch identity, observation
interval and validation policy. One aggregate publication binds the complete capsule; it does not
create N fake operations or N intent events. Bound capsule chunks by 64 results/1 MiB and bind
all chunk digests into the aggregate. Omitted or failed results prevent the platform barrier.

A capsule is only evidence for its associated apply barrier. It is not a reusable health cache
for the next command. After interruption, reuse immutable content and durable completed mutation
receipts, but re-observe validation health before a new stamp/finalization. After a write affecting
any covered dependency, expire the corresponding health proof. Store exact resource IDs and UIDs
without credential bodies. Per-resource diagnostics must remain available to resume and close.

Use the same append coordinator for individual mutation events. It must durably commit mutation
intent before any provider request, and retain ambiguous outcome on cancellation/lost reply.
Keep existing claim checks at mutation boundaries; savings in read-only proof publication do not
authorize caching claim authority indefinitely.

### M3 — Prove compatibility, recovery and the budget


Extend `InventoryRecoveryModelSpec.hs`, `InventoryTransactionSpec.hs`,
`InventoryCloseSpec.hs`, `InventoryJournalHeadAdvanceSpec.hs` and the generated store fault worlds.
Test partially successful proof chunks, stale head, foreign resource, replacement under the same
name, failed readiness, duplicate descriptors, conflicting events, expired epochs and asynchronous
cancellation. Require faults to fire. A failed proof cannot mark its scope converged, publish the
stamp, accept a missing UID, or make a later close lose the previous receipts.

Read old journal/review fixtures without rewriting them. If new transaction metadata is needed
to protect batch recovery, add explicit capability/version admission and an idle-store upgrade
path. Prove old supported CLIs refuse an open new-format batch before writing, and new CLIs finish
old open transactions using the old serial append path. Keep the old path only for that documented
compatibility purpose, with fixtures and a retirement condition tied to supported release sources.

For V legacy verifications, head advancement count is at most `ceil(V/64)` on the success path,
plus separately counted transaction admission/convergence writes; byte-limit chunks may increase
the count and must be present in the budget formula. Immutable event puts remain proportional to
event count. For new no-op validation, no per-resource journal event exists; proof-capsule chunks
and one aggregate binding carry evidence. Add negative budget tests that restore old per-event
head advancement and prove the performance fixture fails. Native tests later confirm store latency.


## Concrete Steps


From the repository root after registering the new group:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p VerificationBatch' --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p journal' --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p recovery' --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p TransitionCost' --test-show-details=direct
just haskell-style-check
```

Check that patterns select tests. At a committed boundary run `just gate-fast <revision>` and the
normal changed mutation-record proof required by the release gate. The new test's fault manifest
must include each descriptor, event-upload and head-commit boundary, not only final happy paths.


## Validation and Acceptance


M1 is accepted only after the two-operation crash/reopen matrix passes under a fresh coordinator.
M2 requires the real adapter's combined proof path, zero execution calls for verification and
complete per-resource evidence after chunking. M3 requires previous-release compatibility,
generated recovery faults, mutation checks and the request-growth budget. Recovery assertions
must be extended for the new boundaries, not merely kept “unchanged and green.” If the v1 event
format cannot safely support the protocol, record and implement an explicit versioned migration;
do not hide that change behind a performance flag or waive the crash cases.


## Idempotence and Recovery


Immutable bytes are create-only and digest-verified. A head pointer commits only a contiguous
validated chain. Reusing an existing matching descriptor/chunk is idempotent; a mismatch is an
error. Lost replies cause observation and reconciliation, never overwrite. Retry budgets remain
bounded. A refused or killed verification performs no provider mutation; resume may safely
re-observe it, but must first reconcile any durable orphan events. Durable data effects retain
their existing fences, recovery choices and prohibition on automatic rollback.


## Interfaces and Dependencies


Hard prerequisite for all work: [EP-224 M1](224-make-a-platform-transition-take-minutes-and-keep-its-cost-traced.md).
M2 additionally requires [EP-226 M1–M2](226-share-bounded-cluster-observations-through-a-guarded-command-session.md)
and [EP-225 M2](225-keep-platform-revisions-stable-when-deployment-meaning-is-unchanged.md). EP-225 owns the
validation requirement contract; this plan owns its proof-capsule representation, journal batch
descriptor and compatible recovery. The parent sequence completes EP-225 before M2 integration.
[EP-228](228-run-incremental-platform-rollouts-with-bounded-waits-and-durable-progress.md) must
consume this coordinator instead of adding another head writer. Keep the existing object store;
no alternative database or new dependency is required by the plan.
