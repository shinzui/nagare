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
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-23T22:41:49Z
      mode: "update"
      note: "Correct trace ownership and failure semantics, complete instrumentation, repair the profiling harness, and constrain optimizations to measured safe reuse."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-23T22:48:09Z
      verdict: "approved"
      note: "Approved revised plan after source and ADR review: live typed tracing, acyclic ownership, complete effect boundaries, safe pinned-head reuse, and reproducible local/cloud evidence; implementation and performance remain unverified."
---

# Profile the image publication and site deployment path and remove its measured waste

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It implements
[IR-37](../improvement-requests/profile-the-complete-image-publication-and-site-deployment-path.md).


## Purpose / Big Picture

On 2026-10-23 the operator released the protected TAN Connect site in `mori://tan/tan-ng-labs`
with Nagare v0.9.0. The Docker archive existed at 01:33:09 UTC and the new Knative revision was
Ready at 01:38:04 UTC: about 295 s across the four-command procedure, including operator
review and gaps, against 33 s to build, test and package the image. This is an end-to-end
observation, not 295 s of measured command execution. No phase trace was captured. v0.10.0's
`NAGARE_TRACE=1` counts inventory store work but does not explain the whole release path.

After this plan an operator who runs the four release commands with `NAGARE_TRACE=1` sees, on
stderr, each phase start and finish (typed-configuration load, archive inspection, inventory
read, provider observation per executor, credential guard and registry login, registry upload,
admission, journal writes, readiness wait) and, on normal completion, refusal or an exception
that unwinds Haskell cleanup, one summary that names each phase's count and time, marks nested and concurrent time, and states how
much of the wall time no phase covers. Stdout, review bytes, journals, exit codes and every
safety check are unchanged. Costs selected by repeatable measurements are then removed,
with before-and-after traces recorded here. Required checks and costs that cannot yet be measured are explicitly explained.
A killed process or an unavailable stderr cannot promise a final summary; diagnostics must
never change the command result to manufacture one.

The sequence profiled, with an archive that already exists:

```text
nagarectl app image-plan --archive A --destination D --key K --save-plan IMAGE_REVIEW
nagarectl inventory apply IMAGE_REVIEW --yes
nagarectl site deploy -f nagare/Config.hs --skip-build --tag T --image-resource PUBLICATION --save-plan SITE_REVIEW
nagarectl inventory apply SITE_REVIEW --yes
```


## Progress

- [ ] M1: Phase tracing. A dependency-leaf trace core records uniquely identified spans (one
  invocation of a phase), explicit parents, monotonic intervals and fixed outcomes. Pass:
  `InventoryTraceSpec` proves nested and inherited worker attribution, overlapping repeated
  labels, inclusive and exclusive time, interval-union accounting, typed refusals, thrown
  failures, interruption and `ExitSuccess`, one final summary, session restoration, a failing
  sink that preserves results, and silence with tracing off.
- [ ] M2: The four commands are instrumented. Pass: fake transport start/finish events are
  observable before child exit; a delayed/failing copy and delayed/failing kubectl wait retain
  their correct parent and outcome; journal intent and completion writes are both counted;
  traced/untraced plan and apply fixtures preserve stdout, review bytes, normalized journals
  and exit behavior. Invalid, truncated and secret-bearing diagnostic input cannot become
  trace output. The real shell transport also passes with fake provider executables.
- [ ] M3: Reproducible profile. A checked-in profiling runner prepares the disposable local
  fixture and captures the four commands for published v0.10.0 and the M1/M2 candidate, with
  one cold and at least three matched warm samples per binary. Pass: source/version, archive
  digest and size, target architecture, inventory and cache state, actual create/update/verify
  work, per-command outer times, summaries and operator gaps are recorded. Add fake-cloud
  call-count/attribution evidence; mark cloud latency as unmeasured until M6 supplies it.
- [ ] M4: Selected costs removed or explained. Pass: each cost selected by M3 has a targeted
  regression proof and matched warm before/after traces; all other costs have a reason in the
  Decision Log, including cloud-only candidates awaiting real timing. No change is required
  if none meets the selection rule. `just gate-fast <implementation-commit>` passes.
