---
id: 212
slug: open-the-inventory-store-once-per-command-and-load-its-history-once
title: "Open the inventory store once per command and load its history once"
kind: exec-plan
created_at: 2026-10-22T20:22:26Z
master_plan: "docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T20:22:26Z
---

# Open the inventory store once per command and load its history once

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It is a child of
[MasterPlan 29](../masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md)
and the warm-path half of
[BUG-8](../bug-reports/reviewed-access-change-reloads-inventory-history-sequentially.md)'s fix.


## Purpose / Big Picture

A reviewed access change on the intranet is two commands: `access team add-member … --save-plan
DIR` (or `access grant`) and `inventory apply DIR --yes`. On 2026-10-22 the first took 28 s and
the second 68 s for one relationship, on a workstation whose digest cache already held every
accepted scope. The time is not in reading scopes; it is in how often the command starts over.
A plan opens the GCS store twice, and each open runs a gcloud credential helper, two
project-ownership reads and a `format.json` fetch (about 5 to 6 s each on the intranet, measured
by EP-185). It reads `head.json` at least five times, loads the whole accepted history twice,
lists every object the context has ever written to compute a value it never uses, and only then
plans. An apply loads the history twice more, once to build the access adapter and once inside
admission.

After this plan a command opens its store once and proves bucket ownership once; reads the head
once and pins it; loads the history once from that pinned head and hands it to every consumer;
and never lists the prefix while planning. Admission, which must decide from the head it holds
under the writer lock, reuses the loaded history only when the locked head is byte-identical to
the pinned one and reloads otherwise. The compare-and-swap protocol, the journal and every
refusal are unchanged.

Observable outcome, with the new `NAGARE_TRACE=1` summary: a plan prints
`store opens 1, gcloud sessions 1, head reads 1, history loads 1, listings 0`; an apply of a
review whose head has not moved prints `history loads 1`. Today's values are 2, 2, 5 or more, 2
and 1 for a plan and 2 history loads for an apply. The MasterPlan's gate (plan under 5 s, apply
under 15 s at 100 scopes) is measured with the same summary once EP-213 and EP-214 have also
landed.


## Progress

- [ ] M1: Per-command counters. A store counts remote gets, cached gets, puts, listings, head
  reads, history loads, opens and gcloud sessions, with the time spent in each; `NAGARE_TRACE=1`
  prints one summary line on stderr when the command ends. Pass: a store over the counting fake
  reports the exact counts for a known sequence (`InventoryObjectOpsSpec`); a plan through the
  `ContractCommands` fixture prints the line; and, from a development build, a read-only
  `NAGARE_TRACE=1 nagarectl --context intranet inventory status --json` summary is recorded here
  as the pre-fix attribution. BUG-8's 27.3 s plan and 68 s apply stand as the wall-clock baseline;
  no second baseline is taken.
- [ ] M2: One open, one head, one history, no listing, for a plan. Pass: the `ContractCommands`
  fixture's plan reports opens 1, head reads 1, history loads 1, listings 0; `planRelationship`
  opens the store once and derives the snapshot from the pinned history with the same refusals as
  `loadTargetSnapshotReadOnly`; the review's `reviewHeadGeneration` and `reviewHeadSequence` are
  the pinned head's; all `InventoryTransactionSpec`, `InventoryAccessSpec` and
  `ContractCommands` tests pass.
- [ ] M3: One history per apply, reused under an unchanged head. Pass: the fixture's apply reports
  history loads 1 with the registry factory and admission sharing it; a store whose head is
  advanced by another writer between the pre-lock load and the lock reports history loads 2 and
  admission refuses `stale-head` as today; `InventoryRecoveryModelSpec` and the fast model tier
  are green.
