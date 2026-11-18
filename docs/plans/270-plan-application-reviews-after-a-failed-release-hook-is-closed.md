---
id: 270
slug: plan-application-reviews-after-a-failed-release-hook-is-closed
title: "Plan application reviews after a failed release hook is closed"
kind: exec-plan
created_at: 2026-11-18T22:05:46Z
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-18T22:05:46Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-18T22:18:57Z
      mode: "implement"
      note: "M1 and M2 implemented: regression test and PreDeployHook selection by its own Job"
---

# Plan application reviews after a failed release hook is closed

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).

This plan fixes BUG-10,
[`docs/bug-reports/closing-a-failed-release-hook-blocks-application-reviews.md`](../bug-reports/closing-a-failed-release-hook-blocks-application-reviews.md),
reported from `mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application` and
tracked by the consumer as `mori://shinzui/kotei/okf/friction-log/concepts/FRIC-80`.


## Purpose / Big Picture

An application's migration hook runs as a Kubernetes Job before each release's Service and workers
start. When that Job fails, the operator closes the stopped transaction with `nagarectl inventory
close` and the previous release keeps serving. In v0.23.0 the context is then unusable for
applications: every later `app deploy --save-plan` whose hook declares an effect on the same
database refuses with

```text
PrepareRefused op-…: Kubernetes declared operation must name exactly one bound Job
```

This holds for a corrected release, for a rollback to the previous image, and for a different
application. The only exits are outside review.

After this change, once the failed release is closed, the operator can save and apply a review for
a corrected release under a new tag, for the previous release's image, or for another application.
None of those reviews contains an operation of the closed release. The failed Job and its
transaction stay in history, and the previous release's converged revision is unchanged until a
successor converges. The proof is a model-world test that fails with the exact refusal before the
fix and passes after it.


## Progress

- [x] M1. A model-world regression test reproduces BUG-10: after a failed hook with a declared
  effect is closed, saving a review for a corrected tag, for the prior tag and for a second hook
  owner each fails with `PrepareRefused … must name exactly one bound Job`. Evidence: the failing
  test output, recorded here.
  2026-11-18: "a closed failed hook does not block later reviews (BUG-10)" in
  `cli/nagarectl/test/ReleaseOnlyHookWorldSpec.hs`, run against the unchanged planner with each
  follow-up alone (`v3`, `v1` again, application `other` at `v1`), failed all three times with
  the closed `v2` hook's operation:

  ```text
  PrepareRefused (OperationId "op-e0c95448efe920350ae30a5d") "Kubernetes declared operation must name exactly one bound Job" :| []
  ```
- [x] M2. The planner no longer seeds a closed release's hook operation into a review that did not
  select that hook's Job. The M1 test passes for all three follow-up reviews, the failed Job is
  retained, the prior release's converged revision is unchanged until the successor converges, and
  `just gate-commit` is green.
  2026-11-18: `scopeDeclared` in `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs` selects a
  `PreDeployHook` operation only through a selected member its own scope owns. The group reports
  five passing tests; the new one asserts converged `v3`, `v1` and `other` reviews with no
  operation on a `v2` hook member, the `v2` Job live with its uid, the `v2` hook scope accepted
  and unconverged, and the Application's converged revision unchanged from close until `v3`.
  `just gate-commit` green (44 s); full `cabal test nagarectl-test` green (all 10 shards).
- [ ] M3. The fix is landed (`just gate-fast`, `just land`), BUG-10 is marked `fixed` with the
  landed revision, and the revision Kotei must qualify is recorded in the bug report and reported
  to the operator.


## Surprises & Discoveries

