---
id: 181
slug: replace-a-stuck-statefulset-pod-through-a-reviewed-operation
title: "Replace a stuck StatefulSet pod through a reviewed operation"
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
      at: 2026-10-07T02:18:32Z
      mode: "update"
      note: "Filled the skeleton: five milestones from RES-4 §5.3 on EP-180's rules; next-review planning and readiness-gated completion recorded as decisions"
---

# Replace a stuck StatefulSet pod through a reviewed operation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A database in Nagare runs as a Kubernetes StatefulSet with one replica. Suppose a review gives
it a template that cannot start, for example a bad image, too much memory, or an unschedulable
node selector. Its single pod, `pg-0` for a database named `pg`, then stays not Ready.
Kubernetes refuses to roll that pod for any later template: under the defaults Nagare renders
(ordered pod management, rolling updates), the controller does not replace a pod that is not
Ready.

A corrected review then lands on the StatefulSet: the API accepts it, and
`status.updateRevision` moves to the corrected template. The pod, however, stays at the broken
revision until someone deletes it. RES-4 calls this G3, a "false hope" defect:

- the operator's fix is accepted;
- the transaction waits 300 seconds and settles as landed and not ready;
- close keeps it;
- the next plan sees nothing to change, so the database never runs the reviewed template.

`db restart` is blocked the same way.

After this plan, the next review of such a StatefulSet contains one extra reviewed operation,
**replace the stuck pod**. It deletes exactly the pod that blocks the rollout, guarded by that
pod's identity and freshness, and then waits for the StatefulSet to roll. An operator sees it in
the review as a line like this:

```text
replace-stuck-pod  statefulset personal/pg  pod pg-0 (uid 3f…, revision 9d647, not Ready) blocks rollout to revision d9d6d
```

After `inventory apply`, the database pod runs the corrected template. If anything changed
between review and apply (the pod became Ready, was replaced, or the StatefulSet moved again),
the operation either refuses before writing or the API server refuses the delete, and the
operation proves that it had no effect.

How to see it working:

- the unit tests named in each milestone pass;
- once EP-182's world models stuck StatefulSets, the recovery model shows a corrected database
  update followed by this operation reaching a Ready StatefulSet, instead of a kept revision that
  never runs;
- every mutation record this plan adds fails its named test.


## Progress

- [ ] M1: a stuck rollout is observed. For a member StatefulSet only, the runtime reports the
  pod that blocks its rollout. A test over recorded API objects finds it exactly when:
  - `observedGeneration == generation`;
  - the pod's revision differs from `updateRevision`;
  - the pod is not Ready.
- [ ] M2: the operation is planned and prepared. A plan over a stuck member contains one
  `ReplaceStuckPod` operation, with the pod's identity in its reviewed bytes. No other plan
  contains it.
- [ ] M3: the operation executes under the conditional-write discipline.
  - It re-reads the StatefulSet and the pod.
  - It refuses before any write unless the reviewed pod is still the stuck one.
  - It deletes the pod with its UID and its fresh resourceVersion as preconditions.
  - It waits for the rollout.
- [ ] M4: the operation settles and recovers by proof. A table test covers every row of this
  plan's class table, and the driver and close treat the operation like any other.
- [ ] M5: end to end.
  - The kind table and its totality test know the operation.
  - With EP-182's world, the recovery model's corrected-database scenario reaches Ready through
    it.
  - The user documentation says what the operator sees.
  - Every mutation record added here fails its named test.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: the replacement is planned in the review **after** the correction, not in the same
  review as the correcting update.
  Rationale: a StatefulSet update waits for readiness
  (`kubectl rollout status --timeout=300s`). When the pod is stuck, that wait stops the
  transaction as landed and not ready before any dependent operation could run. The same review
  could carry the replacement only by moving the update's readiness wait into the replacement,
  which changes the update's proof. The next review needs no such change: close keeps the landed
  correction (ADR 26), and the next plan observes the stuck pod. RES-4 §5.3 allows either; the
  cost is one close and one more review.
  Date: 2026-10-06

- Decision: a replaced pod classes as completed only when the StatefulSet is then Ready, and as
  landed otherwise.
  Rationale: RES-4 §5.3 lists "new pod UID → Completed", but RES-4's own create and update tables
  class an effect as completed only by readiness, and as landed before it. ADR 26's adapter
  settlement has no completed class: completion is proved by recovery (`RecoveryProvedComplete`)
  and journalled by resume. A new pod running a still-broken template must not let the scope
  report converged.
  Date: 2026-10-06

