---
id: 182
slug: derive-the-recovery-model-s-kubernetes-world-from-validated-api-semantics
title: "Derive the recovery model's Kubernetes world from validated API semantics"
kind: exec-plan
created_at: 2026-10-06T22:01:40Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-06T22:01:40Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T22:09:33Z
      mode: "update"
      note: "Filled the skeleton: fake API server behind the kubectl interpreter, M1-M5, predicted before/after table"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T22:38:00Z
      mode: "update"
      note: "No compatibility with the old world, old pins or earlier journals (operator)"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-07T04:06:18Z
      mode: "implement"
      note: "M1-M4 implemented; F77 ledgered as deferred; before/after classification filled"
---

# Derive the recovery model's Kubernetes world from validated API semantics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [182-derive-the-recovery-model-s-kubernetes-world-from-validated-api-semantics.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/182-derive-the-recovery-model-s-kubernetes-world-from-validated-api-semantics.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare's recovery model (the test suite `recovery model` in
`cli/nagarectl/test/InventoryRecoveryModelSpec.hs`) runs every scenario under injected faults and
checks that every stopped transaction has a supported exit. Its Kubernetes "world" is an in-memory
stand-in for the Kubernetes API server. Today that world decides by itself whether an object is
ready, and it hands the adapter a ready-made verdict. It therefore shares every assumption the
adapter makes, and fault injection can only find code defects, never wrong beliefs about
Kubernetes. Five defects found on 2026-10-06 (F63, F66–F69) all came from such beliefs. The
research record [RES-4](../research/kubernetes-api-semantics-for-inventory-proofs.md) then measured
the real API semantics with 16 experiments on k3s 1.34.6 and Knative 1.22 and found seven more
(G1–G7).

The world also skips the runtime transport entirely, so a transport defect is invisible to the model. F72, found in
EP-180 M5a, is the proof. The production runtime refused every update whose reviewed precondition was NotReady
("unsupported action or precondition"), except for Knative Services. F63's corrective update of an unready
StatefulSet, and EP-180 M1's of a Deployment, therefore could never run in production, yet the model passed.

After this plan, the world behaves the way the experiments showed the real API server and kubectl
behave, and the adapter's **production** code interprets it. Concretely:

- The world becomes a fake API server answering the exact kubectl requests the production runtime
  sends. It renders realistic object JSON: conditions, replica counters, `metadata.generation` only
  where the kind has one, `status.observedGeneration`, Nagare's ownership stamp, and
  `deletionTimestamp`.
- The production runtime builds the requests, maps the answers, waits for readiness and parses the
  objects.
- Each Kubernetes kind's behaviour comes from a table of validated semantics, and a conformance test
  checks the world against traces recorded from a real cluster.
- Every fault a pinned regression schedules must actually change something. A fault that fires but
  does nothing fails the pin; "fired" is not "acted".

How to see it working:

- The fast tier runs on the new world. It reports the known RES-4 defects that are not yet fixed as
  named, counted entries of a known-defect ledger.
- The ledger shrinks as EP-180 and EP-181 fix them. A listed defect that stops occurring fails the
  tier until its entry is removed.
- `cabal test nagarectl-test --test-options "-p '/world conformance/'"` passes.
- Reverting the RES-4 G1 fix (Deployment readiness), once EP-180 lands it, makes the fast tier
  fail with an I2 violation. The world can now catch a false belief.

## Progress

- [x] M1: the validated semantics are data. `KindRow` carries RES-4 §2's columns, and a checked-in
  trace file, recorded from a real cluster by a checked-in script, agrees with them under
  `-p '/kind semantics/'`. Done 2026-10-06:
  - `traces.json` holds 255 steps (k3s v1.34.6+k3s1, kubectl v1.37.0, Knative 1.22.0).
  - The three `kind semantics` tests pass.
  - Changing Deployment's `generationRule` to `SpecOnly` and dropping ResourceQuota's `PodChanges` fails with
    `("apps","deployment") generationRule: the table says SpecOnly, the traces say SpecAndAnnotations` and
    `("","resourcequota") churnSource: the table says NoChurn, the traces say PodChanges`.
