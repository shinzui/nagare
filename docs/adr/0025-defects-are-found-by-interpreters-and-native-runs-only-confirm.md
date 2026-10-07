---
title: "Defects are found by interpreters, and native runs only confirm"
status: accepted
date: 2026-10-04
authors: [shinzui]
related:
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md
  - docs/adr/0007-publish-immutable-nix-releases-from-validated-tags.md
  - docs/audits/mp23-engineering-retrospective-2026-10-04.md
  - docs/runbooks/before-a-native-run.md
  - docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md
  - docs/plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md
  - docs/plans/174-gate-every-commit-before-any-native-run.md
---

# ADR 25 — Defects are found by interpreters, and native runs only confirm

## Status

Accepted, 2026-10-04, by operator decision on
[the engineering retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md), after
MasterPlan 23's native verification day.

## Context

[ADR 22](0022-compose-independent-resource-scopes-through-a-typed-inventory.md) routes every provider
action through a narrow adapter interface. In `cli/nagarectl/src/Nagare/Inventory/Adapter.hs`, the
`Adapter` record holds observe, prepare, preflight, execute, verify and recover. Beneath it sit
per-provider operation records such as `KubernetesAdapterOps`, `GcloudRunner` and the store's
`ObjectOps`. One purpose of that design is cheap feedback: the planner, driver, recovery policy and
real adapters can run against in-memory interpreters in seconds.

MasterPlan 23 did not use them that way.
[The 2026-10-04 retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md) classifies all
54 findings:
- 35 were found by native runs (cp3 or cloud).
- 26 of those could have been found by a type check, a fake-adapter test or a model test.
- 8 needed only local real behaviour.
- 1 needed the cloud.

Thirteen findings were the same invariant violation: a reachable transaction state with no supported,
reviewed exit. The application lifecycle produced it seven times, each fixed as a single branch.
Seven release candidates were frozen in two days, and six were made non-final by findings. None of
those six needed the cloud to discover. The in-memory driver model existed, but its fakes only ever
succeeded or recovered, so it could not find this class. No per-commit check had run for 785
commits.

## Decision

1. **Interpreters find defects; native runs confirm.** A cp3 or cloud run is never the first
   execution of a code path. Before any native exercise of an adapter path, an in-memory test drives
   that path through the adversarial provider states:
   - lost acknowledgement;
   - landed but unready, landed and failed;
   - replaced: a new identity at the same address;
   - renamed: an address change inside a transaction;
   - foreign field manager, foreign object;
   - transient read failure, store failure, interruption.

   The expected new information from a native run is limited to whether the interpreters match
   reality.

2. **The stuck-state invariant is a gate.** An invariant model, running the real planner, driver,
   recovery policy and adapters over adversarial provider worlds, must pass in the ordinary test
   suite. It asserts:
   - every reachable stopped transaction has a supported reviewed exit;
   - nothing unreviewed becomes accepted or converged;
   - incarnations are respected;
   - proved effects are not repeated;
   - store and transient faults never wedge the store.

   New adapter paths extend the worlds before they ship.

3. **A native finding is also an interpreter finding.** The fix for a defect found natively lands
   with a regression at the cheapest layer that can express the defect's whole class. The regression
   must fail on the pre-fix source, shown by a recorded mutation or a parent-revision run. The finding
   states which world fault or invariant now covers it, and why the interpreters missed it before. An
   instance-only regression leaves the finding Verifying.

4. **Native runs record fidelity.** Real provider outputs seen on cp3 or cloud become fidelity
   fixtures, parsed by the runtime and compared with the world model. A response the worlds did not
   model yields a fixture and a world change, not only a fix.

5. **Every commit is gated.** Each commit passes:
   - both Haskell suites, the style and architecture checks;
   - exhaustiveness as an error.

   Each push batch and every candidate also passes `nix flake check --all-systems`, with proof that
   every system's builder actually built. These gates run locally, not on a hosted CI service
   (operator decision, 2026-10-04). A candidate cannot be frozen without a green gate record
   for its exact revision.