- [ ] M5: Operator documentation. Pass: `docs/runbooks/inventory-operations.md` has a "Profiling
  a slow release" section naming the four commands, `NAGARE_TRACE=1`, inclusive/exclusive,
  concurrent and unattributed time, outer timers, and the safe evidence to send with a report.
- [ ] M6: Intranet confirmation on the next ordinary authorized protected-site release using
  a released Nagare containing M1 to M4. Pass: outer times, summaries, operator gaps and cache
  state are recorded, compared with the historical v0.9.0 interval with its limits stated.
  Reclassify cloud-only costs from these measurements; any newly selected optimization needs
  its own M4 proof and before/after confirmation before closure. No release is made solely for
  this measurement. M1–M5 can ship first; the plan and IR-37 AC-1 remain open until M6.

Review handoff (2026-10-23): this update validates and repairs the design only. No phase
tracing or optimization is implemented, and no native performance result is claimed.


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

2026-10-23: A standalone plan, not a child of MasterPlan 29. That MasterPlan's scope is a
reviewed access change and it excludes image and site paths; this plan preserves the meaning
of its counters (EP-212), its cold reads (EP-213) and its journal copy (EP-217).

2026-10-23: Phase labels and outcomes are closed Haskell types with fixed renderers. Never
render exception text, provider output, resource IDs, paths, credentials or environment values
in trace records. Transport diagnostics use a versioned, strictly parsed start/end event
protocol, consumed while the child runs. Haskell timestamps receipt with its monotonic clock;
these are observed boundary times, not child CPU measurements. Duration-only records cannot
supply live progress, failure closure or real interval overlap and are not the interface.

2026-10-23: Selection rule for M4. Investigate a cost when its median warm duration is at
least 2 s or 10% of its command's median warm wall time. Select it only when repeatable traces
show avoidable duplicate work inside that command and removal preserves review semantics,
checks, locking, journals and recovery. Use exclusive time and the command's elapsed reduction,
not a sum of nested or overlapping counters. Observations, archive verification and admission
across separate commands are fresh proofs, not reusable cached authority. Record sample spread
and retain the change only when the matched measurements support an improvement. Other costs
are explained; no deployment-time target is set.

2026-10-23: The local release comparison uses published v0.10.0, verified through GitHub's
release API and upstream tag on this review date: published 2026-10-23T03:05:19Z, tag commit
`16f0d7be4ab03a44716c81b03c6b433103e32651`. v0.9.0 remains historical end-to-end evidence.
M4's phase-level before/after baseline is the instrumented M1/M2 commit, because v0.10.0 has
no phase trace. Record both baselines rather than attributing every difference to M4.

2026-10-23: Local mode uses a filesystem inventory and the local registry branch; it cannot
establish cloud credential, GCS or project-guard latency. Fakes prove cloud call counts and
safety before native confirmation, but injected delays do not select performance work. M6
supplies the first authorized real cloud timing unless suitable existing traces are available.

2026-10-23: Keep the tracing dependency graph acyclic. The trace core does not import store,
adapter or execution modules. `Nagare.Inventory.Trace.Command` owns command-session setup and
summary composition and imports both the core and existing store counters. `Store.Counters`
keeps its compatibility wrapper and never imports the command wrapper. Avoid turning pure
resource/planning code into an effectful dependency on diagnostics.

2026-10-23: Apply the existing ADR 22 pinned-head architecture to any selected inventory
reuse. Do not mechanically substitute `openInventoryForPlanning`: it requires an existing
idle head, whereas `loadTargetSnapshot` can initialize one. Preserve first-use and busy-store
behavior, quiet/contract output, optional build bindings and adoption paths when sharing code.
Admission still reads the current head under the writer lock; no head/history crosses commands.


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
`adapterVerify`, `adapterRecover`, `adapterSettle`), fetched by executor with `lookupAdapter`.
This is the common ordinary-stage lookup; fences and recovery capabilities have separate
lookups. Most failures are returned as `Left`, `AdapterEffectFailed` or
`AdapterEffectAmbiguous`, not thrown exceptions. `AdapterEffectIdentified` wraps an outcome
that must also be classified. Instrument without changing any of these result values.

