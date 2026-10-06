---
id: 177
slug: generate-recovery-model-coverage-from-a-resource-kind-table
title: "Generate recovery model coverage from a resource kind table"
kind: exec-plan
created_at: 2026-10-05T21:51:36Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-05T21:51:36Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T14:20:53Z
      mode: "update"
      note: "Deep tier made change-scoped and bounded (operator, 2026-10-06)"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T15:23:30Z
      mode: "implement"
      note: "Create-scenario deep rerun: three harness gaps fixed, F66 recorded and fixed"
---

# Generate recovery model coverage from a resource kind table

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare's recovery model runs the real planner, driver, recovery and Kubernetes adapter over an
in-memory provider world with injected faults, and fails when a stopped transaction has no exit or
something unreviewed is accepted. It found many defects in seconds, but it only covers what someone
remembered to add. The exhaustive review measured it at 17% of reachable fault cells, all on
Kubernetes, with seven hand-written scenarios
(`docs/audits/mp23-exhaustive-review-2026-10-05/D-model-coverage.md`). So each review round found the
next uncovered instance of a known class.

After this plan, coverage is generated, not hand-picked. A single *kind table* declares, for every
resource kind in MasterPlan 23's release line:
- the actions it supports;
- whether it can be unready or fail;
- whether its effect is one step or several;
- how its identity is known;
- a minimal fixture.

The model generates every (kind, action, fault) case from that table and runs the existing invariants
on each. A *totality test* fails when an executor or an action an adapter admits has no table row. A
kind outside the release line still needs a row; that row marks it a documented limit. So a new kind
or adapter cannot ship silently uncovered.

A reader sees it working in three ways:
- the fast tier reports how many cases it generated;
- the totality test names any missing row;
- deleting a table row makes the totality test fail.

This plan implements the 2026-10-05 amendment of
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), step 3 of
MasterPlan 23's release line (b).


## Progress

- [x] M1 (2026-10-05): the kind table and totality test.
  - **Table.** `test/Nagare/Test/World/Kinds.hs` has 16 in-line Kubernetes rows covering the
    application, database and backup kinds. Three platform-bootstrap Kubernetes kinds (CRD,
    cert-manager Certificate and ClusterIssuer) and every other executor get documented-limit rows
    that name the attested close as their exit.
  - **Universe.** The adapter's update, collection and readiness allowlists are now exported lists
    (`supportedUpdateKinds` and `readinessKinds` in the new `Adapters/KubernetesKinds.hs`,
    `collectionKinds` in `Adapters/KubernetesCollection.hs`), with the predicates reading them. Together with the kinds a standalone PostgreSQL and Redis database compile to, they form
    the universe the totality test requires rows for.
  - **Cross-checks.** Each in-line row's update, collect and readiness claims are checked against
    the adapter. A test checks that the lists agree with the adapter's own predicates.
  - **Mutation records.** Deleting a row, a wrong claim, and an adapter kind added without a row
    each fail a named test.
  - **Not yet.** The plan's per-row fixture is deferred to M2, where generation needs it.
- [ ] M2 (code in 2026-10-05; acceptance waits for `just gate-deep`): the generated product.
  - **Scenarios.** Each in-line row with a fixture yields scenarios: create, update (where the
    row admits it) and retire, with one member of the kind added to the application scope. That
    gives 43 generated scenarios beside the 9 explicit ones.
  - **Fixtures.** `kindFixture` gives each kind a minimal manifest, and the totality test requires
    one for every in-line row.
  - **Placement.** The fast tier places each provider fault once, at the last boundary of its
    call, which falls in the step under test. Every boundary and ordered pair is left to the deep
    tier (`just gate-deep`, registered in the command audit).
  - **Reach.** A test checks that every generated create writes its kind's member: one more
    provider write than the plain create.
  - **Results.** The fast tier passes. The model's scopes moved to `Nagare.Test.Model.Fixtures`,
    because the spec outgrew its size bound.
