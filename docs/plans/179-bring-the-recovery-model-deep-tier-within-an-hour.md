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
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T19:15:39Z
      mode: "implement"
      note: "Implemented M1, M2, M4 and the M5 recipe, pause injection and remote gate-deep; M3 not adopted on its sampled check"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-07T16:59:18Z
      mode: "update"
      note: "MP-23 3d partial deep-tier monitoring record (stopped at 9/52 by operator direction)"
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

- [x] M1: snapshot and restore of a model run. A test restores a snapshot taken at a stop and
  finds the head, journal, world and adversary equal to the snapshot. (2026-10-06: passes in the
  full suite on the remote builder at `31a8a82c`; `EP179-restore-skips-adversary.diff` makes it
  fail.)
- [x] M2: the exit search restores the stop snapshot for each probe. An equivalence test finds
  identical outcomes for every fast-tier schedule under both strategies, and the replay search
  then stays as the reference of a sampled fast-tier check (Decision Log, 2026-10-06).
  (2026-10-06, remote builder: every fast-tier schedule of all 52 scenarios and every 500th fault
  pair, 13,177 schedules, gave identical results under both strategies, in 592 s.)
- [x] M3: placement classes — not adopted (2026-10-06). The sampled check rejected the classes:
  31 members of "create then good update" did not give their representative's outcome. See the
  Decision Log.
- [x] M4: interaction pruning. Pairs whose faults cannot interact are dropped, under a rule stated
  in this plan. A sampled check against unpruned pairs finds no outcome the pruned set misses.
  (2026-10-06, the full 16-shard deep tier at `e78d5969`: of 5,151,686 pairs considered, 756,466
  were dropped as independent and 832 as unreached, about 15%. The check ran 14,866 independent
  pairs against their second fault alone, and 87,468 checkpoint-resumed pairs against the same
  pair from the start. None disagreed.)
- [ ] M5: within budget. `just gate-deep` finishes within an hour with default shards, the
  timings are recorded here, every mutation record whose README row names the recovery model
  still fails, and `just deep-tier-required` reports whether a change needs the deep tier. A
  killed or interrupted run leaves behind everything it found: each violation is written to the
  shard's log as `recovery-model: violation: …` lines the moment it is found, and each
  scenario's summary when that scenario ends.

M5 is not met (2026-10-06): 1 h 53 m before the defect fixes' tryMove fix, about 2.5–3 hours
projected after it (see Surprises). It is re-measured after EP-182 replaces the world. Then the
levers go to the operator: fewer pairs in the 43 generated scenarios, given evidence that they
repeat the explicit scenarios' pairs (46% of the first run's time), or a larger builder. This
plan stays In Progress.

Status (2026-10-06): branch `ep179-rebased`, on land-through-gate `c9bf8d35`, which is on the
defect fixes `9ac3a484`. Commits: M1 `8a66e467`, M2 `2ae4f461`, M4 `e42a7ed2`, the
`deep-tier-required` recipe `16ad5d3c`, the retry pause and the kept replay check `5f122f7d`,
`gate-deep` on the remote builder `95d04c80`, the mutation proofs `31a8a82c`. On the remote builder
at `31a8a82c` the whole nagarectl suite passes (1,233 tests in 409 s), with the snapshot-versus-
replay check costing 33.9 s of the fast tier. The three records EP-179 touches fail as their
README rows say. M2's exhaustive equivalence run (every fast-tier schedule of all 52 scenarios
and every 500th fault pair, both strategies) and M5's 16-shard timing on an idle builder follow.
M3 is not adopted: its sampled check failed (see the Decision Log).


## Surprises & Discoveries

- The object-store inventory keeps no state between commands besides two mutex `MVar`s, the
  backend guard and the process lock (`Nagare.Inventory.Store`, `ObjectBackend`). Both are taken
  with `withMVar` or `finally` and are released on every exception, `Interrupted` included, and the
  model opens its stores with no cache path or lock file. So the fake store's object map is the
  whole store, and restoring it needs no new handle. (M1, 2026-10-06.)
