---
id: 173
slug: find-recovery-defects-with-adversarial-provider-interpreters
title: "Find recovery defects with adversarial provider interpreters"
kind: exec-plan
created_at: 2026-10-05T03:18:08Z
master_plan: "docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-05T03:18:08Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T03:50:52Z
      mode: "update"
      note: "F51/F52 un-deferred; F54 repair landed in 96d38d67"
---

# Find recovery defects with adversarial provider interpreters

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare's inventory can leave a transaction in a state no supported command can end. When that
happens, every later plan on the context is refused, including other applications, backups,
restores and teardown, until someone edits the cluster outside review. MasterPlan 23 found this
thirteen times. Eight of those were found by hours-long native runs on the shared local cluster or
on a cloud context, even though Nagare's adapter design lets the same code run against in-memory
fakes in seconds. The latest instance, F54, wedged the cloud context `mp23-c3i`. A Service update
landed, its new revision never became Ready, and nothing could stop the transaction.

After this plan, the ordinary test suite contains *provider worlds* and an *invariant model*. A
provider world is a small in-memory imitation of a provider, such as Kubernetes or the object store.
It can be told to misbehave the ways real providers do: drop an acknowledgement, never become Ready,
be replaced behind Nagare's back, have another field manager, fail one read. The invariant model runs
the real planner, driver, recovery policy and Kubernetes adapter over those worlds. It checks that
every stopped transaction has a supported way out and that nothing unreviewed is ever accepted. A
maintainer sees it work by running one test command. With the F54 repair reverted, the model fails
in seconds and names the landed-but-unready update that has no exit. With the repair in place, it
passes. The same holds for reverted guards from F16, F30, F35, F37, F38, F49 and F50.

This implements decisions 1–4 of
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md). The data
behind it is in
[the 2026-10-04 retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md).


## Progress

- [ ] M1: A Kubernetes provider world with an adversary drives the real Kubernetes adapter, driver and
  recovery policy through the application lifecycle. The exit, acceptance and at-most-once
  invariants pass. Acceptance: the model fails on the pre-F54-repair source and on documented
  reversions of the F16, F30, F35 and F37 guards, passes on the repaired source, and its fast tier
  runs in under 60 seconds.
- [ ] M2: Incarnation, store and transient faults (replaced, renamed, foreign object, store put
  refused or unacknowledged, one failed read) with the incarnation, store and transient invariants.
  Acceptance: documented reversions of the F38, F49 and F50 guards fail. The model reports F51 and
  F52 as violations on their pre-fix source, and passes once their MasterPlan 23 fixes land
  (operator decision, 2026-10-04: both un-deferred).
- [ ] M3: The production adapter registry is constructed in the library from provider operation
  records, and the model runs that production wiring instead of a test-local copy. Acceptance: the
  model and the F44 observer check use the production registry builder, and every suite and the
  architecture check pass.
- [ ] M4: Worlds for the remaining providers (Pulumi cloud foundation, Helm, host transport) reuse the
  existing restore and collection models, and fidelity fixtures check that the runtime parsers agree
  with the worlds on real recorded output. Acceptance: one fidelity fixture per L3 finding with
  retained real output, and every registered executor has a world.
- [ ] M5: An interpreter-coverage record lists every executor and action with the model scenarios
  that cover it, and a test fails when a registered pair has none. Acceptance: deleting a scenario
  fails the coverage test, and the record is emitted for the release gate
  ([EP-170](170-size-the-release-gate-to-the-change.md)).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Enumerate a bounded scenario space exhaustively instead of sampling it with a random
  property-testing library.
  Rationale: The claim to prove is "every reachable stopped state within this bound has an exit".
  Exhaustive enumeration proves it within the bound, is deterministic on every run, and adds no dependency.
  A random state-machine library (`hedgehog`, registered in mori as `hedgehogqa/haskell-hedgehog`)
  can be added later for a deeper, sampled tier if the bounded space misses something.
  Date: 2026-10-04

