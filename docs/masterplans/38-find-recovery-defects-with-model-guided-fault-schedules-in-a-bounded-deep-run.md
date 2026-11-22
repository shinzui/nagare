---
id: 38
slug: find-recovery-defects-with-model-guided-fault-schedules-in-a-bounded-deep-run
title: "Find recovery defects with model-guided fault schedules in a bounded deep run"
kind: master-plan
created_at: 2026-11-22T04:46:14Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-22T04:46:14Z
---

# Find recovery defects with model-guided fault schedules in a bounded deep run

The operator asked for this plan on 2026-11-21. The recovery model's deep tier (`just gate-deep`)
runs every interacting fault pair: about 8.5M pairs, 16–21 core-hours, 6–9 hours on the 16-shard
builder. That makes it unusable, so it is not run, and changes to recovery code get no pair
coverage at all. The idea: a fast decision model, built with shikumi
(`mori://shinzui/shikumi`), reads a change and chooses which fault schedules to run within a
budget of minutes. The plan starts with two cheap gates that stop it within about two days if the
idea does not beat simpler strategies.


## Vision & Scope

### Finish line

`just deep-sample BASE` runs in a fixed budget (default 15 minutes) on the remote builder. It runs
the fault schedules most likely to expose the change since `BASE`, plus a random slice. It reports
any unexcused violation as a minimal schedule, in terms a reader can follow: step, request,
object and fault. It is a manual tool like `just gate-deep`. It is not a landing or release step.

The finish line is reached only if G1 shows that the model beats both baselines (random and
coverage) on frozen mutants. If coverage alone wins, the plan ships `deep-sample` ordered by
coverage, with no model, and stops there.

### What this plan may change

- The recovery model's test harness: `cli/nagarectl/test/Nagare/Test/Model/`,
  `cli/nagarectl/test/Nagare/Test/World/` and the deep-tier entry in
  `cli/nagarectl/test/InventoryRecoveryModelSpec.hs`. This includes redesigning how faults are
  addressed and how the deep tier chooses and orders its work.
- A standalone experiment under `experiments/guided-deep-tier/`, with its own cabal project. It is
  not in the gate, the flake or the payload until D5 promotes it.
- New `just` recipes for the sampled run.

### What this plan does not change

- The fast tier, the invariants and the two-sided known-defect ledger
  (`test/Nagare/Test/Model/KnownDefects.hs`). The model chooses only what to run. Pass and fail
  are decided only by the invariants and the ledger, as now.
- `just gate-deep`. It stays as the exhaustive manual tool.
- Any production module under `cli/nagarectl/src` or `cli/nagare-core/src`, and any gate, landing
  or release rule.


## Decomposition Strategy

The work is ordered so that the cheapest question that can kill the idea is answered first:

- **G0** asks whether the deep tier has anything to find that the fast tier misses.
- **G1** asks whether a model finds it faster than random choice or coverage, in a fixed budget.
- Only after both pass does the plan build the larger redesign: semantic fault addresses (D3), an
  agent that proposes schedules (D4), and the routine recipe (D5).

G0 and G1 build only what the comparison needs, and nothing they build is wasted if the idea
fails. The cell filter and the coverage map are what D5 needs for a coverage-only `deep-sample`.

Deliverables are owned by this MasterPlan, as in
[MasterPlan 37](37-make-releases-routine-by-deleting-what-nagare-does-not-need.md). The operator's
rule (CLAUDE.md, 2026-11-17) requires an ExecPlan only for multi-day work. D4 gets one if it
proceeds; the others are small enough to track here.

Relevant ADRs:
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) defines
  the recovery model, the fast and deep tiers, the kind table, the validated world and the
  known-defect ledger. Its 2026-10-12 amendment made the deep tier a manual tool.
- [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) applies to any experiment
  code promoted into the repository's packages.

Rejected alternative: having the model choose a subset of the existing pair list without changing
the tests. The ordinal addresses (`Boundary ObserveCall 24`) mean nothing to a model and shift with
every code change, so they cannot support stable labels or targeted schedules. G1 still uses
coarse cells (scenario × fault kind × fault kind) so the comparison needs none of D3.