- The fake object store could not grow in `test/InventoryObjectOpsSpec.hs`, which sits at its size
  allowance. It moved to `test/Nagare/Test/World/ObjectStore.hs` (`fakeObjectOps`,
  `fakeObjectState`). The object-ops spec re-exports `fakeObjectOps`, and its allowance dropped
  from 1086 to 1054. (M1.)
- Where the fault-free runs spend their boundaries (contended census, 2026-10-06): `create` has 2
  mutate, 10 observe, 20 store-put and 37 store-get calls, 201 placements; `create then good
  update` 406; `create, bad update, corrected update (history unchanged)` 576 (4, 30, 56, 118).
  Store calls are about 68% of placements, because each store put carries five faults. The
  snapshot search was 1.15–1.4x faster than replay where no step stops fault-free, and 2.0x
  (singles) and 2.3x (pairs) in the bad-update scenario, whose fault-free run stops once. So the
  exit search is not the dominant cost; the forward execution is.
- `ingestReceipt` reads history through the faulting store with `orFail`. A `GetFailedOnce`
  during ingestion turns into `assertFailure` and aborts the whole shard. The deep run of
  2026-10-06 lost shard 6 to it after 878 s. The fix (retry through `retryingStoreFaults`) is
  item 5 of the defect fixes. The new deep tier reports a model assertion inside one run as that
  run's violation instead of ending the shard.
- The first interaction rule compared only where each step stopped. Its sampled check failed at
  once: a `CrashBeforeStorePut` on the claim write of step 0 leaves no stop, but step 0 never
  applies its review, so a later fault meets a different state. The plan's condition is that the
  first fault's step "converged with an idle head". The trace now also records the head's
  accepted and converged revisions and active transaction at every step boundary, and a step
  counts as affected when either its stop or its end state differs. With that rule the check
  found no disagreement in a 1/100 rehearsal (113 independent pairs checked).
- Checkpoint resumption measured 1.19x less CPU on the 1/100 rehearsal (511 s to 431 s), under a
  load average above 140. That is less than estimated; later steps cost more than earlier ones
  (the journal grows), so skipping early steps saves less than their count suggests.
- The deep run of 2026-10-06 (`deep-20261006T140621Z`) was killed at 16:04:20 UTC by this plan's
  implementer: a `pkill -f "nagarectl-test -p /deep tier/"` meant for a rehearsal matched every
  shard. The run had printed only violation counts, because `runTier` kept the texts for the
  final assertion, so the violations of shards 1 and 5 (92–154 per finished scenario) were lost.
  Hence M5's requirement that each violation is written the moment it is found. Processes are
  now stopped by their recorded PID only.
- Placement classes keyed by what a placement does alone — its fault, its step, and the exits
  and head states of its single run — compress placements about 6.5x (2,894 placements into 436
  classes over the first six explicit scenarios, about 40x fewer pairs). The sampled check
  rejected them at once: in "create then good update", 31 members, each paired with one of three
  fixed partners, did not give their representative's outcome. For example `ForeignObject` at
  observation 6 and at observation 5 do the same alone, but with `GetFailedOnce` at store read 21
  one stops with `[Resume,Close]` and the other with `[Close]`. The cause is that a second fault
  is placed by absolute call ordinal: members that do the same alone shift the later calls
  differently (a retry, a re-observation), so the same partner ordinal names a different moment.
- A 1/8 shard of M2 and M4 without classes, run alone at load 8–15 on 2026-10-06 from 16:24
  UTC: `create` 69 s, `create then good update` 118 s, the three bad-update scenarios 315, 284
  and 497 s, `create with a durable volume, then retire` 110 s, `create a database, then ingest
  a scheduled receipt` 1,081 s, `create a database, then retire it` 1,033 s; `create a database,
  update its resources, then update it again` reached 25 of 130 heads in 528 s. Then the process
  received SIGTERM at about 17:40 UTC, 4,586 s in. The signal is unexplained: neither session
  nagare nor nagare-defects sent it. Projected, the shard needs 6,000–7,000 s: twice the budget.
