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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-07T03:12:27Z
      mode: "implement"
      note: "M1 and M2 implemented; side-channel, pod-ops input, terminating rule, read scope and G15 deferral recorded"
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

- [x] M1: a stuck rollout is observed. For a member StatefulSet only, the runtime reports the
  pod that blocks its rollout. A test over recorded API objects finds it exactly when:
  - `observedGeneration == generation`;
  - the pod's revision differs from `updateRevision`;
  - the pod is not Ready.

  Done 2026-10-06 (ee961352 on `ep181-stuck-pod`, rebased onto c3755ad7). It adds
  `Nagare.Inventory.Adapters.KubernetesStuckPod`, with `stuckPod` and `runtimePodOps`. The
  `stuck pod` group's observation and runtime tests cover E6e and E6f, a terminating pod, another
  owner, the lowest ordinal, a missing `updateRevision` or revision label as an error, and a
  refusing guard.
- [x] M2: the operation is planned and prepared, and status names it. A plan over a stuck member
  contains one `ReplaceStuckPod` operation, proposed automatically from the observation, with the
  pod's identity in its reviewed bytes. No other plan contains it. `inventory status` reports the
  member as a stuck rollout and names the operation the next plan proposes.

  Done 2026-10-06 (df4b987a and e6926f60). Tests in the `stuck pod` group:
  - planner: one replacement, none, update only when drifted, and update only when corrected;
  - status: `StuckRollout` with its reason;
  - adapter observe: the stuck pod; no pod read when Ready or drifted; unavailable on a failed pod
    read;
  - prepare: the bytes decode, stale refusal, refusal for a non-StatefulSet;
  - an end-to-end test over a stubbed kubectl, through the production adapter,
    `observeWithRegistry`, `planChanges`, `prepareReview` and status's `statusFacts`.

  `just gate-fast` is green. Execute, settle and recover refuse with no effect until M3 and M4.
- [x] M3: the operation executes under the conditional-write discipline. It starts only once
  EP-180 M6 is on master: its constructor `KubernetesTerminating` (decided by nagare-defects,
  2026-10-06) is how the pod's terminating state is read.
  - It re-reads the StatefulSet and the pod.
  - It refuses before any write unless the reviewed pod is still the stuck one.
  - It deletes the pod with its UID and its fresh resourceVersion as preconditions.
  - It waits for the rollout.

  Done 2026-10-06 (27f78869). Execute and preflight re-read through `readStuckPod` and refuse,
  with no effect and before any write, when:
  - the pod is Ready by then, or has been replaced;
  - the update revision has moved, or the StatefulSet has been replaced;
  - the re-read fails.

  Runtime tests pin the request: `delete --raw /api/v1/namespaces/personal/pods/pg-0 -f -` with
  the UID and fresh-resourceVersion preconditions and no propagation, followed by `rollout status`.
  They also cover how answers are mapped: a 409 is no effect, a timeout is ambiguous, a rollout
  that never becomes Ready is ambiguous, and a refusing guard deletes nothing.
- [x] M4: the operation settles and recovers by proof. A table test covers every row of this
  plan's class table, and the driver and close treat the operation like any other.

  Done 2026-10-06 (c76353bc and 76c524a6).
  - The `stuck pod` group's class-table test covers every row; the journalled-refusal row is the
    M3 409 test.
  - Apply converges a replacement whose StatefulSet becomes Ready, and close keeps a landed one
    at the desired revision.
  - The seven `EP181-*` mutation records each fail their named test (`test/mutations/README.md`).