- [x] M2: a fake API server behind the production kubectl interpreter, with the adapter composed
  exactly as the CLI composes it, passes `-p '/world conformance/'` against the traces. The recovery
  model is not yet switched. Partial, 2026-10-06:
  - `ApiServer`, `Kubectl` and `Cluster` exist.
  - `world conformance` passes on the third recording (298 steps): every compared aspect, including
    kubectl's refusal lines.
  - Three mutations of the fake server each fail it with a named step: a Deployment that loses
    Available during a broken update (E5), no apply conflicts (E13), no lagging controller (E4).
  - The smoke test (runtime → fake kubectl → fake server → production parser) passes.
  - The branch is rebased onto EP-180 M6 (`fee4d8bc`). The composition moved to
    `Nagare.Inventory.Adapters.KubernetesApplication.kubernetesApplicationAdapter`, which the CLI and
    `Cluster.clusterAdapter` both call.
  - Landed (2026-10-09 reconciliation): `1086911b` and the EP-182 series in `83124396`; `Nagare/Test/World/ApiServer.hs`, `Kubectl.hs` and `Cluster.hs` are in the final candidate.
- [x] M3: faults are re-expressed on the fake server, with `acted` accounting, `ControllerLag`,
  table-driven churn, finalizer-held Terminating, and the stuck StatefulSet rollout. Each fault has
  a test that it acts. Nearly done, 2026-10-06:
  - `Cluster.clusterAnswer` counts boundaries by request and applies every world fault, and the store records
    `acted` for its faults.
  - `world faults` holds 18 tests: each fault acts; LandsUnready, StatusChurn, ChurnAlways (on a Knative
    Service) and ForeignObject (at an occupied address) do not act where they change nothing; and the stuck
    StatefulSet clears only by a pod DELETE.
  - Dropping ForeignObject's acted record, or making ChurnAlways churn nothing, fails the matching test.
  - Done on the EP-180 base: the smoke test now asserts that the production parser does not read a lagging
    controller's stale `Ready=True` as Present. Removing EP-180's observedGeneration check makes it fail.
  - Landed (2026-10-09 reconciliation): `d006edbf`, `290af91c` and `3a032038` in `83124396`.
- [x] M4: the recovery model runs on the new world. The old world is deleted, pinned regressions
  are re-pinned by locator and require their faults to act, and the known-defect ledger is two-sided.
  The before/after classification of every fast-tier change is recorded below with nothing unexplained.
  Nearly done, 2026-10-07:
  - The model runs on the fake API server (`b1a3bbf5`); the old world is deleted. The self-test passes with
    14,567 runs and no violation, and every pin passes with its faults fired and acted.
  - The fast tier finds three violations, all F77. All three are in the two-sided ledger
    (`Nagare/Test/Model/KnownDefects.hs`), and the tier passes (70 s locally).
  - The ledger's own test passes: an unlisted violation, a missing occurrence and an extra occurrence each
    fail.
  - The before/after classification is filled in under Milestone 4.
  - Remaining: the remote run of the committed revision.
  - Landed (2026-10-09 reconciliation): the model runs on the fake API server and the two-sided ledger `Nagare/Test/Model/KnownDefects.hs` is in `83124396`; the remote run is covered by M5.
- [x] M5: acceptance evidence. The fast tier, self-test, conformance and pins are green on the remote
  builder through `just test-remote`, `just gate` passes, and the coordinator lands it.
  - Done (2026-10-09 reconciliation): landed through `just land` (`356e7f18`). The fast tier, self-test, conformance and pins run in `nagarectl-test`, a step of the final candidate's green gate ([gate](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/gate-83124396.json)); the mutation sweep killed 149 of 149. The deep-tier confirmation became monitoring on 2026-10-07.

## Surprises & Discoveries

