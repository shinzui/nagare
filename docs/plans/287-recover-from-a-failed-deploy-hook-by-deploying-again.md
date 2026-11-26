---
id: 287
slug: recover-from-a-failed-deploy-hook-by-deploying-again
title: "Recover from a failed deploy hook by deploying again"
kind: exec-plan
created_at: 2026-11-26T17:19:02Z
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-26T17:19:02Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-26T18:20:26Z
      mode: "implement"
      note: "M1 same-tag retry under a new hook attempt"
---

# Recover from a failed deploy hook by deploying again

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today an application deploy whose pre-deploy hook (for example a migrate Job) fails leaves the
context stopped. The developer must find the transaction, run `nagarectl inventory close TX
--review DIGEST`, and then deploy a new tag, because the same tag is refused. The closed hook's
scope stays accepted and never converges. Kotei hit this on the intranet on 2026-11-22 and
2026-11-25.

After this change, the recovery from a failed hook is `nagarectl app deploy` again, with the same
tag or a new one. The old release keeps serving throughout, no object is deleted, the failed Job
stays in the cluster for inspection, and once a deploy of that application converges no hook scope
of it is left accepted and unconverged.


## Progress

- [x] M1 (2026-11-26): a same-tag redeploy after a closed failed hook plans a fresh hook run and
      converges. Evidence: "the same tag deployed again after a failed hook runs the hook afresh,
      beside the failed Job" in `cli/nagarectl/test/ReleaseOnlyHookWorldSpec.hs` passes; the failed
      Job keeps its UID and the retry's scopes converge.
- [x] M2 (2026-11-26): `app deploy` ends its own application's stopped failed-hook transaction
      itself, through the existing close, and then deploys. Evidence: `ownStoppedDeploy` holds for
      the application's own stopped deploy and for a hook-only retry, and not for another
      application or a review that changes another scope (assertions in the same-tag test of
      `cli/nagarectl/test/ReleaseOnlyHookWorldSpec.hs`). The command path
      (`stoppedOwnDeploy` in `cli/nagarectl/app/Nagare/Cli/Application/Inputs.hs`, then `runInventoryClose`) has no test of its own; M4 runs it.
- [ ] M3: a converged deploy leaves no accepted, unconverged hook scope of that application; the
      failed Jobs keep their UIDs. Evidence: the BUG-10 test's last two assertions inverted, with
      its three follow-ups (corrected release, rollback, another application) still converging.
- [ ] M4: native confirmation on a disposable local context: a hook that exits non-zero, then the
      same `app deploy` with the hook fixed. Evidence: the two command transcripts and
      `inventory status --json`.
- [ ] `just mutation-check REV BASE` green, ADR 26 amended, `docs/user/deploying-apps.md` updated.


## Surprises & Discoveries