- A Job the fake API server fails stops its transaction as `StoppedAmbiguous` ("Kubernetes Job did
  not prove readiness"), not `StoppedFailed`, as in Kotei's report ("Apply returned ambiguous").
  The test accepts either, and close handles both.
- `just gate-commit` selected no test for this group: the script turned `(` and `)` into `.`,
  but a tasty `/…/` pattern is a substring match, not a regular expression. Fixed in the same
  commit (`scripts/gate-commit.sh`); FRIC-18.


## Decision Log

- Decision: Fix the planner's selection of declared operations, not the adapter and not
  `inventory close`.
  Rationale: Close behaved as ADR 26 specifies: the failed Job is an effect, so its scope keeps
  its desired revision. The adapter's refusal is also correct: it was handed an operation whose
  Job the review never bound. The defect is that the planner put that operation into an unrelated
  review. BUG-10's expected behaviour says a new review must not bind the previous hook.
  Date: 2026-11-18

- Decision: A pre-deploy hook operation is planned only when the review selects a member that the
  operation's own scope owns (its Job). An affected member owned by another scope, such as the
  database volume, no longer selects it.
  Rationale: The affected data is shared by every release's hook, so selecting by it re-plans
  every unproven hook of every earlier release. The Job is unique to one release. The rule is
  limited to the `PreDeployHook` kind because other operation kinds were not audited for
  cross-scope selection; widening it is a separate change.
  Date: 2026-11-18

- Decision: Retrying the failed release under its own tag, and retiring the closed hook's scope,
  are out of scope.
  Rationale: BUG-10 asks for a corrected release with a new hook identity, a rollback and a fresh
  application. A Job's spec is immutable and the planner already answers a changed Job under one
  identity with `job-revision-required`. The closed hook scope stays accepted and unconverged,
  which is what "its hook effects stay unaccepted" requires. If the M1 test or the full suite
  shows that this leftover scope blocks another command, record it in the deferral ledger with the
  operator's approval instead of widening this plan.
  Date: 2026-11-18

- Decision: The second hook owner is the same fixture compiled as application `other`, with its
  service, worker and task renamed, not a hand-built standalone scope.
  Rationale: It takes a few lines in the test's `releaseOf` helper and goes through
  `compileApplicationDeployment`, which is the path Kotei's fresh application took.
  Date: 2026-11-18

- Decision: Shorten the `job-revision-required` refusal in `Changes.hs` to one line to keep the
  file inside its 1000-line allowance.
  Rationale: The plan forbids raising the allowance; that refusal sits on the same hook path and
  matches its one-line neighbours.
  Date: 2026-11-18

- Decision: No native run in this plan.
  Rationale: The change is planner logic with no new native behaviour, so the repository rule
  (CLAUDE.md, "Size the ceremony to the risk") asks for a unit test only. The native confirmation
  is Kotei rerunning its Plan 135 rehearsal on its disposable `kotei-mp26` context against the
  landed revision.
  Date: 2026-11-18


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare records what it manages in an inventory: a set of scopes, each a named group of resources
with a desired revision (what the last accepted review declared) and a converged revision (the last
one that was fully applied). A review is a saved, digest-addressed plan; `inventory apply` executes
it as a transaction of planned operations. All of this is in `cli/nagarectl/src/Nagare/Inventory/`.

An application deploy compiles one application scope plus one scope per pre-deploy hook per
release tag. `compileApplicationHooks` in
`cli/nagarectl/src/Nagare/Inventory/Application/Tasks.hs` builds the hook scope
`standalone:app-hook-<digest of CronJob id and tag>`. It holds one member, the hook Job, and one
declared operation of kind `PreDeployHook` whose `affects` list is the Job followed by the
resources the operator declared the hook changes (`scopeHookEffects`, passed on the command line
as the `hook/<task>` override; Kotei names its PostgreSQL volume there). A declared operation is
a reviewed action that is not a plain create or update of one object; the planner turns it into a
`RunDeclaredOperation` planned operation.

The planner is `buildOperations` in `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs`. Its
local function `scopeDeclared` walks every scope of the composed inventory, not only the scopes
the review replaces, and keeps each declared operation for which
`any (`Set.member` selectedIds) affects` holds and `operationIsProven` does not. `selectedIds` is
`affectedManagedIds` in `cli/nagarectl/src/Nagare/Inventory/Plan/Observation.hs`; its
`declaredTargets` part adds every resource affected by an operation of a replaced scope. An
operation is proven when its scope's accepted revision is also its converged revision.

That combination is the defect. Follow the report's sequence. Release 2's hook Job fails. Close
classifies the Job as terminal partial, an effect, so by
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) decision 2 the hook
scope keeps its desired revision and stays unconverged; its operation is therefore never proven.
The next review replaces a new hook scope whose operation affects the same database volume, so the
volume enters `selectedIds`. `scopeDeclared` then matches release 2's operation through the
volume and plans it again. The review binds native bytes only for what it selected, so release
2's Job has none, and `kubernetesOperationResource` in
`cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs` finds no bound Job among the
operation's resources and refuses at prepare. A rollback and a second application fail the same
way because their hooks name the same volume. A hook with no declared effect, and a review with
no hook such as a Secret sync, never select the volume, which is why those still converged in the
report.