- Original M2 text: the generated product. The scenario × applicable-fault × invariant product is generated
  from the table and replaces the hand-written scenario list. The fast tier runs a sampled product
  in the ordinary suite, and the deep tier runs the full product under `just gate-deep`.
- [ ] M3 (code in 2026-10-05; acceptance waits for `just gate-deep`): the faults and harness fixes.
  - **New faults.** `CrashBeforeStorePut`, `CrashAfterStorePut` and `ClaimLost`. `ClaimLost` lands
    another client's claim at the generation a head write expects, so the write conflicts.
  - **Exit move.** `TakeOver`, a resume with take-over: the supported exit after a lost claim.
  - **Harness.** A crash while planning is retried once, as an operator re-runs the command.
  - **Liveness.** `LandsFailed` is live through the generated Job scenarios. A test proves the new
    faults take effect: some lost claim needs take-over, and some failed Job needs close.
  - **`ForeignObject` exemption.** It is scoped to refusals that name a resource the fault filled.
    That exposed four refusals the blanket exemption had hidden, all of one expected kind:
    retiring a scope whose create was closed and reverted, which was never accepted. That refusal
    is now declared expected, and only when the named scope really is not accepted.
  - **Mutation record.** `ADR25-model-no-takeover-exit`.
  - **Deferred.**
    - `ReplacementRequired`: the model has no reviewed replacement or migration exit, so the fault
      would only produce expected refusals.
    - A dedicated corrected-review exit move: corrected reviews are explored by the explicit
      bad-then-corrected scenarios, and by the fresh-review replan that EP-176 M3 added.
- [x] M3 follow-up (2026-10-06, branch `create-scenario-fixes`): the deep tier's "create"
  scenario, rerun alone as deep shard 0/52 at `a4d84543`, had 67 violations. Each has a cause:
  - 25 were a harness gap: admission was retried only once (see Surprises).
  - 3 were a harness gap: there was no close with take-over (see Surprises).
  - 3 were a harness gap: progress ignored the world (see Surprises).
  - 36 (20 I1 and 16 I8) were one product defect, F66 in `docs/audits/mp23-findings.md`.
  After all four fixes, the same rerun reports `recovery-model: [1/1] create: done in 722s, 0
  violation(s)` (19,758 schedules, observed). A regression test pins one schedule of each cause: "create-scenario fault pairs that had no exit now have one (EP-177, F66)".
- Original M3 text: the faults and harness fixes. The model gains:
  - the `CrashAtStore` and `ClaimLost` faults;
  - a live `LandsFailed` through Job fixtures;
  - a `ForeignObject` exemption scoped to the faulted step;
  - a corrected-review exit move;
  - every in-line action exercised under every applicable fault.

  The fast tier and deep tier pass.


## Surprises & Discoveries

- **Size of the deep tier.** With the generated product it is far larger than planned.
  - The explicit scenarios alone have about 1.4 million ordered fault pairs, with up to 351,711
    for one scenario.
  - One process runs about 600–850 pairs a minute.
  - Run as one process, the tier did not finish in more than eight hours.
- **What changed.**
  - `just gate-deep` now runs parallel shards of the scenario list (`shards=8` by default),
    each printing `recovery-model:` progress lines.
  - Even sharded, the largest scenario bounds the wall time at about seven hours.
  - The replay-based exit search is the main cost. Searching from a snapshot is planned in
    `docs/plans/179-bring-the-recovery-model-deep-tier-within-an-hour.md`.
- **A bug the first deep run found.** Two store faults could crash both planning attempts, and the
  `Interrupted` escaped the harness. Planning is now retried until no new fault fires.