- [x] M5: end to end.
  - The kind table and its totality test know the operation.
  - With EP-182's world, the recovery model's corrected-database scenario reaches Ready through
    it.
  - `doctor` names a stuck database rollout and the fix: plan, review the proposed replacement,
    apply.
  - The user documentation says what the operator sees.
  - Every mutation record added here fails its named test.

  Done 2026-10-07, on `ep181-land` (rebased onto aaa96eaf):
  - kind row and totality: 5c6e8363;
  - action publication totality: 5c6e8363 and 04001275;
  - `db restart` and the doctor probe: e2361e58 and db901cd3 (RES-4 U15);
  - the world's pods: a1838ae2;
  - I9 and the restart scenario: ec906376 and 2213591b;
  - records: 58e8b6cc, 04001275, 300d1e7d, 02eb39a1 and 2213591b.

  Acceptance:
  - the kind totality and action publication tests pass;
  - `just mutation-sweep 2cc6078a` reports "109 killed, 0 not";
  - `just gate-fast` is green, with the mutation-records and mutation-patterns steps;
  - the fast tier is clean with I9.

  I9's classification, before and after:
  - On master (356e7f18 with I9), the fast tier found 4 violations, all in the database scenario,
    after nagare-first-principle fixed EP-182's `acted` bookkeeping for LandsFailed and
    ControllerLag. Earlier, on c37bc231, 15 more had come from that bookkeeping.
  - The true G3, a LandsUnready or LandsFailed update write (MutateCall 10), now converges: the
    restart step observes the stuck pod and the plan replaces it.
  - A fault on the correction's own write (MutateCall 11) is excused by the faulted-template rule.
  - A fault on the create (MutateCall 5) is F78, a documented limit listed in the ledger.
  - EP181-model-correction-never-replaced proves that the scenario fails without the replacement.

## Surprises & Discoveries

- The close test found that publishing any review with a replacement failed.
  `publishObservationMembers` (`src/Nagare/Inventory/ObservationNative.hs`) decoded every
  `kubernetes-conditional-object` envelope as a `KubernetesMutation`, and a `PodReplacement` has
  no `action` key. A replacement writes no member object, so it now yields no observation member,
  once its bytes prove to be this operation's replacement. The unit tests above the store missed
  this. Every new action needs a test that publishes and loads a review containing it.
  Date: 2026-10-06

- The first observed-generation mutant survived. Its only test had the pod at the stale update
  revision, which the revision condition already rejects. The test now has a pod stuck behind an
  earlier correction under a newer spec the controller has not observed, which only that
  condition rejects.
  Date: 2026-10-06


## Decision Log

- Decision (confirmed by session nagare for the operator, 2026-10-06): the replacement is planned
  in the review **after** the correction, not in the same review as the correcting update. The
  next plan proposes it automatically from the observation, and `inventory status` and `doctor`
  name it, so the operator is never left to find the stuck pod.
  Rationale: a StatefulSet update waits for readiness
  (`kubectl rollout status --timeout=300s`). When the pod is stuck, that wait stops the
  transaction as landed and not ready before any dependent operation could run. The same review
  could carry the replacement only by moving the update's readiness wait into the replacement,
  which changes the update's proof. The next review needs no such change: close keeps the landed
  correction (ADR 26), and the next plan observes the stuck pod. RES-4 §5.3 allows either; the
  cost is one close and one more review.
  Date: 2026-10-06

- Decision (refinement of RES-4 §5.3, confirmed by session nagare, 2026-10-06): a replaced pod
  classes as completed only when the StatefulSet is then Ready, and as landed otherwise.
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

- Decision (nagare-defects for EP-180 M6, 2026-10-06): a terminating object is the
  `KubernetesState` constructor `KubernetesTerminating`, not a field, so that every consumer
  decides "not a live member" explicitly. This plan classifies pods through the same parser.
  Date: 2026-10-06

- Decision (operator, 2026-10-06): no backward compatibility. The new operation action and
  observation are added outright; earlier reviews and journals need not decode.
  Date: 2026-10-06


- Decision (implementation, accepted by session nagare, 2026-10-06): a stuck rollout is a side
  channel of `ObservationSet` (`observationStuck`, `withStuckRollouts`), not a new
  `ResourceObservation` constructor `ObservedStuckReplica`. The member itself stays
  `ObservedPresent`.
  Rationale:
  - many consumers match `ObservedPresent` directly (planning proofs, incarnation checks, status
    health, retention and collection). A new constructor would make each of them decide again
    what a stuck but present member is, and a missed one would mis-class a live member.
  - a consumer that drops the side channel only fails to propose the replacement, which is the
    behavior before this plan.

  Every rebuild of the set keeps the channel: `observeWithRegistry`, the CLI planning wrapper,
  the reviewed-access adapter, and status through `Status.statusFacts`. Nagare required, as a
  condition, an end-to-end test that a stuck pod read by the production observe path reaches the
  plan and status; `stuck pod`'s end-to-end test is that test.
  Date: 2026-10-06

