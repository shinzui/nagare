---
id: 217
slug: serve-the-committed-journal-from-a-verified-local-copy-and-fetch-only-its-new-tail
title: "Serve the committed journal from a verified local copy and fetch only its new tail"
kind: exec-plan
created_at: 2026-10-22T23:31:41Z
master_plan: "docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-22T23:31:41Z
---

# Serve the committed journal from a verified local copy and fetch only its new tail

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It is a child of
[MasterPlan 29](../masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md),
added on 2026-10-22 when the intranet confirmation of EP-212 showed the apply bounded by the
journal.


## Purpose / Big Picture

Every `inventory apply` reads the whole committed journal before it executes:
`Nagare.Inventory.Execute.Transaction.executeWithJournal` calls `readJournal`, which reads the
head and then `Nagare.Inventory.Store.readJournalPrefix store (headSequence head)`. On a GCS
store that lists the `journal/` prefix and downloads every event. On the intranet on
2026-10-22 that was about 6,900 events and about 60 s of a 67 s apply, and it grows by about ten
events per reviewed change.

Journal events are written once (`journal/<sequence>.json`, a conditional create) and never
replaced, and each event names the digest of the one before it. After this plan a command keeps
the events it has read in the context's local cache and, on the next read, serves the cached
contiguous prefix locally, reads the newest cached event once from the store to prove the copy
is still the store's, and fetches only the events after it. Callers still decode and validate the
whole chain, so the safety check is unchanged; the cost becomes one read plus the new tail.
Observable outcome: `NAGARE_TRACE=1 nagarectl inventory apply` on the intranet shows a handful of
remote gets instead of one per journal event, and the apply's wall time no longer grows with the
journal.


## Progress

- [x] M1: `readJournalPrefix` on an object store with a cache serves the cached contiguous prefix
  (`<cache>/journal/<n>.json`), re-reads the newest cached event with one `getImmutableObject`,
  fetches a tail of at most 64 events in waves of eight, and falls back to the batch for an empty
  cache, a longer tail or a differing anchor, writing what it fetched. Pass:
  `InventoryStoreOnceSpec` "a cached journal is anchored by one read and only its new tail is
  fetched (EP-217)": a cold read of 500 events is one batch; after 3 appends a read of 503 is 0
  batches and 4 single reads and returns the store's bytes; a tampered cached event (anchor
  intact) fails `validateJournal`; a differing newest event refills from one batch and validates.
- [x] M2: every journal reader goes through `readJournalPrefix` unchanged; the full
  `nagarectl-test` suite (including the recovery model's fast tier) passes and every mutation
  record still applies (`bee3babc`).
- [x] M3: ADR 22 records the rule (this commit). Intranet, 2026-10-22, packaged build of `bee3babc`, the same
  net-zero revoke and grant-back pair as EP-212 M4 under the operator's go-ahead. Cold copy (the
  revoke, `tx-bc378524…`): apply `remote gets 18 (69.11 s), cached gets 355`, wall 79.5 s, which
  filled 6,919 cached events. Warm copy (the grant, `tx-6a1406ad…`): apply `store opens 1,
  gcloud sessions 1 (2.14 s), head reads 10 (2.53 s), history loads 1 (0.03 s), remote gets 22
  (4.50 s), cached gets 7274, puts 10 (1.55 s), listings 0`, wall 12.5 s, against 67.2 s before.


## Decision Log

2026-10-22: Approach A, chosen by the operator over reading only the active transaction's
events: the chain is still validated over every event on every read; only where old events come
from changes. The cached prefix is bound to the store by re-reading its newest event (one GET):
any rewrite of an older event that keeps a valid chain changes that event's bytes. The residual
trade-off, accepted: an older remote event corrupted without repairing the chain is no longer
noticed by a client whose cache predates the corruption, because it validates its own copy.

2026-10-22: The tail is fetched per key only while it is short (at most 64 events); a longer tail
or an empty cache uses the existing batch transport, whose eight persistent workers are faster
than waves for thousands of events, and fills the cache.


## Context and Orientation

`cli/nagarectl/src/Nagare/Inventory/Store.hs`: `readJournalPrefix` (the object backend uses
`getObjects ops (ObjectName "journal")`, the batch in `Nagare.Inventory.Store.Gogol`), the digest
cache root carried by `ObjectBackend` (`~/.cache/nagare/<context>/inventory-blobs`,
`Nagare.Inventory.Store.Target.inventoryCacheRoot`), `getImmutableObject` (EP-213: one media
request, no generation, no listing), and `immutableReadWidth` (8). Journal keys are
`journalKey n` = `journal/<20-digit n>.json`. `Nagare.Inventory.Journal.validateJournal` checks
sequence numbers and that each `eventPreviousDigest` equals the digest of the event before.
Readers: `Execute/Journal.hs` (`readJournal`, `readJournalAtHead`), `Plan/History.hs`
(`loadUnstartedApplicationCreates`), `Status.hs` (`loadActiveTransactionStatus`),
`LineageHistory.hs`, `ScheduleHistory.hs`, `BootstrapRegistryRecovery.hs`.
Tests: `InventoryObjectOpsSpec` ("journal replay reads 50 and 500 committed members in one
batch"), `InventoryStoreOnceSpec`, the recovery model (`InventoryRecoveryModelSpec`).
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) owns the
store contract; [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
puts the proof in fakes; [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md)
governs the Haskell.


## Plan of Work

In `readJournalPrefix`'s object branch with `Just root`: read `root/journal/<n>.json` for
`n = 0 ..` while present and below the requested count (a contiguous prefix of `k` events). If
`k > 0`, read `journalKey (k - 1)` with `getImmutableObject`; if the bytes differ from the cached
ones, discard the copy. Then, if `k == count`, return the copy; if `count - k <= 64` and the copy
was anchored, fetch `journalKey k .. count - 1` in waves of eight with `getImmutableObject`
(missing is "committed journal event is missing"); otherwise use the batch as today. Write every
event fetched to the cache with `atomicWrite` (failures ignored, as for the digest cache). The
memory and filesystem backends and a store without a cache are unchanged.


## Concrete Steps

```bash
just haskell-style-check
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/journal/||/object store/||/fast tier/"' --test-show-details=direct
just gate-fast
```


## Validation and Acceptance

The M1 tests above, every existing suite and the recovery model's fast tier green, and the
intranet trace in M3.
