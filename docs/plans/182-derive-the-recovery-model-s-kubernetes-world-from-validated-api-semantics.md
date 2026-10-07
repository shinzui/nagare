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
---

# Derive the recovery model's Kubernetes world from validated API semantics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


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
- [ ] M2: a fake API server behind the production kubectl interpreter, with the adapter composed
  exactly as the CLI composes it, passes `-p '/world conformance/'` against the traces. The recovery
  model is not yet switched. Partial, 2026-10-06:
  - `ApiServer`, `Kubectl` and `Cluster` exist.
  - `world conformance` passes on the third recording (298 steps): every compared aspect, including
    kubectl's refusal lines.
  - Three mutations of the fake server each fail it with a named step: a Deployment that loses
    Available during a broken update (E5), no apply conflicts (E13), no lagging controller (E4).
  - The smoke test (runtime → fake kubectl → fake server → production parser) passes.
  - Remaining: the `src/` composition move, timed after EP-180 M5b; `Cluster.clusterAdapter` composes
    the production functions directly until then.
- [ ] M3: faults are re-expressed on the fake server, with `acted` accounting, `ControllerLag`,
  table-driven churn, finalizer-held Terminating, and the stuck StatefulSet rollout. Each fault has
  a test that it acts. Nearly done, 2026-10-06:
  - `Cluster.clusterAnswer` counts boundaries by request and applies every world fault, and the store records
    `acted` for its faults.
  - `world faults` holds 18 tests: each fault acts; LandsUnready, StatusChurn, ChurnAlways (on a Knative
    Service) and ForeignObject (at an occupied address) do not act where they change nothing; and the stuck
    StatefulSet clears only by a pod DELETE.
  - Dropping ForeignObject's acted record, or making ChurnAlways churn nothing, fails the matching test.
  - Remaining: the parser-side test "a lagging controller's stale Ready is not accepted". It asserts EP-180's F69
    fix, so it is written after rebasing onto EP-180.
- [ ] M4: the recovery model runs on the new world. The old world is deleted, pinned regressions
  are re-pinned by locator and require their faults to act, and the known-defect ledger is two-sided.
  The before/after classification of every fast-tier change is recorded below with nothing unexplained.
- [ ] M5: acceptance evidence. The fast tier, self-test, conformance and pins are green on the remote
  builder through `just test-remote`, `just gate` passes, and the coordinator lands it.


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
- kubectl 1.37 warns on every run that it is three minor versions from the 1.34 server (RES-4 G12). The recorded
  answers match RES-4's, so the skew did not change any observed behaviour.
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


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**Terms.**

- *Inventory transaction*: one applied review: an ordered set of operations (create, update, retire,
  verify, adopt) on managed resources, journalled in Nagare's store.
- *Adapter*: the code that executes and proves one executor's operations; the Kubernetes adapter is
  `cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs`.
- *Runtime*: the adapter's transport, `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`.
  It turns operations into `kubectl` requests and parses kubectl's JSON output into `KubernetesState`
  in `parseObservedWithConfiguration`, whose readiness predicates are `knativeReady`,
  `deploymentAvailable`, `statefulSetReady` and `jobCompleted`.
- *Settle*: ADR 26's per-operation classification of an interrupted operation (NoEffect, Landed,
  TargetGone, TerminalPartial, Unknown).
- *Recovery model*: the test that drives scenarios under fault schedules and checks invariants I1–I8.
  The ones that matter here:
  - I1: every stop has a supported exit;
  - I2: a scope reported converged is the reviewed, Ready object;
  - I3: identity is never laundered;
  - I4: no operation writes twice;
  - I7: persistent churn needs no repeated exits;
  - I8: every operation with intent settles to a proof class.
- *Fast tier*: the model's default test, every single fault at every boundary of the explicit
  scenarios and one placement per fault for the generated ones.
- *Deep tier*: every interacting fault pair, run only on request.
- *Boundary*: the n-th call of one provider operation (`MutateCall`, `ObserveCall`, `StorePutCall`,
  `StoreGetCall`), where a scheduled fault fires.