- **Three harness gaps in the "create" deep rerun (2026-10-06, shard 0/52 at `a4d84543`).** Each
  was confirmed by its own schedule before the fix. The search is unchanged: a found exit still
  has to reach an idle head through the product's own commands.
  - **Admission was retried only once (25 violations).** When store faults hit both admission
    attempts, the review was refused with `StoreIoError` (`retention-coverage`, `store`,
    `head-condition` or `deferred-operation`). `applyRetryingFaults` now re-runs admission while
    new faults fire and the head stays idle, as `retryingStoreFaults` already does for planning.
  - **There was no close with take-over (3 violations).** A landed, unready create whose claim
    was lost cannot resume or close without take-over (`executor-claim`). Take-over resume then
    stops in the same state, so the search pruned it as "no progress". The product's exit is
    `inventory close --take-over`, and the model now has it as the `CloseTakeOver` move.
  - **Progress ignored the world (3 violations).** A landed, unready create whose Service is then
    deleted outside Nagare is proved safe to retry, so close says "run inventory resume first".
    Resume recreates the Service, which again lands unready in the same journal state, so the
    search pruned it. `progressSignature` now also compares each live object's UID, content and
    readiness, but not its resourceVersion, which status churn moves. The exit found is exactly
    `[Resume, Close]`, so the product is consistent: resume progresses exactly as close says. A
    fault firing during a move can also count as progress. That only extends the search; it
    cannot create an exit.
- **A fourth harness gap aborted a whole deep shard (2026-10-06, found by session nagare).** Shard 6
  of the run that started at 14:06 UTC failed after 878 s, at about schedule 12,500 of 260,427 in
  "create a database, then ingest a scheduled receipt", with `load history: StoreIoError
  "injected: store read failed"`. `ingestReceipt` read the faulting store through `orFail`, so one
  injected read failure became an `assertFailure` that ended the shard. The shard's other five
  scenarios never ran.
  - The native-evidence read in the same function turned a failed read into `Map.empty`. That
    silently passed the I3 ingestion clause under a fault.
  - Both reads now run through `retryingStoreFaults`, as an operator re-runs the command after a
    failed read. Fault-free behaviour is unchanged.
  - The regression test "a store read that fails during receipt ingestion is re-run, as an
    operator would (EP-177)" places `GetFailedOnce` at every store read in that scenario. Before
    the fix it aborted in 3 s with the same error; after it, it passes in 3.4 s. This sweep is
    the accepted proof. The 6/52 shard (260,427 pairs, several hours) was not rerun, and the
    confirming deep run after plan 179 lands covers the pairs. Item 6 later folded this test into
    the harness self-test, which runs the same placements.
- **A fifth harness gap: a crash during admission passed vacuously (2026-10-06, proved before the
  fix).** `CrashBeforeStorePut` on admission's head write (put 7 in "create") leaves the head
  idle. `classify` then read the stop from the head, found no active transaction and called the
  step `Done`. The run ended with no violation, no exit and 0 provider writes: the create never
  ran. Every other crash placement in that scenario writes both members. Apply now re-runs a
  crash only when the head generation is unchanged. A crash after the final head write is a
  transaction that finished, and is not re-run; the first cut tested "head idle", and the fast
  tier caught that with two `stale-head` refusals. The self-test pins the case: the create writes
  both members under that crash.