- Decision (implementation, accepted by session nagare, 2026-10-06): pod access is a separate
  `KubernetesPodOps` input to `mkKubernetesAdapterWithObservations`, not a field of
  `KubernetesAdapterOps`.
  - Production builds its adapter through that constructor, now exported, with `runtimePodOps`.
  - Every other constructor installs `noPodOps`, under which nothing is ever stuck.
  Rationale: a new field would change about fifteen adapter-ops constructions in the tests and
  EP-182's `test/Nagare/Test/World/Kubernetes.hs`. EP-182 wires its world's pods when it models
  stuck StatefulSets (M5).
  Date: 2026-10-06

- Decision (implementation, 2026-10-06): pods are classed as terminating by EP-180 M6's rule,
  applied in `podTerminating`: a `metadata.deletionTimestamp` that is present and not null. It is
  not applied through `parseObserved`, which classes stamped members against a desired object;
  pods carry no Nagare stamp. A terminating pod is never stuck: it is already going.
  Date: 2026-10-06

- Decision (implementation, 2026-10-06): the observation reads pods only for a member
  StatefulSet observed as `ObservedPresent` and `KubernetesNotReady`. A Ready or drifted member
  costs no pod read, and a drifted member plans its update first (see the first decision). A
  failed pod read makes the member's observation unavailable, never "not stuck", so planning
  waits instead of proposing nothing.
  Date: 2026-10-06

- Decision (implementation, 2026-10-06): RES-4 G15 (a `currentRevision` term in the stuck
  condition) is deferred. It would change the readiness the recovery model's current world
  reports. It is reconsidered with EP-182's world in M5.
  Date: 2026-10-06


- Decision (session nagare, 2026-10-06): on a StatefulSet whose rollout is stuck, `db restart`
  submits the accepted scope unchanged, so the plan proposes `replace-stuck-pod`. Otherwise it
  stamps a restart token, as before.
  - The choice is made from the observation (`runtimePodOps`, the pure `stuckPod`), not from a
    flag. A failed read refuses the restart.
  - The plan output says why: "db restart: rollout stuck on pod X at revision R; proposing
    replace-stuck-pod instead of a restart token".
  - The decision is the pure `DataService.compileStatefulSetRestart`.
  Rationale: `db restart` means "make the pod run the current template", and on a stuck
  StatefulSet only replacing the pod can do that. Another restart token is an update that can
  never roll, a defect of its own. Before this, no operator command re-planned an accepted
  database unchanged:
  - `inventory plan` needs a compiled candidate;
  - re-running `db create` drops an accepted restart override;
  - re-running `db restart` plans another update.
  The alternatives were rejected: a new `db replan` command adds a command not yet needed, and
  documenting only the `db create` re-run leaves the post-restart wedge.
  Date: 2026-10-06

- Decision (session nagare, 2026-10-06): the M4 publication defect becomes a mechanism, not a
  lesson.
  - `observationBytesFromMutation` names every action's envelope in an exhaustive case, with no
    default, so a new action fails to compile where its bytes are read.
  - "action publication totality" (`test/InventoryActionPublicationSpec.hs`) checks its action
    list against the generic constructors of `OperationAction`. It publishes a review prepared
    by the real Kubernetes adapter for each action and loads it back intact, with a stub
    reviewed data fence for maintenance and live restore.
  - The rename review covers every `MigrationStage`, also checked against its constructors.
  Date: 2026-10-06

- Decision (implementation, 2026-10-06): the doctor probe lists StatefulSets and pods once
  (`kubectl get … -A`). It classes only StatefulSets stamped with `nagare.dev/resource-id`, with
  the same pure `stuckPod` that planning uses. It reports one FAIL "stuck rollout ns/name" per
  stuck member, an UNKNOWN for a StatefulSet it cannot class, and one OK line otherwise. The
  plan had one probe per database StatefulSet; this enumerates them from the cluster, which is
  the same coverage without reading inventory history.
  Date: 2026-10-06

- Decision (implementation, 2026-10-06): `stuckPodReplacementKinds` in `KubernetesKinds.hs` is the
  single source of truth: `isStatefulSet` reads it, and the kind totality test compares the
  StatefulSet row's `KindReplaceStuckPod` claim with it.
  Date: 2026-10-06

