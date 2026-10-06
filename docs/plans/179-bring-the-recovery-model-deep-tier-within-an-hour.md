---
id: 179
slug: bring-the-recovery-model-deep-tier-within-an-hour
title: "Bring the recovery model deep tier within an hour"
kind: exec-plan
created_at: 2026-10-06T14:07:13Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-06T14:07:13Z
---

# Bring the recovery model deep tier within an hour

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The recovery model (`cli/nagarectl/test/InventoryRecoveryModelSpec.hs`) proves that every stopped
inventory transaction has a supported exit and that nothing unreviewed is accepted. Its deep tier
replays every scenario under every ordered pair of faults. With the scenarios generated from the
kind table (`docs/plans/177-generate-recovery-model-coverage-from-a-resource-kind-table.md`) that is
about 1.4 million pairs. It takes about 35 hours in one process and 7–9 hours on eight shards. The
operator's ruling (ADR 25 amendment of 2026-10-06) is that the deep tier gates changes to
recovery-related code and must finish within an hour; hours are acceptable only for something
extraordinary.

After this plan, `just gate-deep` finishes within an hour on the operator's workstation, with its
default shards, and proves the same things. Three reductions get it there, each shown not to lose
a verdict:
- **Snapshot search.** On a stop, the exit search restores a snapshot of the run instead of
  replaying the scenario from its start for every probe.
- **Equivalent placements.** Fault placements that reach the same provider operation in the same
  step are grouped, and each group is tested through one representative.
- **Non-interacting pairs.** A pair is tested only if its second fault can see the first one's
  effect. Otherwise the pair is two single faults the fast tier already covers.

A reader sees it working in three ways: the timings `just gate-deep` prints per scenario, an
equivalence report for each reduction, and every mutation record still failing.


## Progress

- [ ] M1: snapshot and restore of a model run. A test restores a snapshot taken at a stop and
  finds the head, journal, world and adversary equal to the snapshot.
- [ ] M2: the exit search restores the stop snapshot for each probe. An equivalence test finds
  identical outcomes for every fast-tier schedule under both strategies, and the replay search is
  then deleted.
- [ ] M3: placement classes. The deep tier pairs class representatives, not raw boundaries. A
  sampled check finds that every member of a sampled class gives its representative's outcome.
- [ ] M4: interaction pruning. Pairs whose faults cannot interact are dropped, under a rule stated
  in this plan. A sampled check against unpruned pairs finds no outcome the pruned set misses.
- [ ] M5: within budget. `just gate-deep` finishes within an hour with default shards, the
  timings are recorded here, every mutation record whose README row names the recovery model
  still fails, and `just deep-tier-required` reports whether a change needs the deep tier.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The budget is one hour wall-clock on the operator's workstation with `just gate-deep`'s
  default shards, measured end to end, including the build.
  Rationale: the operator's ruling is that the deep tier need not take 15 minutes but cannot take
  hours. One hour is the stated ceiling, and it allows the tier to gate recovery-code changes on
  the same day.
  Date: 2026-10-06

- Decision: Every reduction is accepted only with evidence that it loses no verdict: equivalence
  for the snapshot search, and sampled checks against the unreduced product for classes and
  pruning. The replay search and the full pair set stay available behind a flag until their check
  passes.
  Rationale: a faster model that proves less is worse than a slow one. The reductions change what
  is run, not what is proved, and each must show it.
  Date: 2026-10-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**The model.** `cli/nagarectl/test/InventoryRecoveryModelSpec.hs` runs Nagare's real planner,
driver, recovery and close code against in-memory providers:
- the Kubernetes world in `test/Nagare/Test/World/Kubernetes.hs`, an `IORef KubeWorld`;
- the fault adversary in `test/Nagare/Test/World/Adversary.hs`, an `IORef Adversary` that fires
  a fault at the n-th call of one provider operation (a boundary);
- an object-store inventory over `fakeObjectOps` from `test/InventoryObjectOpsSpec.hs`, wrapped by
  `test/Nagare/Test/World/Store.hs` for store faults.

A `Run` holds the store, a clean inspection view of it, the world, the adversary, and `IORef`s the
invariants use (`runBound`, `runImages`, `runIncarnations`, `runDatabase`, `runConverged`). The
scopes are in `test/Nagare/Test/Model/Fixtures.hs`.

**Scenarios, placements and tiers.**
- A scenario is a list of steps (reviews), explicit or generated from the kind table
  (`test/Nagare/Test/World/Kinds.hs`).
- A fault-free run counts each call. A placement is a (call number, fault) pair, and every fault
  kind is tried at every call number of its call.
- The fast tier tries each placement alone. The deep tier (`faultPairs`) tries every ordered pair.
- `just gate-deep` runs the deep tier as parallel shards of the scenario list
  (`NAGARE_RECOVERY_MODEL_SHARD=i/n`, eight by default). Each shard prints `recovery-model:` lines
  with schedule counts, heartbeats, and per-scenario time and violations.

**Measured size (2026-10-06, before this plan).**
- Pairs per explicit scenario:
  - 19,758 (create);
  - 81,531 (create then update);
  - 164,656 to 274,407 (bad update then correction);
  - 62,232 (retire with a volume);
  - 260,427 (receipt ingestion);
  - 351,711 (database retire).
- About 600–850 pairs a minute per shard process.

