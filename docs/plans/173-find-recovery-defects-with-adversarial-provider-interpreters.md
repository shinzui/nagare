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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Find recovery defects with adversarial provider interpreters

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [173-find-recovery-defects-with-adversarial-provider-interpreters.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
[the 2026-10-04 retrospective](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-engineering-retrospective-2026-10-04.md).

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
- [x] M1 (accepted 2026-10-05; evidence in the dated entries above): A Kubernetes provider world with an adversary drives the real Kubernetes adapter, driver and
  recovery policy through the application lifecycle. The exit, acceptance and at-most-once
  invariants pass. Acceptance: the model fails on the pre-F54-repair source and on documented
  reversions of the F16, F30, F35 and F37 guards, passes on the repaired source, and its fast tier
  runs in under 60 seconds.
- [x] M2 (accepted 2026-10-05 except F50, which moves to M4's cloud-foundation world): Incarnation, store and transient faults (replaced, renamed, foreign object, store put
  refused or unacknowledged, one failed read) with the incarnation, store and transient invariants.
  Acceptance: documented reversions of the F38, F49 and F50 guards fail. The model reports F51 and
  F52 as violations on their pre-fix source, and passes once their MasterPlan 23 fixes land
  (operator decision, 2026-10-04: both un-deferred).
**M3–M4 out of this plan's scope and re-chartered on a trigger, M5 declined (operator, 2026-10-14; MasterPlan 26 Decision Log).** The host-transport world is reopened when an intranet upgrade finds a host-stage defect, the Pulumi cloud-foundation world when MasterPlan 25 reopens; M3 goes first when either does. F121–F124, the four upgrade defects since v0.5.0, all sat in these providers.

- [-] M3: The production adapter registry is constructed in the library from provider operation
  records, and the model runs that production wiring instead of a test-local copy. Acceptance: the
  model and the F44 observer check use the production registry builder, and every suite and the
  architecture check pass. {disposition=out-of-scope}
- [-] M4: Worlds for the remaining providers (Pulumi cloud foundation, Helm, host transport). The Pulumi cloud-foundation world is shared with [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md): EP-165 and EP-167 extend it with retained cloud members and teardown faults, so build it to observe from a stack export and to delete by exact physical identity reuse the
  existing restore and collection models, and fidelity fixtures check that the runtime parsers agree
  with the worlds on real recorded output. Acceptance: one fidelity fixture per L3 finding with
  retained real output, and every registered executor has a world. {disposition=out-of-scope}
- [-] M5: An interpreter-coverage record lists every executor and action with the model scenarios
  that cover it, and a test fails when a registered pair has none. Acceptance: deleting a scenario
  fails the coverage test, and the record is emitted for the release gate
  ([EP-170](170-size-the-release-gate-to-the-change.md)). {disposition=declined}

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

Closed 2026-10-14. M1–M2 delivered the Kubernetes, store and rename worlds and the recovery model, which found F55–F65 before any native run and is the fast tier every commit runs. M3–M4 (production registry, worlds for host transport, Helm and Pulumi) are out of this plan's scope and are re-chartered when an intranet upgrade finds a host-stage defect or MasterPlan 25 reopens; F121–F124 all sat in those providers. M5 is declined: the coverage record has no consumer.