- Decision (session nagare, forwarding nagare-first-principle, 2026-10-06): M5's model scenario
  adds invariant I9, "a correction converges". If a run takes every step of its scenario, and its
  final step reviews a spec the scenario does not mark unready, the run must end with that
  step's scope converged at its accepted revision. Every member that revision bound must be live
  at its reviewed digest and Ready.
  - Hook: `drive`'s end-of-steps arm, beside `storeConsistent` (not `checkInvariants`; mid-run
    non-convergence is legitimate).
  - A close that keeps the scope does not satisfy I9: that is G3 itself.
  - Excuses are faults that acted (`Adversary.acted`):
    - (a) one placed during the final step, where its boundary ordinal is greater than that
      call's count at the final step's start;
    - (b) ForeignManager, ForeignObject, Replaced, Deleted, ChurnAlways.
  - LandsUnready, LandsFailed, ControllerLag, and store and crash faults are not excuses.
    Excusing LandsUnready would excuse G3.
  Acceptance: the corrected-database scenario fails I9 without `ReplaceStuckPod` and passes with
  it, and a mutation record proves it. The operation's planner rule is disabled in that record.
  Date: 2026-10-06


- Decision (session nagare, from RES-4 U15 / experiment E17 on k3s 1.34.6, 2026-10-07): `db restart`
  never stamps a token behind a pod that is not Ready. E17 showed that no template change, whether a
  restart annotation or a fix, replaces such a pod; it only moves `updateRevision`.
  `compileStatefulSetRestart` returns a `RestartDecision`:
  - a pod stuck at an old revision: review the accepted scope unchanged, and the plan replaces it;
  - a pod not Ready at the update revision: `RestartNotPlanned`, and `db restart` exits non-zero
    with "the pod's current template doesn't become ready; correct the database spec, then run db
    restart to replace the stuck pod";
  - otherwise, a restart token as before.
  Submitting the scope unchanged in the second case would not plan nothing: after a landed
  correction the scope is not converged, so the plan verifies the StatefulSet, and prepare refuses
  it as not Ready.
  Date: 2026-10-07

- Decision (session nagare, 2026-10-07): I9's template excuse is per member. The run is excused only
  when a LandsUnready or LandsFailed fault acted and every member left unconverged is justified:
  - it declares exactly a template such a fault landed (by spec digest); or
  - it is absent in the world, never started (no `IntentRecorded` event in the journal for an
    operation on it), and reaches such a member through the final revision's OrderedAfter edges,
    transitively.
  A member that started and then went missing is never justified. Tests cover each side, including a
  dependent created and later deleted.
  Date: 2026-10-07

- Decision (implementation, 2026-10-07): EP-182's world now serves StatefulSet pods to kubectl.
  `get pods` lists them filtered by `-l`, and `get pod NAME` renders one. Each pod carries an owner
  reference to its StatefulSet (controller: true), the template's labels, and its
  `controller-revision-hash`. Before, `get pods` always answered an empty list, so the model could
  never see a stuck pod. The world also records each applied review's operations, so I9 can tell
  from the journal which members started.
  Date: 2026-10-07

