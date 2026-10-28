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
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-22T22:38:49Z
      mode: "implement"
      note: "EP-212 M1-M3 implemented; EP-213 and EP-214 merged onto it, fast gate green at db83d2b6"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T19:28:11Z
      mode: "update"
      note: "Reconcile completed API signatures, logical counter semantics and stale-head acceptance; assign remaining latency work to EP-221."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T19:15:39Z
      verdict: "comments"
      note: "One-open and locked-head reuse are present with focused proofs; historical Interfaces and Validation sections still disagree with the implemented signatures and counters."
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

- [x] M1: Per-command counters (`Nagare.Inventory.Store.Counters`). Every opened store counts
  opens, gcloud sessions, head reads, history loads, remote gets, cached gets, puts and listings
  with their time; `NAGARE_TRACE=1` prints one line per store and the wall time when the command
  ends (`Nagare.Cli.Dispatch`). Pass: `InventoryStoreOnceSpec` "a store counts its open, head
  reads, cached and remote gets and puts" asserts opens 1, head reads 1, history loads 0, remote
  gets 4, cached gets 2, puts 1, listings 0 for the current sequence over `fakeObjectOps`
  (including the verified-cache republish added after initial integration). The
  intranet attribution run is recorded under M4.
- [x] M2: One open, one head, one history, no listing, for a plan. `Command.openInventoryForPlanning`
  opens once (never initializing, with `loadTargetSnapshotReadOnly`'s refusals, which it now
  implements), reads the head once and loads the history at it; `planInventoryCandidateLoaded`
  plans against it and `prepareReviewWithPayloadIdentity` takes the pinned head, so the review
  carries its generation and sequence and nothing lists the prefix. `planRelationship` and
  `planPortalSync` use it. Pass: `ContractCommands` "a plan opens one store, one head and one
  history and lists nothing" gives one store with `[opens, head reads, history loads, listings]`
  = `[1, 1, 1, 0]` (the code review behind MasterPlan 29 read two opens, at least five head
  reads, two loads and a listing on this path before).
- [x] M3: One history per apply, reused under an unchanged head. `applyInventoryWithFactory`
  reads the head once, loads the history at it and passes it to the registry factory
  (`ReviewInventory`, whose `pinnedHistory` is `Nothing` for resume, recover and close, which load
  as before) and to `applyReviewedWithHistory`; admission uses it only when the head observed
  under the lock equals its head and otherwise loads the locked head's history once for all three
  coverage checks. Pass: `ContractCommands` apply gives `[opens, history loads, listings]` =
  `[1, 1, 0]`; `InventoryStoreOnceSpec` "admission reuses a pinned history only under the head it
  was loaded from" counts 0 admission loads for the equal head and 1 for another head, both
  converging. A stale head is refused by the static checks before any history is used, as before.
  `ADR27-N8-collection-unverified` regenerated for the moved admission lines; it and the six other
  admission records still kill with their `records.json` patterns.
- [x] M4: ADR 22 amended with the one-open, one-pinned-head, reuse-under-equal-head rule and
  `docs/runbooks/inventory-operations.md` naming `NAGARE_TRACE=1` (both `624fa813`). Read-only
  attribution, development build of `79de5b0a`, `inventory status --json`: `store opens 1
  (0.44 s), gcloud sessions 1 (2.04 s), head reads 1 (0.29 s), history loads 1 (0.02 s), remote
  gets 2 (0.73 s), cached gets 371, listings 0`. On 2026-10-22, with the operator's go-ahead, a packaged build of `c9ebbb8b` ran a net-zero pair
  on the intranet: revoke, then grant back, of `user_01m4py1q2fesvbtd7xnxr7yede`'s direct grant on
  `keiro-docs.labs.topagentnetwork.net` (team `engineering`'s grant covered the host throughout;
  `access check` afterwards: allowed, grant generation 30). Converged `tx-5f35379e…` (revoke) and
  `tx-8a08c6a9…` (grant). A first revoke apply was refused `stale-head`/`stale-base` before
  admission with no effect: another writer advanced the head from 7247 to 7253 while it waited.
  Pass: the grant plan printed `store opens 1 (0.20 s), gcloud sessions 1 (2.73 s), head reads 1
  (0.26 s), history loads 1 (0.02 s), remote gets 92 (17.04 s), cached gets 88, puts 90
  (20.90 s), listings 0`, wall 43.2 s; its apply `store opens 1, gcloud sessions 1 (1.86 s), head
  reads 10 (1.93 s), history loads 1 (0.03 s), remote gets 20 (59.62 s), cached gets 353, puts 10
  (1.32 s), listings 0`, wall 67.2 s (the revoke pair: 46.3 s and 68.2 s). The plan's 90 puts were
  EP-213's create-first publish re-sending cached scope members, fixed in `b95d479b`; the apply's
  time is the execute path reading the whole journal, recorded in MasterPlan 29.


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