- 2026-11-26: a close cannot revert a failed hook's scopes under ADR 26, and should not. Probe in
  the model world (release v2's hook fails, then close): the hook Job is `ClassTerminalPartial`, one
  operation of the Application scope is `ClassCompleted`, and both scopes close as `KeepDesired`.
  So the fix is not a rolled-back close; it is to supersede what the close keeps.
- 2026-11-26: the same probe then deployed v2 again. Review preparation refused with
  `PrepareRefused … "Kubernetes Job has a terminal failure"`
  (`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesProof.hs:244`). A same-tag retry is
  impossible today, which is the case a database-side fix needs.


## Decision Log

- Decision: the attempt is one number for the whole deploy, chosen by
  `compileApplicationRetry` as the first attempt none of whose hook scopes is accepted and
  unconverged. M3 must keep that true after it retires a failed attempt's scope: the retired
  scope's retained Job still holds the attempt's Job name, so the choice has to count retained
  hook Jobs too, or a later same-tag deploy would compile attempt 1 again and collide with it.
  Rationale: found while testing M1; cheaper to state now than to rediscover in M3.
  Date: 2026-11-26

- Decision: keep ADR 26's close unchanged. A failed hook's transaction still closes by per-operation
  proof and keeps what had an effect.
  Rationale: the failed Job is an effect; reverting its scope would leave an owned object nobody
  accepts. The pain is the manual step and the leftover scope, and both can go without touching
  close.
  Date: 2026-11-26
- Decision: a retry of a tag whose hook scope is accepted and unconverged compiles the hook under a
  new attempt identity (scope and Job name), beside the failed Job.
  Rationale: a Job cannot be rerun in place, and replacing it would delete the failed Job and its
  logs. The operator's condition is that nothing is deleted.
  Date: 2026-11-26
- Decision: superseded hook scopes are retired with `RetainResources` in the deploy that supersedes
  them, not by a separate command.
  Rationale: recovery must be the same command again. Retirement with retention deletes nothing.
  Date: 2026-11-26
- Decision: the automatic close in M2 applies only when the active transaction's review is a deploy
  of the same application, no operation is `Unknown`, resume cannot progress, and no data fence or
  migration is active. Anything else refuses as today.
  Rationale: those are ADR 26's own admission conditions for a close; the deploy only saves the
  developer from typing it.
  Date: 2026-11-26


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

A *pre-deploy hook* is a task of an application that runs as a Kubernetes Job before the release's
workloads change. `compileApplicationHooks` in
`cli/nagarectl/src/Nagare/Inventory/Application/Tasks.hs` (lines 123-271) gives each hook its own
inventory *scope*, `Standalone/app-hook-<40 hex>`, where the hex is a digest of the hook's CronJob
resource id and the release tag, and names the Job `<cron name>-hook-<12 hex of the tag digest>`.
The hook Job depends on the CronJob, whose resource id starts with `application:<app>/`; that is
the only stored link from a hook scope to its application.

`runAppDeploy` in `cli/nagarectl/app/Nagare/Cli/Commands/Application.hs` (around lines 502-590)
compiles the application scope and the hook scopes, composes them with `ReplaceScope` against the
accepted snapshot, and plans with no lifecycle decisions
(`cli/nagarectl/src/Nagare/Inventory/Command.hs:569`).

A scope is *accepted* at the revision a review admitted and *converged* at the revision whose
operations all completed. [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md)
decides how a stopped transaction ends: `inventory close` classes every operation from proof and
keeps a scope's desired revision when any operation on it had an effect. A failed hook Job is such
an effect, so the hook scope stays accepted and unconverged.
[Plan 270](270-plan-application-reviews-after-a-failed-release-hook-is-closed.md) (BUG-10,
`docs/bug-reports/closing-a-failed-release-hook-blocks-application-reviews.md`) made later reviews
ignore that scope and kept it on purpose.

Retiring a scope with retention already exists: `RetireScope owner RetainResources`
(`cli/nagare-dsl/src/Nagare/Resource/Inventory.hs:312`) with the decider `decideRetirement`
(`cli/nagarectl/src/Nagare/Inventory/Lifecycle.hs:132`). The closest precedent for mixing it with
`ReplaceScope` in one review is `cli/nagarectl/app/Nagare/Cli/Data/ScheduledPrune.hs:365-379`.

The release harness no longer refuses on such scopes (commit `78494884`), so this plan is about the
developer's recovery, not about platform releases.

The model world for hooks is `cli/nagarectl/test/ReleaseOnlyHookWorldSpec.hs`; its test
"a closed failed hook does not block later reviews (BUG-10)" asserts today's leftover scope and will
change in M3.


## Plan of Work

M1, the attempt identity. In `runAppDeploy`, before compiling, find the hook scopes this deploy
would produce that are already accepted and not converged at their accepted revision. For each,
compile the hook with an attempt number (the count of such earlier attempts plus one) mixed into
the scope digest and the Job name in `compileApplicationHooks`. A first attempt keeps today's names
exactly, so no accepted context changes. Test: the probe above, turned into a test that converges.

M2, the deploy ends its own stop. In `runAppDeploy`, when the store's head has an active
transaction, load its review. If every changed scope is this application's scope or one of its
hook scopes and ADR 26's close conditions hold, call the existing `closeTransaction`
(`cli/nagarectl/src/Nagare/Inventory/Execute/Close.hs`) and continue; otherwise refuse as today.

M3, no leftover scope. Add `RetireScope old RetainResources` for each accepted, unconverged hook
scope of this application that the deploy does not replace, and plan the deploy with
`decideRetirement` instead of no decisions, on the direct path and both `--save-plan` paths.
Check in the model world that a retained failed Job does not block the three follow-up reviews; if
a retained member that depends on the application's data refuses a later review, stop and record it
here before choosing another route.

M4, native confirmation, on a disposable local context only (`mode=local`); no cloud context.


## Concrete Steps

From `cli/nagarectl` in the working tree:

```bash
cabal build -v1 nagarectl-test
"$(cabal list-bin -v0 nagarectl-test)" -p '/release-only hook in the model world/'
```

Per commit, from the repository root: `just gate-commit`. Before landing:
`just mutation-check REV BASE`, then `just gate-fast` and `just land REV`.


## Validation and Acceptance

In the model world: release v1 converges; v2's hook fails; with no close call, deploying v2 again
with the hook passing converges; the failed Job is still present with its UID; `historyAccepted`
and `historyConverged` agree on every scope of the application; a deploy of another application in
between is unaffected. A stopped transaction of another application, or one with an `Unknown`
operation, still refuses the deploy with today's message.


## Idempotence and Recovery

Every step is a reviewed transaction; a stop in the retry is recovered the same way. Nothing in
this plan deletes a Kubernetes object or touches an application database. A context that already
holds leftover hook scopes needs no repair: the next converged deploy of that application retires
them.


## Interfaces and Dependencies

`Nagare.Inventory.Application.Tasks.compileApplicationHooks` gains the attempt input.
`Nagare.Inventory.Execute.closeTransaction`, `Nagare.Resource.Inventory.RetireScope` and
`Nagare.Inventory.Lifecycle.decideRetirement` are used as they are.