- *Pinned regression*: a test that fixes one schedule to guard one finding.
- *Stamp*: the annotations `nagare.dev/context-id`, `nagare.dev/resource-id` and
  `nagare.dev/spec-digest` that Nagare writes on every object it owns. RES-4 U3 established that the
  stamp lands in the same atomic write as the spec.

**Where the code is.** All paths are under `cli/nagarectl/test/` unless absolute; the state described
is EP-179's tree, which this plan starts from.

- `Nagare/Test/World/Kubernetes.hs` is the current world. `KubeObject` holds an abstract `readiness`
  field, `stateOf` builds `KubernetesPresent`/`KubernetesNotReady`/`KubernetesFailed` directly, and
  `mutate` reimplements the conditional write. A failed precondition returns `KnownNoEffect`, while
  the real runtime maps any non-zero kubectl exit to `AdapterEffectAmbiguous` (RES-4 G4). Every write
  bumps `generation`; `liveObject` renders `observedGeneration == generation` always and a `Ready`
  condition plus `readyReplicas` for every kind.
- `Nagare/Test/World/Kinds.hs` holds `kindTable`, one `KindRow` per resource kind with actions,
  readiness, atomicity, identity and status (in line or a documented limit). `kindFixture` gives each
  in-line kind a minimal manifest.
- `Nagare/Test/World/Adversary.hs` holds the faults, their boundaries and their persistence. It
  records which faults *fired*, not whether they changed anything.
- `Nagare/Test/Model/Run.hs` holds the run state and EP-179's snapshot and restore.
  `Model/Scenarios.hs` holds the explicit and generated scenarios. `Model/Tier.hs`, `Model/Pairs.hs`
  and `Model/Search.hs` hold the tiers and the exit search. `InventoryRecoveryModelSpec.hs` holds
  the invariants and the pinned regressions, which name raw ordinals such as
  `Boundary ObserveCall 7, Deleted`.
- `cli/nagarectl/src/Nagare/Inventory/KubernetesTransport.hs` defines `KubectlRequest`
  (context, argv, stdin), `KubectlResult = Either Text (ExitCode, String, String)`, and
  `withKubectlInterpreter`. The latter makes a `KubernetesRuntimeConfig` send every kubectl call to a
  handler instead of a process.
- `cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs`, `inventoryKubernetesAdapterWith`, composes
  the production application adapter. It combines `mkKubernetesRuntimeOpsAndBatchWithCacheKey`,
  `observeKubernetesConfiguration`, `readBackupReceiptFromCompletedPod`, `restoreScratchPodFailed`
  and `readLiveManagedObject` with `mkKubernetesAdapterWithConfigurationObservation`.
- `docs/audits/k8s-semantics-2026-10-06/` holds RES-4's experiment scripts (`experiments/*.sh`,
  run against a disposable k3d cluster with `KUBECONFIG` set) and their results.

**The semantics to encode** (RES-4 §1–2, each validated by the named experiment):

- **resourceVersion:** it moves on every persisted write, including status and metadata, and never
  on a no-op server-side apply.
- **Generation by kind:**
  - absent on ConfigMap, Secret, ServiceAccount, Role, RoleBinding, Service, PersistentVolumeClaim,
    Namespace and ResourceQuota;
  - moves on spec writes for NetworkPolicy, StatefulSet, CronJob, Job, Knative Service and
    DomainMapping;
  - moves on spec writes **and annotation writes** for Deployment.
- **observedGeneration:** present on Deployment, StatefulSet, Knative Service and DomainMapping;
  absent on CronJob and Job.
- **Knative Service:** keeps a stale `Ready=True` while `observedGeneration < generation`, then goes
  `Unknown`, then `True` or `False/RevisionFailed`.
- **Deployment, broken update:** keeps `Available=True` from the old ReplicaSet and ends at
  `Progressing=False/ProgressDeadlineExceeded`.
- **StatefulSet:** OrderedReady with RollingUpdate never replaces a pod that is not Ready (crash
  loop or Pending) after a template change, until that pod is deleted.
- **Steady-state churn:** CronJob status moves every schedule tick and ResourceQuota status moves on
  every pod change. Knative Service, Deployment, StatefulSet and config objects do not churn at
  steady state.