The existing test harness for this path is `cli/nagarectl/test/ReleaseOnlyHookWorldSpec.hs`
(written by [plan 269](269-declare-release-only-migration-hooks-that-no-schedule-can-run.md)).
Its `deploy` function compiles an application, plans, saves and applies a review with the
production Kubernetes adapter over a fake API server (the "model world",
`cli/nagarectl/test/Nagare/Test/World/`). Its `failedHookBlocksServing` test already makes a hook
Job fail by registering the Job's content digest with outcome `Failed`. The application fixture
is `input` and `scopedApp` in `cli/nagarectl/test/ManagedEnvScopeSpec.hs`; it fixes the tag at
`v1` and gives every hook an empty effect list, which is why no existing test reaches the defect.
`closeTransaction` in `cli/nagarectl/src/Nagare/Inventory/Execute/Close.hs` is the close entry
point; `cli/nagarectl/test/InventoryApplicationUpdateRecoverySpec.hs` shows a test calling it
with `CloseInput transaction reviewDigest False Nothing`.

Relevant ADRs: [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md), which
this plan leaves as it is, and
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), under
which the defect is reproduced in the model world first. This plan changes no architecture
decision, so no ADR is expected.


## Plan of Work

### M1. Reproduce the refusal in the model world

Extend `cli/nagarectl/test/ReleaseOnlyHookWorldSpec.hs` with one test, "a closed failed hook does
not block later reviews". It needs three small fixture changes.