- [ ] M4: ADR 22 amended with the one-open, one-pinned-head, reuse-under-equal-head rule;
  `docs/runbooks/inventory-operations.md` names `NAGARE_TRACE=1` beside `inventory store status`.
  Intranet confirmation, with the operator's go-ahead for the apply: one `access grant --save-plan`
  and its `inventory apply` with their summaries recorded here (this is also the first half of
  MasterPlan 29's gate).


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

2026-10-22: Thread the opened store and pinned history through the two hot paths explicitly;
do not add a process-wide memo of the gcloud session. The plan path (`planRelationship` and
`tryPrepareInventoryCandidateWithDeciderPayload`) and the apply path
(`applyInventoryWithFactory`, the registry factory, `admit`) are the commands BUG-8 measures.
Other commands that open twice (`Nagare.Cli.Inventory.Planning` runtimes) are not in that path
and keep their shape; they still gain EP-213's cold reads.

2026-10-22: A loaded history is reusable exactly when the head it was loaded from equals the
head in hand. `InventoryHistory` from `loadInventoryHistory` is a function of the head's bytes
and immutable digest-named objects, so equal heads mean equal histories. Admission compares the
head it observes under the lock with `historyHead` and reloads on any difference; it never
decides from a history of another head (ADR 26, ADR 27).

2026-10-22: Review preparation takes the pinned head, not a store snapshot. `prepareReview`
uses only `storeSnapshotHead`; the prefix listing that `readStoreSnapshot` performs stays
available for the callers that need review digests (`inventory status --legacy`, materialize,
app-database evidence, bootstrap recovery) and leaves the plan path.

2026-10-22: Counters live in the store and the summary follows `Nagare.Contract.Sink`'s
process-wide pattern. A store created by `openObjectStore` carries its counters; the transport
wrapper counts remote operations; the summary is printed by the CLI at exit only when
`NAGARE_TRACE=1` is set. Subprocess counts (gcloud, kubectl) come from EP-185's PATH shim, not
from code.


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)


## Context and Orientation

**The store.** `cli/nagarectl/src/Nagare/Inventory/Store.hs` is the inventory store: a
`HeadManifest` (`head.json`, line 194; it derives `Eq`) names the accepted and converged
revision of every scope, retained and collected members, the active transaction, claim, fence,
migration and transition; immutable digest-named objects hold scope members, reviews and native
payloads. `Backend` (line 255) is `FilesystemBackend`, `MemoryBackend` or
`ObjectBackend ObjectOps client cache lock guard guard`; `openObjectStore` (line 620) fetches
`format.json` and builds it. `readHead` (line 674) reads and decodes `head.json`;
`readStoreSnapshot` (line 704) reads the head and then `listObjectKeys` (line 1223), which on the
GCS backend lists the whole prefix; `readReviewSnapshot` (line 723) reads the head and one review
directly; `publishIfAbsent` (line 748) reads then conditionally writes; `readObjectUnlocked`
(line 1130) is the cache-aware read EP-213 changes.

**Opening.** `Nagare.Inventory.Command.openTargetStore` (`cli/nagarectl/src/Nagare/Inventory/Command.hs`,
line 791) opens the context's store for mutation: for a GCS context it first opens the local
filesystem store read-only to check for an unmigrated history, then calls
`Nagare.Inventory.Store.Target.openRemoteStore`, which calls
`Nagare.Inventory.Store.Remote.remoteObjectOps`. That runs `Nagare.Inventory.Store.GcloudAuth.newGcloudSession`
(`gcloud config config-helper`), two `readProjectNumber` reads for bucket and project ownership
(`Nagare.Ops.PulumiBackend`; each retries twice with 0.5 s and 1 s pauses when the output is not
a number), builds the SDK transport, creates the client identity and cache directory, and fetches
`format.json`. `openTargetStoreReadOnly` (`Store/Target.hs`, line 35) does the same without
creating anything. EP-185's profile put one open at about 5 to 6 s on the intranet
(`docs/plans/185-make-inventory-status-answer-in-seconds.md`, Decision Log, 2026-10-12).

**The plan path.** `Nagare.Access.Reviewed.planRelationship`
(`cli/nagarectl/src/Nagare/Access/Reviewed.hs`) calls `Command.loadTargetSnapshotReadOnly`
(Command.hs line 906: open read-only, `readHead`, refuse an unresolved transaction, claim, fence
or migration, `loadInventoryHistory`, `mkScopeSnapshot`), compiles the one scope, composes the
candidate and calls `Command.planInventoryCandidateWith`, which reaches
`tryPrepareInventoryCandidateWithDeciderPayload` (line 540): `openTargetStore` again,
`initializeStore` (reads the head), `seedInventoryHistory` (reads the head; acts only on an empty
store), `loadInventoryPlanningHistory` (`loadInventoryHistory`, which reads the head and every
member, then `loadUnstartedApplicationCreates`), the adapter registry, observation, `planChanges`,
`readStoreSnapshot` (reads the head, lists the prefix), `prepareReviewWithPayloadIdentity`
(`cli/nagarectl/src/Nagare/Inventory/Plan/Prepare.hs`, line 56; it uses only
`storeSnapshotHead`, line 71) and `publishReview`. `planPortalSync` and `checkEffectiveAccess` in
the same module open read-only once more.