- **Refusals:** every 4xx refusal (409 AlreadyExists or Conflict, 422 Invalid, 404) leaves the
  object unchanged. A server-side apply with a UID precondition on an absent object is refused
  with 409.
- **Deletion:** a DELETE of an object with finalizers returns 200 and leaves it Terminating with the
  same UID and a new resourceVersion. That holds for a PVC in use, a Knative Service deleted with
  `Orphan`, and a Namespace.
- **Quantities:** the server canonicalizes them (`1024Mi`→`1Gi`), including through Knative.
- **kubectl:** `wait --for=condition` is generation-aware, and `rollout status` applies the full
  rollout rule.

**ADRs.**

- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): defects are
  found by effect interpreters, and native runs only confirm. Its amendment makes the kind table the
  source of model coverage. This plan makes the interpreter faithful, which ADR 25 depends on.
- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) defines the settle
  classes and the close decision the model's exits use.
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
  makes the UID returned by a write the recorded identity; the fake server must return it on every
  write, as `kubectl ... -o json` does.

No ADR yet records "the world is derived from validated semantics"; M4's distillation adds that as
an ADR 25 amendment.

**Sibling plans.** [EP-179](179-bring-the-recovery-model-deep-tier-within-an-hour.md) (hard
dependency) changes `Model/Run.hs`, the world snapshot and the search; it must be on master before
M2's code starts. [EP-180](180-derive-the-kubernetes-adapter-s-proof-rules-from-validated-api-semantics.md)
fixes the adapter (G1, G2, G4–G7, F67's stamp proof, F68). It edits `src/`, while this plan edits
`test/Nagare/Test/World/*` (owned by this plan from 2026-10-06), the model's pinned regressions and
the one composition move. [EP-181](181-replace-a-stuck-statefulset-pod-through-a-reviewed-operation.md)
adds the stuck-pod operation; the fake server's pod DELETE (M3) is what it executes against.


## Plan of Work

### Milestone 1: the validated semantics as data

`KindRow` in `Nagare/Test/World/Kinds.hs` gains a `semantics :: KindSemantics` field. Its parts:

- `generationRule`: `NoGeneration`, `SpecOnly` or `SpecAndAnnotations`;
- `observedGeneration :: Bool` and `statusSubresource :: Bool`;
- `readinessModel`: `NoReadinessModel`, `KnativeConditions`, `DeploymentRollout`,
  `StatefulSetRollout` or `JobTerminal`;
- `churn`: `NoChurn`, `ScheduleTicks` or `PodChanges`;
- `deletion`: `Immediate`, `HeldWhileInUse`, `OrphanBlocked` or `HeldUntilEmpty`.

Every in-line row is filled from RES-4 §2. The existing `readiness` field stays and must agree with
`readinessModel` (a test checks it). Platform rows (CRD, Certificate, ClusterIssuer) get
`semantics = Nothing`, because they are documented limits.

A recorder script, `docs/audits/k8s-semantics-2026-10-06/experiments/record-traces.sh`, replays
the E1, E3, E4, E5, E6, E7, E11, E12 and E13 steps against a disposable k3d cluster. It emits
`cli/nagarectl/test/fixtures/kubernetes-semantics/traces.json`, one entry per step:

```json
{"experiment":"E1","kind":"apps/deployment","step":"annotate",
 "generationPresent":true,"generationDelta":1,"resourceVersionMoved":true,
 "observedGenerationEqualsGeneration":true,
 "conditions":{"Available":"True","Progressing":"True"},
 "counters":{"replicas":1,"updatedReplicas":1,"readyReplicas":1,"availableReplicas":1},
 "deletionTimestamp":false,"finalizers":[],"http":null}
```

Refusal steps carry `"http": {"status": 409, "reason": "Conflict", "stderrPrefix":
"Error from server (Conflict)"}`, with the exact first stderr line kubectl printed.

Run the recorder once and check its output in. The cluster rules are those of RES-4: k3s
`rancher/k3s:v1.34.6-k3s1`, the vendored Knative 1.22, one server, no agents. Run it in a Colima
profile with no other k3d clusters (starting Colima restarts every cluster in its profile). Delete
the cluster afterwards.

A test, `kind semantics: the table agrees with the recorded traces`, derives each in-line row's
columns from the traces and compares them with `kindTable`. It checks generation presence and rule,
observedGeneration presence, status subresource (from E0's discovery list, recorded in the same
file), churn (E10) and deletion (E7/E12).

Acceptance: the test passes, and editing one column of one row (for example Deployment to
`SpecOnly`) makes it fail with a message naming the kind, the column and the trace step.

### Milestone 2: a fake API server behind the production interpreter

First a pure move with no behaviour change: `inventoryKubernetesAdapterWith`'s composition becomes a
library function, `kubernetesApplicationAdapter :: Bool -> KubernetesRuntimeConfig ->
(ResourceId -> IO (Either Text Text)) -> Map ResourceId (ManagedResource, ByteString) -> Adapter`,
in a new module `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesApplication.hs`. The CLI
calls it after its context checks. Register the module in `cli/nagarectl/nagarectl.cabal`. Because
this touches `src/`, coordinate the commit with EP-180's owner through the coordinator.

Then two new test modules:

- `Nagare/Test/World/ApiServer.hs` is pure. It holds stored objects as JSON values plus server
  metadata and per-kind controller state:
  - a Deployment's old and new ReplicaSet availability;
  - a StatefulSet's pod revision and pod readiness;
  - a Knative Service's revision readiness and latest-ready revision;
  - a Job's outcome.

  Its operations reproduce the semantics list:
  - `create`, refused with 409 AlreadyExists;
  - `applyServerSide` with UID and resourceVersion preconditions, including the
    rv-only-creates-when-absent rule of RES-4 U5;
  - `patchJson` with `test` operations, refused with 422;
  - `delete` with preconditions and propagation, finalizer-aware;
  - `get`, which renders the object and its managedFields;
  - `controllerStep`, which advances status per the kind's `readinessModel` and moves
    resourceVersion when status changes;
  - `externalWrite`, for faults.

  It also keeps per-field `managedFields` with RES-4 U10's server-side-apply rules (E13):
  - `create` records its manager as an Update;
  - an apply records Apply, and a forced apply moves only the fields whose value it changes;
  - a no-force apply that changes a field another entry owns is refused with 409 and kubectl's
    "Apply failed with N conflicts" text;
  - a foreign Update that changes a field takes ownership of it (a write that changes nothing changes no ownership; untested, modelled as the API documents);
  - status writes use status-subresource entries;
  - an apply ignores `resourceVersion: "0"`.

  Generation and resourceVersion follow `KindSemantics` and the rules above. Quantities are
  canonicalized on write by a function with its own unit tests from E11's pairs. Every write returns
  the object, so the runtime's `identified` records the UID (ADR 27).
- `Nagare/Test/World/Kubectl.hs` provides `worldKubectl :: IORef KubeWorld -> IORef Adversary ->
  KubectlRequest -> IO KubectlResult`. It parses the argv shapes the production runtime emits:
  - `get <kind> <name> [-n ns] -o json --ignore-not-found [--show-managed-fields]`;
  - `create --field-manager=nagare-inventory -f - -o json`;
  - `apply --server-side --force-conflicts --field-manager=nagare-inventory -f - -o json`;
  - `patch <kind> <name> --type=json ...`;
  - `delete --raw <path> -f -`;
  - `wait --for=condition=<c> <kind>/<name> --timeout=...`, and `wait --for=delete ...`;
  - `rollout status <kind>/<name> --timeout=...`.

  It answers each with the exit code and the stdout or stderr kubectl prints, using the recorded
  `stderrPrefix` lines for refusals. `wait` succeeds only when the condition holds at
  `observedGeneration == generation`; otherwise it returns kubectl's timeout error at once (virtual
  time). `rollout status` applies the rollout rule. An argv outside this grammar is a harness error
  (`assertFailure` naming the argv), never a provider answer.