- The same run used 2,193 s of CPU in 4,586 s, 48%. An instrumented 1/100 run agreed (254 s of
  CPU in 813 s), and `+RTS -A64m` changed nothing. The idle time is the store's retry pauses:
  `commitHead` (`Execute/Journal.hs`) and close's head release (`Execute/Close.hs`) wait 250,
  500 and 750 ms before retrying a refused head write, and the model refuses head writes
  constantly. Time per phase in that run, wall clock with the pauses: apply 350 s, planning
  223 s, exit moves 121 s, invariant checks 62 s, settlement 5 s, checkpoints and resumes 1 s.
- M5's first measurement, `just gate-deep e78d5969` with 16 shards on the remote builder (16
  cores by `nproc`; the builder was otherwise idle, by session nagare's confirmation), ran from
  19:50:11 to 21:43:01 UTC on 2026-10-06: 1 h 53 m. The shards took 6,582–6,732 s, within 2.3% of
  each other. All exited 1 on 40,908 violations, most of them the I1 over-reporting of the
  defect fixes' item 6, which `0c1afa7f` corrects and which this commit predates; each such
  violation is an exhaustive, failed exit search, so the time is overstated by an unknown
  amount. Average per shard: the 9 explicit scenarios 3,609 s (database ingest 578, retire 882,
  update twice 1,349; the bad-update scenarios 159, 183 and 324), the 43 generated kind
  scenarios 3,045 s (an update about 153, a retire about 56, a create about 30). The budget is
  not met at this commit: about 1.9 times the hour.
- M5's second measurement, `just gate-deep 88866f75`, after the defect fixes' `0c1afa7f`, built the
  test binary from 21:45:20 to 21:48:41 UTC (3 m 21 s), then ran. It was stopped at 22:30 UTC by
  session nagare's decision, 41 minutes into the run: the shards were on scenarios 7 and 8 of 52,
  which the first run had reached by 26 minutes. Projected end to end: about 2.5–3 hours. The
  likely cause, not yet proved: `0c1afa7f` re-runs an exit move that a new fault stopped without
  progress, so each stop does more work, and fewer runs end early on a violation. The run was
  stopped because MasterPlan 23 was redirected (RES-4): the deep tier confirms only after
  EP-180–182, and EP-182 replaces the Kubernetes world, so timings and violations against
  today's world are obsolete.
- An adapter registry closes over its run's world and adversary `IORef`s. A probe that replays
  into a fresh run must use the registry of that run, not the one from the original stop. The
  reference strategy carries the replayed run's registry for this reason. (M2.)


## Decision Log

- Decision: The budget is one hour wall-clock on the operator's workstation with `just gate-deep`'s
  default shards, measured end to end, including the build. (Amended 2026-10-06: the machine is
  the remote builder; see below.)
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


- Decision: The snapshot code and the exit search live in new modules, `Nagare.Test.Model.Run`
  (the `Run`, its snapshot and restore) and `Nagare.Test.Model.Search` (a depth-first search over
  any move type, given a probe). The spec keeps the scenario driver and the moves.
  Rationale: the spec has to stay within its 1000-line cap while another branch
  (nagare-defects) edits the moves in the same file, and EP-179 must not grow it. A search that
  is generic over the move type cannot conflict with new move constructors.
  Date: 2026-10-06

- Decision: Each probe starts from a snapshot of the state its parent path reached, taken before
  that path's invariant check, rather than restoring the stop and re-applying the whole path.
  The reference (`ByReplay`) replays the scenario into a fresh run and applies the whole path, as
  the old search did. Both run the invariant check once, after the path's last move.
  Rationale: the result is the same state the old probe reached (the invariant check updates
  `runConverged` and `runIncarnations`, so checking a prefix would change it), and a child probe
  re-executes no move.
  Date: 2026-10-06

