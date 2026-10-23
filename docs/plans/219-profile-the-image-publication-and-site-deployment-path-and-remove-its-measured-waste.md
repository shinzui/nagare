---
id: 219
slug: profile-the-image-publication-and-site-deployment-path-and-remove-its-measured-waste
title: "Profile the image publication and site deployment path and remove its measured waste"
kind: exec-plan
created_at: 2026-10-23T03:57:16Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-23T03:57:16Z
---

# Profile the image publication and site deployment path and remove its measured waste

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It implements
[IR-37](../improvement-requests/profile-the-complete-image-publication-and-site-deployment-path.md).


## Purpose / Big Picture

On 2026-10-23 the operator released the protected TAN Connect site in `mori://tan/tan-ng-labs`
with Nagare v0.9.0. The Docker archive existed at 01:33:09 UTC and the new Knative revision was
Ready at 01:38:04 UTC: about 295 s for four commands, against 33 s to build, test and package
the image. Nothing recorded where those 295 s went, because v0.9.0 had no trace and v0.10.0's
`NAGARE_TRACE=1` only counts inventory store work.

After this plan an operator who runs the four release commands with `NAGARE_TRACE=1` sees, on
stderr, each phase start and finish (typed-configuration load, archive inspection, inventory
read, provider observation per executor, credential guard and registry login, registry upload,
admission, journal writes, readiness wait) and, when the command ends however it ends, one
summary that names each phase's count and time, marks nested and concurrent time, and states how
much of the wall time no phase covers. Stdout, review bytes, journals, exit codes and every
safety check are unchanged. The measured waste on the path is then removed, with before-and-after
traces recorded here, and what remains is explained.

The sequence profiled, with an archive that already exists:

```text
nagarectl app image-plan --archive A --destination D --key K --save-plan IMAGE_REVIEW
nagarectl inventory apply IMAGE_REVIEW --yes
nagarectl site deploy -f nagare/Config.hs --skip-build --tag T --image-resource PUBLICATION --save-plan SITE_REVIEW
nagarectl inventory apply SITE_REVIEW --yes
```


## Progress

- [ ] M1: Phase tracing. `Nagare.Inventory.Trace` records phases from a closed label type with
  an injected monotonic clock and sink; `withCommandTrace` replaces `withStoreTrace` in
  `dispatchTraced` and prints start, done and failed lines plus a final summary on stderr. Pass:
  `InventoryTraceSpec` proves, with a fake clock, nested attribution, a concurrent phase marked
  with its peak in-flight count, the union of top-level intervals reported as attributed time
  and the rest as unattributed, a phase that throws (including `exitWith`) reported `failed`
  with its elapsed time and the summary still printed, and nothing printed when tracing is off.
- [ ] M2: The four commands are instrumented. Pass: with a fake clock, a fake artifact transport
  that delays and then fails, and a fake kubectl interpreter that delays its `wait`, the traced
  image apply attributes the delay to `artifact transport publish` > `registry copy` and the site
  apply to `readiness ksvc`; the failing transport prints `failed` lines and a summary and exits
  as untraced; a traced and an untraced run of the `ContractCommands` plan and apply fixture
  produce identical stdout, identical `review.json` bytes and identical normalized journals; a
  token and a password seeded into the fake environment never appear on stderr.
- [ ] M3: Local profile. On a disposable local context bootstrapped by
  `scripts/site-access-drill.sh` with `NAGARE_DRILL_BOOTSTRAP_ONLY=1`, the four commands for the
  protected static site are run cold and then warm, once with the published v0.10.0 `nagarectl`
  (outer timer and store trace) and once with the candidate (outer timer and full trace). Pass:
  per-command wall times, every summary, CLI version, source commit, archive size and cache state
  recorded under this item, and each cost on the path classified as optimize or explain by the
  Decision Log's selection rule.
- [ ] M4: Selected costs removed. Pass: for each cost M3 selects, the change lands with its own
  fake-level proof and a warm before-and-after trace pair recorded here; every unselected cost has
  a one-line reason in the Decision Log; `just gate-fast` green on the landed commit.
- [ ] M5: Operator documentation. Pass: `docs/runbooks/inventory-operations.md` has a "Profiling
  a slow release" section naming the four commands, `NAGARE_TRACE=1`, how to read the summary
  (nested, concurrent and unattributed time) and what to send with a report.
- [ ] M6: Intranet confirmation on the next ordinary authorized protected-site release after a
  Nagare release containing M1 to M4 runs on the intranet. Pass: the four commands' outer wall
  times and summaries, the operator's time between commands, and a comparison with the v0.9.0
  observation above recorded here. No release is made only to collect this.


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

