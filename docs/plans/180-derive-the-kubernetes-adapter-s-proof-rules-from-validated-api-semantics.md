---
id: 180
slug: derive-the-kubernetes-adapter-s-proof-rules-from-validated-api-semantics
title: "Derive the Kubernetes adapter's proof rules from validated API semantics"
kind: exec-plan
created_at: 2026-10-06T22:01:39Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-06T22:01:39Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T22:28:21Z
      mode: "update"
      note: "Plan written: RES-4 G1, G2, F67 stamp, G4-G7 and mutation-check milestones"
---

# Derive the Kubernetes adapter's proof rules from validated API semantics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The Kubernetes adapter decides, for every stopped transaction, what each operation did. ADR 26 calls these decisions
proof classes: no effect, landed, completed, target gone, terminal partial, and unknown. The adapter also decides when an
object is ready. Both decisions were written from beliefs about Kubernetes. The research record
[RES-4](../research/kubernetes-api-semantics-for-inventory-proofs.md) validated those beliefs against a real k3s 1.34
and Knative 1.22 server, and found seven places where the adapter's rules disagree with the API. Two of them report a
broken state as converged ("wrong success"):

- a worker Deployment whose new image never starts reads as ready, because its old pod keeps `Available=True`;
- a Knative Service's previous `Ready=True` satisfies readiness before its controller has seen the new spec.

After this plan, every rule in the adapter's settlement and readiness code names the RES-4 row it derives from. Each
rule has a failing test written before its fix and a mutation record that removes it, and the wrong-success cases are
gone. Observable result: the unit tests named below pass, the recovery model's fast tier and self-test stay green,
`just mutation-check` reports every record failing its named test, and the deep tier (EP-179) is run on top by the
MasterPlan, not by this plan.


## Progress