**The history loader.** `cli/nagarectl/src/Nagare/Inventory/Plan/History.hs`:
`loadInventoryHistory` (line 129) reads the head and then every accepted, retained, collected and
migration member and runs the composition and migration checks; `loadInventoryPlanningHistory`
(line 283) calls it and adds `historyUnstartedCreates` from the journal for selected incomplete
scopes; `seedInventoryHistory` (line 349) reads the head and seeds an empty store. EP-213 owns
the member reads inside `loadInventoryHistory`; this plan owns the entry points.

**The apply path.** `Command.applyInventoryWithFactory` (line 581): `openTargetStore`,
`requireTransitionOwner` (reads the head), `loadPublishedReview` (review, scopes and native
objects, cached), the registry factory, `readReviewSnapshot` (head and the review),
`verifyReview`, `applyReviewed` (`cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs`,
line 213) which takes the process lock and calls `admit`
(`cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`, line 129). `admit` observes the head
(`observeCurrentHead`), runs the static checks against it, then `scheduledPruneRetention`
(line 321, loads the history when a scheduled prune is new), `retentionCoverage` (line 358, always
loads the history), `migrationCoverage` (line 476, loads it when the review migrates), then
claims the head and executes. The registry factory for apply is
`cli/nagarectl/app/Nagare/Cli/Inventory/Execution.hs` `inventoryExecutionRegistry` (line 169):
for an access-only review it calls `Nagare.Inventory.AccessRuntime.accessReviewAdapter`
(`cli/nagarectl/src/Nagare/Inventory/AccessRuntime.hs`, line 367), which calls
`loadInventoryHistory`; for other reviews it loads the history up to five times (lines 272, 287,
417, 456, 595) for app databases, DNS, retained members, retired members and topics.
`Nagare.Cli.Inventory.Workflow.runInventoryApply` and `runInventoryResume` wrap that factory in
`requireAccessKey`; `resumeInventoryWithFactoryTakeover`, `prepareRegistryRecoveryWithFactory`,
`recoverInventoryWithFactory` and `closeInventoryWithFactory` in Command.hs take the same
factory type `InventoryStore -> ReviewBundle -> IO AdapterRegistry`.

**Tests.** `cli/nagarectl/test/Nagare/Test/ContractCommands.hs` drives `planInventoryCandidateWith`
and the apply through a local-mode `ActiveTarget` under a temporary `XDG_STATE_HOME`
(`withFixture`, `fixtureActive`); `InventoryRenameCommandSpec.hs` does the same with
`openTargetStore`. `InventoryTransactionSpec.hs` exercises plan and apply over the memory and
object backends (`exerciseStore`, `preparedFixtureWith`); `Nagare.Test.World.ObjectStore.fakeObjectOps`
is the in-memory `ObjectOps`; `Nagare.Test.World.Store.faultingObjectOps` injects faults.
`InventoryRecoveryModelSpec.hs` is the recovery model whose fast tier runs in `just gate-fast`.

**Precedents.** `Nagare.Contract.Sink` is a process-wide output sink created with
`unsafePerformIO` and `NOINLINE`, the pattern for the trace summary. `Nagare.Inventory.Recorded`
(MasterPlan 28) reads one head and hydrates exactly that head; its reader is the model for
"pin the head, read from it".