2026-10-22: The registry factory takes a `ReviewInventory` (store and optional pinned history),
not the `OpenedInventory` the plan named. Resume, recover and close have no pinned history and
must keep loading exactly as before, and the old `seedInventoryHistory`,
`loadInventoryPlanningHistory` and `prepareReview` keep their signatures beside new `…At`/`…From`
variants so tests and other callers are unchanged.

2026-10-22: To keep the module size ratchet, the head-manifest types moved to
`Nagare.Inventory.Store.Manifest` (re-exported by `Nagare.Inventory.Store`, whose allowance is
removed) and store opening to `Nagare.Inventory.Command.Open`.

2026-10-22: Counters live in the store and the summary follows `Nagare.Contract.Sink`'s
process-wide pattern. A store created by `openObjectStore` carries its counters; the transport
wrapper counts remote operations; the summary is printed by the CLI at exit only when
`NAGARE_TRACE=1` is set. Subprocess counts (gcloud, kubectl) come from EP-185's PATH shim, not
from code.


2026-10-28 revision: Reconciled implementation signatures, counter values and stale-head
acceptance with the current code; explicitly labeled the old context walkthrough as historical.
The completed one-open/pinned-history work remains accepted; EP-221 owns the failed latency gate.


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)


## Context and Orientation

The following call-site walkthrough describes the pre-change baseline at `4e0efd38`; its line
numbers and old signatures are historical. Progress, Plan of Work and Interfaces describe the
accepted implementation. EP-221 owns the still-open end-to-end latency target.

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

These milestones are implemented. This section records the accepted shape for follow-up work;
it does not instruct a future contributor to replace compatibility wrappers with old sketches.

M1 added `Nagare.Inventory.Store.Counters`. Every backend carries `StoreCounters` and
`Nagare.Cli.Dispatch` uses `withStoreTrace` to print summaries on stderr when `NAGARE_TRACE=1`.
`countingObjectOps` counts logical remote operations: one `getObjects` batch counts as one
`RemoteGet`, regardless of HTTP requests or bytes. The `GcloudSession` interval currently
includes ownership reads and transport construction. Subprocess/forward counts use EP-185's
PATH shim. EP-221 owns finer attribution; the logical counter meanings stay stable.

M2 added `OpenedInventory` in `Nagare.Inventory.Command.Open`, re-exported through Command.
`openInventoryForPlanning` opens read-only, requires an existing idle head belonging to the
context, and returns `inventoryStore`, `pinnedHead` and `loadedHistory`. It never seeds an absent
store. `planRelationship` and `planPortalSync` use `openedSnapshot` and
`planInventoryCandidateLoaded`. `loadTargetSnapshotReadOnly`, also used by effective-access
checks, delegates to the same opener. The loaded planner calls `seedInventoryHistoryAt` and
`loadInventoryPlanningHistoryFrom`; old wrappers retain their signatures for other callers.
`prepareReviewWithPayloadIdentity` takes the pinned `HeadManifest`, so planning needs no prefix
listing. `prepareReview` retains its snapshot compatibility wrapper.

M3 passes `ReviewInventory` to registry factories. It contains `executionStore` and optional
`pinnedHistory`; apply supplies the loaded history, while resume/recover/close without one keep
loading through `reviewInventoryHistory`. `applyReviewedWithHistory` and `admitWithHistory`
accept the optional history; the original `applyReviewed` and `admit` remain wrappers. Admission
first checks the locked head, reuses history only if equal, and otherwise memoizes one reload for
the coverage checks. Static stale-head refusals precede history use; they do not promise a second
load. Writes retain their locked-head observations and review publication proof.

