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
- [ ] M2: the generated product. The scenario × applicable-fault × invariant product is generated
  from the table and replaces the hand-written scenario list. The fast tier runs a sampled product
  in the ordinary suite, and the deep tier runs the full product under `just gate-deep`.
- [ ] M3: the faults and harness fixes. The model gains:
  - the `CrashAtStore` and `ClaimLost` faults;
  - a live `LandsFailed` through Job fixtures;
  - a `ForeignObject` exemption scoped to the faulted step;
  - a corrected-review exit move;
  - every in-line action exercised under every applicable fault.

  The fast tier and deep tier pass.


## Surprises & Discoveries

(None yet.)


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
recipe. MasterPlan 23's step 5 verification replays the generated product and every mutation record
on the final candidate.