- Decision: Put the Kubernetes world at the `KubernetesAdapterOps` seam (observe returns
  `KubernetesState`, conditional mutate returns `AdapterExecution`), not at the `kubectl` process
  level.
  Rationale: Every recovery decision is made above that seam, and an in-process world is
  milliseconds per run. The runtime code below the seam (`parseObserved`, `readinessForAddress`,
  `waitForReadiness` in `src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`) is checked separately
  by M4's fidelity fixtures, using real recorded output. The process-level F20 collection world stays
  where it is.
  Date: 2026-10-04

- Decision: Faults are either transient (they clear after one occurrence) or persistent (they hold
  for the rest of the run). Exits are explored with persistent faults still in place.
  Rationale: F54's revision never becomes Ready, F37's foreign manager stays, and F49's replacement
  stays. An exit that works only after the provider fixes itself is not an exit.
  Date: 2026-10-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root. The Haskell package is `cli/nagarectl`. Its library
code is in `cli/nagarectl/src`, its executables in `cli/nagarectl/app`, and its tests in
`cli/nagarectl/test`, registered in `cli/nagarectl/nagarectl.cabal` (test suite `nagarectl-test`)
and assembled in `cli/nagarectl/test/Nagare/Test/Suite.hs`.

**The inventory.**
- Nagare manages cloud and cluster resources as a typed *inventory*, grouped into *scopes* (an
  application is one scope).
- A change is planned into a *review*, a saved immutable list of planned operations. It is then
  applied as a *transaction* by the *driver*.
- The driver records every step in a *journal* in an *inventory store*. In production the store is a
  GCS bucket or a local directory. In tests, `newMemoryStore` in `src/Nagare/Inventory/Store.hs`
  provides it in memory.
- The store has a *head*. The head names the active transaction, the *accepted* revision of each
  scope (what was last reviewed and admitted), and the *converged* revision (what has been proven to
  exist). While a transaction is active, every other plan is refused. A transaction that stops and
  cannot be resumed or ended through a supported command leaves the context *wedged*.

**The driver and recovery.** The driver's public functions are in
`src/Nagare/Inventory/Execute.hs`:
- `applyReviewed` admits and runs a review.
- `resumeTransaction` continues a stopped one.
- `recordOperatorRecovery` records an operator's decision for a stopped operation. The decisions are
  the constructors of `RecoveryAction` in `src/Nagare/Inventory/Execute/Types.hs`:
  `AcceptAdapterProof`, `RetryAfterAdapterProof`, `StopIncompleteApplication`,
  `AbandonRefusedOperation`, `AbandonPartialDatabaseRestore`, and others.

These return a `TransactionResult`: `Converged`, `PausedAtBarrier`, `StoppedFailed` or
`StoppedAmbiguous`.

**Adapters.** Every provider action goes through an *adapter*, the `Adapter` record in
`src/Nagare/Inventory/Adapter.hs`. Its fields are `adapterObserve`, `adapterPrepare`,
`adapterPreflight`, `adapterExecute`, `adapterVerify` and `adapterRecover`. After an interruption,
`adapterRecover` returns a `RecoveryDecision`:
- `RecoveryProvedComplete`;
- `RecoverySafeToRetry`;
- `RecoveryAwaitingReadiness`;
- `RecoveryLandedUnready`, added by the F54 repair in commit `96d38d67`;
- `RecoveryTerminalFailure`;
- `RecoveryUnresolved`.

Observation returns a `ResourceObservation`: `ObservedPresent`, `ObservedDrifted`,
`ObservedReplacementRequired`, `ObservedUnowned`, `ObservedForeign`, `ConfirmedAbsent` or
`ObservationUnavailable`.

