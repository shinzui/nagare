---
title: "Stopped transactions close by per-operation proof, not by allowlists"
status: accepted
date: 2026-10-05
authors: [shinzui]
related:
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md
  - docs/adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md
  - docs/audits/mp23-exhaustive-review-2026-10-05/PROPOSAL.md
  - docs/audits/mp23-exhaustive-review-2026-10-05/A-recovery-matrix.md
  - docs/audits/mp23-exhaustive-review-2026-10-05/B-exit-rules.md
  - docs/audits/mp23-exhaustive-review-2026-10-05/E-crash-points.md
  - docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md
---

# ADR 26 — Stopped transactions close by per-operation proof, not by allowlists

## Status

Accepted by the operator on 2026-10-05 ("approve all six"), as decisions D1 and D5 of
[the exhaustive review's proposal](../audits/mp23-exhaustive-review-2026-10-05/PROPOSAL.md).

## Context

A stopped or ambiguous inventory transaction blocks every later plan on its context until a reviewed
exit ends it. Until now, exits were special cases. The review counted 23 of them, about ten
predicates with about 35 hard-coded allowlist entries
([B](../audits/mp23-exhaustive-review-2026-10-05/B-exit-rules.md)):
- `incompleteApplicationOnlyReview` in `Plan/History.hs`;
- the review-shape abandon predicates in `Execute/RecoveryPolicy.hs`;
- the per-kind recovery classification in `Adapters/Kubernetes.hs`.

Each rule guessed "no effect" from a review's shape and from named scope kinds, resource kinds,
actions and executors. Operations run in operation-ID (digest) order, so which companions are still
pending at a stall is effectively arbitrary. Every finding from F16 to F65 added or widened one
entry, and each review found the next sibling.

The enumerated recovery matrix
([A](../audits/mp23-exhaustive-review-2026-10-05/A-recovery-matrix.md)) has 748 reachable cells. 281
of them wedge the store and 21 leave a scope stuck idle; 266 of those were untracked. The abort path
also had hazards:
- it reset every scope's accepted revision;
- it kept retained entries that admission had added;
- its separate head release could fail and leave no re-entry
  ([E](../audits/mp23-exhaustive-review-2026-10-05/E-crash-points.md) U1, U3).

## Decision

1. **Every operation is classified once, from proof.**
   - From the journal, with no adapter call: `Completed`, `NeverStarted` (no intent event; this is
     sound because intent is journalled before any effect), `Refused` or `Reverted`.
   - From a new total adapter function, `adapterSettle`: `NoEffect` (a proved, unchanged
     before-state), `Landed` (the exact reviewed effect on the reviewed object, not yet ready),
     `TargetGone` (the reviewed object was replaced or deleted outside review), `TerminalPartial`, or
     `Unknown`.
   - "Safe to retry" is not "no effect".
   - An adapter answers `Unknown` only when the provider cannot be observed, or when the effect may
     still be in flight, and it states what would resolve it.

2. **One reviewed decision, `close-transaction`, replaces the stop and abandon allowlists.** It is
   admissible when no operation is `Unknown`, resume cannot make progress, and no data fence or
   migration is active. It:
   - writes nothing to any provider, binds no incarnation and converges nothing;
   - leaves scopes the review did not change untouched;
   - reverts a changed scope to its review base only when no operation on it had an effect (each is
     `NeverStarted`, `Refused`, `Reverted` or `NoEffect`), and undoes that scope's own retained and
     migrated additions in the same head write;
   - otherwise keeps the scope's desired revision, so everything created or landed stays owned;
   - performs its head release with the same reread-and-retry discipline as the journal append, and
     makes it re-enterable after a failed write.

3. **Follow-up exits are guaranteed by data, not by kind.**
   - The never-started set holds creates that are `NeverStarted` or `Refused` and confirmed absent, for
     every scope kind.
   - A corrected review, or a retirement, plans from these records.
   - A durable member outside the set that is found absent still refuses with `durable-resource-missing`.

4. **Migrations** are excluded from `close-transaction` and get forward exits of their own. For a
   rename destination that a copy left partially written (F61), the exit is a mark-bound redo, not a
   separately reviewed wipe (amended 2026-10-05, EP-175, reviewer condition):
   - Before copying, the copy writes a mark on the destination that names its transaction and
     operation, and it removes the mark only after the whole copy.
   - A retry by the same transaction and operation may clear and redo a destination that carries
     that exact mark.
   - The destination must be the migration's own reviewed destination object: its stamped claim
     name now, and its recorded identity once ADR 27 lands.
   - No pod other than the migration's transfer Jobs may mount it.

   A destination with any other data, or with another migration's mark, is still refused.

5. **The last resort is attested, not raw.** For a transaction whose operations an adapter cannot
   prove (`Unknown` that observation cannot reduce), the operator may record an attested
   **close, accept nothing** decision. It names the operator, the reason and the evidence. It binds and
   converges nothing, and later plans re-observe everything. It replaces hand edits of the store, which
   the repository rules forbid.

6. **Verify is effect-free by construction.** The driver never runs an adapter's execute step for a
   `VerifyResource` operation.

## Consequences

- **What is deleted.** `incompleteApplicationOnlyReview`, the review-shape abandon predicates, the stop
  branch, the partial-restore, partial-prune and refused-operation abandons, and both terminal claim
  releases. About 800 lines of source and about 15 instance-level mutation records go; about six
  rule-level records replace them.
- **Recovery actions.** The five existing recovery actions become aliases of `close-transaction`,
  except for the fenced data-restore steps, which keep their own phases.
- **Adapter obligations.** Each adapter must implement `adapterSettle` totally. A model test per adapter
  checks that every fault in its world yields a non-`Unknown` class, or a stated reason.
- **Behaviour change.** The F35, F36 and prune exits now keep a scope accepted but not converged,
  instead of orphaning its leftovers. The next plan reconciles it.
- **Not covered here.** Identity laundering (F60, F62) is [ADR 27](0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md).
  Providers that are genuinely unobservable remain `Unknown` and use the attested exit.