- Deletion needed its own experiment, E14 (`record-deletions.sh`). The RES-4 runs traced deletion for only five kinds,
  and an allowlist of eleven untraced deletion rules would have defeated M1's purpose. E14 deletes every E1 object
  with Nagare's collection propagation. Every kind is gone within 5 s except a Namespace, which stays Terminating
  even when empty. Its `HeldUntilEmpty` rule is derived from E12 instead.
- A full recording takes about 20 minutes on a 2-CPU, 4 GiB Colima VM, not 10. Most of it is E1's 8-second settles
  across 16 kinds and E10's churn window, which overlaps the later experiments.
- Conformance found real semantics RES-4 had not stated, all now modelled and checked against the traces:
  - A held DELETE moves `generation` along with `deletionTimestamp`, and a controller stops reconciling an
    object being deleted. A Knative Service held by an Orphan delete therefore shows `observedGeneration` behind.
  - A mutating admission plugin's change (a PVC's default StorageClass) is owned by the request's manager, for
    Apply and Update alike. Defaulting (a Namespace's `kubernetes.io/metadata.name` label) is owned only by an
    Update-style create. That is why a repeated identical apply of a PVC moves resourceVersion once, and why
    `kubectl create` of a Namespace leaves a `kubectl-create` entry.
  - A DomainMapping carries Knative's `domainmappings.serving.knative.dev` finalizer from creation, as a
    non-status field of the `controller` manager.
  - `kubernetes.io/pvc-protection` is removed asynchronously, so even an unused PVC is briefly Terminating after
    DELETE.
  - A creating manager's entry keeps owning the map containers it created after a forced apply took every leaf.
  - kubectl's wait timeout names the bare plural (`services/e4`). An apply with several conflicts lists their
    paths on later lines, and one with a single conflict keeps it on the first.
- The first two recordings could not be replayed. Their actions named intents ("stale rv") instead of what was
  sent, and setup steps (a consumer pod, a frozen controller, a namespace's contents) were not recorded. The
  recorder now records each action exactly as sent and records setup as steps. A replay maps real UIDs and
  resourceVersions to its own through the observations at the same steps, so the recorder also observes an
  object right before every DELETE whose preconditions it reads.
- The F69 mutation check first passed when it should have failed. `Cluster.writtenKey` fell back to a request's
  target for every verb, so a plain `get` counted as a write and woke the lagging controller before the parser
  read the stale state. It now covers only write verbs, and the ControllerLag fault test pins that an observation
  leaves the controller frozen.
- kubectl 1.37 warns on every run that it is three minor versions from the 1.34 server (RES-4 G12). The recorded
  answers match RES-4's, so the skew did not change any observed behaviour.
- The first fast-tier runs on the new world found harness defects before any product finding. Each was fixed in
  M4:
  - Kind fixtures were not valid objects: a core Service had no `spec.ports`, and a StatefulSet no selector. That
    produced 13 violations, so the fixtures now carry valid bodies (`0afa551d`).
  - Every PVC was held as if mounted. A claim is now in use only while a running workload's pod template names it.
  - An annotation-only StatefulSet update "landed unready", because a spec's outcome was keyed by the stamp digest.
    It is now tied to the pod template it rolls out (`12876d1b`). That cleared five violations.
  - The ground truth read a StatefulSet's update revision at the wrong path.
- F77, a real finding: a mounted database PVC deleted outside review stays Terminating, and every later review of
  the database refuses at planning, indefinitely. The old world deleted the PVC at once, which leads to the excused
  `durable-resource-missing`. The operator deferred F77 as a documented limit (Decision Log). E16 found the
  runbook's facts on a real cluster:
  - No second pod can mount a Terminating claim, so a backup must go through the running pod.
  - Ending the pod releases the claim within seconds, and its `Delete` volume takes the data with it.
  - Setting the volume to `Retain` first keeps the data, and a recreated claim pinned to the volume mounts it.
- Planning drops the adapter's `ObservationUnavailable` reason (`Plan/Changes.hs`, `observation-unavailable`). So
  the "being deleted" text never reaches the operator, and a runbook pointer there would not be seen. This is
  noted in F77 for the next MasterPlan.
- G3 (P6) is invisible, not absent. A database StatefulSet that lands unready closes, and the corrected review lands
  and stays stuck. No invariant flags a correction that never takes effect: the model has no "a corrected review
  converges" liveness invariant. Raised with the coordinator as a scope question; EP-181 owns the G3 fix.
- `acted` was not exact for two faults, found when nagare-deep-tier-fixes ran the proposed I9 invariant on
  `c37bc231`; 15 violations looked new because of it:
  - LandsFailed was recorded only on a Job, though every controller with a readiness model treats a failed spec as
    not ready.
  - ControllerLag was recorded only when the object already had status, so a lagged create went unrecorded.

  Fixed in M3's code: a lag now acts exactly when the controller would have changed the object after the write.
  Two failing-first `world faults` tests cover the fix, and two mutation records pin it.
- The first mutation sweep (2026-10-07, at `2e8a68bb`) killed 93 of 95 records. Two survived, and both were
  harness gaps:
  - **The world churned before writes.** A ChurnAlways object churned before every request that named it, writes
    included. So a write carrying the resourceVersion it had just observed always conflicted. Under ChurnAlways, a
    ResourceQuota or CronJob update then needed a resume (I7) at most placements. The fast tier places ChurnAlways
    once per generated scenario, so it never reached those placements.
    - EP-180's F30 record survived because every such update failed with or without its guard.
    - Churn now precedes observations only, pinned by a failing-first world rule.
    - With the fix, F30's mutant changes no outcome at any ChurnAlways placement on either churning kind. Since
      G6 (EP-180), the apply's resourceVersion comes from the live guard read, so the refresh it reverts is
      redundant. The record is EP-180's to retire or re-target.
  - **The template-outcome rule was unpinned.** No fast-tier scenario makes a metadata-only update, so
    `G11-outcome-per-write` survived. A world rule test now pins it.
- EP-182's mutation proofs are now records (`G11-*` in `cli/nagarectl/test/mutations/`, 15 of them), swept with
  the others.
- The fast gate's architecture check bounds a module at 1000 lines. `ApiServer.hs` reached 1043 with E15's quantity
  rules, which now live in `Nagare/Test/World/Quantity.hs`.
- Every RES-4 claim reproduced in the second, independent recording: the stale `Ready=True` (E4),
  `Available=True` past the progress deadline (E5), OrderedReady corrections stuck for both a crash loop and a
  Pending pod until the pod is deleted, with Parallel rolling (E6), the 409/422/404 classes (E3), the SSA
  ownership conflicts (E13), and churn only from ResourceQuota and a running CronJob (E10).

## Decision Log

- Decision: the world sits behind the production kubectl interpreter
  (`Nagare.Inventory.KubernetesTransport.withKubectlInterpreter`) as a fake API server, not behind
  `KubernetesAdapterOps`.
  Rationale: behind `KubernetesAdapterOps` the world must build `KubernetesState` itself, which is
  exactly how it came to share the adapter's beliefs. Behind the interpreter, production code does
  request building, the refusal mapping (RES-4 G4), the readiness waits and the parser (G1, G2, G5,
  G7). The effectful collection tests already answer production kubectl argv this way
  (`cli/nagarectl/test/Nagare/Test/Effectful/CollectionModel.hs`). This also satisfies the
  operator's "refusals returned as HTTP classes through the runtime's own mapping" without
  extracting the mapping: the fake returns what kubectl prints for each HTTP class.
  Date: 2026-10-06

- Decision: known RES-4 defects not yet fixed when this plan lands are listed in a two-sided
  known-defect ledger with exact counts. The invariants are not relaxed.
  Rationale: the operator asked that nothing be papered over. A ledger entry names the gap (G1–G7),
  its owning plan, the scenario, the fault and the violation prefix, and states how many times it
  must occur. The tier fails on any unlisted violation and on any count mismatch, so a fix forces
  the entry's removal and a regression cannot hide inside an entry.
  Date: 2026-10-06

- Decision: the conformance test compares by step class. After a write: presence, resourceVersion and generation
  movement, deletion state, the refusal class, non-status writers, and kubectl's first stderr line (UIDs and
  numbers masked). After a settling step (a wait, `rollout status`, `kubectl wait`, an unattended window): also
  conditions, reasons, replica counters, revision equality and pods. What a controller had done "immediately"
  after a write, and a namespace's emptying within a timed 5-second window, are racy in a real cluster and are
  not compared. A refused write must not move resourceVersion in the world. Its recorded movement is compared
  only for kinds without a controller, because a real controller may write status around the refusal.
  Rationale: compare everything that is deterministic in a real cluster and nothing that depends on controller
  speed, so a failure is always a semantic difference.
  Date: 2026-10-06

- Decision: the adapter composition moves from `cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs`
  into a library function, as a pure move, so the CLI and the world use one function.
  Rationale: the test suite cannot import the executable's modules, and a hand copy in the test tree
  would drift from production.
  Date: 2026-10-06

- Decision: no compatibility with today's world, its pinned schedules, or earlier reviews and journals
  (operator, 2026-10-06: Nagare has no deployed users, and this is its first reliable version).
  Rationale: the new world replaces the old one outright. Existing pinned regressions may be rewritten or deleted
  freely, as long as each finding they guard (F63–F69 and the EP-177/EP-179 pins) stays guarded by a pin on the new
  world. The before/after classification in M4 stays: it is the audit that no behaviour change goes unexplained, not
  a compatibility promise.
  Date: 2026-10-06

- Decision: F77 is a documented limit for MP-23 (operator, 2026-10-07, relayed by the coordinator). Its three
  fast-tier violations stay in the known-defect ledger with owner "deferral ledger (operator, 2026-10-07)".
  Its tracker entry is Deferred, and the runbook section is in `docs/runbooks/inventory-operations.md`. The
  reviewed exit is the next MasterPlan's.
  Rationale: the exit needs a new reviewed operation (a backup through the running pod, the release of the
  claim, a rebind), which is beyond EP-182's world-fidelity scope and after MP-23's fidelity freeze.
  Date: 2026-10-07

- Decision: only the fast tier reads the ledger. The deep tier reports every violation.
  Rationale: the ledger's counts are exact for the fast tier's single-fault placements. The deep tier's pairs
  would reach the same defects a different number of times, and a deep run is a confirmation that must show
  them.
  Date: 2026-10-07

## Outcomes & Retrospective

**One mutation record survives at landing: `F30-refresh-before-state-at-write` (EP-180's), retired by EP-180 M9.**
- Once the world churns only before observations, the mutant changes no outcome. Its guard, the refresh of
  `mutationBefore` to the execute-time observation, is redundant since G6: the apply's resourceVersion comes
  from `verifyLiveOwnership`'s fresh read.
- Its earlier kills rested on the old world's churn before writes (Surprises & Discoveries).
- Under the no-tech-debt rule the coordinator decided (2026-10-07) that EP-180 M9 deletes the refresh and
  retires the record. EP-182 lands with exactly this one survivor.

**Deep-tier acceptance: pending MP-23 step 3d (a recorded departure from ADR 25).**
- ADR 25's 2026-10-06 amendment requires a passing `just gate-deep` before accepting a change to the
  recovery model or to adapters. This plan touches the model and the world (`test/Nagare/Test/World/`,
  `test/Nagare/Test/Model/`, `test/InventoryRecoveryModelSpec.hs`) and, through the pure composition
  move, `src/Nagare/Inventory/Adapters/`.
- It lands on `just gate` without a deep run. MP-23's Decision Log entry of 2026-10-06 ("first
  principles, not brute force", approved by the operator) makes the deep tier the confirmation at step
  3d, after EP-180, EP-181 and EP-182. The coordinator applied that entry to this plan on 2026-10-07.
- The deep tier does not read the known-defect ledger. Step 3d's run will therefore report F77's
  violations (deferred), and possibly more of them through fault pairs, as well as anything G3's
  liveness invariant exposes once EP-181 adds it.