`worldKubernetesAdapter` in `Nagare/Test/World/Kubernetes.hs` gets a new implementation. The old one
stays only as scaffolding until M4, so M2 and M3 can be tested before the model switches; nothing depends on it. It builds `withKubectlInterpreter (runKubectlWith (worldKubectl world
adversary))` over a `KubernetesRuntimeConfig` whose guard always passes, and calls
`kubernetesApplicationAdapter False` with it. It wraps only the ops' `kubernetesMutateConditional`,
to record which reviewed operation is in flight so I4 can attribute writes. Because the
composition is production's, the backup-receipt reader (`readBackupReceiptFromCompletedPod`) and
the restore-scratch probe (`restoreScratchPodFailed`) also send kubectl requests. The fake answers
their pod-list `get` with the pods it models: none, so no receipt and no failed scratch pod, which
matches today's stubs. The grammar lists these requests explicitly.

A conformance test, `world conformance: the fake API server reproduces the recorded traces`, replays
every trace step against `ApiServer` (and, for the kubectl-shaped steps, through `worldKubectl`) and
compares the same abstraction the recorder emitted. It needs no adapter.

Acceptance:

- the conformance test passes;
- the composition move leaves the existing CLI test suite green;
- a smoke test drives the new world adapter through one Knative Service create, a good update and a
  bad update, and asserts the production parser's `KubernetesState` at each step: Present, Present,
  then NotReady once the controller has observed the bad generation, and Present with stale
  readiness before it does.

