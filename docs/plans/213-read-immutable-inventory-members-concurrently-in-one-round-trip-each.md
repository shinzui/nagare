---
id: 213
slug: read-immutable-inventory-members-concurrently-in-one-round-trip-each
title: "Read immutable inventory members concurrently in one round trip each"
kind: exec-plan
created_at: 2026-10-22T20:22:26Z
master_plan: "docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T20:22:26Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-22T22:09:02Z
      mode: "implement"
      note: "Implement M1-M4: waves of eight immutable reads, one-request immutable GET, create-first publish"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-22T22:40:58Z
      mode: "implement"
      note: "Merged onto EP-212/214 and recorded the read-only intranet M5 trace"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T19:28:11Z
      mode: "update"
      note: "Reconcile waves, cached republish and HTTP counts; replace unsafe cache move/restore recipe with isolated XDG_CACHE_HOME."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T19:15:39Z
      verdict: "comments"
      note: "Concurrent digest-verified reads and create-first publish are present; reconcile semaphore/cancellation prose with waves, cached republish behavior, and the cache restoration commands."
---

# Read immutable inventory members concurrently in one round trip each

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It is a child of
[MasterPlan 29](../masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md).


## Purpose / Big Picture

When a `nagarectl` command's local digest cache is cold (a new workstation, a cleared
`~/.cache/nagare/<context>/inventory-blobs`, a CI runner), loading a context's accepted history
today fetches every scope member one after another, and each fetch is two HTTPS round trips: an
object-metadata request and then a generation-bound media download. For the intranet's 86 accepted
scopes at 0.15 s a round trip that is about 26 s before the command does anything. Publishing a
new review, scope or native object costs three more round trips each: a metadata GET that returns
404, a prefix listing that proves the absence, and the conditional PUT.

After this plan, the members a history load needs are read in one bounded concurrent batch of at
most eight downloads in flight, each immutable object is fetched with one media request and
verified by its content digest, and a digest-named publish attempts its conditional create first
and reads back only when the store refuses. On the local GCS fixture with 100 scopes and a cold
cache, a history load issues 100 member requests with at most eight in flight and finishes in
about thirteen fixture latencies instead of two hundred; with a warm cache it issues none. On the
intranet, `NAGARE_TRACE=1 nagarectl inventory status` on a cleared cache shows one remote GET per
member and a load that is seconds, not half a minute.

This is the cold-cache half of BUG-8's fix. The warm-path half (one open, one head, one load per
command) is EP-212; the two land independently.


## Progress

- [x] M1: `Nagare.Inventory.Store.readImmutableObjects` reads a list of immutable keys through
  the cache with bounded concurrency. Pass: a delaying fake `ObjectOps` records at most eight
  concurrent gets for 100 keys and zero gets when every key is cached; a key that is not
  digest-named is refused before any request; one failed get stops scheduling and the call returns
  `Left` with no partial map (`InventoryObjectOpsSpec`).
  Evidence: `InventoryImmutableReadSpec` (split from `InventoryObjectOpsSpec` for its size
  allowance). "immutable members load with at most eight reads in flight, and none from a warm
  cache": 100 reads cold, peak in flight between 2 and 8, 0 reads warm, and `head.json` in the
  list refused with 0 reads. "one failed immutable read schedules no further read, returns no
  partial map, and caches nothing for its key": a failure at the third key returns `Left`
  after 8 reads (its wave) with 7 cache files, none for the failed key; a missing member is
  `StoreInvalidObject "immutable member is missing"`. Pass.
- [x] M2: `loadInventoryHistory` reads accepted, retained, collected and migration members with
  one `readImmutableObjects` call and decodes them as today. Pass: `InventoryTransactionSpec`,
  `InventoryMigrationSpec`, `InventoryCloseSpec` and `InventoryAccessSpec` unchanged and green;
  the Gogol fixture counts 100 member requests and at most eight in flight for a 100-scope head.
  Evidence: those suites unchanged and green, with the recovery model (248 selected tests).
  `InventoryGogolSpec` "a 100-scope history reads each member with one media request, eight in
  flight, and none from a warm cache": cold load 102 requests, 101 of them media (100 members and
  the head's pinned download), peak in flight at most 8; warm load 2 requests (the head). Pass.
- [x] M3: The SDK transport fetches an immutable object with one media request and no metadata
  request, verified by digest in the store. Pass: fixture `mediaGets` equals `requests` for
  member reads; `head.json` and `format.json` still use the generation-bound two-step read; a
  media response whose digest differs is `StoreInvalidObject`, never cached.
  Evidence: `ObjectOps.getImmutableObject`. `InventoryGogolSpec` "an immutable member is one media
  request, its absence one 404, and a digest mismatch is never cached": a member is 1 request and
  1 media GET, an absent member 1 request (no listing), a forged member `StoreInvalidObject
  "remote immutable member digest mismatch"` with only the good member in the cache, and the head
  2 requests. The fixture now refuses an unpinned media GET of `head.json` or `format.json`, so
  every existing head test proves the two-step read. Pass.