- Decision: one operation replaces one pod, the lowest-ordinal stuck pod of the StatefulSet.
  Rationale: Nagare renders `replicas: 1`. Ordered pod management recreates pods one ordinal at a
  time anyway, and a later review plans again if another pod is stuck. One pod per operation
  keeps one write per operation, like every other operation.
  Date: 2026-10-06

- Decision (operator, 2026-10-06): no backward compatibility. The new operation action and
  observation are added outright; earlier reviews and journals need not decode.
  Date: 2026-10-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are under `cli/nagarectl/` unless written in full. Line numbers are from master at
`f1f02717`. This plan depends on EP-180, which edits the same adapter on branch
`create-batch-2`. Where EP-180 changed or will change something this plan uses, the text below
says so. Re-read those places on master once EP-180 has landed.

**Terms.**

- A *member* is a resource that an inventory scope owns. A database's StatefulSet, its PVC and
  its Secrets are members. Pods are not members: the StatefulSet's controller creates and owns
  them.
- A *review* is a published plan: a list of *operations*, each with reviewed native bytes that
  the adapter prepared. `inventory apply` executes a review as one *transaction*, and journals
  intent before each effect.
- A *revision* of a StatefulSet is a hash of its pod template. The controller records the
  current target in `status.updateRevision`. It labels each pod with the revision the pod was
  created from, `controller-revision-hash`.
- `og` is `status.observedGeneration` and `gen` is `metadata.generation`. `og == gen` means the
  controller has seen the latest spec.
- A StatefulSet is *stuck* when all of these hold:
  - it is a member, and `og == gen`;
  - a pod it controls has a `controller-revision-hash` different from `status.updateRevision`;
  - that pod's `Ready` condition is not `True`.

**The defect, validated.** [RES-4](../research/kubernetes-api-semantics-for-inventory-proofs.md)
holds evidence from k3s 1.34.6, gathered on 2026-10-06.

- §2 records that under ordered pod management with rolling updates and one replica, "once pod-0
  is not Ready (crash loop or Pending), no later template change replaces it".
- Experiment E6f (`docs/audits/k8s-semantics-2026-10-06/experiments/e6e.out`) shows it: a good
  template, then a broken one, then a correction. The StatefulSet then reads `gen 3, og 3,
  updateRevision d9d6d`, while its only pod stays at revision `9d647`, not Ready.
- §4 G3 rates this "false hope, then a hidden wedge".
- §5.3 prescribes the operation this plan builds:
  - it is planned on the stuck condition;
  - its effect is a DELETE of the pod with the pod's UID and resourceVersion as preconditions;
  - its classes are: 4xx → no effect; same pod UID → no effect; new pod UID → completed; same
    UID being deleted → landed;
  - it is data-safe, because the database PVC is a separate member and the deleted pod was not
    Ready.

**What Nagare renders.** `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs` `statefulSetValue`
(around line 145) sets `replicas: 1`, a selector, and a template that mounts the separately
reviewed PVC by `claimName`. It sets no `volumeClaimTemplates`, `podManagementPolicy` or
`updateStrategy`, so the Kubernetes defaults apply (OrderedReady, RollingUpdate). The golden
output is `cli/nagare-dsl/test/golden/db-postgres.statefulset.yaml`. The broker
(`Dsl/Broker/Render.hs`) and the Redis restore scratch follow the same pattern.

**Operations and planning.**

- `OperationAction` (`src/Nagare/Inventory/Adapter.hs` 115–125) has `CreateResource`,
  `UpdateResource`, `VerifyResource`, `AdoptResource`, `RetireResource`, `RunDeclaredOperation`,
  `OpenMaintenanceSession`, `RestoreLiveDatabase` and `MigrateResource`.
- `PlannedOperation` (127–136) carries the action, the executor, the resources, the input digest,
  the dependencies and the recovery class.
- `ResourceObservation` (`Adapter.hs` 58–66) is what the planner sees for each member. Its
  constructors are `ObservedPresent`, `ObservedDrifted`, `ObservedReplacementRequired`,
  `ObservedUnowned`, `ObservedForeign`, `ConfirmedAbsent` and `ObservationUnavailable`.
  Readiness is not part of it. The Kubernetes adapter's `toObservation`
  (`src/Nagare/Inventory/Adapters/Kubernetes.hs` 214–244) maps a not-ready object with the
  reviewed digest to `ObservedPresent`.