- [x] M1 (G1, F70, F63's worker half), 2026-10-06: Deployment readiness is the `kubectl rollout status` rule, and an
  unready Deployment can be corrected by a reviewed update.
  - Evidence: both tests failed first (a mid-rollout Deployment read ready; the correction was refused at planning) and
    now pass, the correction exiting `[[Close]]`.
  - Records `F70-deployment-ready-ignores-rollout` and `F63-deployment-correction-refused` each fail their test.
  - The readiness predicates moved to `Adapters/KubernetesReadiness.hs`, and the runtime's allowance dropped from 1403
    to 1311.
- [x] M2 (G2, F69), 2026-10-06: Knative Service and DomainMapping readiness require
  `observedGeneration == generation`.
  - Evidence: the unit test failed first and passes now. Record `F69-knative-ready-ignores-generation` fails it.
  - A DomainMapping fixture lacked generation fields and was completed. The model test waits for EP-182.
- [x] M3 (F67), 2026-10-06: the spec-digest stamp proof replaces the dropped configuration-digest version 4.
  - Every observation returns the stamp from its existing read.
  - Prepare records the required `beforeStamp`.
  - Settlement classes an update on its reviewed UID by its stamp.
  - The pure settle test failed first and now passes. Record `F67-settle-ignores-stamp` fails it.
  - The world reads no stamps (two lines, agreed with EP-182), so the three F67 model schedules are handed to EP-182 as
    its acceptance test.
- [x] M4 (G4, F71), 2026-10-06: definitive 4xx refusals map to no effect.
  - `kubectlRefusal` covers the server's 4xx answers and E13's apply field conflict. Transport failures and 5xx stay
    ambiguous.
  - The unit test failed first. The runtime wiring test is proved by its record.
  - `readinessForAddress` moved to `Adapters/KubernetesReadiness.hs`, and the runtime allowance dropped to 1303.
  - Done before M5, because M5's bounded rv-409 re-read relies on every other 409 or 422 being no effect.
- [x] M5 (G6): one conditional-write discipline for updates and retires.
  - M5a, 2026-10-06, done for updates.
    - Adapter: `requireWriteTarget` guards an update by (UID, owner, stamp) when its before stamp differs from the
      reviewed digest, and the write carries the fresh observation.
    - Runtime: `confirmUpdateTarget` adds the stamp, field-owner and takeover-revision checks on the managed-fields
      read, and applies with that read's resourceVersion, re-read up to three attempts on "the object has been
      modified" before G4 decides.
    - Tests failed first. Records `G6-write-guard-compares-whole-state`, `G6-runtime-guard-ignores-stamp` and
      `G6-no-revision-retry` each fail their test.
    - F72 was found and fixed: the transport refused an unready correction. Record `F72-unready-update-unsupported`.
    - Retires keep the exact guard until M6 (G5): see Surprises.
  - Follow-up (session nagare): settlement's stamp row and the write guard share one rule, `stampDistinguishes` (the
    before stamp exists and differs from the reviewed digest). A drift-repair test and record
    `G6-repair-proves-by-stamp` pin it in both places.
  - M5b, 2026-10-06, done: Knative-only version 2 is deleted. That covers prepare, decode, the observation envelope,
    the configured guard, the stable observation (runtime flag, `observeKubernetesConfiguration`, `configurationDigest`,
    the adapters' stable-observer parameter, and the world's `stableObserve`) and `requireWriteTarget`'s version-2
    clause. A Knative Service update is a version-1 review under the M5a guard.
    - Tests failed first: `InventoryKnativeServiceUpdateSpec` (the renamed configuration spec) asserted version 1,
      stamp-guarded churn, and F73's arm, and got version 2.
    - The landed-update stop spec's four landed-digest cases now await readiness instead of being refused, because the
      reviewed digest on the reviewed UID is this write live (U3).
    - F30's tracker entry records the removal. F73 was found first and fixed in its own commit.
  - Retires, 2026-10-06, after M6: `requireWriteTarget` guards a retire by (UID, owner, digest == reviewed), and the
    delete carries the fresh resourceVersion. A finalizer-held delete is now `KubernetesTerminating`, never an owned
    live object, so a retire is never repeated.
    - Two tests encoded the replaced exact-resourceVersion semantics and now pin the new rule. The unready-route
      collection test is refused by a changed digest, not by a moved resourceVersion. The effectful collection's
      resourceVersion race still conflicts at the raced delete, but resume now deletes once with resourceVersion 11.
      Its model checks the delete's authority (the reviewed UID, the propagation policy) and compares the
      preconditions with the live object, as the server does.
    - The five effectful-collection tests that caught the first cut's double delete pass.
    - Records `G6-retire-exact-guard`, `G6-retire-stale-precondition` and `G5-retire-deletes-terminating` fail their
      tests.
    - Session nagare asked for a pin that an object Nagare created (`nagare-inventory`/Update) and then applied
      (`nagare-inventory`/Apply) is Nagare's under both entries (E13). Test and record `E13-create-manager-foreign`.
    - The fast gate now runs its static checks first (`fastSteps`), so a style failure stops it in seconds.
    - The recovery model's world now reports a stamp (pre-approved by nagare). Without one, every Knative update fell
      back to the exact guard, and 16 fast-tier schedules (`create then good update` under `ChurnAlways`) needed a
      close (I7). With it, all 13 model tests pass. This is an interim world-side stamp in `World/Kubernetes.hs`
      `observe`: an owned object's digest, which only Nagare's writes set and which status churn and a foreign manager
      leave alone. EP-182 replaces it with rendered annotations.
    - Records `ADR26-O1-kubernetes-settle-unknown`, `G6-runtime-guard-ignores-stamp`,
      `G6-write-guard-compares-whole-state` and `F73-awaiting-readiness-ignores-digest` were regenerated for the moved
      context, and each still fails its tests.
- [x] M6 (G5), 2026-10-06: terminating objects are classified, not read as present (F74).
  - `parseObserved` maps a set deletion timestamp to `KubernetesTerminating`, and planning reports it as unavailable.
  - Settlement makes it TargetGone for a create or update, ahead of the stamp rows, and Landed for a retire on the
    reviewed UID.
  - Tests failed first: the parser test and the settlement test. Three records each fail their test.
  - Consumers outside the adapter match only Present, so they refuse a terminating object.
  - M5b's window is closed: requireWriteTarget refuses an update of a terminating target, because it is not an owned
    live object.
- [x] M7 (G7), 2026-10-06: resource quantities compare canonically (F75).
  - `canonicalQuantity` in nagare-dsl holds the rule. `mkQuantity` emits it, and `desiredFieldsMatch` compares
    resource lists (`resources.{limits,requests}`, `spec.hard`) in it.
  - Tests failed first.
  - The rule was taken from E15's trace, not from the source alone. E15 corrected two derived rows: milli rounding,
    and kept text such as `1500e0`.
  - Four records each fail their test. `G7-no-milli-rounding` first survived (a coincidence of `numerator`), and the
    case `1500u` -> `2m` now kills it.
