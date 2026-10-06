---
id: 179
slug: search-recovery-model-exits-from-a-snapshot-instead-of-a-replay
title: "Search recovery model exits from a snapshot instead of a replay"
kind: exec-plan
created_at: 2026-10-06T14:07:13Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-06T14:07:13Z
---

# Search recovery model exits from a snapshot instead of a replay

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The recovery model (`cli/nagarectl/test/InventoryRecoveryModelSpec.hs`) proves that every stopped
inventory transaction has a supported exit. When a faulted run stops, it searches for an exit:
resume, close or take-over, sometimes several moves deep. Each candidate path is replayed from the
start of the scenario: a new store, a new world, every earlier review planned and applied again.
That is correct, but most of a deep-tier run's time goes to these replays. A single-process deep
tier did not finish in more than eight hours.

After this change, the search snapshots the run's state once at the stop and restores it for
each candidate path, without replaying the scenario. The fast and deep tiers reach the same
verdicts in much less time. A reader sees it working in two ways:
- the timings `just gate-deep` prints per scenario fall;
- an equivalence test shows both search strategies return the same outcome for every
  fast-tier schedule.


## Progress

- [ ] M1: snapshot and restore of a model run. Restoring a snapshot and rereading the head,
  journal and world gives the same values as at the snapshot. A test checks this after a stop.
- [ ] M2: the exit search uses snapshots. An equivalence test runs every fast-tier schedule under
  both strategies and finds identical outcomes. The replay search is then deleted.
- [ ] M3: measured. Per-scenario deep-tier times before and after are recorded in this plan, and
  the single-process deep tier is at least five times faster.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Keep the replay strategy until the equivalence test passes, then delete it.
  Rationale: the replay is the model's reference behaviour. Snapshots must not weaken what the
  model proves, so both run side by side for one milestone.
  Date: 2026-10-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**The model.** `cli/nagarectl/test/InventoryRecoveryModelSpec.hs` runs Nagare's real planner,
driver, recovery and close code against in-memory providers:
- the Kubernetes world in `test/Nagare/Test/World/Kubernetes.hs`, an `IORef KubeWorld`;
- the fault adversary in `test/Nagare/Test/World/Adversary.hs`, an `IORef Adversary`;
- an object-store inventory over `fakeObjectOps` from `test/InventoryObjectOpsSpec.hs`, wrapped by
  `test/Nagare/Test/World/Store.hs` for store faults.

A `Run` (in the spec) holds the store, a clean inspection view of it, the world, the adversary, and
`IORef`s the invariants use (`runBound`, `runImages`, `runIncarnations`, `runDatabase`,
`runConverged`).

**Scenarios and tiers.** A scenario is a list of steps. `runScenario` replays it under a fault
schedule. On a stop, `searchExit` explores the moves (`Resume`, `Close`, `TakeOver`), and each
probe calls `replay`, which builds a new `Run` with `newRun` and re-executes every step and every
exit taken so far. The fast tier tries each fault placement alone. The deep tier
(`NAGARE_RECOVERY_MODEL_DEEP=1`) tries every ordered pair. `just gate-deep` runs it as parallel
shards (`NAGARE_RECOVERY_MODEL_SHARD=i/n`), each printing `recovery-model:` progress lines.

**Why replay is expensive.** A probe's cost is the whole scenario's cost. A deep-tier pair often
stops twice and explores several paths at each stop, so one schedule can cost many full replays.

**Relevant ADRs.**
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) makes
  the model the primary defect finder and requires its deep tier before model or kind-table work
  is accepted. A faster deep tier makes that requirement practical.
- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) defines the exits the
  search explores.

The plans that built the model are `docs/plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md`
and `docs/plans/177-generate-recovery-model-coverage-from-a-resource-kind-table.md`.


## Plan of Work

### Milestone 1: snapshot and restore

Give the fake object store a way to read and replace its whole state. `fakeObjectOps` keeps its
objects in an `IORef`, so expose that as `fakeObjectState`. Add `snapshotRun :: Run -> IO
RunSnapshot` and `restoreRun :: Run -> RunSnapshot -> IO ()`, which copy and write back:
- the object map;
- the `KubeWorld`;
- the `Adversary`, including counts, so later faults fire at the same ordinals;
- each model `IORef`.

The store keeps no in-process cache or lock between commands. Confirm this in
`cli/nagarectl/src/Nagare/Inventory/Store.hs` and record what you find. If it does keep one,
include it in the snapshot or open a new store handle on restore.

Acceptance: after a stop, take a snapshot, run a move that changes state, restore, and compare
the head, the journal and the world with the snapshot. They are equal.

### Milestone 2: search from the snapshot

Change `searchExit` so each probe restores the stop snapshot and applies its moves, instead of
calling `replay` with the taken paths. Keep `replay` as the reference.

Add an equivalence test that runs every fast-tier schedule under both strategies and requires
identical results: the same violation text, or the same exit path. When it passes, delete the
replay-based probing and keep the test as a regression only if it stays cheap.

### Milestone 3: measurement

Run `just gate-deep` before and after, and record the per-scenario `recovery-model:` timings
here. Acceptance: the single-process deep tier (`just gate-deep shards=1`) is at least five
times faster, and both tiers still pass.


## Concrete Steps

From the repository root:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/recovery model/"'
just gate-deep shards=1
```

Before each commit: `just gate-fast`, then `git diff --numstat`.


## Validation and Acceptance

- **Equivalence.** Every fast-tier schedule gives the same outcome under both strategies.
- **Speed.** The single-process deep tier is at least five times faster than replay.
- **Model unchanged.** Every mutation record in `cli/nagarectl/test/mutations/` whose README row
  names the recovery model still fails.


## Idempotence and Recovery

Test-only change. Each milestone is one commit; reverting it restores replay-based search.


## Interfaces and Dependencies

No production module changes. Test modules touched:
- `test/InventoryRecoveryModelSpec.hs`;
- `test/InventoryObjectOpsSpec.hs` (expose `fakeObjectState`);
- possibly `test/Nagare/Test/World/Kubernetes.hs` and `Adversary.hs`, if a snapshot needs
  accessors.