- `planChanges` (`src/Nagare/Inventory/Plan/Changes.hs` 191) builds the operations. Each member's
  action is chosen in `classifyDesired` (709–784), and operation ids come from `mkPlanned`
  (838–842).
- Review validation is `verifyReview` (`Plan/Validation.hs` 74–104), and admission is `admit`
  (`src/Nagare/Inventory/Execute/Admission.hs` 121). Neither has a per-kind action list; per-kind
  gating lives in the adapter.

**The Kubernetes adapter.** In `src/Nagare/Inventory/Adapters/Kubernetes.hs`:

- `KubernetesState` (59–66), `KubernetesMutation` (71–83) and `KubernetesAdapterOps` (95–101,
  with `kubernetesObserve` and `kubernetesMutateConditional`);
- `prepare` (245–264), `preflight` (283–292), `execute` (293–306) and `recover` (315–400);
- `singleSpec` (514–550, the per-action allowlist) and `validateBefore` (552–604);
- `decodeMutation` (688–701), `settleMutation` (763–805) and `requireSameBefore` (807–846).

On `create-batch-2`, EP-180 adds three things this plan uses:

- `beforeStamp`;
- the refusal mapping `kubectlRefusal` (M4: definitive 4xx answers are known to have had no
  effect);
- the write guard `requireWriteTarget`, with the shared rule `stampDistinguishes` (M5a).

In `src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`:

- `observe` (132–165) runs `kubectl get … -o json`.
- `mutate` (166–251) performs the writes.
- `waitForReadiness` (307–361) waits after a write. For a StatefulSet it runs
  `kubectl rollout status statefulset/<name> --timeout=300s` (336–347).
- `statefulSetReady` (802–832) requires `og == gen` and the ready and updated replica counts. It
  omits `currentRevision == updateRevision` (RES-4 G15).
- No code reads `updateRevision`, `currentRevision` or `controller-revision-hash`, and the
  reviewed adapter never deletes a pod.

Conditional raw deletes already exist:
`src/Nagare/Inventory/Adapters/KubernetesCollection.hs` `collectionDeleteRequest` (18–46) runs
`kubectl delete --raw <path> -f -` with a `DeleteOptions` body that carries
`preconditions {uid, resourceVersion}`.

Two read-only places already read the pods a StatefulSet controls. Both check the pod's controller
`ownerReference` against the StatefulSet's UID:

- `src/Nagare/Inventory/Adapters/RestoreScratch.hs`, `restoreScratchFailureFromPodList`
  (75–110);
- `src/Nagare/Inventory/DataFence/DatabaseShutdown.hs`, `observeDatabasePod` (56–70).

**Settlement and close.** `Settlement` (`Adapter.hs` 202–216) has `SettledNoEffect`,
`SettledLanded`, `SettledTargetGone`, `SettledTerminalPartial` and
`SettledUnknown reason resolvedBy`. There is no completed settlement. Completion is proved by
recovery (`RecoveryProvedComplete`) and journalled by resume; for such an operation, settlement
answers "proved complete, resolved by inventory resume".

Close lives in `src/Nagare/Inventory/Execute/Close.hs` (`closeTransaction` 126, `classify`
299–314). It classes each operation from the journal or from settlement. It keeps a scope's
desired revision when anything landed, and reverts it only when nothing had an effect.

Terminating objects: EP-180 M6 makes the parser report `deletionTimestamp` (RES-4 G5). This
plan's pod parser reads it directly and follows the same rule: the same UID being deleted is
landed.

**The recovery model.** `test/Nagare/Test/World/Kubernetes.hs` models neither pods nor
revisions. [EP-182](182-derive-the-recovery-model-s-kubernetes-world-from-validated-api-semantics.md)
replaces this world with one derived from RES-4. Its fake API server keeps a StatefulSet stuck
until a pod DELETE with UID and resourceVersion preconditions. Its prediction P6 is the
model-level case this plan closes: "database update × `LandsUnready`, then the corrected update:
the correction lands and stays stuck".

**Tests that exist.**

- `test/InventoryKubernetesSpec.hs`: `statefulSetReady` tests around lines 3784–3816, and
  `compileStatefulSetRestartScope` tests around 3438–3459.
