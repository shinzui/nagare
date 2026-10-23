---
id: 218
slug: read-inventory-status-native-evidence-concurrently
title: "Read inventory status native evidence concurrently"
kind: exec-plan
created_at: 2026-10-22T23:31:41Z
master_plan: "docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-22T23:31:41Z
---

# Read inventory status native evidence concurrently

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It is a child of
[MasterPlan 29](../masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md),
added on 2026-10-22.


## Purpose / Big Picture

With a cold digest cache (a new workstation, a cleared cache, a CI runner),
`nagarectl --context intranet inventory status --json` took 45.8 s on 2026-10-22 although its
history loaded in 2.18 s (EP-213 M5): after the history it reads the accepted native payloads
(`native/<digest>.json`, about 270) one at a time. After this plan those reads go in waves of
eight, so a cold status costs a few seconds more than its history load; a warm one is unchanged.


## Progress

- [x] M1: `loadObservationNativeChecked` reads its native members with one call to the new
  `Nagare.Inventory.Store.readImmutableObjectsEach` (waves of eight, every key read, each result
  kept) and applies today's per-member checks, so a missing member still selects the legacy
  reader and an invalid one is reported first. Pass: `InventoryImmutableReadSpec` "every member's
  own result is read with at most eight in flight, a missing one among them (EP-218)": 101 reads
  for 100 members and one absent key, the absent one `Right Nothing`, at most eight in flight;
  the full `nagarectl-test` suite passes (`bee3babc`).
- [x] M2: Intranet, read-only, 2026-10-22, development build of `bee3babc`, empty
  `XDG_CACHE_HOME`, `inventory status --json`: `store opens 1 (0.60 s), gcloud sessions 1
  (2.60 s), head reads 1 (0.21 s), history loads 1 (1.93 s), remote gets 375 (40.59 s summed
  across workers), cached gets 0, listings 0`, wall 11.75 s, down from 45.8 s.


## Decision Log

2026-10-22: The operator chose fixing this over a deferral-ledger entry, inside MasterPlan 29.
The batch keeps one result per member instead of reusing `readImmutableObjects`, which stops at
the first failure, because this reader's semantics distinguish a missing member (fall back to the
legacy review reader) from an invalid one (refuse).


## Context and Orientation

`cli/nagarectl/src/Nagare/Inventory/ObservationNative.hs` `loadObservationNativeChecked` reads
each `objectKeyFor "native" digest` with `readObject` inside `Map.traverseWithKey`.
`Nagare.Inventory.Status.loadNativeFor` calls it for status, recovery and planning.
`cli/nagarectl/src/Nagare/Inventory/Store.hs` holds `readImmutableObjects` (EP-213's waves of
eight over the cache-aware read). Proofs live in fakes
([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md));
Haskell per [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md).


## Plan of Work

Add `readImmutableObjectsEach :: InventoryStore -> [FilePath] -> IO (Map FilePath (Either
StoreError (Maybe ByteString)))` to `Nagare.Inventory.Store`: the same waves of eight, every key
read, each result kept. `loadObservationNativeChecked` maps its digests to keys, calls it once,
and applies today's per-member checks to the results.


## Concrete Steps

```bash
just haskell-style-check
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/status/||/object store/||/native/"' --test-show-details=direct
just gate-fast
```


## Validation and Acceptance

M1's tests, every existing suite green, and M2's trace.