**Where the time goes.**
1. **Exit search by replay.** On a stop, `searchExit` explores moves (`Resume`, `Close`,
   `TakeOver`), and every probe calls `replay`. That builds a new `Run` and re-executes every step
   and every exit already taken. Pairs stop more often than single faults, and a stop costs several
   full replays.
2. **Placement granularity.** A planning pass observes each member, so a scenario has dozens of
   observe boundaries. Many of them are the same kind of moment: the same operation, in the same
   step, on a member of the same role. The pair count grows with the square of the placements.
3. **Pairs that cannot interact.** A transient fault whose effect is fully resolved before the
   second fault's boundary, for example both inside different converged steps, makes a pair that
   is two independent single faults.

**Relevant ADRs.**
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), with its
  amendments of 2026-10-05 and 2026-10-06. It makes the model the defect finder, defines the
  change-scoped deep tier and the list of recovery-related paths, and sets the one-hour budget.
- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) defines the exits the
  search explores.


## Plan of Work

### Milestone 1: snapshot and restore

Give the fake object store a way to read and replace its whole state. `fakeObjectOps` keeps its
objects in an `IORef`, so expose that as `fakeObjectState`. Add `snapshotRun :: Run -> IO
RunSnapshot` and `restoreRun :: Run -> RunSnapshot -> IO ()`, which copy and write back:
- the object map;
- the `KubeWorld`;
- the `Adversary`, including counts, so later faults fire at the same ordinals;
- every model `IORef`.

Confirm in `cli/nagarectl/src/Nagare/Inventory/Store.hs` that the store keeps no in-process cache
or lock between commands, and record what you find. If it does keep one, snapshot it or open a new
handle on restore.

Acceptance: a test takes a snapshot at a stop, runs a move that changes state, restores, and finds
the head, journal, world and adversary equal to the snapshot.

### Milestone 2: search from the snapshot

`searchExit` takes the snapshot at the stop, and each probe restores it and applies its moves.
Keep `replay` as the reference behind a flag. Add an equivalence test that runs every fast-tier
schedule under both strategies and requires identical results: the same violation text, or the
same exit path. Then delete the replay probing.

### Milestone 3: placement classes

During the fault-free run, label each boundary with its class: the call, the scenario step, the
provider operation, and the member's role (for an observation, the member observed; for a write,
the reviewed operation). The deep tier pairs one representative per class. Choose the first
boundary of the class, and record the choice.

Add a sampled check. For a fixed-seed sample of classes, every member of the class, paired with a
fixed set of second faults, must give the representative's outcome. A mismatch splits the class,
which means the labelling was too coarse, so refine it. Run the check in the deep tier itself,
not the fast tier.

### Milestone 4: interaction pruning

State the rule and implement it in `faultPairs`. A pair (f1, f2) at boundaries (b1, b2), b1
before b2, is kept when any of these holds:
- f1 is persistent (`faultPersistence`);
- b2 falls in the step b1 falls in;
- b2 falls in the exit search or recovery of a stop that f1 caused;
- b2 falls in the step after that.

A pair is dropped only when f1 is transient and its step converged with an idle head before b2's
step began.

Add a sampled check against unpruned pairs for a fixed-seed sample of dropped pairs. Each one's
outcome must equal the outcome of f2 alone after f1's step, so that it is already covered by the
fast tier. A mismatch means the rule is unsound: tighten it, and record the reason.

### Milestone 5: within budget, and a change check

Measure `just gate-deep` end to end and record the per-scenario timings here. If it is still over
an hour, rebalance the shards by measured cost instead of round-robin before reducing anything
further.

Add `just deep-tier-required base=<ref>`. It lists the files changed since `base` that fall under
the recovery-related paths named in ADR 25's 2026-10-06 amendment, and exits non-zero when there
are any. Register the recipe in `scripts/audit-managed-commands.py` and regenerate its catalogue.


## Concrete Steps

From the repository root:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/recovery model/"'
time just gate-deep
just deep-tier-required base=origin/master
```

Expected `gate-deep` output ends with each shard passing:

```text
shard 0/8: passed
…
shard 7/8: passed
```

Before each commit: `just gate-fast`, then `git diff --numstat`. Mutation proofs run in a scratch
worktree.


## Validation and Acceptance

- **Budget.** `time just gate-deep` finishes within an hour with default shards, and every shard
  passes.
- **No lost verdicts.**
  - The snapshot equivalence test passes.
  - The class and pruning sampled checks pass.
  - Every mutation record whose README row names the recovery model still fails.
- **Change check.** `just deep-tier-required` names the recovery-related files changed since its
  base, and exits non-zero only when there are any.


## Idempotence and Recovery

Everything is test-only except the new recipe. Each milestone is one commit. Reverting a milestone
restores the slower but unreduced behaviour. The flags that keep the replay search and the full
pair set can be removed once their checks have passed in one deep-tier run.


## Interfaces and Dependencies

No production module changes. Touched:
- `test/InventoryRecoveryModelSpec.hs`;
- `test/InventoryObjectOpsSpec.hs` (`fakeObjectState`);
- `test/Nagare/Test/World/Kubernetes.hs` and `Adversary.hs`, if snapshots need accessors;
- `justfile` and `scripts/audit-managed-commands.py`, for `deep-tier-required`.