- Decision: M3 (placement classes) is not adopted.
  Rationale: the plan's rule is no reduction without evidence, and the evidence rejected the
  classes (see Surprises: 31 mismatches in "create then good update", because partner faults
  are placed by absolute ordinal). Classes that survive the check would have to be found by
  probing every member with partners, which costs about as many runs as the pairs it saves,
  since every shard needs every class. Classes labelled by call target would need the world
  modules to record targets and meet the same cause. The operator's requirement is the
  one-hour budget, not three reductions.
  Date: 2026-10-06

- Decision: The interaction rule (M4) as implemented. A pair of distinct boundaries is headed by
  its fault in the earlier step of the fault-free run, or by the earlier boundary when both share
  a step. It runs when both share a step, when the first fault is persistent, when the first
  fault's run alone violates the model, or when the second boundary falls (in the run of the
  first fault alone) in the first fault's step, or no later than one step after the last step the
  first fault made stop differently or end in another head state. It is dropped as `Unreached`
  when the first fault's run never reaches the second boundary, which makes the pair run exactly
  as the first fault alone, and as `Independent` otherwise. Every 50th independent pair is run
  and must end, from the second fault's step on, as the second fault alone at the same place in
  the fault-free run does. `NAGARE_RECOVERY_MODEL_PAIRS=all` runs every pair.
  Rationale: the plan's rule, with "converged with an idle head" checked on the head itself. The
  rule needs only step boundaries, not the order of calls within a step, so no world module
  changes.
  Date: 2026-10-06

- Decision: The deep tier runs every placement alone, then each pair it heads. Every run starts
  from the latest checkpoint whose prefix it shares. A checkpoint is a run's snapshot as a step
  begins, with the step, the image, the exits taken and the trace so far. A single fault or a
  same-step pair starts from the fault-free run's checkpoint at its step, and any other pair
  from its first fault's checkpoint at the second boundary's step. Every 50th pair run from a
  checkpoint is also run from the start, and the two must agree exactly.
  Rationale: this is M2's restore-instead-of-replay applied to a run's prefix: it changes what
  runs, not what is proved, and the comparison checks it continuously.
  Date: 2026-10-06

- Decision: Shards split placements, not scenarios. Every shard runs every scenario and heads
  every n-th placement of each, offset by the scenario's index.
  Rationale: the largest scenario had more than a third of a shard's eight-hour run to itself.
  Splitting by placement balances the shards without measured weights, which is the
  rebalancing M5 asks for.
  Date: 2026-10-06

- Decision: Each violation is written to stderr the moment it is found, every line prefixed
  `recovery-model: violation: [k/N] <scenario> |`, and each scenario's summary when it ends.
  Rationale: required by session nagare after the killed run of 2026-10-06 lost every violation
  text.
  Date: 2026-10-06

- Decision: The deep tier runs on the remote x86_64-linux builder (16 cores), not on the
  operator's workstation. `just gate-deep [rev] [shards]` calls `just test-remote` for a committed
  revision with 16 shards by default, and the one-hour budget is measured there.
  Rationale: operator decision of 2026-10-06, relayed by session nagare: heavy runs go to the
  builder, which is the machine the budget is defined on.
  Date: 2026-10-06

- Decision: The replay search is not deleted after the equivalence check passes, as M2 first
  said. It stays as the reference, and the fast tier checks the snapshot search against it on
  every 25th single fault and every 5,000th fault pair of the explicit scenarios. A mutation
  record (`EP179-restore-skips-adversary.diff`) must fail that check. The spec stays within its
  size by moving the scenario definitions to `Nagare.Test.Model.Scenarios`.
  Rationale: session nagare's ruling. The check is the only guard that snapshot and restore
  stay faithful as the model changes, and deleting it would be the sloppy-test pattern the
  operator called out.
  Date: 2026-10-06