**Provider operations.** Each real adapter is built from a record of provider operations, which is
the seam this plan uses:
- **Kubernetes:** `KubernetesAdapterOps` in `src/Nagare/Inventory/Adapters/Kubernetes.hs`, with
  `kubernetesObserve :: ResourceId -> IO KubernetesState` and
  `kubernetesMutateConditional :: KubernetesMutation -> IO AdapterExecution`. `KubernetesState` is
  one of `KubernetesAbsent`, `KubernetesPresent`, `KubernetesNotReady`, `KubernetesFailed`,
  `KubernetesReplacementRequired` or `KubernetesUnknown`; each present form carries a physical
  identity (the UID), a native digest and an owner. The adapter is constructed by
  `mkKubernetesAdapter` and its variants in the same module.
- **Store:** `ObjectOps` in `src/Nagare/Inventory/Store/ObjectOps.hs` (`getObject`, `getObjects`,
  `putObject`, `listObjects`).
- **Cloud foundation:** `GcloudRunner` in `src/Nagare/Inventory/Adapters/FoundationRuntime.hs`.
- **Others:** `PulumiAdapterOps`, `HelmAdapterOps`, `HostAdapterOps` and their siblings in
  `src/Nagare/Inventory/Adapters/`.

**Production wiring.** The production adapters are assembled from real operations in
`cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs` (570 lines; for example
`inventoryKubernetesAdapterWith` and `inventoryPulumiAdapterWithCollections`). The test suite cannot
import `app/` modules, so today no test exercises the production wiring.

**What tests exist.**
- **The EP-153 driver model.** `runFixedSeedDriverModel` in
  `cli/nagarectl/test/InventoryTransactionSpec.hs` runs the real planner and driver over four fixed
  cases. Each interrupts one effect with `AdapterEffectAmbiguous`, and recovery always returns
  `RecoveryProvedComplete` with a stable identity. It therefore covers only "the effect landed and
  the proof is available".
- **Per-finding regressions.** `InventoryJournalHeadAdvanceSpec.hs` (F38) has its own faulting
  `ObjectOps`, built on `fakeObjectOps` from `InventoryObjectOpsSpec.hs`. Others are
  `InventoryIncarnationSpec.hs` (F49), `InventoryRefusedPreflightRecoverySpec.hs` (F35),
  `InventoryKubernetesFieldTakeoverSpec.hs` (F37) and `InventoryApplicationUpdateRecoverySpec.hs`
  (F30). Each covers one finding's branch.
- **Two adversarial models.** `test/Nagare/Test/Effectful/Model.hs` covers restores with faults
  `NoFault`, `BeforeWrite`, `AfterWrite` and `WaitTimeout`. `test/Nagare/Test/Effectful/CollectionModel.hs`
  is the F20 collection world, with 14 faults behind the real `kubectl` transport. Both run under
  `just test-inventory-effects`.
- **Helpers.** `fixtureBinding`, `preparedFixtureWith` and `recordingRegistry` are exported from
  `InventoryTransactionSpec.hs` and are reused by other specs.

**Findings this plan reproduces.** All are described in `docs/audits/mp23-findings.md` (open) and
`docs/audits/mp23-archive/mp23-findings-closed.md` (closed):

| Finding | What has no exit, or goes wrong |
|---|---|
| F16 | unready create |
| F30 | status churn before an update |
| F35 | a preflight refusal after admission |
| F37 | a foreign field manager |
| F38 | a failed head write |
| F49 | an out-of-band replacement reported converged |
| F50 | one transient `gcloud` read stops a run |
| F51 | retirement keeps a replacement's identity |
| F52 | a reviewed rename reads as replaced mid-transaction |
| F54 | a landed update that never becomes Ready |

**ADR context.**
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) defines
  scopes, reviews, the journal and the adapter boundary this plan tests. Its "Known limits" (fail-open
  incarnation recording) are what M2's incarnation invariant checks.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) is the
  decision this plan implements.
- [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) and
  [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) apply
  the production Haskell standard to test support code as well. Use the package Prelude
  (`Nagare.Dsl.Prelude`), strict record fields with `!`, explicit deriving strategies and generic-lens
  labels.


## Plan of Work

### Milestone 1: the Kubernetes world and the exit invariant