- `test/InventorySettleSpec.hs`, which calls `settleMutation` directly.
- `test/InventoryLandedUpdateStopSpec.hs` and `test/InventoryCloseSpec.hs`.
- `test/InventoryKindTotalitySpec.hs`, which checks the kind table against the adapter's kind
  lists.
- The mutation records in `test/mutations/`, with their table in `test/mutations/README.md`
  (columns: diff, guard reverted, expected failure).

**ADRs.**

- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md): every operation is
  classified from proof, close keeps what landed, and verify never executes. It governs this
  plan's classes. The operation fits it as an ordinary reviewed operation with its own proof, so
  no ADR change is expected.
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md):
  identity is recorded at creation and read through one checked accessor. This applies to the
  StatefulSet. The pod's identity is evidence in the reviewed bytes, never a recorded
  incarnation, because a pod is not a member.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): defects
  are found by interpreters, and native runs only confirm. It sets the acceptance order: unit
  tests and the model first.


## Plan of Work

### Milestone 1: observe a stuck rollout

Teach the runtime to report the pod that blocks a member StatefulSet's rollout, and only that.

In `KubernetesRuntime.hs`, add a pure parser
`stuckPod :: Value -> [Value] -> Either Text (Maybe StuckPod)`. It takes the StatefulSet object
and the list of pods, and returns the lowest-ordinal pod that satisfies all of these:

- the StatefulSet's `status.observedGeneration == metadata.generation`;
- the pod has a controller `ownerReference` naming the StatefulSet's UID, as
  `restoreScratchFailureFromPodList` checks;
- the pod's `metadata.labels.controller-revision-hash` differs from the StatefulSet's
  `status.updateRevision`;
- the pod's `Ready` condition is not `True`;
- the pod has no `deletionTimestamp`, because a pod being deleted is not stuck: it is already
  going.

`StuckPod` records the pod's name, namespace, UID, resourceVersion and revision, plus the
StatefulSet's UID and `updateRevision`. A missing `updateRevision`, a malformed label or a
non-integer generation is an error, never "not stuck".

The runtime reads pods only when they matter: when the observed object is a member StatefulSet
that reads not ready (`statefulSetReady` is false). It lists them with one
`kubectl get pods --namespace <ns> -l <spec.selector.matchLabels> -o json`, then filters them by
owner UID.

Expose this through `KubernetesAdapterOps` as a new field,
`kubernetesStuckPod :: ResourceId -> IO (Either Text (Maybe StuckPod))`, so that tests and the
world can supply their own. While here, add the missing `currentRevision == updateRevision` term
to `statefulSetReady` (RES-4 G15), with its own test.

Add `ObservedStuckReplica !Text` to `ResourceObservation`; the text describes the pod for the
review. In `Kubernetes.hs` `toObservation`, a StatefulSet that reads not ready with the reviewed
digest and has a stuck pod becomes `ObservedStuckReplica`. One without a stuck pod stays
`ObservedPresent`. Every other adapter is untouched: none of them produce the new constructor,
and the planner's pattern matches are total, so the compiler finds every place to extend.

Acceptance: a new spec, `test/InventoryStuckPodSpec.hs`, decodes JSON transcribed from RES-4's
E6e and E6f (`docs/audits/k8s-semantics-2026-10-06/experiments/e6e.out`). It asserts:

- E6f's final state is stuck;
- the same pod, once Ready, is not stuck;
- nothing is stuck while `og < gen`;
- a pod whose revision equals `updateRevision` is not stuck (E6e's first states, a broken
  create);
- a pod with a `deletionTimestamp` is not stuck;
- a pod owned by another UID is not stuck;
- a StatefulSet without `updateRevision` is an error.

### Milestone 2: plan and prepare the operation

Add `ReplaceStuckPod` to `OperationAction`.

In `Plan/Changes.hs` `classifyDesired`:

- A member observed as `ObservedStuckReplica` whose declaration is unchanged plans
  `ReplaceStuckPod` for that member: one operation, with the StatefulSet as its
  `plannedResources`.
- A member that is both drifted and stuck plans only its `UpdateResource`. The replacement
  follows in the next review (see the Decision Log).
- The recovery class is `VerifyBeforeRetry`: the operation re-reads before every attempt.

In the Kubernetes adapter:

- `singleSpec` admits `ReplaceStuckPod` only for an `apps/StatefulSet` address.
- `prepare` reads the stuck pod through `kubernetesStuckPod`. It records the pod, with the
  StatefulSet's UID and `updateRevision`, as the reviewed native bytes of a new, versioned JSON
  form, `PodReplacement`.