## Exec-Plan Registry

| Deliverable | Plan or owner | Hard prerequisite | Status |
|---|---|---|---|
| G0. Realistic recovery bugs that survive the fast tier | MasterPlan | None | Not Started |
| G1. Model, coverage and random orderings compared on a fixed budget | MasterPlan | G0 passed | Not Started |
| D3. Semantic fault addresses | MasterPlan | G1 passed with the model winning | Not Started |
| D4. Schedule-proposing agent with expansion and shrinking | ExecPlan, created when it starts | D3 | Not Started |
| D5. `just deep-sample` | MasterPlan | G1 (coverage-only form), D4 (model form) | Not Started |


## Dependency Graph

G0, then G1, then D3, then D4, then D5. Each gate can end the plan:

- If G0 fails, record the result in ADR 25 and close the plan.
- If G1 shows coverage ≥ model, go straight to D5 in its coverage-only form and cancel D3 and D4.
- If G1 shows the model winning, continue with D3.
- If D4 does not beat G1's selector (Gate 2, below), D5 ships G1's selector.


## Integration Points

- **The cell list and the catalogue belong to G1.** A cell is a scenario label, a first fault
  kind and a second fault kind. The catalogue is JSON written by the test suite. It lists every
  scenario's label and steps, every fault kind with its Haddock comment from
  `test/Nagare/Test/World/Adversary.hs`, and each cell's pair count and measured cost. Strategies
  hand the deep tier an ordered cell file. D5 reads the same file. D3 widens a cell to a
  semantic address without changing the file's ordering contract.
- **Semantic addresses belong to D3.** D4's tools and D5's reports consume them. `Boundary` stays
  the internal run key, so existing pinned regressions keep working.
- **The selector interface belongs to G1:** a diff and the catalogue in, scores per scenario and
  per fault kind out. D4 replaces the implementation and keeps the interface, so D5 can run
  either one.


## Progress

No deliverable started.

**G0. Do realistic recovery bugs survive the fast tier?** Budget: half a day of work, about an hour
of builder time.

Write 20 mutants before any selector exists, and commit them so the set cannot be tuned later.
Each mutant is a realistic, compiling, single-site bug in the recovery paths that
`just deep-tier-required` lists: `Execute/`, the journal, the store, `Adapters/`, `Collection/`,
the data fence, live restore. Examples: a missed journal write, a wrong settle condition, a retry
that skips observation, an incarnation check against the wrong identity. The person or model that
writes them is not the model the selector uses.

Prove each one against every nagarectl and nagare-core test that `just gate-fast` runs. Reuse the
mutation sweep (`just mutation-sweep`): make a throwaway commit, never landed, whose
`cli/nagarectl/test/mutations/` holds only these mutants. Each record's pattern selects the whole
suite. A record that survives is a candidate: a bug that only the deep tier, or nothing, could
catch.

- [ ] At least 5 of the 20 mutants survive the fast gate. If fewer survive, the fast tier already
  catches what the deep tier would: record the counts in ADR 25 and close this plan.

**G1. Does the model beat random and coverage on a fixed budget?** Budget: about a day and a half
of work, plus one unattended afternoon of builder time.

1. **Cell filter and deadline.** The deep tier reads `NAGARE_RECOVERY_MODEL_CELLS` (an ordered cell
   file) and `NAGARE_RECOVERY_MODEL_DEADLINE` (seconds), next to the existing
   `NAGARE_RECOVERY_MODEL_DEEP`, `_SHARD` and `_PAIRS`. It runs cells in file order across the
   shards and stops at the deadline. It reports the cells completed, and the first unexcused
   violation with its elapsed time. It also writes the catalogue.
2. **Coverage map.** Build the suite once with HPC and run each scenario fault-free with its own
   tix file. Map a diff's changed lines to the scenarios that execute them. The coverage strategy
   runs the covered scenarios' cells in random order.
