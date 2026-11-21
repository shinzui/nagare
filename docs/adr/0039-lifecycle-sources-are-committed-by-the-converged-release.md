---
title: "Lifecycle sources are committed by the converged release"
status: accepted
date: 2026-11-17
authors: [shinzui]
related:
  - docs/masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md
  - [docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md](https://github.com/shinzui/nagare/blob/940c1481caa27e7b267f070b623201c5da31e64f/docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md)
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0033-lifecycle-delivery-separates-destination-state-from-transport-adapters.md
---

# ADR 39 — Lifecycle sources are committed by the converged release

## Status

Accepted and implemented by [EP-231](https://github.com/shinzui/nagare/blob/940c1481caa27e7b267f070b623201c5da31e64f/docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md)
M1.

## Context

Lifecycle events (MasterPlan 31) must announce a deployment or backup acceptance only when its inventory transaction
converged, and must not lose one that did. The journal's transaction-level `Completed` event is appended before
collections are finalized and before the release that clears the executor claim and records convergence, so a
transaction can stop between them. Matching `Completed` would announce transactions that never converged.

## Decision

1. A converged release whose registered producers return source facts publishes one immutable, content-addressed facts
   object (`facts/<digest>.json`), then appends one convergence journal event naming it, in the same conditional head
   replacement that clears the claim. The event has journal schema version 2 and a `convergence` field; every other
   event stays version 1, so no existing journal byte or digest changes. A release without facts writes only the head,
   as before.
2. A head that commits a convergence event has wire version 2. A version 1 CLI refuses it at head read. The new CLI
   reads both versions; nothing rewrites a version 1 store, and capture begins with the first release that has facts.
3. The journal sequence is every consumer's checkpoint. A consumer reads the head once, then only the journal suffix
   after its checkpoint, one event beyond it, and the facts objects committed sources name.
4. If the release's head write fails, its convergence event is an uncommitted orphan, and a later append by the same
   transaction may commit it as ordinary history while the transaction stays active. While a transaction is active, only
   its own events are appended. So a convergence event is a committed source exactly when the next event belongs to
   another transaction, or when it is the last event and its transaction is no longer active; it is never a source when
   the next event is its own transaction's. A last event whose transaction is still active waits.
5. Producers are pure functions of the converging transaction, registered on the adapter registry. Facts that do not
   assemble (one key naming two different facts) stop the release, so the transaction stays resumable.

6. A producer names the members whose bytes it reads; the executor gives it, for each such member the transaction
   operated, its native object bytes at the desired scope revision and at the revision converged before the release.
   The built-in deployment producer (EP-232) announces `app.deployed` when a release log's current release differs from
   the converged one, and calls it a rollback when the log's records are unchanged and only the current release moved.

## Consequences

- No second chain, head field or tip is carried through copy, transfer, export and rebuild; facts objects are ordinary
  inventory members and move with the store.
- A transaction with facts costs one facts object and one journal event more than before, and no extra head write.
- An older CLI cannot operate a store once a release has committed facts; a downgrade is refused, not attempted.
- The recovery model registers a producer, so every fault placement reaches the new writes, and its I10 invariant
  checks that each released transaction has exactly one committed source and a closed one none.