- If the pod is no longer stuck at prepare, prepare refuses with a reason: the plan is stale.
- The review's public summary names the namespace, the StatefulSet, the pod, its UID prefix, its
  revision and the target revision, as in the Purpose example.

Acceptance:

- planner tests in `test/InventoryStuckPodSpec.hs`: a stuck member plans exactly one
  `ReplaceStuckPod`; a member that is not stuck plans none; a member that is drifted and stuck
  plans only the update;
- a prepare test whose bytes decode back to the recorded pod;
- a refusal test for an address that is not a StatefulSet;
- the existing planning, review and admission suites stay green.

### Milestone 3: execute under the conditional-write discipline

`execute` for `ReplaceStuckPod` follows EP-180's discipline (RES-4 §5.2): check the reviewed
identity on a fresh read, then write with the fresh resourceVersion, so the server enforces that
nothing changed in between.

1. Re-read through `kubernetesStuckPod`. Unless the result is a stuck pod with the reviewed pod
   UID, under the reviewed StatefulSet UID, refuse with a known-no-effect failure and write
   nothing. A pod that became Ready, was replaced, or is being deleted no longer meets the
   reviewed condition.
2. Delete through a new runtime request, `podReplacementRequest`, modelled on
   `collectionDeleteRequest`:
   `kubectl delete --raw /api/v1/namespaces/<ns>/pods/<name> -f -`, with
   `DeleteOptions{preconditions:{uid: <reviewed pod UID>, resourceVersion: <fresh rv>}}` and the
   default grace period. Map the answer with EP-180's `kubectlRefusal`: 409, 422 or 404 is known
   no effect; a transport failure, timeout or 5xx is ambiguous.
3. Wait for the rollout as an update does
   (`rollout status statefulset/<name> --timeout=300s`). Ready returns completed. Otherwise the
   effect is identified and not ready (ambiguous), so the driver stops and settlement decides.

`preflight` runs step 1 only.

Acceptance:

- runtime tests pin the exact request: the path, the UID and fresh-resourceVersion
  preconditions, and no propagation override;
- adapter tests with stub `KubernetesAdapterOps` cover:
  - a stuck pod → one delete;
  - a pod Ready by then → no delete, and a no-effect failure;
  - a pod replaced by then → no delete;
  - a 409 answer → no effect;
  - a timeout → ambiguous.

### Milestone 4: settle and recover by proof

Recovery and settlement observe the StatefulSet and its pods, and class the operation by this
table. It is derived from RES-4 §3's retire table and from §5.3.

| Observed | Recovery | Settlement |
| --- | --- | --- |
| delete answered 409, 422 or 404 (journalled as a refusal) | (journal) | no effect |
| reviewed pod, same UID, no `deletionTimestamp` | safe to retry | no effect |
| reviewed pod, same UID, `deletionTimestamp` set | landed, not ready | landed (deletion accepted) |
| reviewed pod gone or another UID, StatefulSet Ready at `updateRevision` | proved complete | proved complete (resolved by resume) |
| reviewed pod gone or another UID, StatefulSet not Ready | landed, not ready | landed |
| the StatefulSet itself gone or another UID | target replaced | target gone |
| observation unavailable | unresolved | unknown |

"Same UID, no deletion timestamp → no effect" is sound because a pod DELETE either removes the
object or marks it deleted (RES-4 U6). A pod that still carries no `deletionTimestamp` was never
deleted, whatever its resourceVersion.

Close then needs nothing new:

- a landed replacement keeps the scope's revision, since the StatefulSet still carries the
  corrected template;
- a no-effect replacement leaves the revision as it was;
- the next review plans again if the StatefulSet is still stuck.

Acceptance:

- a table test in `test/InventoryStuckPodSpec.hs`, with one case per row;
- a close test showing that a landed replacement keeps the desired revision;
- mutation records, each failing its named test, for each of these mutants:
  - deleting without the UID precondition;
  - deleting with the reviewed resourceVersion instead of the fresh one;
  - ignoring `og == gen`;
  - ignoring the pod's revision;
  - ignoring the pod's readiness;
  - classing a same-UID pod with a `deletionTimestamp` as no effect;
  - classing a new pod as complete without the StatefulSet's readiness.

### Milestone 5: end to end