### Milestone 3: faults on the fake server, and "acted"

`Adversary` gains `acted :: [(Boundary, Fault)]` and `noteActed :: IORef Adversary -> Boundary ->
Fault -> IO ()`. A fault counts as acted only when it changed the world's state or the answer the
caller received. Boundaries are counted by request class: `ObserveCall` for every `get` of a member
object, `MutateCall` for every write request (create, apply, patch, delete).

Each existing fault is re-expressed on the fake server, with its acted condition:

| Fault | Effect on the fake server | Acts when |
| --- | --- | --- |
| `LostAcknowledgement` | the write applies; kubectl exits non-zero with a transport error | the request reached the server |
| `RefusedBeforeEffect` | an admission refusal (`Error from server (Forbidden)`) | always |
| `LandsUnready` / `LandsFailed` | the written spec's controller outcome is bad | the kind's `readinessModel` is not `NoReadinessModel` |
| `StatusChurn` | `controllerStep` writes status just before the write | the object exists and the kind has a status subresource |
| `ForeignManager` | another manager owns a reviewed field | the object exists |
| `Interrupt` | throws after the write applies | a write applied |
| `ChurnAlways` | from this observation on, the kind's `churn` source writes status before each observation | an object whose kind churns exists |
| `ForeignObject` | an unstamped object at an empty address | the address was empty |
| `Replaced` | a delete and recreate with the same stamp and a new UID | the object existed with this member's stamp |
| `Deleted` | a background DELETE as `kubectl delete` sends it; a finalizer-held object becomes Terminating | the object existed |
| `TransientReadFailure` | `get` exits non-zero with `Unable to connect to the server` | always |

Store faults are unchanged and act when they fire, as today. Knative Services no longer churn
persistently: RES-4 E4 and E10 saw none at steady state.

One new fault, `ControllerLag` (persistent, at `MutateCall`): after this write, the object's
controller does not observe the new generation until the next write to the same object. Status,
including a stale `Ready=True`, stays at the old generation. It acts when the kind has
`observedGeneration` and had a status before the write. It gives F69 (G2) its model test.

Three rules are built into the server, not scheduled as faults:

- a finalizer-held DELETE leaves the object Terminating: a PVC whose consuming workload exists, a
  Knative Service deleted with `Orphan`;
- once a StatefulSet's pod is at a revision whose spec is unready, later template changes do not
  replace it until a pod DELETE (`delete --raw /api/v1/namespaces/<ns>/pods/<name>-0`, with UID and
  resourceVersion preconditions) removes it, which EP-181's operation will send;
- the controller performs one status write after every spec write of a kind with a controller.

A ground-truth function, `groundTruth :: KubeWorld -> ResourceId -> Maybe (PhysicalIdentity,
ContentDigest, Readiness)`, is computed from the controller state, never from the parser. It replaces
the model's reads of `readiness object'` and `nativeDigest object'` for I2 and progress detection.