2026-10-23: A standalone plan, not a child of MasterPlan 29. That MasterPlan's scope is a
reviewed access change and it excludes image and site paths; this plan reuses its counters
(EP-212), its cold reads (EP-213) and its journal copy (EP-217) unchanged.

2026-10-23: Phase labels are a closed Haskell sum type, never caller text. Every label is
fixed at compile time, so a trace line cannot carry a destination, a token, a path or an
environment value. The shell transport reports its sub-phases as `NAGARE_TRACE_PHASE <label>
<nanoseconds>` lines on its stderr; the adapter accepts only the labels in its closed set and
drops every other line, and it never forwards transport stderr itself.

2026-10-23: Selection rule for M4. A cost is optimized when its warm time is at least 2 s or 10%
of its command's warm wall time, it repeats work already done in the same command or an earlier
command of the sequence, and removing it changes no review digest, check, lock, journal or
recovery behavior. Any other cost is explained, not optimized. No deployment-time target is set.

2026-10-23: The local "before" is the published v0.10.0 `nagarectl`, not v0.9.0. v0.9.0 has no
trace at all, and a local context bootstrapped by the candidate is not a v0.9.0 context; v0.9.0
is represented by the intranet observation in Purpose.


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)


## Context and Orientation

All paths are relative to the repository root. The CLI is the Haskell package in
`cli/nagarectl`; its library is `cli/nagarectl/src` and its executable-private code is
`cli/nagarectl/app`.

**Existing trace.** `cli/nagarectl/src/Nagare/Inventory/Store/Counters.hs` (EP-212) keeps one
`StoreCounters` per opened store with a count and summed nanoseconds per `Counter` (`StoreOpen`,
`GcloudSession`, `HeadRead`, `HistoryLoad`, `RemoteGet`, `CachedGet`, `RemotePut`, `Listing`),
using `GHC.Clock.getMonotonicTimeNSec`. `withStoreTrace` checks `NAGARE_TRACE=1` and, in a
`finally`, prints one `nagarectl trace: <kind> store: …` line per store and a `nagarectl trace:
stores N, wall S s` line on stderr. `cli/nagarectl/app/Nagare/Cli/Dispatch.hs` wraps every
command with it in `dispatchTraced = withStoreTrace . dispatch`. Counter times summed across
EP-213's eight concurrent readers already exceed wall time; EP-218's record says "summed across
workers".

**Image publication plan.** `runAppImagePlan` in `cli/nagarectl/app/Nagare/Cli/Commands/Image.hs`
validates the destination, calls `Inventory.loadTargetSnapshot` (in
`cli/nagarectl/src/Nagare/Inventory/Command/Open.hs`; it opens the store writable with
`openTargetStore`, runs `initializeStore` and loads the history), optionally opens the store a
second time read-only to bind build inputs, calls `inspectArchive` from
`cli/nagarectl/src/Nagare/Inventory/Components/ControllerImage.hs` (`shasum -a 256` of the whole
archive and `skopeo inspect docker-archive:` for its manifest digest), compiles one artifact
scope and calls `Inventory.planInventoryCandidateWith`
(`cli/nagarectl/src/Nagare/Inventory/Command.hs`), which opens the store again, prepares the
review through the planning registry and writes the review directory.

**Site deployment plan.** `runSiteDeploy` in `cli/nagarectl/app/Nagare/Cli/Commands/Site.hs`
loads `nagare/Config.hs` with `Nagare.Dsl.Load.loadSite` (`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`
compiles and runs the file with `runghc` and decodes its JSON;
[ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md) packages that runtime
with `nagarectl`). `runReviewedSiteDeployPlan` then calls `loadTargetSnapshot` (open one),
`openTargetStoreReadOnly` and `loadInventoryHistory` (open two, second history load),
`loadAcceptedNative`, compiles the site scope and calls `planInventoryCandidateWith` (open
three). EP-212 threaded one `OpenedInventory` (store, pinned head, loaded history) through the
access path only (its Decision Log, 2026-10-22); `Inventory.planInventoryCandidateLoaded`
already accepts one.

**Apply.** `nagarectl inventory apply DIR --yes` runs `applyInventoryWithFactory` in
`cli/nagarectl/src/Nagare/Inventory/Command.hs`, which admits the review under the writer lock
(`cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`) and executes it
(`cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs`), appending journal events. Each
operation goes through an `Adapter` record (`cli/nagarectl/src/Nagare/Inventory/Adapter.hs`,
fields `adapterObserve`, `adapterPrepare`, `adapterPreflight`, `adapterExecute`,
`adapterVerify`, `adapterRecover`, `adapterSettle`), fetched by executor with `lookupAdapter`,
the one place every registry is read.