**Scope.** Add `cli/nagarectl/test/Nagare/Test/World/Kubernetes.hs`. It defines a `KubeWorld`, a
map from provider address to a modelled object, held in an `IORef`. Each object has:
- a UID and an owner annotation;
- generation and observed generation;
- `resourceVersion`;
- the applied native digest;
- a set of field managers;
- a readiness of Ready, NotReady or Failed.

The module provides `worldKubernetesOps :: IORef KubeWorld -> IORef Adversary -> KubernetesAdapterOps`:
- **Observe** maps an object to the matching `KubernetesState`.
- **Conditional mutate** checks the mutation's `mutationBefore` UID and version against the world,
  exactly as the API server does. It then applies the native digest, bumps generation and
  `resourceVersion`, and sets readiness from the adversary (Ready by default).

**Adversary.** Add `cli/nagarectl/test/Nagare/Test/World/Adversary.hs`. An `Adversary` is a list of
`(Boundary, Fault)` pairs, where a boundary is the n-th call to an operation. Faults for this
milestone:
- `LostAcknowledgement`: apply, then return `AdapterEffectAmbiguous`;
- `RefusedBeforeEffect`: return `AdapterEffectFailed` with known no effect;
- `LandsUnready` and `LandsFailed`: persistent;
- `StatusChurn`: bump `resourceVersion` only;
- `ForeignManager`: persistent, adds a manager on a reviewed field;
- `Interrupt`: throw a test exception that aborts the driver, as a killed process would.

**Invariant model.** Add `cli/nagarectl/test/InventoryRecoveryModelSpec.hs`. It builds one
application scope with a PostgreSQL member and a Knative Service member, reusing the scope and
candidate helpers in `InventoryTransactionSpec.hs`. Extract them to
`cli/nagarectl/test/Nagare/Test/World/Scenario.hs` if they need to be shared. The registry uses the
real Kubernetes adapter (`mkKubernetesAdapter` over `worldKubernetesOps`) and a memory store. It
enumerates:
- review sequences: create; create then good update; create, bad update, then corrected update;
  create then retire;
- every single fault at every boundary (the fast tier);
- every ordered pair of faults (the deep tier).

After any result other than `Converged`, the model explores exits, with persistent faults kept and
transient faults cleared, to a depth of four. The exits are:
- `resumeTransaction`;
- each `RecoveryAction` constructor through `recordOperatorRecovery`, then resume;
- a new corrected review planned from the current history.

It asserts:
- **I1 (exit).** Some exit path reaches a head with no active transaction, without any direct world
  write.
- **I2 (nothing unreviewed accepted).** After every step, accepted revisions change only to the
  desired revisions of a review whose transaction completed, or stay as they were. A scope is
  converged only when every member's world object has the reviewed digest, the recorded UID and
  Ready.
- **I4 (at most once).** No mutation is applied twice for one operation after its proof was
  recorded.

A violation fails with the scenario, the fault list, the stopped result and the exits tried, so the
failure explains itself.

**Reproducing the known findings.** Make the model fail on each known finding:
- **F54:** run the model in a temporary worktree at commit `3135cddeebb2f2738915322bf78b60adfc6b155a`,
  which predates the F54 repair, with the new test files copied in.
- **F16, F30, F35, F37:** write one mutation file per finding under
  `cli/nagarectl/test/mutations/`, as a unified diff that reverts that finding's guard. Find each
  guard by reading the finding's implementation update and the named regression, then confirm it by
  running that regression with the diff applied. The diffs are records for a human or script to apply
  in a scratch worktree. They are never applied in the shared checkout.

### Milestone 2: incarnation, store and transient faults

**New faults.**
- `Replaced`: persistent; delete and recreate at the same address with a new UID and the same
  annotations.
- `Renamed`: the reviewed migration changes the address, and status is queried at every journal step
  in between.