**Rules.** [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
(the store contract, amended by M4), [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
(ownership is asserted on every command; once, never skipped),
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
(admission and convergence decide from the locked head),
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) (fixtures
prove, the intranet confirms), [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md)
with `mori://shinzui/haskell-jitsurei/docs/core-standards` (strict record fields, explicit deriving,
generic-lens labels).


## Plan of Work

**M1, counters.** Add `Nagare.Inventory.Store.Counters`: a `StoreCounters` record of `IORef Int`
pairs (count and nanoseconds) per `Counter` (`RemoteGet`, `CachedGet`, `RemotePut`,
`RemoteList`, `HeadRead`, `HistoryLoad`, `StoreOpen`, `GcloudSession`), with `newStoreCounters`,
`counted :: StoreCounters -> Counter -> IO a -> IO a` (bumps the count and adds the elapsed
monotonic time) and `snapshotCounters`. `ObjectBackend` gains a `StoreCounters` field;
`openObjectStore` creates it and counts itself as one `StoreOpen`; `remoteObjectOps` wraps the
transport so that `getObject`, `getObjects`, `putObject` and `listObjects` count as remote
operations and the gcloud session creation counts once. `readObjectUnlocked` counts a cache hit as
`CachedGet`; `readHead` counts `HeadRead`; `loadInventoryHistory` counts `HistoryLoad`. The
summary: `Nagare.Inventory.Store.Counters.registerForTrace` records every created counters
record in a process-wide list (the `Contract.Sink` pattern) when `NAGARE_TRACE` is set, and
`Nagare.Cli.Main` prints one line per store at exit, for example
`nagarectl trace: store opens 1 (5.1 s), gcloud sessions 1 (0.6 s), head reads 1 (0.3 s), history loads 1 (0.4 s), remote gets 3, cached gets 86, puts 3, listings 0, wall 7.9 s`.
Expose `storeCounters :: InventoryStore -> Maybe StoreCounters` for tests. The memory and
filesystem backends can carry counters too (cheaply) so the `ContractCommands` fixture, which
uses a local store, can assert head reads and history loads.

**M2, the plan path.** In `Nagare.Inventory.Plan.History` add
`loadInventoryHistoryAt :: InventoryStore -> HeadManifest -> IO (Either StoreError InventoryHistory)`
(the body of today's loader after the head read) and make `loadInventoryHistory` read the head
and call it. Make `seedInventoryHistory` take the `HeadManifest` it already read, and
`loadInventoryPlanningHistory` take the loaded `InventoryHistory` instead of loading. In
`Nagare.Inventory.Command` add

```haskell
data OpenedInventory = OpenedInventory
  { openedStore :: !InventoryStore
  , openedHead :: !HeadManifest
  , openedHistory :: !InventoryHistory
  }

openInventoryForPlanning :: ActiveTarget -> IO OpenedInventory
```

which opens once with `openTargetStore`, reads the head once, applies
`loadTargetSnapshotReadOnly`'s refusals (absent head, foreign binding, unresolved transaction,
claim, fence or migration), and loads the history once. Add
`tryPrepareInventoryCandidateLoaded`, which takes an `OpenedInventory` and does what
`tryPrepareInventoryCandidateWithDeciderPayload` does minus the open, `initializeStore`,
`seedInventoryHistory` (the head is non-empty, or the opener seeded and reloaded) and
`readStoreSnapshot`; it computes the planning history from the loaded one and passes the pinned
head to `prepareReviewWithPayloadIdentity`, whose `StoreSnapshot` parameter becomes a
`HeadManifest`. Keep `tryPrepareInventoryCandidateWithDeciderPayload` as the opener-plus-loaded
composition so every existing caller is unchanged except for the counts. `planRelationship`
becomes: open once, build the snapshot from `openedHistory` with `mkScopeSnapshot`, compile,
compose, `withEnApiKey` around `planInventoryCandidateLoaded`. `planPortalSync` and
`checkEffectiveAccess` use the same opener.

**M3, the apply path.** `applyInventoryWithFactory` reads the head once after
`requireTransitionOwner` (fold that function's read into it), loads the history at that head, and
passes both to the factory and to `applyReviewed`. The factory type becomes
`OpenedInventory -> ReviewBundle -> IO AdapterRegistry` for every `…WithFactory` function;
`inventoryExecutionRegistry` and `accessReviewAdapter` take the history from it instead of loading
(coordinate the latter's signature with EP-214, which changes its transport argument at the same
time). `applyReviewed` and `admit` take `Maybe InventoryHistory`; after `observeCurrentHead`,
`admit` uses the given history when `historyHead given == headValue` and otherwise calls
`loadInventoryHistoryAt store headValue`, and hands the chosen history to
`scheduledPruneRetention`, `retentionCoverage` and `migrationCoverage`, which stop loading
themselves. `readReviewSnapshot`'s head read folds into the same single read where the review
digest check keeps its direct, uncached GET. Resume, recover and close pass `Nothing` unless they
already hold a history.

**M4, durable context and confirmation.** Amend ADR 22 with a dated paragraph: a command opens its
store once and asserts ownership once; it pins the head it read and loads history from that head;
a loaded history is reused only under a byte-identical head; a mutation re-observes the head under
the writer lock before every conditional write. Add one sentence to
`docs/runbooks/inventory-operations.md` where `inventory store status --json` is described:
`NAGARE_TRACE=1` prints the store's operation counts and times on stderr. Then the intranet
confirmation (Progress M4), with the operator's go-ahead for the apply.


## Concrete Steps

From the repository root after every Haskell change:

```bash
just haskell-style-check
just gate-fast
```

Focused suites while iterating:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/ObjectOps/||/Transaction/||/Access/||/Contract/||/RecoveryModel/"' --test-show-details=direct
```

Pre-fix attribution from a development build, read-only, in a clean shell as
`docs/user/local-development.md` and the operator's notes prescribe:

```bash
NAGARE_TRACE=1 nagarectl --context intranet inventory status --json > /dev/null
```

Commit message shape:

```text
perf(inventory): open the store once per command and load one history from a pinned head

MasterPlan: docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md
ExecPlan: docs/plans/212-open-the-inventory-store-once-per-command-and-load-its-history-once.md
```


## Validation and Acceptance

- `InventoryObjectOpsSpec`: a store over `fakeObjectOps` with counters, after `readHead`, one
  cached read, one remote read and one `publishIfAbsent`, snapshots head reads 1, cached gets 1,
  remote gets 2 (the miss and the publish's read; EP-213 M4 later makes the publish 0 reads) and
  puts 1.
- `ContractCommands`: the plan reports opens 1, head reads 1, history loads 1, listings 0; the
  apply reports history loads 1. Before M2 the same assertions show the current counts, which is
  the evidence that the test measures the right thing.
- `InventoryTransactionSpec` over the object backend: a plan's review carries the pinned head's
  generation and sequence; an apply after another writer's head advance is refused `stale-head`
  with history loads 2 and no claim taken.
- Every existing `nagarectl-test` test passes, `InventoryRecoveryModelSpec`'s fast tier passes and
  `just gate-fast` is green. Mutation records under `cli/nagarectl/test/mutation` that name
  `admit`, `retentionCoverage`, `loadInventoryHistory` or `tryPrepareInventoryCandidateWithDeciderPayload`
  still kill, proved with their exact `records.json` patterns.
- Intranet (M4): the plan's trace shows store opens 1, gcloud sessions 1, head reads 1, history
  loads 1, listings 0; the apply's shows history loads 1. Wall times are recorded but the
  MasterPlan's thresholds are judged after EP-213 and EP-214.


## Idempotence and Recovery

Every milestone is a code change under test. Nothing changes the bytes written to the store: the
same review document, scope members and journal events are produced, so a review planned by the
new code applies on the old and the reverse. Reverting the landed commit restores today's opens
and loads. The intranet confirmation is one ordinary reviewed change that the operator would make
anyway; if it stops, `inventory resume` finishes it as for any review.


## Interfaces and Dependencies

```haskell
-- cli/nagarectl/src/Nagare/Inventory/Store/Counters.hs (new)
data Counter = RemoteGet | CachedGet | RemotePut | RemoteList | HeadRead | HistoryLoad | StoreOpen | GcloudSession
newStoreCounters :: IO StoreCounters
counted :: StoreCounters -> Counter -> IO a -> IO a
snapshotCounters :: StoreCounters -> IO (Map Counter (Int, Double))   -- count, seconds

-- cli/nagarectl/src/Nagare/Inventory/Store.hs
storeCounters :: InventoryStore -> Maybe StoreCounters

-- cli/nagarectl/src/Nagare/Inventory/Plan/History.hs
loadInventoryHistoryAt :: InventoryStore -> HeadManifest -> IO (Either StoreError InventoryHistory)
seedInventoryHistory :: InventoryStore -> HeadManifest -> CompositionCandidate -> IO (Either StoreError HeadManifest)
loadInventoryPlanningHistory :: InventoryStore -> InventoryHistory -> CompositionCandidate -> IO (Either StoreError InventoryHistory)

-- cli/nagarectl/src/Nagare/Inventory/Plan/Prepare.hs
prepareReviewWithPayloadIdentity :: Text -> AdapterRegistry -> HeadManifest -> ChangeProposal -> IO (Either (NonEmpty PrepareError) ReviewBundle)

-- cli/nagarectl/src/Nagare/Inventory/Command.hs
data OpenedInventory = OpenedInventory { openedStore :: !InventoryStore, openedHead :: !HeadManifest, openedHistory :: !InventoryHistory }
openInventoryForPlanning :: ActiveTarget -> IO OpenedInventory
tryPrepareInventoryCandidateLoaded :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) -> (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) -> Text -> OpenedInventory -> CompositionCandidate -> IO (Either Text (InventoryStore, ReviewBundle, ContentDigest))
applyInventoryWithFactory :: (OpenedInventory -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> FilePath -> Bool -> IO ()

-- cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs and Admission.hs
applyReviewed :: InventoryStore -> AdapterRegistry -> ReviewedPlan -> Maybe InventoryHistory -> IO (Either (NonEmpty AdmissionError) TransactionResult)
admit :: LockedStore s -> AdapterRegistry -> ReviewedPlan -> Maybe InventoryHistory -> IO (Either (NonEmpty AdmissionError) (ExecutablePlan s))
-- reuse only when historyHead given == the head observed under the lock
```

No hard dependency. EP-213 edits the member reads inside `loadInventoryHistoryAt`'s body and
adds store read functions; this plan does not touch those lines. EP-214 edits
`accessReviewAdapter`'s transport argument while this plan edits its history argument; the second
to land rebases. EP-215 waits for this plan's `planRelationship`.