**Artifact transport.** `cli/nagarectl/src/Nagare/Inventory/Adapters/ArtifactRuntime.hs` runs
`scripts/inventory-artifact-transport.sh observe|publish` once per call with a canonical JSON
request on stdin, capturing stdout and stderr (`readCreateProcessWithExitCode`). For a cloud
OCI image each run sources `scripts/lib/target.sh` and calls `_require_target_project`
([ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)), then
`gcloud auth print-access-token | skopeo login`; `observe` runs `skopeo inspect docker://D`;
`publish` re-hashes the archive with `shasum`, re-reads its manifest with `skopeo inspect
docker-archive:`, runs `skopeo copy --preserve-digests` and then observes. Planning observes once;
apply observes in prepare or preflight, publishes, and verifies by observing again.

**Readiness.** `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`
`waitForReadiness` runs `kubectl wait --for=condition=ready ksvc/NAME --timeout=300s` (and the
DomainMapping and certificate waits) through `invokeKubectl` in
`cli/nagarectl/src/Nagare/Inventory/KubernetesTransport.hs`, whose `InterpretedRuntime`
constructor lets tests supply a fake kubectl.

**Harnesses.** `cli/nagarectl/test/Nagare/Test/ContractCommands.hs` plans and applies a fixture
review against fakes and already collects store counters with `collectStoreCounters`.
`cli/nagarectl/test/InventoryArtifactSpec.hs` builds `ArtifactAdapterOps` fakes.
`cli/nagarectl/test/Nagare/Test/Suite.hs` is at its 300-line limit, so new tests join an
existing group (MasterPlan 29's Decision Log does the same). `scripts/site-access-drill.sh`
bootstraps a disposable local context on a disposable Docker daemon and publishes and deploys
the protected static-site example; `NAGARE_DRILL_BOOTSTRAP_ONLY=1` stops after bootstrap.

**ADRs.** [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
attribution and failure behavior are proved with fakes; the local and intranet runs confirm.
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md),
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
fix the store, admission and recovery contracts this plan must not change. ADR 9 keeps the
project guard on every cloud path; an optimization may make it cheaper, never skip it.
[ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) binds the Haskell to
`mori://shinzui/haskell-jitsurei/docs/core-standards`. No ADR covers diagnostics; none is needed
unless M4 changes the transport contract.


## Plan of Work

**M1.** Add `cli/nagarectl/src/Nagare/Inventory/Trace.hs` and list it in
`cli/nagarectl/nagarectl.cabal`. It defines:

```haskell
data Phase
  = ConfigLoad
  | ArchiveInspect
  | InventoryRead
  | ReviewWrite
  | Admission
  | JournalAppend
  | AdapterStage !Executor !Stage
  | TransportStep !TransportStep
  | Readiness !ReadinessKind
  deriving stock (Eq, Ord, Show)

data Stage = Observe | Prepare | Preflight | Execute | Verify | Recover | Settle
data TransportStep = ProjectGuard | RegistryLogin | RemoteInspect | ArchiveVerify | RegistryCopy
data ReadinessKind = ReadyKnativeService | ReadyDomainMapping | ReadyCertificate | ReadyOther

data TraceEnv = TraceEnv { clock :: !(IO Word64), sink :: !(Text -> IO ()) }

withPhase :: Phase -> IO a -> IO a
withCommandTrace :: IO a -> IO a
withCommandTraceIn :: TraceEnv -> IO a -> IO a
recordPhase :: Phase -> Word64 -> IO ()  -- a sub-phase timed elsewhere (the transport)
```

The process-wide registry follows `Counters`' pattern (`unsafePerformIO` `IORef`, `Nothing`
when tracing is off, so `withPhase` costs one `readIORef` untraced). Each record keeps the
phase, its parent (the innermost open phase on the calling thread, from a `Map ThreadId
[Phase]`), start and end, and outcome. `withPhase` prints `nagarectl trace: start <label>` and
`nagarectl trace: done <label> S s` or `failed <label> S s` (via `onException`, which also sees
`exitWith`). `withCommandTrace` reads `NAGARE_TRACE`, runs the command, and in a `finally`
prints the store lines exactly as today, then one line per phase indented under its parent with
count, summed seconds and, when more than one ran at once, `peak N concurrent`, then
`nagarectl trace: wall W s, attributed A s, unattributed U s`, where A is the length of the
union of top-level phase intervals. `Counters.withStoreTrace` becomes a thin call so its
existing callers and output stay valid. Tests go in `cli/nagarectl/test/InventoryTraceSpec.hs`,
joined to the existing "inventory object store" group.