6. **Fixture workloads are proven to run before a cluster sees them.** A saved review proves that a
   change plans, not that it runs.

7. **Deferral belongs to the operator.**
   - Implementers and reviewers do not propose deferring a finding to save time.
   - A known limitation recorded inside a closed finding counts as a deferral.
   - Every deferral request shows the current deferral ledger.
   - A reachable stuck state with no reviewed exit is not deferred past the next native run.

## Consequences

- **More up-front work in tests.** Some new adapter paths take longer to land because their worlds
  and invariants come first. In exchange, a defect costs a test run instead of a candidate cycle.
- **Smaller native runs.** C2 and C3 become shorter, less frequent confirmation steps, and their
  failures point at interpreter fidelity, which is cheaper to diagnose.
- **The production adapter wiring must be testable.** Today it sits in `app/`, where the suite cannot
  import it, so it moves into the library
  ([EP-173](../plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md)).
- **Release evidence gains a precondition.** [EP-170](../plans/170-size-the-release-gate-to-the-change.md)
  accepts native evidence only with an interpreter-coverage record and a green gate record for the
  candidate.
- **Rules move into tools.** Rules that sessions repeatedly forgot under pressure are enforced by
  tools that refuse ([EP-174](../plans/174-gate-every-commit-before-any-native-run.md)). The prose
  checklist [Before a native run](../runbooks/before-a-native-run.md) covers what a tool cannot check.

## Implementation note (2026-10-05)

Decision 5 is implemented by [EP-174](../plans/174-gate-every-commit-before-any-native-run.md):
- **`just gate-fast`** is enforced on push by `.githooks/pre-push`.
- **`just gate`** writes a revision-bound record. It is green only when a salted probe build passed
  on every remote system and every check of every `release.json` system is realised.
- **`just gate-verify <rev>`** is called by the runbooks before native work.
- **Exhaustiveness** is a compile error in every package's `common` stanza, and the architecture
  check forbids module opt-outs.
- **Decision 6** is `just fixture-smoke`.

The Linux half depends on the remote builder's transport. A gcloud IAP websocket drop killed long
builds, so the builder is reached over the operator's tailnet, with IAP as a fallback. When the
builder fails, the gate records RED; it never reports a false green.

## Amendment (2026-10-05): coverage is generated, and reviews verify against a line

