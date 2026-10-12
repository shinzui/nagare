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

Full plan before trimming: [181-replace-a-stuck-statefulset-pod-through-a-reviewed-operation.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/181-replace-a-stuck-statefulset-pod-through-a-reviewed-operation.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- **Mutation records.** All eleven `EP181-*` records are killed by the sweep on `83124396`, 149 of 149 ([sweep](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/mutation-sweep-83124396.tsv)).
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