- Decision (operator, 2026-10-07): F78 is a documented limit. While a StatefulSet's own template
  never becomes Ready, every transaction stops at it, and independent members planned after it are
  starved until the template is corrected. The next MasterPlan owns the fix ("let a transaction
  continue independent operations past a stop"). The two schedules are in the known-defect ledger;
  I9 gains no excuse for them.
  Date: 2026-10-07

- Decision (session nagare, 2026-10-07): the rebase onto aaa96eaf leaves 13 commits whose test
  suite does not compile alone. EP-180 M9 dropped the landed-reader argument of
  `mkKubernetesAdapterWithObservations`. Their tests (`InventoryStuckPodSpec`, then
  `InventoryActionPublicationSpec`) still pass it, and 2213591b fixes the calls. The library and CLI
  build in each.

  A bisect should skip these commits, or test only the library:

  ```text
  9c37bc63 1a9d42ed 15ff7f84 fc2239ae 58e8b6cc 5c6e8363 04001275
  e2361e58 300d1e7d 02eb39a1 a1838ae2 db901cd3 ec906376
  ```

  The rebase also dropped the action publication group from the suite list from 5c6e8363 on;
  2213591b restores it. Rewriting the commits was rejected: the gate proves only the landed tip, and
  rewriting thirteen commits risked new conflicts for no change in the tip.
  Date: 2026-10-07

## Outcomes & Retrospective

**Status (2026-10-09): Complete.**
- **Shipped.** v0.4.0 (`83124396`) ships the reviewed stuck-pod replacement. The production-readiness checklist ticks "Stuck StatefulSet rollouts have a reviewed exit" on `341b01bc`, an ancestor of the final candidate.
- **Mutation records.** All eleven `EP181-*` records are killed by the sweep on `83124396`, 149 of 149 ([sweep](../audits/mp23-independent-results-2026-10-07/mutation-sweep-83124396.tsv)).
- **Not run.** No native drill exercised a stuck rollout. This plan did not require one (Validation and Acceptance), and the checklist does not either.
- **Moved.** F78, where independent members wait behind a StatefulSet whose own template never becomes Ready, stays a ledgered limit with a runbook, deferred to the next MasterPlan.

Outcome (2026-10-07): a database whose rollout is stuck behind a pod that is not Ready now has a
reviewed exit, and the recovery model proves it.
- `inventory status` reports `stuck-rollout`, and `doctor` fails a `stuck rollout ns/name` check.
- The next plan of the unchanged database, which `db restart` makes, proposes `replace-stuck-pod`.
- The operation deletes exactly the reviewed pod, under its UID and fresh resourceVersion, and
  settles by the plan's class table.
- A pod whose current template never becomes Ready is not replaced. `db restart` says to correct
  the spec first (RES-4 U15).
- I9, "a correction converges", now guards the model against G3 recurring unseen.

What went well:
- The pure classifiers (`podBlock`, `recoverReplacement`, `settleReplacement`) made each class
  testable without a cluster.
- The two-sided known-defect ledger turned F78 into an owned, counted limit rather than a silent
  excuse.

What to keep:
- A store-level test of every new action. The close test found a publication defect that no unit
  test above the store could; the action publication totality test now makes that mechanical.
- Classify every new invariant violation before excusing it. I9's first run looked like 19 defects:
  15 were harness bookkeeping, and the rest were G3 or F78.
- Validate a Kubernetes claim before designing on it. E17 settled restart's behaviour in minutes.

What was costly:
- Three rebases across two landings. Each conflicted in the test suite's module list, and the last
  one left 13 commits whose test suite does not build alone (see the Decision Log).
- A stray `git stash` in a shell loop. The stash list is shared by every worktree.

Durable context for ADRs:
- ADR 25's model now checks I9 at the end of a run, with per-member excuses (see the Decision Log).
- RES-4 U15 is the rule that a template change never replaces a pod that is not Ready.


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
StatefulSet's UID and `updateRevision`. Classify each pod's lifecycle through EP-180 M6's shared
runtime parser, `parseObserved` in `KubernetesRuntime.hs`. It returns the constructor
`KubernetesTerminating !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest` (UID,
resourceVersion, owner, digest; defined in `src/Nagare/Inventory/Adapters/KubernetesProof.hs`)
whenever `metadata.deletionTimestamp` is set, before readiness is considered. A pod being deleted
is therefore never stuck, and M4's "same UID being deleted → landed" row holds by construction.
If M1 starts before M6 is on master, read `deletionTimestamp` through one small function,
`podTerminating :: Value -> Bool`, and replace it with the shared parser when M6 lands. A missing `updateRevision`, a malformed label or a
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

Status: `classifyDriftWith` (`src/Nagare/Inventory/Status.hs` 654) classes each member from the
same `ObservationSet`. Add a `DriftCategory`, `StuckRollout`, for `ObservedStuckReplica`. Its
reason names the pod and its revision and says "the next `inventory plan` proposes
replace-stuck-pod". The compiler finds this match once the constructor exists.

Acceptance:

- a status test: a stuck member reports `StuckRollout` with that reason;
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
- Doctor: `nagarectl doctor` (`src/Nagare/Ops/Doctor.hs`) grades the probes that
  `src/Nagare/Ops/Status.hs` gathers. Add a probe per database StatefulSet that reports a stuck
  rollout, and a remediation for it in the knowledge base (`remediationForAt`): why ("its pod at
  an older revision is not Ready, and Kubernetes will not roll it"), and the fix
  (`nagarectl inventory plan`, review the proposed replace-stuck-pod, then `inventory apply`). A
  unit test grades a stuck probe into that check, as the existing remediation tests do.
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
  - M6: terminating objects are classified, as the constructor `KubernetesTerminating` (UID,
    resourceVersion, owner, digest) in `Adapters/KubernetesProof.hs`. Its rules: a create or
    update whose object is terminating is target gone; a retire whose reviewed UID is terminating
    is landed; `requireWriteTarget` refuses a terminating target; `completionProof` never
    completes on one. M5b (folding version 2 into the write discipline) is on `create-batch-2` at
    `8b6f522e`.
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
