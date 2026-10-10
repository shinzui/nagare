---
title: "Physical identity is recorded at creation and read through one checked accessor"
status: accepted
date: 2026-10-05
authors: [shinzui]
related:
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0026-stopped-transactions-close-by-per-operation-proof.md
  - docs/audits/mp23-exhaustive-review-2026-10-05/PROPOSAL.md
  - docs/audits/mp23-exhaustive-review-2026-10-05/C-identity.md
  - docs/audits/mp23-findings.md
---

# ADR 27 — Physical identity is recorded at creation and read through one checked accessor

## Status

Accepted by the operator on 2026-10-05, as decision D2 of
[the exhaustive review's proposal](../audits/mp23-exhaustive-review-2026-10-05/PROPOSAL.md). This
un-defers F60's design.

## Context

Nagare tells an object it created apart from an out-of-band replacement at the same address by its
physical identity: the Kubernetes UID or the provider ID. The review found three things
([C](../audits/mp23-exhaustive-review-2026-10-05/C-identity.md)):
- **No create path keeps the identity the provider returns.** The only writer of the incarnation
  record is a fresh observation at convergence (F60).
- **Four readers trust the record, and all pass when it is missing.**
- **Many paths never read it.** These include backup, snapshot and restore sources, data-fence
  capture, collection deletes, migration sources (F62) and adoption, 22 untracked in all.

Ownership is a copyable annotation, so a same-name replacement reads as owned and present. F49, F51,
F52, F58, F60 and F62 are one cause. F51's fix also showed the opposite failure: a stricter check
without an exit refuses to retire a replaced database (N1).

## Decision

1. **Record identity at the source.**
   - The identity the provider returns for a reviewed create, adopt or update is recorded in that
     operation's completion event in the journal.
   - This covers Kubernetes `create`, `apply` and `replace`, `copySecret`, and adoption.
   - Journals written before this change still decode; their members are treated as having no
     creation record.
   - Convergence binds incarnations from these journal records, never from a fresh observation. A live
     object that differs from the record at convergence is `TargetGone`, per [ADR 26](0026-stopped-transactions-close-by-per-operation-proof.md),
     and is never bound.

2. **Read through one checked accessor.** Every consumer of a member's identity obtains it through one
   accessor that compares the live identity with the record and refuses a mismatch. The consumers are:
   - status;
   - retention and absence proofs;
   - migration sources;
   - receipt listing and ingestion;
   - backup, snapshot and restore sources and targets;
   - data fences;
   - collection-delete preconditions.

   A member with no record is reported as unrecorded, never as matching.

3. **A replaced member has a reviewed exit.** A reviewed **rebind** decision records the current object
   as the member's incarnation. It shows the old and new identities and the data consequences. A
   retirement may retain the record marked `replaced`. Refusal without an exit is not acceptable.

4. **Scope.** This applies to every Kubernetes member Nagare creates. Under MP-23's release line,
   non-Kubernetes kinds without provider identities stay a documented limit: the host VM, GCS buckets,
   Pulumi resources, broker topics and artifacts.

## Consequences

- F60, F62, F52's convergence half and the review's N2–N13 close by construction. F49's and F51's
  fail-open limits become refusals with a reviewed exit.
- `AdapterExecution` gains an identity field, and the journal's `Completed` event gains an optional
  identity. That is a compatible schema extension.
- Status reports `unrecorded` members explicitly. Operators of stores written before this change see
  them until they run a reviewed rebind.
- The recovery model's F60 tolerance and the "admission refusal counts as done" shortcut are removed.


## Amendment (2026-10-10): a reviewed rebuild recreates a lost durable member with an explicit lineage

Made for [EP-183](../plans/183-close-the-intranet-gaps-left-by-v0-4-0-https-login-volume-backups-retention-and-service-rebuild.md)
milestone 4, so that a context can be brought back into service after losing its VM. Before it,
planning refused an accepted durable member whose object was gone (`durable-resource-missing`) and
a backup restored only into the incarnation it was taken from, so the data was recoverable but the
service was not.

- **A rebuild is a reviewed lifecycle decision, not a tolerance.** `nagarectl inventory rebuild
  --input FILE --out DIR` reviews one decision per member (`ApproveRebuild`). Each decision names:
  - the member, at its accepted address, which must still be declared and be confirmed absent at
    planning and again at admission;
  - its predecessor: the recorded incarnation, or none when no incarnation was ever recorded;
  - its data source: one exact recovery point of the predecessor (receipt object and receipt-bytes
    digest), or `fresh`.
- **Who may take which source.** A volume restores a recovery point only when it has a recorded
  predecessor; it may start `fresh` only by the operator's explicit choice. A Secret Nagare
  generates (credential, backup signing key) always starts fresh. No other durable kind is rebuilt.
- **The new object is an ordinary incarnation.** The create's returned identity is recorded at
  convergence, as for any create. The lineage is recorded in the journal: the review that created
  the incarnation carries the decision under `rebuilds`, and `memberLineage` finds it from the
  first journal event that returned the recorded identity.
- **The single restore exception.** A backup may restore into an incarnation other than the one it
  was taken from only when all of these hold (`compileRebuildRestoreScope`, `db restore-rebuilt`):
  - the target volume's recorded, live incarnation is the one a converged rebuild created;
  - the receipt is byte for byte the recovery point that rebuild named;
  - the receipt verifies with the escrowed signing key bound to the rebuild's predecessor;
  - the load runs only into an empty database, in one transaction.

  Later recovery points of the predecessor are never restorable into the new incarnation without
  another decision. Every other consumer still uses the checked accessor unchanged.
- **Known limit.** A rebuild whose create loses its response leaves the new member unrecorded, as
  any such create does; it then has no lineage, so its predecessor's recovery point cannot be
  restored into it. A rebind records the object; the data needs a separate reviewed recovery.
- **Compatibility.** Review documents gain an optional `rebuilds` field, so a binary from before
  this change cannot read a rebuild review. The head and journal formats do not change. EP-172's
  compatibility table carries the row.