Acceptance: a test per fault, `fault acts: <name>`, schedules it where it must act and asserts
`acted`. A second test, `fault does not act: ForeignObject on an occupied address`, shows the
negative case. Plus `ControllerLag keeps a stale Ready that the production parser accepts`: it
documents G2 against the current parser and flips when EP-180's F69 fix lands. And
`a StatefulSet correction stays stuck until its pod is deleted`.

### Milestone 4: switch the recovery model, re-pin, and the ledger

The model uses the new `worldKubernetesAdapter`; the old world code is deleted. `RunSnapshot`
already copies `KubeWorld` wholesale; it stays pure data with no `IORef` inside, so EP-179's
snapshot test keeps passing.

Pinned regressions stop naming raw ordinals. They are rewritten for the new world, with no attempt to keep
their old schedules: each finding a pin guards today must still be guarded, and a pin whose finding the new world
makes unreachable is deleted, with the reason recorded in Surprises & Discoveries. The world logs every request with its boundary. A
helper, `boundaryOf :: Scenario -> (LoggedRequest -> Bool) -> Int -> IO Boundary`, finds the n-th
matching request in the fault-free run, for example "the first `get` of the Knative Service after
its first write". A second helper, `pinned :: Scenario -> Schedule -> IO Finished`, fails unless
every scheduled fault fired **and** acted. Every test in `InventoryRecoveryModelSpec.hs` that names a
`Boundary` uses both. The tier reports, per scenario, the placements whose fault never acted. A test,
`every fault acts in at least one fast-tier placement`, fails if a whole fault never acts anywhere.

Add one explicit scenario for G7: "create a database whose memory request is written
non-canonically (`1024Mi`)", using the database fixture with that value.

Add `Nagare/Test/Model/KnownDefects.hs` with `knownViolations :: [KnownViolation]`. Each entry
names the gap, the owning plan, the scenario label, the fault, the violation prefix and the exact
expected count, for example `KnownViolation "G1" "EP-180" "kind (\"apps\",\"deployment\"): update"
LandsUnready "I2: scope reported converged" 1`. The fast tier fails on any violation not matched by
an entry and on any entry whose observed count differs, with the message "fixed or changed: update
or remove this entry". The existing test "an unexcused planning refusal … F63's open Deployment
half" is rewritten against the new world's actual outcome and folded into the ledger.

Then run the fast tier on the starting master (baseline) and on this milestone, and fill the
**before/after classification** below. Every changed outcome (a violation that appeared, disappeared
or changed class, or a pinned exit list that changed) must have one of three causes:

- a RES-4 rule (fidelity), naming the rule;
- a ledger entry, naming the G-id;
- a harness defect, fixed in this milestone.

An unexplained change blocks acceptance. Predicted changes, to be confirmed or corrected when the
classification is filled in:

| # | Scenarios × fault | Before (old world) | Predicted after | Cause |
| --- | --- | --- | --- | --- |
| P1 | Knative-only scenarios × `ChurnAlways` | persistent Knative churn, absorbed by the version-2 update | the fault does not act (reported) | fidelity: no steady-state Knative churn (E4, E10) |
| P2 | generated `cronjob` and `resourcequota` update × `ChurnAlways` | no churn | the update is refused at every attempt; I7 or I1 | G6 (EP-180), unless already fixed |
| P3 | worker shape and generated `deployment` update × `LandsUnready` | NotReady; F63 worker half, I1 planning refused | the old ReplicaSet stays Available, the parser proves completion: I2 | G1 (EP-180), unless already fixed |
| P4 | every Knative and Deployment update × `ControllerLag` (new) | not exercised | the stale Ready is accepted; I2 | G2 (EP-180), unless already fixed |
| P5 | every scenario × `StatusChurn` at the write | `KnownNoEffect` | 409 → ambiguous → settle sees a moved rv → Unknown: I8 or I1 | G4 (EP-180), unless already fixed |
| P6 | database update × `LandsUnready`, then the corrected update | the correction becomes Ready | the correction lands and stays stuck: an I1/I2-class violation (exact one recorded) | G3 (EP-181) |
| P7 | volume shape × `Deleted` on the PVC | the PVC vanishes; the F64 path | the PVC is Terminating and the parser says Present: I2 or I3 | G5 (EP-180), unless already fixed |
| P8 | explicit G7 scenario (new) | not exercised | perpetual drift; the update never verifies: I1 | G7 (EP-180), unless already fixed |
| P9 | every scenario | `generation` on every kind; `observedGeneration == generation` always | absent on nine kinds; it lags only under `ControllerLag` | fidelity, no outcome change expected |
| P10 | every pinned regression | raw ordinals | locator-based pins requiring "acted" | harness, no outcome change expected |
| P11 | every scenario | boundary counts | more `ObserveCall`s, because the production runtime issues extra `get`s (ownership check, stable observation, live-object reader) | fidelity of the boundary count; ordinals shift |