- [x] M4: `publishIfAbsent` attempts the conditional create first. Pass: a new object costs one
  request on the fixture; an identical existing object costs a refused PUT and one read and
  succeeds idempotently; a different existing object is `StoreObjectConflict`; an unacknowledged
  PUT is classified by read-back as today (`InventoryGogolSpec` "conditional create is idempotent
  and competing values conflict", "landed write with failed acknowledgement is read back, never
  retried").
  Evidence: `InventoryGogolSpec` "a publish creates first and reads back only when the create is
  refused": after the writer's head check (2 requests), a new object is 1 request and 1 write; an
  identical one a refused create and the transport's read-back (3 requests) returning the digest;
  a different one `StoreObjectConflict`. The two named tests are unchanged and green. Pass.
- [x] M5: Intranet confirmation, read-only. With `NAGARE_TRACE=1`,
  `nagarectl --context intranet inventory status --json` from a development build of `79de5b0a`
  (the cache was left in place; an empty `XDG_CACHE_HOME` stood in for the moved-aside cache).
  Pass, 2026-10-22: cold, `store opens 1 (0.23 s), gcloud sessions 1 (2.07 s), head reads 1
  (0.26 s), history loads 1 (2.18 s), remote gets 373 (49.81 s summed across workers), cached
  gets 0, puts 0, listings 0`, and 371 blobs in the empty cache afterwards: one GET per member
  plus `format.json` and the head. Warm, the same command: `history loads 1 (0.02 s), remote gets
  2 (0.73 s), cached gets 371, listings 0`. The cold command's 45.8 s wall is `inventory status`
  reading accepted native payloads one at a time after the history load, outside this plan.


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

2026-10-22: Concurrency lives in the store, not the transport. `readImmutableObjects` bounds
in-flight reads with a semaphore over the existing cache-aware `readObjectUnlocked`, so the
memory, filesystem and legacy `gcloud` backends get the same function and the fakes count the
same calls. The Gogol transport's eight-worker journal batch stays as it is.

2026-10-22: Immutable objects are verified by digest, so they need no generation pin. The
two-step metadata-then-media read stays for `head.json` and `format.json`, whose generation the
compare-and-swap protocol needs.

2026-10-22 (implementation): Reads go in waves of eight, not a semaphore pool. The recovery model
places store faults by the ordinal of each get and compares whole runs; a pool that cancels on a
failure issues a schedule-dependent number of gets after the fault. A wave issues the same gets
whatever order its members finish in, so a fault anywhere in it gives the same run. The cost is
that one slow member holds its wave. The faulting store counts immutable reads as store gets and
the adversary takes a fault's boundary atomically. Admission's pinned store faults move from gets
20 and 21 to 11 and 12, since a publish no longer reads first.

2026-10-22 (implementation): An identical republish costs a refused create plus the transport's
existing read-back of the refused create (metadata and a pinned download), not one media read.
The Gogol `put` already classifies a refused `IfAbsent` create by read-back; the store adds no
read of its own unless that read-back reports a conflict.

2026-10-22: A digest-named publish tries the conditional create before reading. The create's
`ifGenerationMatch=0` is the absence proof; a 412 is followed by a read-back that accepts equal
bytes as idempotent success and reports different bytes as a conflict, which is what
`classifyPutReadback` already decides for an unacknowledged write.


2026-10-28 revision: Aligned the executable instructions with waves, cache-aware republishing
and real HTTP request counts. Replaced the cache move/restore commands with an isolated cache.
This child remains Complete; EP-217 and EP-221 own the outstanding performance work.


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)


## Context and Orientation

The walkthrough below is the pre-change baseline. Progress and Plan of Work describe the
implemented transport and waves; historical line numbers are not current source locations.

The inventory store (`cli/nagarectl/src/Nagare/Inventory/Store.hs`) keeps a context's recorded
state as objects under one prefix of a GCS bucket (or a local directory, or memory in tests). Two
kinds of object exist. Mutable objects, `head.json` and `format.json`, are replaced by
compare-and-swap on their provider generation. Immutable objects are named by the SHA-256 digest of
their bytes: `scopes/<digest>.json` (a scope member), `reviews/<digest>.json` (a published review),
`native/<digest>.json` and `objects/<digest>.json` (provider payloads). `immutableKeyDigest`
(line 1189) recognizes those four categories. The journal, `journal/<sequence>.json`, is written
once per sequence number and read as a prefix batch.