Accepted by the operator as decisions D3 and D6 of [the exhaustive review's proposal](../audits/mp23-exhaustive-review-2026-10-05/PROPOSAL.md).
Seven review rounds on MasterPlan 23 found about ten defects a day without converging. Each round
found the next instance of a class, because model coverage was sampled: 17% of reachable fault
cells, all on Kubernetes ([D](../audits/mp23-exhaustive-review-2026-10-05/D-model-coverage.md)).

- **Coverage is generated from a kind table.**
  - Each resource kind declares its world behaviour in one test-harness table: actions, readiness,
    single- or multi-step writes, identity, fixture.
  - The scenario × applicable-fault × invariant product is generated from that table.
  - A totality test fails when an executor or an admitted action has no row.
  - A new kind or adapter ships with its row.
- **The harness may not hide refusals.** An admission or planning refusal is never counted as a
  successful exit. Every fault kind must have an effect in some world.
- **Reviews verify against a declared release line; they do not sample for new instances.**
  - Findings outside the line become documented limits on the ledger.
  - Open-ended review rounds are not run while the model-plus-gate loop is the discovery mechanism.


## Amendment (2026-10-06): the deep tier is change-scoped and bounded

Decided by the operator on 2026-10-06, after the first full deep-tier run of the generated
product. That run has about 1.4 million ordered fault pairs, so a single process needs about 35
hours and eight shards need 7–9 hours.

- **Every commit and every release run the fast tier.** `just gate-fast` replays every single
  fault at every boundary, with every mutation record; this is the release gate. A release does
  not run the deep tier.
- **The deep tier gates changes to recovery-related code.** A change needs a passing `just
  gate-deep` before it is accepted when it touches any of these paths, all under
  `cli/nagarectl/`:
  - `src/Nagare/Inventory/Execute/` and `src/Nagare/Inventory/Execute.hs` (admission, driver,
    recovery, close, claims, journal, transactions, fenced recovery);
  - `src/Nagare/Inventory/Journal.hs`, `src/Nagare/Inventory/OperationStep.hs`, and the store
    (`src/Nagare/Inventory/Store.hs`, `src/Nagare/Inventory/Store/`);
  - `src/Nagare/Inventory/Plan/CloseRecord.hs` and `src/Nagare/Inventory/Identity.hs`;
  - an adapter's recovery or settlement: `src/Nagare/Inventory/Adapter.hs`,
    `src/Nagare/Inventory/Adapters/`, `src/Nagare/Inventory/Collection/`, and the data-fence,
    live-restore and maintenance adapters;
  - the model itself: `test/InventoryRecoveryModelSpec.hs`, `test/Nagare/Test/World/`,
    `test/Nagare/Test/Model/`.

  A release built on such a change carries the deep-tier result of that change; it does not
  repeat it.
- **The deep tier has a time budget.** It must finish within one hour on the operator's
  workstation with its default shards. Taking hours is acceptable only for something
  extraordinary, and the reason must be recorded in the change's plan.
  [Plan 179](../plans/179-bring-the-recovery-model-deep-tier-within-an-hour.md)
  brings the tier within budget without weakening what it proves. Until it lands, the tier is
  over budget, and a change that needs it records its run time.

## Amendment (2026-10-07): the model's world is derived from validated semantics

Decided by the operator on 2026-10-06, when MasterPlan 23 step 3 was redirected to first principles
([RES-4](../research/kubernetes-api-semantics-for-inventory-proofs.md)), and implemented by
[Plan 182](../plans/182-derive-the-recovery-model-s-kubernetes-world-from-validated-api-semantics.md).
The earlier Kubernetes world built the adapter's view of an object itself, so it shared the adapter's
beliefs. Defects in those beliefs (stale readiness, refusal classes, terminating objects) passed the
model and were found only by analysis.

- **The world is a fake API server behind the production interpreter.**
  - The model runs the adapter that the CLI composes (`kubernetesApplicationAdapter`) against a pure
    API server (`test/Nagare/Test/World/ApiServer.hs`), through the production kubectl interpreter.
  - Production code builds every request, maps every refusal and parses every object. The world
    answers as a real server would; it never tells the adapter an object's state.
- **Its behaviour is data checked against a real cluster.**
  - Each in-line kind's semantics are columns of the kind table (`KindSemantics`): generation,
    observedGeneration, readiness model, churn source and deletion rule.
  - A checked-in script (`docs/audits/k8s-semantics-2026-10-06/experiments/record-traces.sh`)
    records traces from a real k3s and Knative. Two tests fail when the table or the fake server
    disagrees with the traces: `kind semantics` and `world conformance`.
  - **Re-run the recorder on any change of the k3s, kubectl or Knative version, or of the in-line
    kinds,** and commit the new traces with the change.
  - Behaviour the traces do not cover is added by a new recorded experiment, not by assumption.
- **A fault counts only when it acted.** A pinned regression requires every scheduled fault to have
  fired and changed the world or its caller's answer. Every fault kind has a test that it acts.
- **Known defects are a two-sided ledger, never a relaxed invariant.**
  - A violation whose defect is known, owned and unfixed is listed in
    `test/Nagare/Test/Model/KnownDefects.hs`. Each entry names its gap, owner, scenario, fault,
    violation and exact count.
  - The fast tier fails on an unlisted violation and on a changed count.
  - A deferred defect's owner is the deferral ledger, with the operator's decision date.
- **A world change is classified.** A change to the world's fidelity records, for every fast-tier
  outcome it changes, the cause: a validated rule, a ledger entry, or a harness defect it fixed.