**M2.** Place `withPhase` at: `Load.loadSite` in `runSiteDeploy` (`ConfigLoad`);
`inspectArchive` in `runAppImagePlan` (`ArchiveInspect`); the snapshot, history and native loads
in both plan commands (`InventoryRead`); the review write in `Command.hs` (`ReviewWrite`);
`admit` (`Admission`); each journal append in `Transaction.hs` (`JournalAppend`); every adapter
function returned by `lookupAdapter` (`AdapterStage executor stage`), which also covers planning
observation; `waitForReadiness` by object kind (`Readiness`). In
`scripts/inventory-artifact-transport.sh`, when `NAGARE_TRACE=1`, time `_require_target_project`,
the login pipeline, `skopeo inspect docker://`, the archive `shasum` plus manifest check, and
`skopeo copy`, and print `NAGARE_TRACE_PHASE <label> <ns>` to stderr; `runTransport` parses only
those five labels from the captured stderr and calls `recordPhase`. The failing and delayed fakes
in M2's pass line use `InterpretedRuntime` and a fake transport executable written by the test.

**M3.** Bootstrap the local context, run the sequence as in Concrete Steps, cold (fresh
`XDG_CACHE_HOME`, new archive digest) and warm (same cache, second run with a new tag and key),
for both binaries. Record results under M3 and classify each phase.

**M4.** Implement what M3 selects. The code reading predicts these candidates, each to be
confirmed or dropped by M3's numbers: the second and third store opens and history loads in both
plan commands (thread one `OpenedInventory` into `planInventoryCandidateLoaded`, as EP-212 did
for access); one `gcloud` token and `skopeo login` per transport run (four or more per image
apply); the archive hashed and inspected again at publish. The archive recheck at publish and
the project guard stay; only repeated work in the same command may go.

**M5.** Extend the `NAGARE_TRACE` paragraph in `docs/runbooks/inventory-operations.md` into the
section named in Progress.

**M6.** Ask the operator to set `NAGARE_TRACE=1` and wrap each command in `time` on their next
protected-site release, then record the results.


## Concrete Steps

Per Haskell commit, from the repository root:

```bash
just haskell-style-check
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/trace/||/artifact inventory adapter/||/contract commands/"' --test-show-details=direct
just gate-fast
```

M3, local profile (the disposable Docker daemon and drill variables are those
`scripts/site-access-drill.sh` requires):

The archive is built before timing starts, outside Nagare, from the same context directory the
drill prepares in its step 6 (`$ROOT/site/ctx`, rendered from the example's `nagare/Config.hs`).
`$DEST` is the drill's `destination`, `$EXAMPLE` is `cluster/examples/protected-static-site`,
and `$IMAGE` is the `Image resource:` line the image plan prints.

```bash
NAGARE_DRILL_BOOTSTRAP_ONLY=1 NAGARE_DRILL_CONTEXT=profile scripts/site-access-drill.sh
docker build --platform linux/amd64 -t profile-site:t1 "$ROOT/site/ctx"
docker save profile-site:t1 -o "$ROOT/site/t1.tar"
export NAGARE_TRACE=1
time nagarectl --context profile app image-plan --archive "$ROOT/site/t1.tar" --destination "$DEST:t1" --key t1 --save-plan "$ROOT/reviews/image-t1" 2> image-plan.trace
time nagarectl --context profile inventory apply "$ROOT/reviews/image-t1" --yes 2> image-apply.trace
time nagarectl --context profile site deploy -C "$EXAMPLE" -f "$EXAMPLE/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV" --skip-build --tag t1 --image-resource "$IMAGE" --save-plan "$ROOT/reviews/site-t1" 2> site-plan.trace
time nagarectl --context profile inventory apply "$ROOT/reviews/site-t1" --yes 2> site-apply.trace
```

Expected summary tail on each command:

```text
nagarectl trace: wall 4.12 s, attributed 3.98 s, unattributed 0.14 s
```


## Validation and Acceptance

M1 and M2 tests and every existing suite green under `just gate-fast`. M3 and M4 traces recorded
in Progress. M6 recorded from a real release. IR-37's AC-1 is met by M3 and M6, AC-2 by M1 and
M2, AC-3 by M2, AC-4 by M3 to M5.


## Idempotence and Recovery

Tracing writes nothing but stderr. The local profile runs on a disposable context and Docker
daemon; delete the drill root to start again. Each M4 change keeps the reviewed-execution
contract, so a failed apply resumes with `nagarectl inventory resume` as before.


## Interfaces and Dependencies

`Nagare.Inventory.Trace` exports `Phase (..)`, `Stage (..)`, `TransportStep (..)`,
`ReadinessKind (..)`, `TraceEnv (..)`, `withPhase`, `recordPhase`, `withCommandTrace` and
`withCommandTraceIn`. `Nagare.Inventory.Store.Counters` keeps its exports. The artifact
transport's stdout protocol is unchanged; its stderr gains `NAGARE_TRACE_PHASE` lines only under
`NAGARE_TRACE=1`. No new library dependency.