`readObjectUnlocked` (line 1130) is the one read path for the GCS backend. For an immutable key it
looks in the digest cache under `~/.cache/nagare/<context>/inventory-blobs`
(`Nagare.Inventory.Store.Target.inventoryCacheRoot`), verifies the file's digest, and only on a
miss calls the transport's `getObject`, verifies the digest again and writes the cache with
`Nagare.Inventory.Store.FileIO.atomicWrite`. The warm path is therefore local already; this plan
changes the miss path.

The transport is the `ObjectOps` record in `cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs`
(`getObject`, `getObjects`, `putObject`, `listObjects`, `pauseBeforeRetry`). The SDK
implementation is `cli/nagarectl/src/Nagare/Inventory/Store/Gogol.hs`. Its `get` sends
`StorageObjectsGet` for the metadata, then `download` with `Get.generation = Just gen`, and on a
404 lists the prefix (`listing name`) before answering `ObjectAbsent`, because a failed read is
never proof of absence. Its `batch` (the journal prefix) downloads with eight persistent workers
and no barrier; the comment above `workers` explains why. The admin API's reader store in
`Nagare/Inventory/Store/Service.hs` treats a 404 as absence without listing because it only reads.

`publishIfAbsent` (Store.hs line 748) reads the key first and writes only when it is absent, so a
new object costs a metadata GET, an absence listing and a PUT. `classifyPutReadback`
(ObjectOps.hs) already turns a read-back after an uncertain PUT into written, conflict or no-effect.

The history loader, `cli/nagarectl/src/Nagare/Inventory/Plan/History.hs`, reads members one by
one: `loaded <- traverse (loadScope store) (Map.toAscList (headAccepted headValue))` and the same
for retained incarnations, collected tombstones (which also read a review) and migration reviews.
EP-212 owns this file's entry points (`loadInventoryHistory`, a new `loadInventoryHistoryAt`,
`seedInventoryHistory`, `loadInventoryPlanningHistory`); this plan changes only how the members
are read inside the loader.

The tests that matter: `cli/nagarectl/test/InventoryGogolSpec.hs` runs the SDK transport against
an in-process Warp server (`fixture`, `server`) whose `Fixture` counts `requests`, `mediaGets` and
`maximumFlight` and can hold or truncate responses (`mode`); `InventoryObjectOpsSpec.hs` tests the
store over `Nagare.Test.World.ObjectStore.fakeObjectOps` and the adversarial
`Nagare.Test.World.Store.faultingObjectOps`; `InventoryTransactionSpec.hs` exercises the whole
plan-and-apply contract over the memory and object backends.

Haskell follows [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) and
`mori://shinzui/haskell-jitsurei/docs/core-standards`. The store contract is
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md); the proof
style is [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
the fixtures prove the counts, the intranet run confirms.


## Plan of Work

M1 implemented `readImmutableObjects` in `Nagare.Inventory.Store`. It validates all keys as
digest-named, deduplicates/sorts them and reads through the verified cache in waves of at most
eight using `mapConcurrently`. Every member of the current wave finishes; on any `Left`, no
later wave is scheduled and the result is `Left`, never a partial map. Successful reads in that
wave may populate the cache. There is no semaphore pool or sibling cancellation on `Left`.
A missing member is `StoreInvalidObject key "immutable member is missing"`. Memory and
filesystem backends retain the same result contract.

M2 rewrites the body of `loadInventoryHistory` so that it first collects the keys it will need
(accepted scope digests, retained scope digests, collected tombstones' scope and review digests,
migration review digests), reads them with one `readImmutableObjects`, and then runs the existing
per-member decoding and checks (`decodeScopeMember`, the retained owner checks, the collected
review digest check, the migration proof check) against the map. The pure checks do not move;
only the `readObject` calls inside `loadScope`, `loadRetained`, `loadCollected` and
`loadMigrationReview` become lookups.

M3 adds an immutable read to the transport. The cleanest shape is a new field on `ObjectOps`,
`getImmutableObject :: ObjectName -> IO ImmutableGet`, with `ImmutableFound ByteString`,
`ImmutableMissing` and `ImmutableUnknown Text`; the Gogol implementation downloads with
`Get.generation = Nothing` and no metadata request, maps a 404 to `ImmutableMissing` without
listing, and keeps the twenty-second attempt bound. The store's miss path for immutable keys calls
it and verifies the digest; a mismatch is `StoreInvalidObject` and is not cached. The legacy
`gcloudObjectOps`, the fake, the faulting wrapper and the service store implement the field too
(the fake by lookup, the service store by its existing exact GET). `getObject` keeps its
two-step semantics for the mutable keys.

M4 implemented create-first publication for uncached members. `publishIfAbsent` first checks
whether the verified local cache already contains the exact bytes; if so it returns the digest
without a remote call or write. Otherwise it performs the mutable-head guard and attempts the
conditional create. The transport classifies uncertain/refused writes by read-back; equal bytes
are idempotent success and different bytes conflict. An identical uncached republish costs the
refused PUT plus the transport's metadata and generation-bound media read (three HTTP requests,
excluding the head guard), not one media read. A remaining `StoreObjectConflict` is checked by
the store's existing read-back path. Journal keys are not digest-cached and retain their normal
conditional-create behavior. Existing Gogol conditional-write and lost-acknowledgement tests
prove these classifications.