- **Root cause of all five gaps, and the structural fix (item 6, at the operator's request).**
  - **Root cause.** The checker and the code under test shared the faulting store. The retry
    policy was decided per call site: planning looped, apply retried once, moves retried once,
    and ingestion and the checks did not retry. And the harness was never self-tested, so a
    harness error surfaced only as a lost deep shard or as a vacuous pass.
  - **The checker's reads.** A new module, `Nagare.Test.Model.Run`, holds the `Run`. It does not
    export the faulting store (`runStore`), or the constructor of the read-only `InspectStore`,
    which the checks read through `inspectHead`, `inspectJournal`, `inspectHistory` and
    `inspectIncarnations`. A check that reads the faulting store no longer compiles.
  - **One retry policy.** Every operator command (planning, apply, each exit move, ingestion)
    runs through one `operatorAction`, which re-runs it while new faults fire. What counts as a
    failure is the command's own `Left`.
  - **The self-test.** The fast tier gains "harness self-test: every harness-owned fault in every
    scenario ends in a result or a named violation". It places every store fault, crash, lost
    claim and failed read alone, at every placement, in all 52 scenarios. It skips the placements
    the fast tier's own `singleFaults` already runs, and a test checks that every skipped
    placement is one the fast tier runs. It requires no harness exception, and every violation
    must name an invariant. Provider faults are placed at every boundary alone by the deep tier
    (plan 179 M4), which is why the fast tier places them only at the last boundary of their call.
  - **Timing, with the replay-based exit search, for comparison after plan 179's snapshot search
    (both on a loaded machine).**
    - Before the dedup: 15,289 runs, 466 s wall and 270 s of CPU (59% of a core).
    - After the dedup: 14,534 runs, 419 s wall and 241 s of CPU (57% of a core).
    - The operator's budget is 300 s.
  - **Mutation records.** `ADR25-model-check-reads-faulting-store` no longer compiles.
    `ADR25-model-operator-reruns-once` fails the create-scenario regression test.
  - **What it found.** The full single-fault sweep (all faults, 21,555 runs) found one
    unexcused planning refusal: F63's open worker-Deployment half, under `LandsUnready` on the
    Deployment update.


- **A regression in item 6, found by the five-scenario reruns (2026-10-06).** The reruns ran on the
  remote builder at `9b9e9d40`, which carries the same test code as `9ac3a484`. They reported
  429, 429, 713, 715 and 813 violations, against 92, 92, 144, 152 and 154 at `a4d84543`. Of the
  400 violation texts each shard printed, 375–397 were one class:
  - Resume was refused as "no progress", while close refused with "resume can still progress:
    the adapter proves … complete".
  - A typical schedule is `LostAcknowledgement` on the first write, plus a second fault that hits
    the resume itself, such as a refused store write or a failed read.
  - The cause: the old `tryMove` re-ran a move once whenever a fault had fired during it. Item 6's
    `operatorAction` re-runs only a `Left` or a crash, so a resume that a fault stopped again in
    the same state was never re-run. This needs a pair of faults, so neither the fast tier nor
    the self-test could see it.
  - The fix: an attempt that returns without progress while the head is still active counts as a
    failed attempt. `operatorAction` re-runs it only if a new fault fired, so a resume that no
    fault stopped stays a dead end.
  - The test "a move that a new fault stopped without progress is re-run; one that no fault
    stopped is not" pins both sides. The logged pair now exits with `[Resume]`, and `LandsUnready`
    alone still exits with `[Close]`. The mutation record is
    `ADR25-model-move-without-progress-not-rerun`.
  - The remaining 3–25 printed violations per shard are classified after a rerun with the fix.


- **World fidelity: status churn only on kinds with status (2026-10-06, operator ruling).** Class
  B of the rerun triage was an I8 on the release-history ConfigMap. The world's `StatusChurn` had
  bumped its resourceVersion, but a ConfigMap has no status subresource. In production its
  resourceVersion moves only when someone writes it, and its configuration then changes too. The
  world now churns only kinds with a status subresource (its `hasReadiness` kinds).
  - A local pair sweep (`StatusChurn` at every write × `PutRefused` at every store write) checked
    the effect. "create then good update" went from 1 B-class I8 (the ConfigMap) to 0.
  - The real cases remain. The database StatefulSet update has 2, at (10, 72) and (11, 84). The
    generated Deployment update has 1, at (5, 44). F67 fixes them.


## Decision Log

- Decision: Generate rows only for the kinds in MasterPlan 23's release line (b). Every other
  executor gets an explicit documented-limit row, naming ADR 26's attested close as its exit, instead
  of a world.
  Rationale: the operator chose line (b), which defers the non-Kubernetes worlds that D estimates at
  four to five weeks. A limit row keeps the totality test honest without building those worlds.
  Date: 2026-10-05

- Decision: The fast tier samples one placement per (kind, action, fault) at a representative
  boundary and must stay under about two minutes. The deep tier runs every placement and every
  ordered pair, through a new `just gate-deep` recipe that runs the suite on the remote builder.
  Rationale: the fast tier already grew from 51 s to about 130 s with hand-added scenarios, and a
  generated product would grow it much more. Exhaustive placement belongs to the deep tier, which
  today no gate runs.
  Date: 2026-10-05


- Decision (operator, 2026-10-06): the deep tier gates changes to recovery-related code, not
  releases, and must finish within an hour (ADR 25 amendment of 2026-10-06). This plan's own
  acceptance run is the one exception, run once at 7–9 hours on eight shards.
  Rationale: the generated product made exhaustive pairs about 35 process-hours. A release that does
  not touch recovery code learns nothing from repeating them, and an hours-long gate would not be
  run. Plan 179 brings the tier within budget.
  Date: 2026-10-06


- Decision: The model's exit moves include close with take-over (`CloseTakeOver`), and its progress
  check includes the world's live objects (identity, content, readiness).
  Rationale: both are the operator's real exits: `inventory close --take-over`, and a resume
  that recreates a deleted object. Without them the search pruned real exits and reported I1.
  Neither move writes to the world directly, and an exit must still reach an idle head.
  Date: 2026-10-06

- Decision: A Kubernetes create that finds an object not stamped as its member at its address
  settles as `TargetGone`, not `NoEffect` (F66).
  Rationale: `NoEffect` means an unchanged before-state, but the absent before-state changed. In
  the `Deleted`-then-`ForeignObject` schedules the create did land, then was replaced. ADR 26
  defines `TargetGone` as replaced outside review, and ADR 27 §1 names the same class for a live
  object that differs from the record. So the scope keeps its desired revision, and close binds
  nothing.
  Date: 2026-10-06


- Decision (operator, 2026-10-06): the model's checks read a separate, read-only store type, and
  every operator command goes through one retry policy, `operatorAction`. The fast tier
  self-tests the harness on the faults it owns.
  Rationale: five harness gaps had one cause, a checker that shared the faulting store and decided
  retries per call site. A module boundary lets the compiler enforce the separation, and a
  self-test turns the next harness error into a fast-tier failure, not a lost deep shard.
  Date: 2026-10-06


- Decision (operator, 2026-10-06): a planning refusal of a reviewed step that no rule excuses is
  reported as "I1: planning refused (…) with no supported exit". The rules that excuse one are a
  foreign object at a planned address, deleted durable data, retiring a scope that was never
  accepted, and the one replan after a replacement.
  Rationale: ADR 26 requires a supported exit from every stopped state, and a scope whose
  corrective update cannot be planned has none. The self-test found one such refusal, F63's
  open worker-Deployment half under `LandsUnready`. A test pins it as I1 until F63's Deployment
  fix lands.
  Date: 2026-10-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root. The test suite is `nagarectl-test` in
`cli/nagarectl/test`; the recovery model and its worlds are described below. The production Haskell
standard of [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) applies to test
code too.

**The model today.**
- `cli/nagarectl/test/InventoryRecoveryModelSpec.hs` defines scenarios as a list of `Step`s. The
  steps are deploys of an application image, retire, create, update and retire of a standalone
  database, and receipt ingestion, and each scenario has a `Shape` (durable volume, worker).
- `runTier` replays each scenario under every fault placement (`singleFaults`), and under every
  ordered pair (`faultPairs`) when `NAGARE_RECOVERY_MODEL_DEEP=1`.
- After a stop, `searchExit` explores exit moves depth-first by replaying from scratch. After plan 175
  the moves are `Resume` and `Close`.
- **The invariants:**
  - I1: every stop has an exit;
  - I2: nothing unreviewed is converged;
  - I3: incarnations are respected (status, retention, receipt ingestion);
  - I4: no write is repeated within a transaction;
  - I5: the store ends idle with a valid journal chain;
  - I7: status churn alone needs no exit.

**The worlds.**
- `test/Nagare/Test/World/Kubernetes.hs` implements the Kubernetes adapter's provider operations
  (`KubernetesAdapterOps`) in memory.
- `test/Nagare/Test/World/Adversary.hs` schedules faults at the n-th call of a provider operation. The
  faults are `LostAcknowledgement`, `RefusedBeforeEffect`, `LandsUnready`, `LandsFailed`,
  `StatusChurn`, `ForeignManager`, `Interrupt`, `ChurnAlways`, `ForeignObject`, `Replaced`,
  `Deleted`, `TransientReadFailure`, `PutRefused`, `PutLandedUnacknowledged` and `GetFailedOnce`.
- `test/Nagare/Test/World/Store.hs` injects store faults.
- The rename model (`InventoryRenameRecoveryModelSpec.hs`) drives the real `kubectl` runtime over
  the rename world in `InventoryPostgresRenameSpec.hs`.

**Gaps D found that this plan closes for the in-line kinds** (D §1.7, §2.4, §4):
- `LandsFailed` does nothing, because no scenario has a Job.
- A `ForeignObject` anywhere in a schedule masks every planning refusal in it.
- The corrected-review exit is never explored.
- Store faults are swept on one scenario only.
- The deep tier runs in no gate.
- No fault crashes at a store boundary or steals the executor claim.
- Worker Deployments, DomainMappings, CronJobs, Jobs, adoption and collection are not exercised under
  the exit search.

`docs/audits/mp23-held-work/f63-worker-deployment.patch` shows what a hand-added worker scenario
found (nine wedges). The generated product must reach those cells. Plan 175's close rule, not
per-kind fixes, is what must make them pass.

**The release line** (MasterPlan 23, Progress, "Release line (b) and the structural plan") puts these
kinds in scope:
- Kubernetes application scopes: Knative Service, worker Deployment, CronJob tasks, DomainMapping,
  release-history ConfigMap, application databases and attached volumes;
- standalone PostgreSQL and Redis databases, with their backups, receipts, restores and the reviewed
  PostgreSQL rename;
- static sites and previews.

Each is covered for create, update, verify, retire, collect, adopt and migrate.

**Relevant ADRs.**
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) and its
  2026-10-05 amendment are the decision: coverage generated from a kind table, a totality test, and
  no refusal counted as an exit.
- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) gives the universal exit
  (`close`).
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
  defines the identity each row declares.


## Plan of Work

### Milestone 1: the kind table and the totality test

Add `cli/nagarectl/test/Nagare/Test/World/Kinds.hs`. Each `KindRow` declares:
- its executor and Kubernetes group and kind;
- its supported actions, cross-checked against the adapter's allowlist (`Adapters/Kubernetes.hs`,
  `Collection/Adapter.hs` and `Adapters/KubernetesMigration.hs`);
- its readiness: `NoReadiness`, `CanBeUnready` or `CanFail`;
- its atomicity: `Atomic` or `Steps n`;
- its identity: `ProviderUid` or `NameOnly`;
- a fixture function that produces a minimal scope containing that kind;
- its status: `InLine` or `DocumentedLimit reason`.

Add `cli/nagarectl/test/InventoryKindTotalitySpec.hs`. It enumerates every `Executor` constructor
(the type derives `Enum` and `Bounded` in `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs`), and
every action each in-line adapter admits. It fails naming any (executor, kind, action) without a row.
Prove it by deleting one row and watching it fail.

### Milestone 2: the generated product

Derive `applicable :: KindRow -> OperationAction -> Fault -> Bool` from the table. For example,
`LandsUnready` applies only to `CanBeUnready`, and a partial effect only to `Steps n`.

