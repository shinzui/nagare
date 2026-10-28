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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T19:15:40Z
      verdict: "changes-requested"
      note: "The greater-than-64 tail fallback redownloads the full journal and reproduces the recorded latency failure; add long-tail acceptance and a bounded tail-only path."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T19:28:11Z
      mode: "update"
      note: "Reopen M4 for exact anchored suffix reads at every length, boundary and growth fixtures, preserved chain checks and explicit EP-221 handoff."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-28T21:13:15Z
      mode: "implement"
      note: "M4: exact anchored suffix at every tail length; 64-event full-prefix fallback removed; child Complete"
---

# Serve the committed journal from a verified local copy and fetch only its new tail

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It is a child of
[MasterPlan 29](../masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md),
added on 2026-10-22 when the intranet confirmation of EP-212 showed the apply bounded by the
journal.


## Purpose / Big Picture

Before M1-M3, every `inventory apply` downloaded the whole committed journal before it executed:
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
whole chain, so the safety check is unchanged. Remote work becomes one anchor read plus the new
tail; local reads and chain validation still grow with journal length. M1-M3 implemented this for
at most 64 new events. M4 is required because the released code downloads the full journal for a
longer tail, producing the 111.85 s apply recorded in the MasterPlan. A valid cached prefix must
never be downloaded again solely because its missing suffix is long. ObjectOps `remote gets`
counts a whole batch as one call, so exact keys and transport bytes are the remote-work proof.


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