M5 is the read-only intranet confirmation described in Progress. It uses the `NAGARE_TRACE=1`
summary EP-212 M1 adds; if EP-212 M1 has not landed, use `/usr/bin/time -l` and the gcloud and
kubectl PATH shims from EP-185 instead and record wall time only.


## Concrete Steps

Work in `cli/nagarectl`. After every Haskell change run the style check and the fast gate from
the repository root:

```bash
just haskell-style-check
just gate-fast
```

Run the focused suites while iterating:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/ObjectOps/||/Gogol/||/Transaction/||/Access/"' --test-show-details=direct
```

For M5, on the operator's workstation, use an isolated cache for a cold then warm read. The
normal cache is untouched; retain the temporary path with the evidence and remove only that
disposable directory when finished:

```bash
mp29_cache=$(mktemp -d)
XDG_CACHE_HOME="$mp29_cache" NAGARE_TRACE=1 nagarectl --context intranet inventory status --json > /dev/null
XDG_CACHE_HOME="$mp29_cache" NAGARE_TRACE=1 nagarectl --context intranet inventory status --json > /dev/null
```

Commit with Conventional Commits and both trailers, for example:

```text
perf(inventory): read immutable members with eight in flight and one round trip each

MasterPlan: docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md
ExecPlan: docs/plans/213-read-immutable-inventory-members-concurrently-in-one-round-trip-each.md
```


## Validation and Acceptance

- A 100-scope head on the Gogol fixture with an empty cache loads with `requests` equal to 100
  member GETs plus two head requests (102 total), `mediaGets` = 101 including the head
  download, and `maximumFlight` at most eight. With the cache populated the same load makes
  no member request.
- A delaying fake (`fakeObjectOps` wrapped to sleep 20 ms per get and record concurrency) proves
  the bound without the HTTP server; `faultingObjectOps` with `GetFailedOnce` proves one failure
  returns `Left` and no cache entry for the failed key.
- A member whose media bytes do not match its digest is reported as `StoreInvalidObject` and the
  cache has no file for that digest afterwards.
- Excluding the head guard, an uncached new publish costs one request; an identical uncached
  existing object costs a refused PUT plus metadata/media read-back (three requests). A verified
  cached identical republish costs zero remote calls. A different existing object conflicts.
- Every existing `nagarectl-test` test passes; `just gate-fast` is green; the mutation records in
  `cli/nagarectl/test/mutation` that name `publishIfAbsent` or the history loader still kill
  (prove with their exact `records.json` pattern).
- M5's trace line on the intranet is recorded in Progress.


## Idempotence and Recovery

Every step is a code change under test. The cache write stays atomic (`atomicWrite`), so an
interrupted batch leaves either a verified file or none. Cold measurements use a temporary
`XDG_CACHE_HOME`; no move/restore step can nest the old cache inside a newly populated one. Reverting the landed commit restores today's sequential reads.


## Interfaces and Dependencies

```haskell
-- cli/nagarectl/src/Nagare/Inventory/Store.hs
readImmutableObjects :: InventoryStore -> [FilePath] -> IO (Either StoreError (Map FilePath ByteString))
-- every key must have an immutableKeyDigest; at most eight remote reads in flight; no partial result

-- cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs
data ImmutableGet = ImmutableFound !ByteString | ImmutableMissing | ImmutableUnknown !Text
data ObjectOps = ObjectOps
  { getObject :: !(ObjectName -> IO GetOutcome)            -- unchanged: generation-bound, lists before absence
  , getImmutableObject :: !(ObjectName -> IO ImmutableGet) -- new: one media request, no listing
  , getObjects :: ...
  , putObject :: ...
  , listObjects :: ...
  , pauseBeforeRetry :: ...
  }
```

Depends on nothing. EP-212 owns the loader's entry points and the `Backend` constructor; this
plan does not change either. `Control.Concurrent.Async` is already used in the repository. The implementation uses waves,
not `Control.Concurrent.QSem`. EP-217 consumes the immutable transport for sequence-named
journal keys, and EP-218 owns the separate per-member-result reader; neither may weaken this
function's digest-key validation or fail-without-partial-result contract.