Generate scenarios from each row and action. Each one is a setup review, the action's review, then a
follow-up review: a correction, or a retirement and collection where the kind supports them. Add one
combined scope per in-line application shape (Service, worker, CronJob, DomainMapping, volume,
database), so cross-kind ordering is exercised.

Replace the hand-written `scenarios` list with the generated set. Keep the specific scenarios that
exercise receipt ingestion, the rename and the database update as explicit additions.

Tier the product:
- **Fast tier:** one representative placement per (kind, action, fault), within about two minutes.
- **Deep tier:** every placement and every ordered pair. Add a `just gate-deep` recipe that runs it
  with `NAGARE_RECOVERY_MODEL_DEEP=1`, and register the recipe in `scripts/audit-managed-commands.py`
  (regenerate its catalogue with `--update-catalogue`).

### Milestone 3: the remaining faults and harness fixes

Add the faults:
- `CrashAtStore`: throw `Interrupted` at a store put boundary, before or after the write lands;
- `ClaimLost`: a second client takes the executor claim between two operations;
- `ReplacementRequired`: the provider answers that an update needs replacement.

Make `LandsFailed` live with Job fixtures (backup, restore and prune Jobs). Scope the `ForeignObject`
refusal exemption in `InventoryRecoveryModelSpec.hs` to the step and resource the fault touched. Add
"a corrected review planned from current history" as an exit move.

