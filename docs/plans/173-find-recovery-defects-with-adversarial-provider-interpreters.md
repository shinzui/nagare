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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T14:39:49Z
      mode: "implement"
      note: "M2 part 2: retire scenario (F51, F58) and F38/F49 mutation records"
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

- [x] (2026-10-05) M1 core: `Nagare.Test.World.Adversary`, `Nagare.Test.World.Kubernetes` and
  `InventoryRecoveryModelSpec`. Real planning (`observeWithRegistry`, `planChanges`, `prepareReview`),
  the driver, the recovery policy and the production application adapter
  (`mkKubernetesAdapterWithConfigurationObservation`) run over the world. Five application scenarios
  (create; good update; bad update then corrected update, with release history unchanged, following
  the release, and with a durable volume) run under every single fault at every Kubernetes write
  boundary. I1, I2 and I4 hold. The fast tier takes 12.6 s. The model found F55 on the F54-repaired
  source; it is fixed in MasterPlan 23.
- [x] (2026-10-05) M1 acceptance:
  - The fast tier passes on the repaired source in 27 s.
  - It fails on the pre-F54 worktree (`3135cdde`) with I1 on all three bad-update scenarios, with no
    injected fault.
  - Each of the F16, F30, F35 and F37 mutation diffs (`cli/nagarectl/test/mutations/`) makes it fail,
    naming that finding's scenario.
  - The suites pass.
  - Observation-boundary faults (`ChurnAlways`, `ForeignObject`) and the liveness invariant I7 were
    added to reach F30 and F35.
- [x] (2026-10-05) M2 part 1: store and transient faults (`PutRefused`, `PutLandedUnacknowledged`,
  `GetFailedOnce` through `Nagare.Test.World.Store`; `TransientReadFailure`) with I5 (the store reads
  back idle with one valid journal chain). The `Replaced` fault, and I3's status clause computed as
  `inventory status` computes it (`classifyDriftWith` over the accepted snapshot, read in an
  inspection mode that fires no faults). The model found F56 and F57, and both are fixed in
  MasterPlan 23. The fast tier passes in 51 s, and all 1,197 `nagarectl` tests pass.
- [x] (2026-10-05) M2 part 2: the retire scenario ("create with a durable volume, then retire") with
  I3's retirement clause (a retained entry carries the member's last recorded incarnation), and the
  F38 and F49 mutation records. On the pre-fix sources the scenario failed on F51 (I3 under
  `Replaced`) and then on F58 (an application whose first deploy stopped unready could not be
  retired); both are fixed in MasterPlan 23. I3's status clause now uses the production
  `statusIncarnations`. F52's reviewed rename is covered by `InventoryPostgresRenameSpec`, which
  computes status after every Kubernetes request; the model does not yet run a migration.
- [x] (2026-10-05) M2 part 3, receipt ingestion and the reviewed rename:
  - **Database scenario.** "create a database, then ingest a scheduled receipt" reviews a standalone
    PostgreSQL scope (`compileStandaloneDatabase`). It then plans ingestion as `db backup-receipts`
    does: live UIDs through the adapter, accepted native bytes through
    `Status.loadAcceptedNativeSelected`, and `compileScheduledIngestScope`. A new I3 clause fails when
    a receipt from a source created outside review (the world's `replacedUids`) compiles. A
    fault-free run must compile, so the clause is never vacuous. The scenario found F59 (P1, fixed) and
    F60 (the F49 fail-open-recording limit, deferred by the operator, named as a tolerance).
  - **Rename model.** `InventoryRenameRecoveryModelSpec` runs the reviewed PostgreSQL rename under one
    fault (refused, lost acknowledgement, or interrupted after the write) at every `kubectl` write it
    issues. It checks:
    - I3 status at every stop and at the end;
    - an exit (resume, then each recovery decision);
    - the renamed data and the source volume;
    - I4: the destination volume is written once.

    It passes in about 30 s.
  - **Fast tier.** It now takes about 69 s, above M1's 60 s target. The database scenario added about
    18 s.
- [x] (2026-10-05) M2 part 4, from nagare-84's review items (checkpoint; further fixes held by the
  operator, 2026-10-05):
  - **Scenarios:**
    - "create a database, then retire it";
    - "create a database, update its resources, then update it again".
  - **Model:** a `Shape` (volume, worker) replaces the volume flag. The worker scenario itself is held
    in `docs/audits/mp23-held-work/`.
  - **Faults:** `Deleted` in the Kubernetes world, and `PartialCopy` in the rename world.
  - **Findings reproduced on HEAD `ab3d5bdc` and fixed:** F59 gap A, F61, F63 (StatefulSets) and the
    new F64 and F65. F58's admission regression was added.
  - **Fast tier:** about 130 s, against M1's 60 s target.