3. **Selector.** A shikumi program in `experiments/guided-deep-tier/`, using a fast model (Haiku
   5.5) through baikai (`mori://shinzui/baikai`). It gives a `Score '["unrelated", "possible",
   "likely"]` per scenario and per fault kind. Cells are ranked by the product of their scores
   divided by their cost.

   The selector sees the mutant's diff with test files and comments removed, plus the catalogue.
   It never sees tests, the ledger, the mutants' descriptions or this plan.
4. **Comparison.** For each survivor, run four orderings with the same 10-minute budget on 16
   shards: model, coverage, random with seed 1, and random with seed 2. Record which ones detect
   it and when.

- [ ] The model detects at least 2 more survivors than coverage and at least as many as the better
  random seed. Or it detects as many as coverage, with a median time to detection no more than half
  of coverage's.
  - If coverage ≥ model: build D5 in its coverage-only form and cancel D3 and D4.
  - If no ordering detects anything: rerun model and coverage once with a 30-minute budget. If
    still nothing, record that the pair tier does not catch fast-tier survivors within a usable
    budget, and close the plan.

**D3. Semantic fault addresses.** The world names each boundary by step, request verb, `ObjectKey`
(`World/ApiServer.hs`), occurrence, and whether the fault comes before or after the write lands.
Violations and pinned regressions print it. A pinned regression stays valid when an unrelated
change adds a provider call.

- [ ] A schedule written as semantic addresses runs and reports the same outcome as its ordinal
  form, for every pinned pair regression in `InventoryRecoveryModelSpec.hs`.

**D4. Schedule-proposing agent.** A shikumi agent with typed tools: list a scenario's addresses,
trace a schedule, run a batch of schedules, read the diff and the code it touches. It proposes
schedules of up to three faults. The harness expands each one to the other fault kinds at nearby
addresses on the same object and step, and shrinks every violation to a minimal schedule. A random
slice of 20% stays in every run.

- [ ] Gate 2: within the same budget, the agent detects more than G1's selector does. The test set
  is G0's survivors plus at least 5 fresh mutants written after G1. Otherwise D5 ships G1's
  selector.

**D5. `just deep-sample BASE [BUDGET]`.** It runs the chosen strategy, keeps a per-cell staleness
ledger under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/gates/deep-sample/`, and saves the
selection, model id and evidence of each run so it can be replayed. Moving the selector from
`experiments/` into the build, with shikumi as a flake input, is decided here.

- [ ] A sampled run on a recovery change finishes within its budget and reports in the terms D3
  defines (or in cells for the coverage-only form).


## Surprises & Discoveries

- The deep tier's last triaged run found no unknown production defect. The 2026-10-10 run on
  `d42913c9` reported only known ledger classes (F77, F78) and pair-only stops that already had a
  reviewed exit (`git show a8287c7a`). The 3d findings B1, B6 and B8 were fixed in the test world:
  `39154e2f`, `0caa1ea1`, `32e90bf4`. Past findings are therefore too few to evaluate a selector,
  so G0 plants mutants and first checks whether the deep tier has anything to find.


## Decision Log

- Decision: two kill gates come before any redesign. G0 asks whether bugs that survive the fast
  tier exist; G1 asks whether the model beats random and coverage on the same budget.
  Rationale: the operator asked for a quick way to find out whether this helps without spending
  days. Every artifact the gates build is reused by a coverage-only `deep-sample` if the model
  loses.
  Date: 2026-11-21
- Decision: the model only orders and proposes work. Pass and fail stay with the invariants and the
  known-defect ledger. The fast tier and `just gate-deep` do not change.
  Rationale: a wrong model then costs coverage, never a false pass.
  Date: 2026-11-21
- Decision: the selector stays in `experiments/guided-deep-tier/`, outside the gate, the flake and
  the payload, until D5.
  Rationale: an unproven idea should not change Nagare's build closure.
  Date: 2026-11-21
- Decision: `deep-sample` is a manual tool, not a landing or release step.
  Rationale: ADR 25, 2026-10-12 amendment, and the operator's release rules in CLAUDE.md.
  Date: 2026-11-21


## Outcomes & Retrospective

(To be filled at completion.)