M4 amended ADR 22 and the operations runbook and recorded the attribution evidence in Progress.
It proved this child's command-count contract, not the MasterPlan's wall-time target. That
remaining acceptance is assigned to
[EP-221](221-close-the-reviewed-access-latency-gate-with-measured-command-costs.md).


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

- `InventoryStoreOnceSpec`: the current fixture's open/read/cache/republish/new-publish sequence
  reports `[StoreOpen, HeadRead, HistoryLoad, RemoteGet, CachedGet, RemotePut, Listing]` =
  `[1, 1, 0, 4, 2, 1, 0]`. A verified cached republish makes no remote call.
- `ContractCommands`: the plan reports opens 1, head reads 1, history loads 1, listings 0; the
  apply reports history loads 1. Before M2 the same assertions show the current counts, which is
  the evidence that the test measures the right thing.
- `InventoryTransactionSpec` over the object backend: a plan's review carries the pinned head's
  generation and sequence; an apply after another writer's head advance is refused `stale-head`
  before a claim or admission history load. Separately, an injected mismatching pinned-history
  head with an otherwise admissible review reloads once; an equal pinned-history head reloads
  zero times, as `InventoryStoreOnceSpec` proves.
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
-- cli/nagarectl/src/Nagare/Inventory/Store/Counters.hs
data Counter = StoreOpen | GcloudSession | HeadRead | HistoryLoad | RemoteGet | CachedGet | RemotePut | Listing
newStoreCounters :: Text -> IO StoreCounters
snapshotCounters :: StoreCounters -> IO CounterSnapshot
-- Store.hs: all backends carry counters
storeCounters :: InventoryStore -> StoreCounters

-- cli/nagarectl/src/Nagare/Inventory/Plan/History.hs
loadInventoryHistoryAt :: InventoryStore -> HeadManifest -> IO (Either StoreError InventoryHistory)
seedInventoryHistoryAt :: InventoryStore -> HeadManifest -> CompositionCandidate -> IO (Either StoreError HeadManifest)
loadInventoryPlanningHistoryFrom :: InventoryStore -> InventoryHistory -> CompositionCandidate -> IO (Either StoreError InventoryHistory)
data ReviewInventory = ReviewInventory
  { executionStore :: !InventoryStore
  , pinnedHistory :: !(Maybe InventoryHistory)
  }

-- cli/nagarectl/src/Nagare/Inventory/Command/Open.hs; re-exported by Command
-- OpenedInventory fields: inventoryStore, pinnedHead, loadedHistory
openInventoryForPlanning :: ActiveTarget -> IO OpenedInventory
openedSnapshot :: OpenedInventory -> IO ScopeSnapshot

-- cli/nagarectl/src/Nagare/Inventory/Command.hs
tryPrepareInventoryCandidateLoaded :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) -> (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) -> Text -> ActiveTarget -> OpenedInventory -> CompositionCandidate -> IO (Either Text (InventoryStore, ReviewBundle, ContentDigest))
applyInventoryWithFactory :: (ReviewInventory -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> FilePath -> Bool -> IO ()

-- cli/nagarectl/src/Nagare/Inventory/Plan/Prepare.hs
prepareReviewWithPayloadIdentity :: Text -> AdapterRegistry -> HeadManifest -> ChangeProposal -> IO (Either (NonEmpty PrepareError) ReviewBundle)

-- cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs and Admission.hs
applyReviewedWithHistory :: InventoryStore -> AdapterRegistry -> ReviewedPlan -> Maybe InventoryHistory -> IO (Either (NonEmpty AdmissionError) TransactionResult)
admitWithHistory :: LockedStore s -> AdapterRegistry -> ReviewedPlan -> Maybe InventoryHistory -> IO (Either (NonEmpty AdmissionError) (ExecutablePlan s))
```

No hard dependency. EP-213 owns member reads inside the history loader; EP-214 owns transport
arguments. Both are integrated. EP-215 consumes the accepted planner, EP-217 consumes the store
and counters, and EP-221 owns further fixed-cost work. This child remains Complete.