- [x] (2026-10-05) M2 acceptance, except F50:
  - The F38, F49 (status and ingestion), F52 and F59 guard reversions each fail a model:
    `cli/nagarectl/test/mutations/README.md`, each mutant's diff checked in the scratch worktree
    before the run.
  - F51 and F58 failed the retire scenario on their pre-fix sources.
  - F50 lives in the cloud-foundation world (M4).
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

- 2026-10-05: The first model run found a new P1, F55, on the F54-repaired source in under a second,
  with no injected fault. A landed unready Service update could not be stopped whenever its review
  also updated the release-history ConfigMap, which every application update does, or verified any
  other member. F54's stop reused F30's companion rule (never-started ConfigMap creates only). The
  F54 native run on `mp23-c3i` escaped only because its release history had never been created.
  Evidence: `docs/audits/mp23-findings.md#f55`.
- 2026-10-05: World fidelity mattered at once. Giving every kind readiness made ConfigMaps "land
  unready", and giving Knative Services a Failed state (only failed Jobs report it) produced false
  violations. The world now models readiness only for workloads and failure only for Jobs.
- 2026-10-05: A greedy in-place exit search under-explored. Resume appends journal events on every
  call, so measuring progress by head generation always committed to resume. In the refused-write
  case, committing to resume hid the real exit (abandon, then a corrected review). Progress is now a
  signature of the active transaction, the accepted and converged revisions, and each operation's
  latest state. The search replays from scratch per path (see the Decision Log).

- 2026-10-05: The `Replaced` fault found two more wedges (F56, F57) within a minute of being added.
  A Service replaced after a landed unready update could not be stopped, and the runbook told the
  operator to "investigate" with no command to run afterwards. A verification whose target was
  replaced after it ran stayed ambiguous forever, although a verification never writes. In both,
  every refusal was correct in isolation, and only the exit search showed the composition wedged.
  Evidence: `docs/audits/mp23-findings.md#f56`, `#f57`.


- 2026-10-05: The first database scenario found a P1 wedge (F59) on its first run, with one fault.
  F16's stop had been fixed only for application Services, and nothing had driven a data service's
  create through the model. The same run reached the F49 fail-open-recording limit (F60) with one
  `Replaced` fault. Evidence: `docs/audits/mp23-findings.md#f59`, `#f60`.

## Decision Log

- Decision: Run the reviewed rename under faults in the rename spec's own `kubectl`-level API world
  (`InventoryPostgresRenameSpec`), not in `Nagare.Test.World.Kubernetes`.
  Rationale: The migration adapter (`kubernetesMigrationAdapter`) reaches Kubernetes only through the
  `Kubectl` effect: transfer Jobs, pod termination messages, raw Job deletes, StatefulSet scaling and
  fences. The recovery model's world sits at `KubernetesAdapterOps` and models none of these.
  Extending that world would re-implement the rename world. The exit search here is in place and
  bounded (resume up to three times, then each recovery decision), because every rename fault is
  transient.
  Date: 2026-10-05

- Decision: The rename's I4 counts writes into an empty destination volume, not transfer Jobs.
  Rationale:
  - Observed in the model: after a lost acknowledgement or an interrupt on the copy Job's cleanup
    delete, or any fault on the verification Job's create, recovery creates the copy Job a second
    time.
  - Observed in source (`transferScript`, `src/Nagare/Inventory/Migration/PostgresRename.hs`): a copy
    into a non-empty destination only compares manifests, and fails if they differ.
  - Inferred: the second Job proves the earlier copy rather than repeating it, so it is a safe retry
    and not a finding. The world counts real copies, and I4 requires exactly one.
  - **Pending independent verification.** This change relaxes a model invariant. A reviewer must
    confirm that the script's "non-empty destination, compare and do not copy" path covers every
    observed fault:
    - a lost acknowledgement or an interrupt on the copy Job's cleanup delete;
    - any fault on the verification Job's create.
  Date: 2026-10-05