**Artifact transport.** `cli/nagarectl/src/Nagare/Inventory/Adapters/ArtifactRuntime.hs` runs
`scripts/inventory-artifact-transport.sh observe|publish` once per call with a canonical JSON
request on stdin, capturing stdout and stderr (`readCreateProcessWithExitCode`). For a cloud
OCI image each run sources `scripts/lib/target.sh` and calls `_require_target_project`
([ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)), then
`gcloud auth print-access-token | skopeo login`; `observe` runs `skopeo inspect docker://D`;
`publish` re-hashes the archive with `shasum`, re-reads its manifest with `skopeo inspect
docker-archive:`, runs `skopeo copy --preserve-digests` and then observes. Planning observes once;
apply observes in prepare or preflight, publishes, and verifies by observing again. `publish`
also observes after copying, so count actual invocations rather than assuming a fixed total. Local k3d observation uses
`scripts/lib/local-registry.sh` and Docker rather than `skopeo inspect`; its time must be
covered too. On failure `runTransport` currently includes captured stderr and stdout in its
error result. Tracing must strip its valid protocol records before that existing error path,
not suppress normal errors or add raw subprocess streams to diagnostics.

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
the protected static-site example; `NAGARE_DRILL_BOOTSTRAP_ONLY=1` stops after bootstrap,
before step 6 renders the Dockerfile and site files. Its XDG paths and variables belong to the child shell and do not propagate
to the caller. The drill creates an arm64 context. Its bootstrap-only mode does not require
`NAGARE_DRILL_GHC_ENV`, but this profile still needs that environment to render the example.
The proposed runner below must perform that missing preparation and use the same XDG roots,
age key and local-registry forward for every timed command.

**ADRs.** [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
attribution and failure behavior are proved with fakes; the local and intranet runs confirm.
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md),
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
fix the store, admission and recovery contracts this plan must not change. ADR 9 keeps the
project guard on every cloud path; an optimization may make it cheaper, never skip it.
[ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) binds the Haskell to
`mori://shinzui/haskell-jitsurei/docs/core-standards`. ADR 22's 2026-10-22 amendment already
requires one store, one pinned head and one history per command; any M4 reuse follows it. No existing ADR defines command tracing. At completion,
distill the new diagnostics ownership and non-interference contract into an ADR if it becomes
a shared project constraint; do not amend execution authority merely to add measurements.


## Plan of Work

**M1.** Add `cli/nagarectl/src/Nagare/Inventory/Trace.hs` and
`cli/nagarectl/src/Nagare/Inventory/Trace/Command.hs`, registering public facades and any
private implementation modules in `cli/nagarectl/nagarectl.cabal`. The core's proposed API is:

```haskell
data Phase
  = ConfigLoad | ArchiveInspect | InventoryRead | ReviewWrite
  | Admission | WriterLockWait | JournalAppend
  | AdapterStage !Executor !Stage
  | ArtifactTransport !TransportAction
  | TransportStep !TransportStep
  | Readiness !ReadinessKind
  deriving stock (Eq, Ord, Show)

data Stage = Observe | Prepare | Preflight | Execute | Verify | Recover | Settle
data TransportAction = TransportObserve | TransportPublish
data TransportStep = ProjectGuard | RegistryLogin | RemoteInspect | ArchiveVerify | RegistryCopy
data ReadinessKind = ReadyKnativeService | ReadyDomainMapping | ReadyCertificate | ReadyOther
data PhaseOutcome = PhaseDone | PhaseFailed | PhaseInterrupted

data TraceEnv = TraceEnv { clock :: !(IO Word64), sink :: !(Text -> IO ()) }

withPhase :: Phase -> IO a -> IO a
withPhaseResult :: Phase -> (a -> PhaseOutcome) -> IO a -> IO a
captureTraceContext :: IO TraceContext
withTraceContext :: TraceContext -> IO a -> IO a

-- In Nagare.Inventory.Trace.Command:
withCommandTrace :: IO a -> IO a
withCommandTraceIn :: TraceEnv -> IO a -> IO a
```