Run the fast tier. Every new violation is either a gap in plan 175's close obligations (an adapter's
`adapterSettle` answers `Unknown` where it should prove), which goes back to plan 175's owner; a gap
in plan 176's identity accessor; or a new finding recorded in `docs/audits/mp23-findings.md`.


## Concrete Steps

From `cli/nagarectl`:

```bash
cabal build nagarectl-test
cabal test nagarectl-test --test-options='-p "/kind totality/ || /fast tier/"'
```

Expected output names the number of generated cases, for example:

```text
recovery model
  fast tier: every generated (kind, action, fault) case has an exit: OK (… s)
kind totality
  every executor and admitted action has a kind row:                   OK
```

Before each commit, from the repository root: `just gate-fast`, `nix flake check`, and
`git diff --numstat`. Run `just gate-deep` before declaring M2 or M3 accepted.


## Validation and Acceptance

Required acceptance:
- **Totality.** The totality test passes, and fails when any row is deleted.
- **Fast tier.** It passes over the generated product within about two minutes, and its output
  states the case count.
- **Deep tier.** `just gate-deep` passes.
- **Reaches the held cells.** The generated product contains the worker-Deployment cells in the held
  patch, and plan 175's close passes them without per-kind code.
- **Faults are live.** `LandsFailed`, `CrashAtStore` and `ClaimLost` each have an effect in some
  generated case, checked by a test that counts faults that fired.
- **No hidden refusals.** A planning or admission refusal in a generated case is a violation unless
  the case declares it expected.


## Idempotence and Recovery

The kind table and generator are test-only code. Replacing the scenario list is one commit, and
reverting it restores the hand-written model. The deep-tier recipe only reads the repository and runs
tests on the builder.


## Interfaces and Dependencies

This plan depends on
`docs/plans/175-close-stopped-inventory-transactions-by-per-operation-proof.md`, which provides
`close` as the universal exit move and the refusal-is-not-success harness change. It also depends on
`docs/plans/176-record-physical-identity-at-creation-and-read-it-through-one-checked-accessor.md`,
which provides each kind's identity. Start M1 at any time; M2 and M3 need both plans accepted.

It provides `Nagare.Test.World.Kinds` (the kind table), the totality test and the `just gate-deep`
recipe. MasterPlan 23's step 5 verification replays the fast tier, which includes the generated product
with one placement per fault, and every mutation record on the final candidate. Under the ADR 25
amendment of 2026-10-06, it runs the deep tier only if recovery-related code changed after the
deep tier's last passing run.