- Decision: The store's retry pause is injectable, and only the recovery model's stores
  replace it. `ObjectOps` gains `pauseBeforeRetry` (`threadDelay` in `gcloudObjectOps`, Gogol
  and the shared test fake), `Store` gains `storeRetryPause`, and `retryPause` in
  `Execute/Journal.hs` keeps the 250/500/750 ms schedule for both retry loops. The model's
  `newRun` sets a pause that counts calls (`runPauses`) and does not wait. A test pins the
  production schedule, and a model test with a mutation record (`headRetries` 3 to 2) shows
  that the model still exercises the retry count.
  Rationale: about half of the deep tier's wall time was sleeping. Session nagare assigned this
  production change to EP-179, on the conditions above.
  Date: 2026-10-06

## Outcomes & Retrospective

2026-10-06, at landing with the defect fixes, land-through-gate and the MP-23 redirect. M5 is open.

Achieved:
- The exit search restores snapshots instead of replaying: 1.15–2.3x faster where scenarios stop.
  The replay search stays as a sampled fast-tier reference (33.9 s on the builder). Breaking
  restore fails only that check, not the fast tier.
- The deep tier runs every placement alone, then only the pairs whose faults can interact. Runs
  resume from per-step checkpoints, and shards split placements. Its 16 shards finished within
  2.3% of each other, and every sampled check of the pruning and the resumption agreed.
- The store's retry pause no longer stalls the model. It was half the wall time on the
  workstation.
- `just deep-tier-required` names the recovery-related files a change touches, and `just
  gate-deep` runs on the remote builder.

Not achieved:
- The one-hour budget: 1 h 53 m before the defect fixes' tryMove fix, and about 2.5–3 hours
  projected after it.
- Placement classes (M3), which their sampled check rejected.

Lessons:
- Measure where the time goes before reducing what is proved. The largest single cost was
  sleeping, found from the ratio of CPU time to wall time, not from the plan's three reductions.
- Faults placed by absolute call ordinal limit any reduction that merges placements. A first
  fault that shifts later calls changes what every later ordinal names. A world whose faults
  name a target and a moment (EP-182) would remove that limit.
- The sampled checks earned their place. They rejected the first interaction rule and the
  placement classes within minutes.
- An operational failure. A pattern-based `pkill` killed a teammate's deep run two hours in, and the
  pre-EP-179 tier printed only violation counts, so that run lost everything it had found. Stop
  processes by recorded PID only, and write findings as they are found.

2026-10-07, MP-23 step 3d: a partial monitoring record. The run was **stopped at scenario 9/52
after about 2 h by operator direction**.

The run:
- Command: `just gate-deep 341b01bc`.
- Shards: 16, on the remote builder (n2-standard-16, "16 cores" in the test run's header).
- Started 14:49:17Z and stopped 16:48:41Z, so the wall time was 1 h 59 m.
- No other builder jobs ran during it (coordinator-confirmed).
- Why it stopped: by the 2026-10-07 amendment to [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) (MP-23 Decision Log), the deep tier is per-release monitoring for v1, not a gate. The run had found no unclassified shape, and it was contending for the builder that the release batch needed.

Scenarios 1–8 finished on every shard. The per-shard seconds below are the fastest and slowest shard for each scenario. Pair counts are summed over the shards. Independent pairs are the ones M4 pruned, so they were not run.

| Scenario | Per-shard s (min–max) | SameStep | PersistentFirst | Interacting | Independent |
| --- | --- | --- | --- | --- | --- |
| 1 create | 16–22 | 20,147 | 0 | 0 | 0 |
| 2 create then good update | 98–130 | 43,207 | 10,416 | 17,820 | 15,800 |
| 3 bad update, corrected (history unchanged) | 226–334 | 56,762 | 28,716 | 25,077 | 62,107 |
| 4 bad update, corrected (history follows) | 276–373 | 65,442 | 32,848 | 27,918 | 72,639 |
| 5 bad update, corrected (durable volume) | 489–639 | 96,649 | 51,528 | 37,470 | 104,400 |
| 6 durable volume, then retire | 61–106 | 40,454 | 5,976 | 10,803 | 6,031 |
| 7 database, then ingest a receipt | 1,015–1,244 | 248,534 | 5,616 | 10,155 | 2,611 |
| 8 database, then retire it | 1,571–1,789 | 258,152 | 30,888 | 50,475 | 19,723 |

The slowest shards' times for scenarios 1–8 sum to 4,637 s. At the stop, every shard was in scenario 9 ("create a database, update its resources, update it again, then restart it"). Fourteen shards had finished 25 of their 78–79 heads (the model's first-fault placements), and shards 2 and 3 had finished 50. The shards had spent 1,785–2,778 s in that scenario so far.