`TraceContext` is opaque: it binds a command session and parent span ID, never caller text.
`withPhase` handles exceptions; `withPhaseResult` additionally classifies a returned result
without changing it. Local wrappers map `Left` and failed/ambiguous adapter outcomes to
`PhaseFailed`. Successful absence observations and recovery decisions are not failures merely
because they describe an absent object or a retry. Map those domain results at their owning
boundary; the core knows none of their types. Treat `ExitSuccess` as done, `ExitFailure` as
failed, and asynchronous cancellation as interrupted, always rethrowing the original exception.

Use a bracketed process-wide active-session slot, with the disabled path doing only a cheap
lookup and no clock or sink calls. Restore the previous slot and store-counter registry on
all exits. Nested command wrappers join the current session and print only one summary;
independent command tests run serially because the existing counters are process-global.
Within a command, spans may run concurrently. Allocate a unique span ID for every invocation;
a `Map ThreadId [SpanId]` supplies lexical parents, and explicitly captured `TraceContext`
propagates that parent into worker threads and subprocess readers. Never infer ancestry from
a phase label: repeated labels can overlap or nest.

Exception-safe registration and finalization must close each started span exactly once and
restore the thread stack. Do not hold a trace-state lock while calling an action or sink.
Diagnostic write failures disable that sink without replacing the action's result or original
exception; asynchronous cancellation must retain its normal semantics. Tests cover failure
at start, finish and summary writes as well as cancellation during work. Final reporting is
best effort on unwinding, not a promise after SIGKILL or process/host failure.

Start/end lines contain fixed labels, span IDs, parent IDs, fixed outcomes and elapsed time.
Group summaries by parent label path, showing count, inclusive seconds, exclusive seconds
and peak concurrency. Inclusive time includes children; exclusive time subtracts the union
of that span's child intervals, so overlap is not subtracted twice. Report command attribution
as the union of root span intervals, clipped to command start/end, and unattributed time as
wall time minus that union. Summed worker time can exceed wall time; label it explicitly and
never add store-counter totals to phase totals. A fake-clock test uses two overlapping
children with the same label to prove this arithmetic and their inherited parent.

`Trace.Command` composes the phase report with the existing store lines through narrow
collection/render helpers in `Store.Counters`. Preserve `collectStoreCounters` and
`withStoreTrace` for callers, without making either call back into `Trace.Command`. Change
`dispatchTraced` to use the new command wrapper. Outer process time remains necessary because
dispatch tracing excludes process startup and work before dispatch. Tests live in
`cli/nagarectl/test/InventoryTraceSpec.hs`, joined to the existing inventory object-store group.

**M2.** Instrument at effect boundaries. Wrap `Load.loadSite` in `runSiteDeploy`, archive
inspection in `runAppImagePlan`, and store opening/history/native/review loading in both
planning commands and `applyInventoryWithFactory`. Cover `publishReview` and local review
writes as separate invocations of `ReviewWrite`, including the quiet/contract path. Trace
`admitWithHistory`, which apply actually invokes, rather than only its `admit` wrapper. Time
writer-lock acquisition until the callback starts separately from admission/execution; do
not label the whole lock-held transaction as lock wait. Place `JournalAppend` at
`appendEventWith` in `cli/nagarectl/src/Nagare/Inventory/Execute/Journal.hs`, which covers
intent and completion writes from `Execute/Driver.hs`, admission and transaction convergence.
It includes retries; do not instrument only `Transaction.hs`'s few append call sites.

Wrap ordinary adapter fields returned by `lookupAdapter` once per lookup, preserving metadata,
optional settlement, fences and recovery registrations. Use result-aware classification for
returned failures. Trace actual waits inside `waitForReadiness` by object kind, including the
DomainMapping HTTPS/certificate wait, rather than counting a no-op address as a readiness wait.
Introduce `ArtifactTransport TransportObserve/TransportPublish` around each `runTransport`
invocation so tests and operators can distinguish a publish from the enclosing adapter execute.

Replace the artifact transport's all-at-once subprocess capture with a runner that drains
stdout and stderr concurrently, supplies canonical stdin, waits/reaps the child, and cleans
up readers/processes on exceptions. Keep existing stdout decoding, exit classification and
ordinary error text unchanged after removing valid trace records. The reader captures its
parent transport context explicitly. Its first producer/consumer test must prove that a
start line is delivered while a fake child is still blocked, and that a full stdout pipe
cannot deadlock stderr consumption. Only then expand instrumentation in the shell transport.