- [ ] M8: `just mutation-check` proves every mutation record on the remote builder.
- [ ] M9 (session nagare, 2026-10-06, from nagare-deep-tier-fixes' attribution): no adapter recovery guard stays
  untested. Seven guards stopped being observed when ADR 26's close by proof landed (`1f6c1a13`, `5bb33741`), and their
  records now pass. Each pin gets a failing-first test and a fresh record. Each deletion gets a test that the remaining
  close by proof still exits.
  - Pin F57a: a stopped verify is safe to retry, and resume re-runs it to completion.
  - Pin F54: a landed, unready Knative update is LandedUnready, so resume stops at once with a reason. Keep it
    consistent with F73's awaiting arm.
  - Delete F56: a replaced target answers TargetReplaced, but the driver result and settlement are the same without it.
  - Delete F64: an absent owned target answers SafeToRetry, but it only adds a journal record.
  - Pin F59: a created StatefulSet not yet ready awaits readiness, so resume converges a slow database without a close.
  - Delete F63's StatefulSet `landedUpdate` answer. First check that settlement grants Landed for an update only
    through the M3 stamp row (stamp == D_new on the reviewed UID), and remove any digest-only Landed arm that
    bypasses it, tests first.
  - Delete F63's readiness-by-replicas check in `KubernetesConfiguration.hs` with it, unless the previous item
    adopts it.


## Surprises & Discoveries

- M5a's first cut regressed twice, and the gate caught both before commit.
  - The stamp guard accepted a missing stamp (`Nothing == Nothing`, as in the world, which reads no stamps). A landed
    update was then retried, so the fast tier's I4 reported a second write, and a landed Knative update was answered
    as safe to retry. A drift repair would do the same in production, because its stamp does not change when the write
    lands. The guard now applies only when the before stamp exists and differs from the reviewed digest; otherwise the
    exact before-state guards, as before.
  - Guarding a retire by (UID, owner, digest) re-deleted an object whose DELETE had been accepted and was held by a
    finalizer: its digest is unchanged, and only its moved resourceVersion told it apart. Five effectful-collection
    tests caught it. A retire needs the terminating state RES-4 §3 classifies ("same UID, deletion timestamp set,
    landed"), which is G5. Retires therefore keep the exact guard until M6.
- M1 needed no Deployment branch in `confirmLandedUnready`. `recover`'s landed-update path does not cover
  Deployments, so the branch would be dead code, and settlement already classes an exactly landed, unready update as
  landed through its generic arm. The Plan of Work's mention of it is superseded.
- Version 2 was hiding a false Landed (F73), found before M5b. `recover`'s awaiting-readiness arm for a version-1 or
  version-3 Knative update ignored the digest. Another write that left the object unready was therefore awaited as
  this update's, and settle maps that decision to Landed. Production updates were version 2, which the arm excludes,
  so deleting version 2 would have made this the default path. The fix requires the reviewed digest (RES-4 U3) and
  landed in its own commit ahead of M5b.


## Decision Log

- Decision: F67's configuration-digest mutation version 4 (written on 2026-10-06, kept unlanded on the local branch
  `create-batch-2-f67-v4`, commit `71e21f23`) is dropped in favour of RES-4 §5.1's stamp proof.
  Rationale: the stamp is written in the same atomic write as the spec (RES-4 U3), so it witnesses Nagare's own write
  whatever status or controller metadata does. It needs no new mutation version and no extra observation at prepare.
  The extra observation is what shifted the model's ObserveCall ordinals and made the F68 pin vacuous. It also settles
  reviews made before this change. Operator approval of RES-4, relayed by session nagare on 2026-10-06.
  Date: 2026-10-06

- Decision: the world model (`cli/nagarectl/test/Nagare/Test/World/*`) is out of this plan's scope. Its realignment,
  including routing readiness through the production parser and a `ControllerLag` fault for F69's model test, belongs
  to EP-182. Model-level tests for M1 and M2 therefore wait for EP-182; this plan pins them with unit tests.
  Date: 2026-10-06

- Decision: `D_before` is the stamp observed at prepare, recorded as `beforeStamp` (RES-4 author's recommendation (b)),
  not the base revision's declared digest and not "any stamp other than `D_new`".
  Rationale: ADR 26's no effect is "a proved, unchanged before-state", and only an observation records one. The base
  digest is an expectation that can diverge after an earlier close kept a revision over an older stamp. "Any other
  stamp" would claim landed for a drift repair that never wrote, and would read an external stamp edit as no effect.
  The stamp comes from the read prepare already makes, so there is no extra GET and no shift in the model's ordinals.
  Date: 2026-10-06

- Decision (operator, 2026-10-06): no compatibility for earlier versions anywhere in this plan. Nagare is not yet used
  anywhere, and this is its first reliable version. `beforeStamp` is required, earlier reviews need not decode, and
  disposable stores are rebuilt rather than migrated. Where this plan touches compatibility code that exists only for
  earlier reviews, such as a mutation-version branch, it removes that code and says so in the commit.
  Date: 2026-10-06


- Decision: M5 (G6) follows RES-4 §5.2.2 and rule U10, which the RES-4 author validated in experiment E13.
  - The apply stays forced.
  - Execute and preflight compare (UID, owner, live stamp == `beforeStamp`), not whole-state equality.
  - The runtime's existing managed-fields read requires no foreign non-status entry, except a reviewed takeover and
    the allowlisted controller paths, with no resourceVersion equality.
  - The forced apply carries `metadata.uid` and that read's fresh resourceVersion. A 409 for "the object has been
    modified" is re-read a bounded number of times.
  - A retire guards on (UID, owner, digest == reviewed), then deletes with the fresh resourceVersion.
  Rationale (E13): a no-force apply conflicts with Nagare's own create-time Update entry, and every API write records
  its writer per field. So "only nagare-inventory owns non-status fields" with the before stamp proves no other writer
  touched the spec or metadata, and status churn never conflicts. Options rejected: recording a configuration digest
  (the dropped v4) and keeping v1's exact guard (G6's friction).
  Date: 2026-10-06


- Decision (2026-10-06, session nagare): M5b deletes version 2 before M6. Version 2's `configurationDigest` refused a
  terminating object, and version 1 has no such check until M6 (G5). Until then, an update of a terminating Knative
  Service passes the stamp guard on this branch. The window exists only on this branch: the batch lands whole after
  M6, which refuses an update whose target is terminating, alongside a retire's Landed.

- Decision (2026-10-06, M6, with session nagare; shared with EP-181 for pods): a terminating object is the
  constructor `KubernetesTerminating uid resourceVersion owner digest`, not a field. Terminating is orthogonal to
  readiness, but nearly every consumer must treat it as "not a live member", so a forgotten case is a compile error
  rather than a missed field check. It keeps the resourceVersion, which a retire's fresh-resourceVersion guard needs,
  and the owner and digest, which settlement needs.

- Decision (2026-10-06, session nagare): once M6 makes terminating objects observable, a retire's G6 change carries
  the fresh resourceVersion without a re-read loop.
  Rationale: a retire's window shrinks from "since review" to milliseconds. Against RES-4's measured steady-state
  churn (about 30 s between status writes for CronJob and ResourceQuota, E10), a 409 is rare, and it is a no-effect
  refusal (G4) that the next plan retries. Re-verifying the digest on a re-read would need a re-parse.
  Date: 2026-10-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Terms used below:

- **Stamp.** Every object Nagare writes carries three annotations: `nagare.dev/context-id`, `nagare.dev/resource-id`
  and `nagare.dev/spec-digest`. The last is `D`, the digest of the reviewed native object. `D_before` is the stamp
  the object had at review; `D_new` is the reviewed digest, recorded in the mutation as `mutationNativeDigest`.
- **Mutation.** The private reviewed plan of one Kubernetes operation, `KubernetesMutation` in
  `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesProof.hs`. Version 1 is a plain conditional write, version 2
  a Knative Service update whose execution refreshes the resourceVersion (F30), and version 3 a version-1 update with
  a reviewed field takeover (F37).
- **Settlement.** `settleMutation` in the same module maps an operation's recovery decision and fresh observations to
  an ADR 26 class. The adapter wrapper `settle` in `cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs`
  gathers the observations.
- **Readiness.** `parseObservedWithConfiguration` in `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`
  turns a live object into `KubernetesPresent` (ready) or `KubernetesNotReady` through `observedReady`, which calls
  `deploymentAvailable`, `statefulSetReady`, `knativeReady` and others in the same file. `confirmLandedUnready` in
  `cli/nagarectl/src/Nagare/Inventory/KubernetesConfiguration.hs` proves an exactly landed but unready update.
- **Mutation record.** A diff under `cli/nagarectl/test/mutations/` that removes one guard. Applied, it must fail a
  named test. `cli/nagarectl/test/mutations/README.md` lists every record with its expected failure.

RES-4 rows used:

- §1 U1 (UIDs are never reused), U2 (resourceVersion moves on every write), U3 (the stamp lands in the same write as
  the spec), U4 (every 4xx left the object unchanged), U6 (two-phase delete), U7 (canonical quantities), U9
  (`rollout status` and generation-aware `wait`).
- §2 per-kind readiness: Deployment rollout rule; Knative Service and DomainMapping `og == gen ∧ Ready=True`.
- §3 decision tables for create, update, retire and adopt.
- §4 gaps G1, G2 and G4–G7.

ADRs that govern this work:

- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): defects are found by effect
  interpreters, and native runs only confirm.
- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md): the per-operation proof classes, close,
  and the attested exit reserved for genuinely unobservable outcomes.
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md): a live
  object that differs from the record is target gone and never bound, and stamps are trusted when bound to the UID.

Size limits: `scripts/check-haskell-architecture.py` caps a module at 1000 lines unless
`scripts/haskell-size-allowances.json` allows more, and allowances may only be lowered.
`KubernetesRuntime.hs` is at its allowance (1403). Any rule added there must be offset by moving code out, and its
allowance is then lowered to the new size. `cli/nagarectl/test/InventoryKubernetesSpec.hs` is likewise at its
allowance, so new unit tests go into a new module, `cli/nagarectl/test/InventoryKubernetesReadinessSpec.hs`.


## Plan of Work

Each milestone follows the same order, which is required: write the failing test and watch it fail, make the fix,
write the mutation record that removes the fix and check it fails the test, add or update the tracker entry in
`docs/audits/mp23-findings.md`, run `just gate-fast` niced, and commit with the `MasterPlan:`, `ExecPlan:` and
`Intention:` trailers. Each rule's decision logic lives in one function, with a comment naming the RES-4 row it relies
on.

**M1: Deployment rollout rule (G1, F70) and correction of an unready Deployment (F63's worker half).** Move the
readiness predicates out of `KubernetesRuntime.hs` into a new module,
`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesReadiness.hs`: `deploymentAvailable`, `statefulSetReady`,
`knativeReady`, `hasCondition`, `jobCompleted`, `crdEstablished` and `certificateReady`. `KubernetesRuntime` re-exports
them, so importers don't change. Lower its allowance. Then replace `deploymentAvailable`'s body with the rollout
rule: `og == gen ∧ updatedReplicas == spec.replicas ∧ status.replicas == updatedReplicas ∧ availableReplicas ==
updatedReplicas`, with `spec.replicas` defaulting to 1. `ProgressDeadlineExceeded` is not terminal, so the object
stays not ready (landed). `confirmLandedUnready` gains a Deployment branch that uses the same function. Finally,
`validateBefore` in `Adapters/Kubernetes.hs` admits an `UpdateResource` of an owned, unready Deployment. A Deployment
rollout replaces stuck pods, unlike a StatefulSet (RES-4 §2, G3). Record F70.

**M2: Knative readiness requires the observed generation (G2, F69).** `knativeReady` requires
`status.observedGeneration == metadata.generation` as well as `Ready=True`. It is used for Knative Service and
DomainMapping. `certificateReady` has the same shape, but cert-manager is outside release line (b); note it in F69
as a documented limit. Unit test and record now; the model test comes with EP-182's `ControllerLag`.

**M3: stamp proof (F67).** `KubernetesAdapterOps` gains a stamped observation, `kubernetesObserveStamped ::
ResourceId -> IO (KubernetesState, Maybe Stamp)`, with `kubernetesObserve = fmap fst` of it. Prepare reads through it
once, with no extra GET, and records the observed stamp as `beforeStamp`, a **required** field of every update
mutation. Settle reads the current stamp the same way. Settlement for an update, in order:
1. whole-state equality (resourceVersion unchanged) is no effect, as today;
2. if `beforeStamp ≠ D_new`, a live stamp equal to `beforeStamp` on the same UID is no effect, and `D_new` on the same
   UID is landed, or completed when ready;
3. if `beforeStamp == D_new` (a drift repair), the stamp proves nothing either way. Desired fields that now match after
   canonical comparison (M7) are landed or completed; anything else stays unknown, because the write may have landed and
   then drifted again identically;
4. any other or missing stamp falls to the existing target-gone (F68) and unknown rules.

The failing tests are the three F67 model schedules kept from EP-177: the database StatefulSet update at
`(Mutate 10, StatusChurn) + (StorePut 72, PutRefused)` and `(11, 84)`, and the generated Deployment update at `(5, 44)`.
Re-check their ordinals with `pinned`. Pure tests pin the repair case, the stamp rollback and a missing field, which
fails to decode.

**M4: definitive refusals (G4).** In the runtime's conditional-write fallback, map kubectl's server answers `Conflict`,
`Invalid`, `AlreadyExists`, `NotFound`, `Forbidden`, `BadRequest` and `Operation cannot be fulfilled` to
`AdapterEffectFailed (KnownNoEffect …)`. Only a missing server answer stays ambiguous.

**M5: one conditional-write discipline (G6).** Generalize version 2's execute guard to every update and retire:
require the reviewed UID, the reviewed stamp and unchanged desired fields, then write with the fresh resourceVersion.

**M6: terminating objects (G5).** `parseObservedWithConfiguration` reads `metadata.deletionTimestamp`, and
settlement follows RES-4 §3: target gone for a create or update, landed for a retire.

**M7: canonical quantities (G7).** Normalize quantities in `mkQuantity`, and compare quantities semantically in
`desiredFieldsMatch`.

**M8: `just mutation-check [rev]`.** A recipe that, for each README row, builds a detached proof commit (rev plus the
record, through `GIT_INDEX_FILE` and `git commit-tree`, with a temporary branch ref so the flake fetch can resolve
it). It runs `just test-remote <proof> <pattern>` on the builder, 4 at a time, and fails if any record no longer
fails its named test. A record whose row says it fails to compile counts as failing when its build fails. The README
gains a machine-readable test-pattern column. Register the recipe in `scripts/audit-managed-commands.py`. Gate it per
landing batch.


## Concrete Steps

Work in a worktree of this repository on the branch `create-batch-2`. From `cli/nagarectl`:

```bash
nice -n 10 cabal build nagarectl-test -v0
$(cabal list-bin nagarectl-test) -p '/rollout/'
```

Expected before M1's fix: the new rollout test fails, reporting `KubernetesPresent` for a mid-rollout Deployment.
After: it passes. Each milestone's gate, from the repository root:

```bash
nice -n 10 just gate-fast
```

Expected: `gate: fast gate green`. Run M8's recipe on the builder only, after asking session nagare:

```bash
just mutation-check HEAD
```


## Validation and Acceptance

- M1: a unit test parses a 1-replica Deployment mid-rollout and reads `KubernetesNotReady`. That Deployment has
  `generation == observedGeneration`, `Available=True`, `replicas 2`, `updatedReplicas 1` and `availableReplicas 1`.
  The same object fully rolled out reads `KubernetesPresent`, and one generation behind reads `KubernetesNotReady`.
  The pinned I1 test "an unexcused planning refusal of a reviewed step is I1 …" is replaced by a pin in which the
  Deployment correction exits. Records: `F70-deployment-available-is-ready`, `F63-deployment-correction-refused`.
- M2: Knative Service and DomainMapping objects with `Ready=True` and `observedGeneration` one behind read not ready.
  Record: `F69-knative-ready-ignores-generation`.
- M3: the three F67 schedules exit with `[[Close]]`, and a pure settlement table covers `D_new`, `D_before`, other and
  unstamped, plus the repair case and a missing `beforeStamp`, which fails to decode. Records: `F67-settle-ignores-stamp`
  (fails the pure and the model test); F66 and F68 are regenerated if their context moves.
- M4–M7: each has a unit test that fails first, and a record.
- Whole plan: `just gate-fast` green per commit, `just mutation-check` green on the landing batch, and the fast tier,
  self-test and pins unchanged or stricter.


## Idempotence and Recovery

Every step is a local code change on a branch, with no cloud or host mutation. Re-running a test or the gate is safe.
A mutation record is applied and reverted with `git apply` and `git apply -R`; a probe edit is made on a backed-up file
and restored from the backup. The dropped version-4 work stays on `create-batch-2-f67-v4` until M3 lands.


## Interfaces and Dependencies

- `Nagare.Inventory.Adapters.KubernetesProof`: `settleMutation`, `requireSameBefore` and `completionProof`, the
  mutation encoding, and the module the settlement rules live in.
- `Nagare.Inventory.Adapters.KubernetesReadiness` (new in M1): the readiness predicates, re-exported by
  `Nagare.Inventory.Adapters.KubernetesRuntime`.
- `Nagare.Inventory.KubernetesConfiguration`: `confirmLandedUnready`, `configurationDigest`.
- Prerequisite: EP-177 M3 (the recovery model, its pins and self-test). Successor: EP-182 adds the model tests for M1
  and M2. EP-181 builds the StatefulSet stuck-pod replacement on M3's settlement rules.