- Kind table: `test/Nagare/Test/World/Kinds.hs` gains a `KindReplaceStuckPod` action on the
  `apps/StatefulSet` row. `test/InventoryKindTotalitySpec.hs` checks it against a new adapter
  list, `stuckPodReplacementKinds`, in `src/Nagare/Inventory/Adapters/KubernetesKinds.hs`.
- Recovery model: with EP-182's world, add the scenario "create a database, update it with a
  template that never becomes Ready, correct it, then replace the stuck pod" to
  `test/Nagare/Test/Model/Scenarios.hs`. EP-182's fake server keeps a StatefulSet stuck until a
  preconditioned pod DELETE. The scenario's fault-free run must end with the StatefulSet Ready at
  the corrected revision. The correction's step takes the exit `[[Close]]`, and the
  replacement's step takes none. EP-182's prediction P6 then no longer reports a violation for
  this case.
- User documentation: the database page under `docs/user/` explains:
  - what `inventory plan` shows for a stuck database;
  - why the operation is safe: the PVC is a separate member, and the pod was not Ready;
  - that a `db restart` of a stuck database is completed the same way, in the next review.

Acceptance: the totality test, the new model scenario on the remote builder, `just gate-fast`,
and `just mutation-check` with every record from this plan failing its named test.


## Concrete Steps

Work in a worktree from master once EP-180 has landed, since its stamp, refusal and terminating
rules are this plan's base. From the repository root:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/stuck pod/"'
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/kind totality/"'
just gate-fast
just test-remote <commit> '/recovery model/'
just mutation-check <commit>
```

Expected output once M4 is done:

```text
stuck pod
  observation: E6f final state is stuck:                    OK
  observation: Ready pod is not stuck:                      OK
  plan: a stuck member plans one ReplaceStuckPod:           OK
  execute: a pod that became Ready is not deleted:          OK
  settle: same UID with deletionTimestamp is landed:        OK
```

Before every Haskell commit, run `just gate-fast` and check `git diff --numstat`. Heavy runs go
to the remote builder. Stop processes only by the exact PID that was started.


## Validation and Acceptance

- Unit: `-p "/stuck pod/"` passes, covering observation, planning, prepare, execute, settlement
  and recovery as listed in each milestone. The existing suites stay green.
- Mutation: each record this plan adds fails its named test, as proved by `just mutation-check`.
- Model: once EP-182's world is on master, the stuck-database scenario's fault-free run ends with
  the StatefulSet Ready at the corrected revision, and the fast tier and the self-test stay
  green. Until then, M5's model item waits; it does not block M1–M4.
- Not required here:
  - a native run (MP-23 step 5 confirms);
  - changing the database renderer to `podManagementPolicy: Parallel`. That field is immutable,
    and RES-4 ledgers it for new databases.


## Idempotence and Recovery

Every step is code and tests. The operation itself is safe to repeat: a pod that is no longer
stuck is not deleted (M3 step 1), and the server refuses a stale delete (a precondition 409).
Each milestone is one or more commits. Reverting a milestone restores the previous behaviour, in
which a stuck StatefulSet waits for a manual pod delete.


## Interfaces and Dependencies

Dependencies:

- Hard: four EP-180 milestones, on master before this plan's M3 starts. M1 and M2 may start on
  EP-180's branch.
  - M3: the stamp proof and `beforeStamp`.
  - M4: `kubectlRefusal`, so that 4xx answers are no effect.
  - M5: the conditional-write discipline.
  - M6: terminating objects are classified.
- Soft: EP-182 M3 (the fake server's stuck StatefulSet and pod DELETE), for M5's model scenario.

New or changed interfaces:

- `Nagare.Inventory.Adapter.OperationAction`: new constructor `ReplaceStuckPod`.
- `Nagare.Inventory.Adapter.ResourceObservation`: new constructor `ObservedStuckReplica !Text`.
- `Nagare.Inventory.Adapters.Kubernetes.KubernetesAdapterOps`: new field
  `kubernetesStuckPod :: ResourceId -> IO (Either Text (Maybe StuckPod))`.
- `Nagare.Inventory.Adapters.KubernetesRuntime`:
  - `stuckPod :: Value -> [Value] -> Either Text (Maybe StuckPod)`;
  - `podReplacementRequest`;
  - `data StuckPod`: the pod's name, namespace, UID, resourceVersion and revision, plus the
    StatefulSet's UID and `updateRevision`.
- `Nagare.Inventory.Adapters.KubernetesKinds.stuckPodReplacementKinds`.