- `ForeignObject`: an object appears at an address planned for creation.
- `TransientReadFailure`: one observe returns `KubernetesUnknown`, or one `gcloud` capture fails.
- **Store faults**, through an `ObjectOps` wrapper in `cli/nagarectl/test/Nagare/Test/World/Store.hs`
  generalizing the F38 spec's fake: `PutRefused`, `PutLandedUnacknowledged` and `GetFailedOnce`, on
  any put or get, head or journal.

**Scenarios.** Add a backup receipt scenario (ingestion after replacement) and a reviewed PostgreSQL
rename, reusing `InventoryPostgresRenameSpec.hs`'s setup.

**Invariants.**
- **I3 (incarnation).** Status never reports converged for a member whose world UID differs from its
  recorded incarnation. A receipt from a different incarnation never plans for ingestion. Retirement
  retains the accepted incarnation. A reviewed rename in progress is never reported as
  `replaced-incarnation`.
- **I5 (store).** A store fault never leaves the head unrecoverable, and never loses a published
  journal event.
- **I6 (transient).** One transient read failure never ends a run without a resume path.

**Acceptance.** Mutations reverting the F38, F49 and F50 guards fail the model. The operator
un-deferred F51 and F52 on 2026-10-04, and they are fixed in MasterPlan 23. Their MasterPlan 23
fixes use this milestone's incarnation scenarios as their class-level regressions: the model fails on
each pre-fix source and passes after the fixes. If M2 lands before the fixes, the two cases fail
until the fixes land. They are not hidden or marked as expected failures.

### Milestone 3: production wiring in the library

Move the construction logic of `cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs` into a new
library module, `cli/nagarectl/src/Nagare/Inventory/Registry.hs`. It takes a record of provider
operations (`ProviderOps`) and the reviewed specs, and returns the `AdapterRegistry`. The `app/`
module keeps only the construction of real operations from the active target, then calls the library.

Switch the invariant model and the F44 observer-totality check
(`cli/nagarectl/test/InventoryObservationSpec.hs`) to the production builder, supplying world
operations. Production code is moved here, not changed. Each moved function keeps its body, and only
the operations it closes over become parameters.

### Milestone 4: remaining worlds and fidelity fixtures

**Remaining worlds.** Add worlds for:
- the cloud foundation (`GcloudRunner`, `PulumiAdapterOps`), including a stack entry whose ID changes
  between review and apply (F33);
- Helm (`HelmAdapterOps`);
- the host transport (`HostAdapterOps`).

Wrap the existing restore model and the collection world so the invariant model can include restore
and collection operations.

**Fidelity fixtures.** Add `cli/nagarectl/test/fixtures/fidelity/`. Each fixture is a real provider
output with the state the world says it represents, for example:
- a `kubectl get -o json` of a Knative Service whose latest revision is not Ready;
- a Pulumi preview without `same` steps (F39);
- a CRI listing with a sandbox-only image (F32).

Real outputs are already retained in `docs/audits/` evidence. Collect them from there and from future
native runs; never invent them. Add `cli/nagarectl/test/InventoryFidelitySpec.hs`, which feeds each
fixture through the runtime parser (for example `parseObserved` and `readinessForAddress` in
`src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`) and asserts the recorded state.

### Milestone 5: the interpreter-coverage record

Add a test that enumerates every `Executor` and every `OperationAction` the production registry
supports. It fails when a pair has no model scenario. A pair may instead be marked uncoverable, with a
reason and an operator-approved note in this plan's Decision Log. The test also writes
`interpreter-coverage.json`: each pair, its scenarios, the fault kinds exercised and the source
digest. [EP-170](170-size-the-release-gate-to-the-change.md) requires that record before it accepts
native evidence. The scripted harness ([EP-168](168-script-the-local-acceptance-run-as-one-command.md))
refuses a native step whose path has no entry.


## Concrete Steps

Run the fast tier, which is part of the ordinary suite, from the repository root:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "recovery model"' --test-show-details=direct
```

Expected on the repaired source:

```text
recovery model
  fast tier: every single fault at every boundary has an exit:    OK (… s)
  deep tier is skipped unless NAGARE_RECOVERY_MODEL_DEEP=1