Acceptance: the fast tier passes on the new world, with every remaining violation in the two-sided
ledger. The classification table is filled from the actual output. Each pinned regression passes
and its faults act. The `fault acts` and coverage tests pass. The deleted old world leaves no
references (`grep -rn "stateOf\|unreadyDigests" cli/nagarectl/test` finds nothing).

### Milestone 5: acceptance runs and landing

Commit, then run the model's tests on the remote builder (never on the Mac). Run `just gate` on a
clean checkout and send the revision to the coordinator, who runs `just land`. A deep-tier run is
not part of this plan's acceptance (MP-23 step 3d owns it). Running one needs the coordinator's
approval first. Afterwards:

- add the ADR 25 amendment: the world is derived from validated semantics, and the trace recorder is
  re-run on any k3s or Knative version change;
- mark MP-23 step 3c;
- delete the superseded branch `k8s-semantics-first-principles`.


## Concrete Steps

All commands run from the repository root of this plan's worktree unless stated. `$SCRATCH` is
any scratch directory outside the repository (the session scratchpad).

Start from master after EP-179 lands, in a new worktree:

```bash
git fetch origin master
git worktree add -b ep182-world "$SCRATCH/ep182-world" origin/master
cd "$SCRATCH/ep182-world"
```

M1, record the traces (minutes; one small cluster, torn down afterwards):

```bash
colima start default --cpu 2 --memory 4
k3d cluster list   # stop any other cluster this profile restarted: k3d cluster stop <name>
k3d cluster create ep182-traces --image rancher/k3s:v1.34.6-k3s1 --servers 1 --agents 0 --no-lb \
  --k3s-arg '--disable=traefik@server:0' --k3s-arg '--disable=metrics-server@server:0' \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait
export KUBECONFIG="$SCRATCH/ep182-traces.kubeconfig"; k3d kubeconfig get ep182-traces > "$KUBECONFIG"
docs/audits/k8s-semantics-2026-10-06/experiments/record-traces.sh \
  > cli/nagarectl/test/fixtures/kubernetes-semantics/traces.json
k3d cluster delete ep182-traces; colima stop default
```

The recorder installs Knative from `cluster/bootstrap/vendor/` itself; apply `serving-core` twice,
because its caching `Image` object needs the CRD established first.

Focused checks while developing (small, local):

```bash
cabal build nagarectl-test --project-dir=cli/nagarectl -v0
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options "-p '/kind semantics/'"
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options "-p '/world conformance/'"
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options "-p '/fault acts/'"
```

Expected conformance output:

```text
world conformance: the fake API server reproduces the recorded traces: OK
```

Model runs go to the remote builder from a committed revision:

```bash
just test-remote HEAD '/recovery model/'
```

The last lines show one status line per shard and end with `exit=0`. For the baseline, run the same
command on the starting master revision and keep both logs: their `recovery-model:` lines are the
before and after sides of the classification.

Before handing off for landing:

```bash
just gate-fast        # every Haskell commit
just gate             # the candidate, on a clean checkout
```


## Validation and Acceptance

The plan is accepted when all of the following hold on the remote builder for the landed revision:

- the fast tier passes, with every remaining violation matched by a ledger entry and its exact count;
- the harness self-test, the EP-179 snapshot tests, the pinned regressions (each with its faults
  acted), `kind semantics`, `world conformance` and every `fault acts` test pass;