**The first input to the next MasterPlan's pair budget: SameStep pairs dominate the database scenarios.** They are 248,534 of the 264,305 pairs run in scenario 7 (94%) and 258,152 of 339,515 in scenario 8 (76%). Those two scenarios alone took 2,600–3,000 s of each shard's time. A shard-0 sample shows the same: 16,464 of 17,660 pairs in scenario 7, and 15,352 of 21,358 in scenario 8. Ways to cut the cost:
- Prune pairs in which either fault does not act in its own single-fault run. Such a pair can only repeat the other fault's outcome.
- Budget SameStep pairs per step.

The run found 4,944 distinct violating schedules, in nine classes. Each class was triaged under the M4 rule, and each is either fixed in the step-3d batch or recorded in the ledger:

| Class | Schedules | What it is | Kind | Disposition |
| --- | --- | --- | --- | --- |
| F78 | 2,238 | independent members starve behind a StatefulSet whose own template never becomes Ready | ledger | [F78](../audits/mp23-findings.md#f78), deferred to the next MasterPlan |
| F77 | 2,614 | a database volume claim deleted outside review stays Terminating, and reviews refuse | ledger | [F77](../audits/mp23-findings.md#f77), deferred, with a runbook |
| B5 | 8 | F77 composed with an already-excused foreign-object refusal | ledger | counted as F77 |
| B4 | 13 | **product defect F79**: close dropped a never-started member whose absence read failed, leaving a scope no review could exit | (d) new finding | fixed: close refuses, retryably, until absence is confirmed ([F79](../audits/mp23-findings.md#f79)) |
| B1 | 8 | the world ran a lagging controller's catch-up before answering the write that woke it, and recorded a Lands* fault as acted only on its own request | (c) harness | fixed in the world (RES-4 U16): the catch-up follows the write, and a Lands* fault acts when any write of its spec lands |
| B2 | 32 | the model's refusal excuses did not compose (a deleted durable member and a foreign object in one refusal) | (c) harness | fixed: excuses compose per PlanError and resource |
| B6 | 8 | re-reviewing a template that a Lands* fault poisoned plans a verify that prepare refuses, and I1 lacked I9's per-member faulted-template excuse | (c) harness | fixed: a prepare refusal is excused only when each refused member is live at a poisoned template |
| B7 | 2 | I8 asked the adapter to settle a verify, and ADR 26 §6 says a verify never executes | (c) harness | fixed: I8 settles a verify as no effect, and both schedules then end at F77 |
| B8 | 21 | the world's ForeignObject planted a StatefulSet with no spec, which no API server stores | (c) harness | fixed: planted objects are whole, and the fake server refuses missing required fields with 422 |

Only one class, F79, was a product defect. The five harness classes and F79 have mutation records that fail without their fixes. Under the new rule, the next per-release deep run is the place to see whether the fixed classes stay gone and whether scenarios 9–52 hold new ones.


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
same exit path. The replay search then stays as the reference for a sampled fast-tier check (see
the Decision Log).

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

Production changes: the injectable retry pause (`Store/ObjectOps.hs`, `Store/Gogol.hs`,
`Store.hs`, `Execute/Journal.hs`, `Execute/Close.hs`). Test modules touched:
- `test/InventoryRecoveryModelSpec.hs`;
- `test/InventoryObjectOpsSpec.hs` (`fakeObjectState`);
- `test/Nagare/Test/World/Kubernetes.hs` and `Adversary.hs`, if snapshots need accessors;
- `justfile` and `scripts/audit-managed-commands.py`, for `deep-tier-required`.