- [x] M4: Every anchored suffix, including 64, 65 and 1,024 new events, fetches exactly one
  anchor and the missing event keys with at most eight requests in flight and no prefix batch.
  A 500-event and a 5,000-event cached prefix with the same suffix produce identical remote key
  sets relative to the anchor and identical transferred tail bytes for equal-sized events.
  Missing/failed tail reads refuse; tampered cached events still fail full-chain validation;
  an empty cache or differing anchor still refills from the existing batch. Pass: focused store
  tests and the Gogol HTTP fixture count the actual keys/downloads, then the recovery model's
  fast tier and `just gate-fast` pass. EP-221 owns the later released-command confirmation.
  Evidence, 2026-10-28: `readJournalCached` drops the 64-event condition and `journalTailLimit`.
  Before the change the new tests failed (the Gogol 65-event tail made 190 requests and 166
  media downloads; the 100-event failure case returned a journal through the batch). After it,
  `InventoryStoreOnceSpec` "every anchored suffix reads the anchor and exactly the missing
  events, whatever its length (EP-217 M4)" passes for (prefix, suffix) of (500, 0), (500, 1),
  (500, 64), (500, 65), (500, 1024) and (5000, 65): sorted keys read are exactly
  `[prefix - 1 .. prefix + suffix - 1]`, bytes read equal those events' sizes, 0 batches, 0
  listings, 2 to 8 reads in flight, and the 500- and 5,000-event prefixes request the same keys
  relative to the anchor. "a missing or unreadable tail event refuses with no partial journal
  and a retry succeeds (EP-217 M4)": `ImmutableMissing` and `ImmutableUnknown` at event 530 of a
  100-event tail return `Left`, the last key requested is 531 (the failing wave's end, no later
  wave), and the retry returns all 600 events. `InventoryGogolSpec` "a 65-event journal tail is
  one anchor and 65 event downloads, never the cached prefix (EP-217 M4)": 66 HTTP requests, 66
  media downloads of exactly `journal/99` to `journal/164`, response bytes equal to those
  events, 2 to 8 in flight. The M1 tamper and differing-anchor checks pass unchanged. Focused
  run (`/journal/||/object store/||/fast tier/`, including the recovery model's fast tier) and
  `just gate-fast` green; commit in the MasterPlan registry row.


## Surprises & Discoveries

The release run exceeded the short-tail limit after a platform transition and downloaded the
whole journal again: 111.85 s wall, 89.58 s summed remote-get time. The low logical get count did
not expose the number of event downloads inside the batch. This is why M4 counts object keys.


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


2026-10-28 revision: Supersede the 64-event fallback for valid anchors. Reuse the existing
waves-of-eight suffix reader for every tail length; do not change ObjectOps or introduce another
batch interface. This keeps scheduling deterministic for the recovery model and avoids turning
a large new suffix into a download of all old events. Only an absent/unusable anchor uses the
full-prefix fallback. ADR 22 records the revised rule as pending M4.


## Outcomes & Retrospective

M1-M3 reduced a warm apply from 67.2 s to 12.5 s in the recorded run; M4 removed the long-tail
full-prefix download, so a valid cached prefix is never fetched again. Complete. Release and growth
acceptance belongs to
[EP-221](221-close-the-reviewed-access-latency-gate-with-measured-command-costs.md).


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

M1-M3 are implemented in `readJournalCached` in `cli/nagarectl/src/Nagare/Inventory/Store.hs`.
For M4, retain `cachedPrefix`, the anchor comparison, atomic cache writes, and the existing
`fetchTail` implementation. Remove the `count - next > journalTailLimit` full-batch condition
and the unused `journalTailLimit`; when the anchor matches, run `fetchTail [next .. count - 1]`
regardless of suffix length. When it does not match, discard the cached prefix and use
`readJournalBatch` as before. Never use `readImmutableObjects` for journal keys: they are
sequence-named rather than content-digest-named, and journal validation supplies their integrity.

Extend `cli/nagarectl/test/InventoryStoreOnceSpec.hs` with boundary and growth cases before
changing the branch. Test suffix lengths 0, 1, 64, 65 and 1,024. With a valid anchor and `d` new
events, require exactly `d + 1` immutable reads, no `getObjects`, no listing, no event below the
anchor and no key beyond the pinned requested count. Compare 500- and 5,000-event prefixes with
the same suffix; assert key identity and bytes as well as counts. Add the representative
65-event case to `InventoryGogolSpec`: count HTTP media downloads and response bytes so the
logical ObjectOps wrapper cannot hide a full-prefix batch. Retain eight-read concurrency and
no scheduling of another wave after failure; no partial journal result is returned.

Prove missing tail events and transport failures refuse, an interrupted read can be retried,
a changed newest cached event causes a refill, and a tampered older cached event still fails
`validateJournal`. Leave the memory/filesystem/no-cache paths unchanged. Keep all readers on
`readJournalPrefix` and retain complete chain validation; no journal format or write changes.
Update ADR 22's pending implementation note when these checks pass. EP-221 then confirms the
released path and owns the latency evidence, so this child does not duplicate a live mutation.


## Concrete Steps

```bash
just haskell-style-check
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/journal/||/object store/||/fast tier/"' --test-show-details=direct
just gate-fast
```


## Validation and Acceptance

The historical M1-M3 evidence remains. M4 must meet its exact-key/count, failure and full-chain
checks at both sides of the 64/65 boundary and for a much longer suffix, and the existing
recovery model must remain green. `remote gets` alone is insufficient evidence: record actual
HTTP media requests and event bytes for the Gogol case. Completion is all four milestones;
EP-221's release benchmark is a subsequent integration gate.


## Idempotence and Recovery

This changes reads only. Atomic cache writes remain a disposable optimization; an interrupted
read returns no partial journal and can be retried against the same pinned count. Do not delete
or alter remote events to produce a fixture. Tests use temporary stores/cache roots. A cold or
invalid anchor still falls back to the full batch, whose performance is reported separately.


## Interfaces and Dependencies

Hard dependencies are completed [EP-212](212-open-the-inventory-store-once-per-command-and-load-its-history-once.md)
and [EP-213](213-read-immutable-inventory-members-concurrently-in-one-round-trip-each.md): their
counters, opened-store contract and `getImmutableObject` already exist. There is no dependency
on EP-221's new telemetry; this child's fixtures count exact operations directly. EP-221 waits
for this whole child to complete. `readJournalPrefix` and `ObjectOps` keep their public types;
M4 changes only the anchored suffix selection and its proofs.