- the before/after classification has no unexplained row.

To prove the world now catches a false belief, as a recorded mutation run (a diff under
`cli/nagarectl/test/mutations/`, listed in its README):

- with EP-180's G1 fix landed, revert `deploymentAvailable` to `Available=True ∧ og == gen`, and the
  fast tier fails with I2 on the deployment update scenarios;
- before that fix lands, the G1 ledger entry is the proof, and removing it makes the tier fail.

Do the same for G2 with `ControllerLag`.

F72 is a named case. With the world behind the production kubectl interpreter, applying F72's mutation record
(`cli/nagarectl/test/mutations/F72-unready-update-unsupported.diff`, which restores the Knative-only branch) must make a
model test fail. That test is the corrective update of an unready StatefulSet or Deployment.

For F67's stamp proof (EP-180 M3):
- The world renders real `nagare.dev/spec-digest` stamps on every object it returns, exactly as written.
- The F67 model schedules pass on the new world. They are the StatefulSet schedules (10,72) and (11,84) and the
  Deployment schedule (5,44) as EP-180 pins them today, or their locator equivalents after M4's re-pinning.
- Applying F67's mutation record (`cli/nagarectl/test/mutations/`) makes that model test fail.

`KubernetesAdapterOps` gains `kubernetesObserveStamped` in EP-180 M3. Until this plan's rebuild, the old world's
`worldKubernetesOps` returns `Nothing` stamps (a one-line interim edit made by EP-180). The new world gets real stamps
from the production runtime, which provides the field.

Not required here: the deep tier (MP-23 step 3d), and fixing any G-defect (EP-180, EP-181).


## Idempotence and Recovery

- **Rebuilding:** every milestone is additive until M4 deletes the old world, so a failed
  milestone is redone on its own.
- **The trace recorder** creates and deletes its own cluster; re-running it overwrites
  `traces.json` deterministically except for UIDs and timestamps, which the abstraction omits. If it
  stops midway, run `k3d cluster delete ep182-traces` and start again.
- **The composition move** is behaviour-preserving; if it conflicts with EP-180, rebase it onto
  EP-180's tree rather than merging the two by hand.
- **Processes:** stop them only by the exact PID started, never by pattern.


## Interfaces and Dependencies

Hard dependency: EP-179 on master (Run snapshot, search, tiers). Soft dependencies: EP-180 and
EP-181. Their fixes shrink the ledger, and EP-181's operation needs M3's pod DELETE.

New or changed interfaces:

- `Nagare.Inventory.Adapters.KubernetesApplication.kubernetesApplicationAdapter :: Bool ->
  KubernetesRuntimeConfig -> (ResourceId -> IO (Either Text Text)) -> Map ResourceId
  (ManagedResource, ByteString) -> Adapter` (library; used by the CLI and the world).
- `Nagare.Test.World.Kinds.KindSemantics`, as in M1, and `KindRow.semantics :: Maybe KindSemantics`.
- `Nagare.Test.World.ApiServer`: `ApiServer`, `ApiRefusal { httpStatus :: Int, reason :: Text,
  message :: Text }`, `create`, `applyServerSide`, `patchJson`, `delete`, `get`, `controllerStep`,
  `externalWrite`, `canonicalQuantity`.
- `Nagare.Test.World.Kubectl.worldKubectl :: IORef KubeWorld -> IORef Adversary -> KubectlRequest
  -> IO KubectlResult`, and `LoggedRequest`.
- `Nagare.Test.World.Adversary`: `Fault` gains `ControllerLag`; `Adversary` gains `acted`;
  `noteActed`.
- `Nagare.Test.World.Kubernetes.groundTruth`.
- `Nagare.Test.Model.KnownDefects.KnownViolation` and `knownViolations`.
- `cli/nagarectl/test/fixtures/kubernetes-semantics/traces.json` and its recorder,
  `docs/audits/k8s-semantics-2026-10-06/experiments/record-traces.sh`.

Libraries: aeson for rendering and parsing; effectful through `KubernetesTransport`'s existing
`runKubectlWith`; tasty and HUnit as the suite already uses. No new package dependency.