The shell emits newline-delimited `NAGARE_TRACE_PHASE 1 start <label>` and
`NAGARE_TRACE_PHASE 1 end <label> <done|failed>` records under `NAGARE_TRACE=1`. Labels are
exactly `project-guard`, `registry-login`, `remote-inspect`, `archive-verify`, `registry-copy`.
The protocol describes sequential steps within one transport invocation; the adapter owns
span IDs and monotonic timestamps on receipt. Include the local registry observation branch
in `remote-inspect`. Never emit argv, durations from a wall clock, resource names or payloads.
Measure around the project guard, login pipeline, archive checks, copy and post-copy observe;
use traps/helpers that preserve exit status, `pipefail`, subshell cleanup and existing
`set -e` behavior. In particular, wrapping a shell function in a conditional must not silently
disable its errexit checks. Verify this with a failing guard, hash mismatch and login pipeline.

Strictly validate protocol version, field count, label, outcome and allowed start/end order;
bound diagnostic line length. Unknown or malformed records never become trace labels or
synthetic durations. End an open child span as failed on nonzero exit or interrupted on
cancellation; mark incomplete diagnostics with a fixed warning without changing a successful
transport into a failed operation. Child pipe buffering can delay event receipt, so the
report describes observed boundaries. Check reporting overhead with paired traced/untraced
warm runs before trusting a small improvement. Tracing never newly forwards raw child output;
ordinary non-protocol error handling remains the transport's existing behavior.

Extend `InventoryArtifactSpec` with runtime fake executables and a fake-tool execution of the
real `scripts/inventory-artifact-transport.sh`; a fake script alone cannot prove its traps or
markers. Use `InterpretedRuntime` for delayed and ambiguous readiness. Compare traced/untraced
`ContractCommands` fixtures from identical initial state with fixed volatile inputs: byte-identical
stdout/review documents and journals normalized only for timestamps and resulting hash-chain
bytes, not operation order, identity or outcomes. Add coverage of image/site command wiring
(the generic fixture alone does not call those executable-private commands), including normal
and `--contract 1` output. Seed token, password and private native sentinels in fake inputs;
assert no trace contains them, and successful captured child stderr is not newly forwarded.
Exercise typed failure, thrown failure and refusal equivalence, not only happy paths.

**M3.** Add `scripts/profile-site-release.sh`, a runner with the explicit interface and setup
below. It reuses the disposable drill, then performs the missing step-6 rendering and archive
preparation before starting any command timer. It captures stdout, stderr, exit code and outer
elapsed time separately for all four commands and stops after the first failure. The runner
owns fresh review directories and parses exactly one `Image resource:` value for site planning.
It uses explicit absolute executable paths and checks `version --json` rather than relying on
whichever `nagarectl` is on PATH. No cold run deletes operator caches.

Use matched fixtures for both binaries, with the same platform, inventory size, archive bytes,
resource shape and cache protocol. Record first deployment separately from updates. Repeated
warm samples must exercise comparable publication and deployment work, not a first creation
against an already-converged verification. Prepare a small numbered set of archives before
timing, shared byte-for-byte between binaries, with changed site content to force real updates;
record registry blob reuse, node image cache and actual operation counts. Fresh `XDG_CACHE_HOME`
only makes the CLI cache cold, not the registry, node or filesystem cache. Use independent
disposable contexts/daemons for the baseline and candidate to avoid one binary warming the
other's provider state. Never clear live registry or node caches just to simulate cold results.
Alternate warm sample order where practical, use at least three, and record median and range.

Record the v0.10.0 outer/store comparison and preserve the instrumented pre-optimization M1/M2
commit for M4's detailed comparison. Fake cloud providers exercise the guard/login/inspect/copy
path and GCS call counts, but label those as structural evidence without real latency. Each
candidate receives a decision: selected by measurements, required work, below threshold, or
cloud measurement outstanding. Do not treat local absence of a cloud cost as zero cost.