- Decision: Model relaxations made with the `Deleted` fault and the database update scenario. Each is
  listed for independent verification (nagare-84's rule for invariant relaxations).
  - **Per-transaction I4.** I4 counts writes per transaction. Observed: a later review reuses
    deterministic operation IDs.
  - **Deleted writes.** An object deleted out of band no longer counts toward its operation's writes.
    Rewriting it is not a repeated effect.
  - **I2.** I2 skips members deleted out of band after verification. That is an unavoidable race;
    status, not convergence, reports it.
  - **Expected refusals.** A planning refusal `durable-resource-missing` that names only members
    deleted out of band ends the scenario as an expected refusal.
  - **Persistent churn (inferred).** Persistent status churn is restricted to Knative Services, the
    behaviour F30 observed natively. A settled StatefulSet's status changes only when its pods
    change. Without the restriction, a StatefulSet update needed `abandon-refused-operation` under
    every churn placement (75 I7 violations).
  Date: 2026-10-05

- Decision: F60 is an explicit tolerance in the I3 receipt clause, by operator decision. Only a
  replacement the head itself records as the accepted incarnation is exempt.
  Rationale: It is the F49 fail-open-recording item on the deferral ledger
  (`docs/audits/mp23-findings.md#f60`). A replacement the head does not record must still refuse, and
  the F49 ingestion mutation proves the clause checks that.
  Date: 2026-10-05

- Decision: Enumerate a bounded scenario space exhaustively instead of sampling it with a random
  property-testing library.
  Rationale: The claim to prove is "every reachable stopped state within this bound has an exit".
  Exhaustive enumeration proves it within the bound, is deterministic on every run, and adds no dependency.
  A random state-machine library (`hedgehog`, registered in mori as `hedgehogqa/haskell-hedgehog`)
  can be added later for a deeper, sampled tier if the bounded space misses something.
  Date: 2026-10-04

- Decision: Put the Kubernetes world at the `Kubectl` effect, not at `KubernetesAdapterOps`. Supersedes the first version of this decision, which placed it at the adapter-ops seam.
  Rationale: The decisions behind F30, F37 and F54 live below the ops seam, in `mutate` and `parseObserved` in `src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`:
  - choosing the request from the action and the "before" state;
  - `verifyLiveOwnership` (field managers, F37);
  - rewriting an unready Knative Service's "before" state (F30);
  - the readiness wait that returns `AdapterEffectAmbiguous` on timeout (F54);
  - deriving owner and foreign context from annotations.

  An ops-level fake would re-implement that logic and test itself. The runtime already sends every cluster call through the `Kubectl` effect in `src/Nagare/Inventory/KubernetesTransport.hs`, which can be replaced through `withKubectlInterpreter`. The F20 collection model and `InventoryKubernetesFieldTakeoverSpec.hs` already use that seam. So the real adapter, runtime, driver and recovery all run, and only `kubectl` is fake. The runs stay in memory and take milliseconds.
  Date: 2026-10-04

- Decision: Faults are either transient (they clear after one occurrence) or persistent (they hold
  for the rest of the run). Exits are explored with persistent faults still in place.
  Rationale: F54's revision never becomes Ready, F37's foreign manager stays, and F49's replacement
  stays. An exit that works only after the provider fixes itself is not an exit.
  Date: 2026-10-04


- Decision: Explore exits by deterministic replay, depth-first, at most four moves deep. Every
  candidate path re-runs the scenario from a fresh world and store. A move the driver refuses ends
  its path. A move that changes the progress signature without ending the transaction is extended.
  An I2 or I4 violation on any explored path fails the run.
  Rationale: The memory store and world cannot be snapshotted, and an in-place greedy search missed
  real exits. Replay keeps paths independent and deterministic, and each run takes milliseconds.
  Date: 2026-10-05

- Decision: World fidelity rules. Only Knative Services, Deployments, StatefulSets, DomainMappings and
  Jobs have readiness. Only Jobs fail. `Interrupt` throws after the write lands. Writes are
  conditional on the reviewed UID and resourceVersion. An update of an object with a foreign manager
  is refused unless the mutation carries a reviewed takeover. The configuration observation ignores
  status, so status churn changes resourceVersion but not its digest.
  Rationale: Each rule mirrors the runtime (`KubernetesRuntime.hs`) or the API server. A violation
  that depends on an unfaithful world is noise.
  Date: 2026-10-05

- Decision: Add I7 (liveness): with only persistent status churn, a scenario without a bad image
  must converge without any exit. Status churn quiets while the operator works an exit.
  Rationale: Abandon now exists, so reverting F30's guard no longer wedges anything. A correction
  just never converges, which only a liveness check sees. A controller's status churn is bursty, and
  a stop refused by a race is retried once it settles. Churning on every read during exits would
  make the two-read landed proof unsatisfiable, which does not happen in practice.
  Date: 2026-10-05

- Decision: Store faults run on one representative scenario in the fast tier and on all of them in
  the deep tier. The model's own reads use a second, fault-free store over the same objects, and a
  planning step retries once when a store fault fired during it.
  Rationale: Store faults do not depend on the application's shape. Sweeping them on all five
  scenarios took the fast tier from 38 s to over 200 s with no new violation. A fault that reaches
  the model's own reads would test the model, not Nagare.
  Date: 2026-10-05

- Decision: I3's status clause computes status the way `inventory status` does: `classifyDriftWith`
  with the head's incarnations over the composed accepted snapshot. Observations go through the
  production adapter with the world in an inspection mode where no fault fires and no churn happens.
  Rationale: A model-side reimplementation of drift classification would test itself.
  Date: 2026-10-05

- Decision: F50's guard (a transient failed `gcloud` read in the state-bucket ownership check) is not
  reachable from the Kubernetes or store worlds. Its mutation is recorded against M4's
  cloud-foundation world instead of M2.
  Rationale: F50 sits in the Pulumi or `gcloud` path, which these worlds do not drive.
  Date: 2026-10-05

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
- **The `kubectl` effect (the seam M1 uses):** every Kubernetes call from the runtime goes through
  `Eff '[Kubectl]` in `src/Nagare/Inventory/KubernetesTransport.hs`. Its request is
  `KubectlRequest { context, arguments, input }`. `withKubectlInterpreter` replaces the real process
  with any handler.
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

**Scope.** Add `cli/nagarectl/test/Nagare/Test/World/Kubernetes.hs`. It defines a `KubeWorld`, held
in an `IORef`: a map from (group, kind, namespace, name) to the object as real Kubernetes JSON.
Each object carries:
- `metadata.uid`, `resourceVersion`, `generation`, annotations and `managedFields`;
- its spec;
- `status.conditions` and `observedGeneration`.

Seed objects come from real captures retained in `docs/audits/` evidence, not hand-written JSON.

The module provides `worldKubectlInterpreter :: IORef KubeWorld -> IORef Adversary -> KubectlInterpreter`.
It handles only the verbs and flags `src/Nagare/Inventory/Adapters/KubernetesRuntime.hs` actually
issues: `get -o json`, `create -f -`, `apply` and `patch` with `--field-manager` and UID or
`resourceVersion` preconditions, `delete` with preconditions, `wait --for=condition=…` and
`rollout status`. Its semantics:
- `create` assigns a UID, sets `resourceVersion` and `generation` to 1, records the field manager,
  and returns AlreadyExists for an existing object.
- Writes check their preconditions and report field-manager conflicts as the API server does.
- After each write, a controller step sets status: Ready with `observedGeneration = generation` by
  default, unless the adversary says otherwise.
- `wait` and `rollout status` use virtual time, so a 300-second timeout returns immediately.
- Any other request fails the test, so a new runtime command cannot be silently accepted. This is the
  rule `test/Nagare/Test/Effectful/CollectionModel.hs` already follows.

The adapter under test is the real one, built by the runtime's `mkKubernetesRuntimeOps` family over
a `KubernetesRuntimeConfig` passed through `withKubectlInterpreter`.

**Adversary.** Add `cli/nagarectl/test/Nagare/Test/World/Adversary.hs`. An `Adversary` is a list of
`(Boundary, Fault)` pairs, where a boundary is the n-th `kubectl` request. Faults for this milestone:
- `LostAcknowledgement`: apply the write, then return a transport error, which the runtime reports
  as ambiguous;
- `RefusedBeforeEffect`: return an error without applying;
- `LandsUnready` and `LandsFailed`: persistent;
- `StatusChurn`: bump `resourceVersion` only;
- `ForeignManager`: persistent, adds a manager on a reviewed field;
- `Interrupt`: throw a test exception that aborts the driver, as a killed process would.

**Invariant model.** Add `cli/nagarectl/test/InventoryRecoveryModelSpec.hs`. It builds one
application scope with a PostgreSQL member and a Knative Service member, reusing the scope and
candidate helpers in `InventoryTransactionSpec.hs`. Extract them to
`cli/nagarectl/test/Nagare/Test/World/Scenario.hs` if they need to be shared. The registry uses the
real Kubernetes adapter over the real runtime, with `worldKubectlInterpreter` in place of `kubectl`,
and a memory store. It
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
- `Nagare.Test.World.Kubernetes` exports `KubeWorld`, `newKubeWorld`, `seedKubeWorld` and
  `worldKubectlInterpreter`. Its seam is `KubectlInterpreter` from
  `src/Nagare/Inventory/KubernetesTransport.hs`.
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