First, the hook must declare an effect on a managed member that exists in the world. Add a
standalone scope holding one plain Kubernetes object (a PersistentVolumeClaim, or a ConfigMap if
the fake API server models the claim poorly) and deploy it first so it is accepted and converged.
Pass its resource id in `scopeHookEffects` and in the matching `hook/<task>` override, joined
exactly as `compileApplicationDeployment` checks in
`cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs` ("every hook needs an exact reviewed
affected-resource set").

Second, the fixture must compile under more than one tag. Give the test a helper that takes
`input app` and replaces the tag everywhere `input` sets it: `imageTag`, `effectiveTag`,
`taggedAppImage`, the `tag` override and the `StaticRelease` in `scopeRelease`.

Third, `deploy` must return what close needs. Split it so the test can obtain the saved review's
digest and the stopped transaction's id, then call `closeTransaction` with a registry built from
the same world adapter.

The test then runs: deploy tag `v1` and assert it converged; record the application scope's
converged revision; mark the `v2` hook Job's digest `Failed`, deploy `v2` and assert it did not
converge; close it and assert the close record is returned and no transaction is active. Then
attempt three follow-ups, each from a fresh review: tag `v3` (the corrected release), tag `v1`
again (the rollback), and a second hook owner that affects the same member. For the second owner,
compile the fixture under another application name if `input` allows it in a few lines;
otherwise build one standalone scope by hand with a Job member and a `PreDeployHook` operation
whose `affects` is that Job followed by the shared member. The planner path is the same.

At this milestone the three follow-ups fail at `prepareReview` with `PrepareRefused` naming one
operation id and the adapter message. Record that output under Progress. Do not commit a red
test alone; M1 and M2 land in one commit.

### M2. Plan a hook only for a review that selects its Job

In `scopeDeclared` (`cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs`), for an operation of
kind `PreDeployHook`, require a selected affected member whose owner is the scope being walked.
`scopeDeclared` receives the scope declaration, and `desiredDeclarations` gives each affected
resource's `owner`. Leave every other operation kind's selection as it is. Keep the change
inside `scopeDeclared` so `declaredSeeds`, and through it `hookJobIds` and the
`operation-revision-required` check, see the same narrowed set.

Then complete the test's assertions. Each follow-up review prepares and converges, and no
operation in its proposal names a resource of the closed `v2` hook scope. The `v2` Job is still
live in the world with its original uid. The `v2` hook scope is still accepted and not converged.
The application scope's converged revision equals the recorded `v1` revision after close and
changes only when a follow-up converges.

`Changes.hs` is under the architecture check's size ratchet
(`scripts/check-haskell-architecture.py`); if the edit raises the file past its allowance, shorten
nearby code instead of raising the allowance.

### M3. Land and close the report

Commit with the `ExecPlan:` trailer, run `just gate-fast` on the committed revision and `just
land`. In `docs/bug-reports/closing-a-failed-release-hook-blocks-application-reviews.md` set
`status: fixed` and add a `resolution` naming the landed commit and the regression test, in the
form BUG-9 uses (`docs/bug-reports/auth-image-change-strands-the-previous-migration-job.md`); add
`fixedVersion` only once a release carries the fix. Add the entry to
`docs/bug-reports/log.md`. Report the landed revision to the operator as the one Kotei qualifies
for `mori://shinzui/kotei/okf/friction-log/concepts/FRIC-80`. Whether to cut a patch release for
it is the operator's decision and is not part of this plan.


## Concrete Steps

All commands run from the repository root.

Run the one test group while developing:

```bash
cabal test nagarectl-test --test-options='-p "/release-only hook in the model world/"'
```

Before the fix, the new test fails with a line of this shape (the operation id differs):

```text
PrepareRefused op-…: Kubernetes declared operation must name exactly one bound Job
```

After the fix the group reports five passing tests. Then, per commit and per landing:

```bash
just gate-commit
git commit   # Conventional Commit, e.g. fix(inventory): plan a hook only for a review that selects its Job
just gate-fast
just land
```

Check each command's exit status, not its printed summary.


## Validation and Acceptance

The plan is accepted when the new model-world test passes and would fail without the `Changes.hs`
edit. Prove the second half once by reverting only that edit and seeing the refusal above. The
test must show, in one world: a converged `v1`; a failed and closed `v2`; converged reviews for
`v3`, for `v1` again, and for a second hook owner affecting the same member; no follow-up
operation on a `v2` hook resource; the `v2` Job retained; and the application's converged
revision unchanged between close and the first converging follow-up.

The existing four tests of the group, and the rest of `nagarectl-test` under `just gate-commit`,
must stay green. In particular `retryKeepsProof` shows that a converged hook is still not re-run
and `failedHookBlocksServing` that a failed hook still blocks serving.

Kotei's rerun of its rehearsal against the landed revision is the native confirmation. It is
reported to Kotei, not awaited by this plan.


## Idempotence and Recovery

Every step is a source edit, a test run or a gate, and can be repeated. Nothing in this plan
touches a cluster, a cloud project or a real inventory store; the test uses an in-memory store
and the fake API server. If `just land` reports a red full gate afterwards, the next land is
blocked until a gated fix lands; fix forward on the same plan.


## Interfaces and Dependencies

No public type, command, wire format or review document changes. The behaviour change is confined
to which `DeclaredOperation`s `Nagare.Inventory.Plan.Changes.buildOperations` seeds for the
`PreDeployHook` kind. A context that already holds a closed failed hook scope, such as Kotei's
`kotei-mp26`, needs no repair: its next review simply omits the old operation.