**M4.** Apply the selection rule. Repeated inventory opens/history loads are a plausible
candidate. Thread one `OpenedInventory` through image build-input bindings, accepted site
native data and review planning. Preserve initializing behavior where currently supported;
`openInventoryForPlanning` alone is not a drop-in replacement. Preserve `planInventoryCandidateQuiet`
contract output and adoption/converge variants if a shared helper changes; narrow the change
to the four-command path when possible. Prove one open/history load for ordinary initialized
planning, with and without build inputs, and preserve the intentional extra load when seeding
changes the head. Test a head change between plan/apply and before locked admission: stale
reviews refuse and history is reloaded only for the new locked head, as ADR 22 requires.

Repeated token/login work may be considered only after cloud timing selects it. If selected,
a command-owned credential session must remain private, scoped to the selected account,
project and registry, cleaned up on every exit, and refreshed safely on expiry. It cannot
replace project guards or reuse provider observations. This needs its own fake tests before
native use, not an unqualified global authfile cache. Archive hash and manifest checks at
publish are mandatory proofs that the reviewed input has not changed; do not remove them
because image-plan already inspected the file. Prove an archive changed after planning still
refuses before copy. Keep readiness waits, verification and journal ordering intact.

**M5.** Extend the trace paragraph in `docs/runbooks/inventory-operations.md` into the section
named in Progress, including local/cloud measurement limits and how to distinguish reported
span sums from outer time and operator gaps.

**M6.** On the next ordinary authorized intranet release, collect the same four-command report
with the released instrumented CLI. Keep review/think time between commands separate. Compare
with v0.9.0 only as historical end-to-end context; it cannot provide per-phase speedups. Apply
the selection rule to newly measurable cloud costs and keep this milestone open until selected
work is validated or the measured residual is explained. This plan authorizes no platform
upgrade or intranet release merely to benchmark.


## Concrete Steps

For implementation, from the repository root, run focused checks before committing:

```bash
just haskell-style-check
python3 scripts/check-haskell-architecture.py
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/trace/||/artifact inventory adapter/||/contract commands/"' --test-show-details=direct
```

The focused suite must include the new trace tests, shell producer/consumer tests and runtime
readiness tests under a name matched by `/trace/`. A filter that selects zero new tests is not
acceptance. After committing a cohesive implementation, run `just gate-fast <commit-sha>`;
the gate checks that committed revision in an isolated worktree, not uncommitted changes.
All commits include this plan's `ExecPlan:` trailer. This documentation-only review does not
claim an implementation gate result.

M3 adds `scripts/profile-site-release.sh` with required options `--nagarectl`, `--root`,
`--context`, `--archives` and `--warm-runs`. It runs one cold creation plus the requested warm
updates. The archive directory holds a manifest with each archive's filename, SHA-256, OCI
manifest digest, platform and byte count. The first invocation prepares that set outside the
timed interval; later invocations validate and reuse the exact set. Both sides use the same
checkout's example/configuration and pinned base image. The script rejects an already-used
review root, a non-local context, a missing executable, or a non-disposable Docker daemon; it
retains the drill's refusal to reset existing k3d state unless explicitly requested.