```

Run the deep tier on demand:

```bash
NAGARE_RECOVERY_MODEL_DEEP=1 cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "recovery model"'
```

Reproduce F54 on the pre-repair source in a scratch worktree. Never run tree-wide git commands in the
shared checkout. `$SCRATCH` is any private temporary directory.

```bash
git worktree add "$SCRATCH/pre-f54" 3135cddeebb2f2738915322bf78b60adfc6b155a
cp -R cli/nagarectl/test/Nagare/Test/World cli/nagarectl/test/InventoryRecoveryModelSpec.hs "$SCRATCH/pre-f54/cli/nagarectl/test/"
# register the new modules in the worktree's nagarectl.cabal and Suite.hs as in this plan's commit
(cd "$SCRATCH/pre-f54" && cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "recovery model"')
git worktree remove "$SCRATCH/pre-f54"
```

Expected: a failure naming invariant I1, the bad-update scenario, the `LandsUnready` fault on the
Service update, and the refused `stop-incomplete-application` exit.

Before committing Haskell, run `just haskell-style-check` and
`python3 scripts/check-haskell-architecture.py` from the repository root.


## Validation and Acceptance

M1 is accepted when four things hold:
1. The fast tier passes on the repaired source in under 60 seconds.
2. It fails on the pre-F54-repair worktree with an I1 violation for the landed-unready update.
3. Each of the F16, F30, F35 and F37 mutation diffs, applied in a scratch worktree, makes the model
   fail with a violation that names that finding's scenario.
4. The existing suites still pass.

M2 is accepted when the F38, F49 and F50 mutations fail the model, and F51 and F52 are either fixed
or registered as expected failures under a recorded operator decision.

M3 is accepted when `cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs` holds only real-operation
construction, the model and the observer check build the production registry, and all suites pass.

M4 is accepted when every registered executor has a world, and each L3 finding with retained real
output has a passing fidelity fixture. Those findings are F14, F20, F21, F27, F32, F34, F39, F41 and
F47.

M5 is accepted when removing any scenario fails the coverage test, and `interpreter-coverage.json` is
produced.

A run of the whole `nagarectl-test` suite must still finish in roughly its current time, plus at most
the fast tier's budget.


## Idempotence and Recovery

Everything here is test code and a pure move of wiring code (M3). The model is deterministic, so a
failure reproduces exactly. Mutation diffs are only ever applied in a scratch worktree, which is then
removed. If the fast tier exceeds its budget, move the slowest scenarios to the deep tier and record
that in the Decision Log, rather than shrinking the fault set.


## Interfaces and Dependencies

No new library dependency for M1–M3 (`tasty` and `tasty-hunit` are already used).

New test modules:
- `Nagare.Test.World.Kubernetes` exports `KubeWorld`, `KubeObject`, `Readiness`, `newKubeWorld` and
  `worldKubernetesOps`.
- `Nagare.Test.World.Adversary` exports `Adversary`, `Boundary`, `Fault`, `Persistence` and
  `nextFault`.
- `Nagare.Test.World.Store` exports `faultingObjectOps`.
- `InventoryRecoveryModelSpec` exports `inventoryRecoveryModelTests`.

New library module (M3): `Nagare.Inventory.Registry` exports `ProviderOps` and
`productionAdapterRegistry`, consumed by `cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs` and
by tests.

**Coordination.**
- The F54 repair landed in commit `96d38d67`, which adds `RecoveryLandedUnready` in `Adapter.hs`.
  M1's model must pass on it and fail on `3135cdde`.
- The plan writes only new test modules until M3.
- MasterPlan 26 treats M1 and M2 as the slice that MasterPlan 23's remaining native work waits for.
- M5's coverage record is consumed by [EP-170](170-size-the-release-gate-to-the-change.md) and
  [EP-168](168-script-the-local-acceptance-run-as-one-command.md).