Prerequisites are two disposable Docker daemon sockets with the drill's matching auth-plane
images and MinIO images available (see `scripts/site-access-drill.sh`'s `seed_images`), the
packaged v0.10.0 CLI and candidate CLI as absolute executable paths, and an absolute GHC
package-environment file resolving `nagare-dsl`. Use the same bootstrap CLI/payload and image
pins for both contexts, via `NAGARE_DRILL_NAGARECTL`; `--nagarectl` selects only the timed
binary. This separates CLI comparisons from platform changes. Check compatibility by running
both binaries' `version --json` and `platform status --json` before timing; an incompatible
baseline context must be rebuilt with compatible pins, not benchmarked through a refusal.
Run the profiles sequentially because the existing drill uses a fixed host port for its
schema check. Supply these environment variables before executing the following Bash:

```bash
: "${PROFILE_BASELINE_CTL:?absolute packaged v0.10.0 nagarectl}"
: "${PROFILE_CANDIDATE_CTL:?absolute packaged candidate nagarectl}"
: "${PROFILE_BASELINE_DOCKER:?disposable baseline Docker socket}"
: "${PROFILE_CANDIDATE_DOCKER:?separate disposable candidate Docker socket}"
: "${NAGARE_DRILL_NAGARECTL:?common bootstrap CLI}"
: "${NAGARE_DRILL_IMAGE_TAG:?matching auth-plane image tag}"
: "${NAGARE_DRILL_GHC_ENV:?absolute GHC package-environment file}"
PROFILE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nagare-profile.XXXXXX")"
export NAGARE_DRILL_NAGARECTL NAGARE_DRILL_IMAGE_TAG NAGARE_DRILL_GHC_ENV
DOCKER_HOST="$PROFILE_BASELINE_DOCKER" NAGARE_DRILL_FORWARD_PORT=15213 \
  bash scripts/profile-site-release.sh --nagarectl "$PROFILE_BASELINE_CTL" \
  --root "$PROFILE_ROOT/baseline" --context profile --archives "$PROFILE_ROOT/archives" --warm-runs 3
DOCKER_HOST="$PROFILE_CANDIDATE_DOCKER" NAGARE_DRILL_FORWARD_PORT=15223 \
  bash scripts/profile-site-release.sh --nagarectl "$PROFILE_CANDIDATE_CTL" \
  --root "$PROFILE_ROOT/candidate" --context profile --archives "$PROFILE_ROOT/archives" --warm-runs 3
```

These runner commands are the M3 interface to implement, not commands available before M3.
Its preparation must clear ambient target/payload variables as the drill does, set and export
`XDG_CONFIG_HOME=$ROOT/config`, `XDG_STATE_HOME=$ROOT/state`, `XDG_CACHE_HOME=$ROOT/cache`,
`NAGARE_DRILL_ROOT=$ROOT` and `NAGARE_DRILL_CONTEXT=$CTX`, and invoke the drill with
`NAGARE_DRILL_BOOTSTRAP_ONLY=1`. On return it restores `SOPS_AGE_KEY_FILE=$ROOT/sops/age/keys.txt`,
the image pins from `$ROOT/images.env`, and
`NAGARE_LOCAL_REGISTRY_FORWARD=127.0.0.1:$NAGARE_DRILL_FORWARD_PORT`. Load the common bootstrap
CLI's `context env` in that isolated environment. Verify local mode and the expected XDG
context before continuing; a child process's exports cannot substitute for these steps.

Render the example exactly as drill step 6 does: copy
`cluster/examples/protected-static-site/public` into the context's `site` directory, run its
`nagare/Config.hs` with `GHC_ENVIRONMENT=$NAGARE_DRILL_GHC_ENV`, render nginx configuration
with `scripts/lib/render-static-nginx.hs`, and write the static Dockerfile used by the drill.
Build the numbered fixtures for `linux/arm64`, matching the drill's cluster, and save each
archive before timing. Derive the destination from the isolated context as
`$NAGARE_REGISTRY_HOST/$CLOUDSDK_CORE_PROJECT/$NAGARE_ARTIFACT_REGISTRY_ID/protected-static-site`.
Reject a mismatch between this destination and the qualified image name that site deploy
derives from its configuration and target profile.

For each sample, the runner's timer captures the following exact argv with `CTL`, `ROOT`,
`CTX`, `EXAMPLE` (absolute), `DEST`, `ARCHIVE`, `TAG` and `KEY` set from that prepared fixture.
`IMAGE` is parsed from the first command's captured stdout before the third command. Set
`NAGARE_TRACE=1` on the timed child, keep stdout/stderr in separate sample files, and write
exit code and monotonic outer duration to a separate JSON timing record. A Python parent
using `time.monotonic_ns` and `subprocess.run` can time the real process including startup;
do not mix shell `time` output into a trace file.

```bash
"$CTL" --context "$CTX" app image-plan --archive "$ARCHIVE" --destination "$DEST:$TAG" --key "$KEY" --save-plan "$ROOT/reviews/image-$TAG"
"$CTL" --context "$CTX" inventory apply "$ROOT/reviews/image-$TAG" --yes
"$CTL" --context "$CTX" site deploy -C "$EXAMPLE" -f "$EXAMPLE/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV" --skip-build --tag "$TAG" --image-resource "$IMAGE" --save-plan "$ROOT/reviews/site-$TAG"
"$CTL" --context "$CTX" inventory apply "$ROOT/reviews/site-$TAG" --yes
```

Expected candidate summary tail (illustrative numbers, not a target):

```text
nagarectl trace: wall 4.12 s, attributed 3.98 s, unattributed 0.14 s
```

The baseline emits its existing store summary. For each candidate command verify
`attributed + unattributed = traced wall` within rendering precision. Outer wall includes
startup and final reporting and is recorded separately; span sums are not required to equal
it. The report retains all raw sample timings and records the interval outside commands.


## Validation and Acceptance

M1 and M2 deterministic tests and the existing suites pass under the implementation commit's
fast gate. First prove one transport marker through the real streaming consumer, including
its failure path, before widening instrumentation. Tests must preserve typed results,
exceptions, contract/stdout bytes, reviews and journal meaning, and prove no diagnostics
leak secrets or suppress cancellation. M3's runner must also pass a fake-CLI smoke test that
checks environment isolation, archive preparation, four-command ordering, image-ID handoff,
separate logs and stopping at a failed apply before any native benchmark.

M3 records the repeatable local profile and explicitly unmeasured cloud costs. M4 records
matched before/after evidence for each selected optimization or explains why no change
qualifies. M6 records a real authorized release, resolving any cloud selection still open.
IR-37 AC-1 is met by M3 and M6, AC-2 by M1 and M2 plus the release capture, AC-3 by M2 and
regression proofs for M4, and AC-4 by the classification report and M3–M5 evidence, extended
by M6 when it selects additional work. The plan is not complete while M6 remains unchecked.


## Idempotence and Recovery

Tracing writes diagnostics only to stderr and keeps trace state in memory. It does not write
trace data into review bundles, inventory history or journals. It restores its session on
exit; normal diagnostic sink failure cannot change transaction behavior. Untraced transport
runs retain the same protocol and results.

The profile writes only inside its explicit scratch roots and disposable daemons. Preserve
failed reviews and traces for diagnosis; never reset inventory state by deleting its root
while the cluster remains active. Resume a recoverable failed apply through the existing
`nagarectl inventory resume <transaction-id> --yes` workflow, or use the supported reviewed
recovery reported by the command. Not every refusal has a transaction to resume. Mark a
recovered benchmark sample separately rather than treating it as an ordinary successful run.
For a fresh benchmark, explicitly tear down only the disposable cluster/registry and owned
forwards, then use a new root; deleting the root alone does not clean up Docker resources.


## Interfaces and Dependencies

`Nagare.Inventory.Trace` exports closed phase/outcome types, `TraceEnv`, opaque `TraceContext`,
`withPhase`, `withPhaseResult`, `captureTraceContext` and `withTraceContext`. Add an internal
start/end span handle API for the subprocess consumer so event intervals have real identity;
do not expose a duration-only `recordPhase`. `Nagare.Inventory.Trace.Command` exports
`withCommandTrace` and `withCommandTraceIn`. `Nagare.Inventory.Store.Counters` preserves its
existing public exports and may add narrow scoped collection/render helpers. The dependency
arrow is from command wrapper to core/counters, never from counters back to command wrapper.

The artifact transport's canonical stdout protocol is unchanged. Its stderr gains only the
fixed version-1 event records under `NAGARE_TRACE=1`; the consumer removes valid records from
ordinary error construction and never stores them in a journal. An older payload with no
markers still works and receives enclosing transport timing only. Malformed diagnostics
cannot change the provider result. The runner can use existing `process`, `async` and `unix`
dependencies and shell tools; no dependency upgrade or new telemetry backend is planned.
Before using unfamiliar dependency APIs, locate their sources with Mori as required by the
repository instructions. Keep new modules below the existing architecture size limits.

Revision note (2026-10-23): source review corrected duration-only buffered tracing, exception-only
failure reporting, missing journal/apply boundaries, cyclic wrapper ownership and unsafe
inventory substitution. It replaced the incomplete drill recipe with a reproducible runner
contract, separated local evidence from cloud selection, and preserved the original
measure-first scope and deferred ordinary-release confirmation.
