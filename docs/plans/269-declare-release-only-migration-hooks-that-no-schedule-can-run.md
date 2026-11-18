---
id: 269
slug: declare-release-only-migration-hooks-that-no-schedule-can-run
title: "Declare release-only migration hooks that no schedule can run"
kind: exec-plan
created_at: 2026-11-18T13:02:46Z
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-18T13:02:46Z
---

# Declare release-only migration hooks that no schedule can run

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).

This plan implements IR-46,
[`docs/improvement-requests/declare-release-migration-hooks-without-periodic-execution.md`](../improvement-requests/declare-release-migration-hooks-without-periodic-execution.md),
requested by `mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`.


## Purpose / Big Picture

An application's migration hook is a task in the aggregate Application's `tasks` list. Today every
such task must carry a cron schedule, so the same deploy that runs the migration as a reviewed
release prerequisite also installs an active CronJob that reruns it nightly with the maintenance
database credential, outside any review. An operator can suspend that CronJob through
`nagarectl task delete --save-plan`, but the next `app deploy` review restores it unsuspended.

After this change an application declares a task as release-only. `app deploy` still runs it as a
pre-deploy hook Job before the Service and workers, and the task's CronJob is accepted with
`spec.suspend: true` and a schedule that matches no date, so nothing can launch it periodically.
Changing an accepted scheduled migration to release-only is an ordinary reviewed `app deploy` that
updates the CronJob in place, and every later deploy keeps it suspended. The operator sees it with:

```bash
kubectl -n personal get cronjob nagare-task-migrate -o jsonpath='{.spec.suspend} {.spec.schedule}'
```

```text
true 0 0 31 2 *
```

Ordinary scheduled tasks render the same bytes as before.


## Progress

- [ ] M1. A task declares its trigger in the typed model; a release-only task round-trips through
  the config program, `app render` and `--rendered`, and renders a suspended CronJob, while every
  existing scheduled golden and config digest is unchanged. Evidence: `nagare-dsl` tests.
- [ ] M2. `app deploy` accepts a release-only hook, shows it in the preview and saved review, keeps
  the hook Job and its proof identical across the scheduled-to-release-only change, and refuses a
  release-only task anywhere but the aggregate `tasks` list. Evidence: `nagarectl-test` compile and
  contract tests.
- [ ] M3. The effect interpreter shows a failed hook blocking the serving workloads, an identical
  retry keeping the first proof with one execution, zero schedule runs for the release-only
  CronJob, and an ordinary scheduled task still ticking. Evidence: `nagarectl-test` world tests.
- [ ] M4. User documentation describes the release-only trigger, and one native confirmation on a
  disposable local context shows the transition and the repeat deploy. Evidence: transcript in this
  plan.
- [ ] M5. IR-46 is marked implemented with the landed revision, and Kotei is told which revision to
  qualify.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: A release-only task keeps its CronJob, accepted suspended, instead of having no
  CronJob.
  Rationale: The hook Job is derived from the reviewed CronJob's `jobTemplate`
  (`jobFromCronJob`), and `task list`, `task run` and `task logs` find tasks by their CronJob.
  Keeping the object makes the scheduled-to-release-only change an in-place update of one plain
  object, with no retirement of a live schedule inside an application deploy, and leaves the hook
  Job bytes, its scope and its completion proof untouched. IR-46 accepts either shape.
  Date: 2026-11-18

- Decision: The typed model replaces `schedule :: Schedule` with `trigger :: TaskTrigger`
  (`OnSchedule Schedule | ReleaseOnly`).
  Rationale: A release-only task that also names a schedule cannot then be written. Adding a
  strict field would break every record literal as well, so a separate flag buys no compatibility.
  The JSON for a scheduled task is unchanged, so no accepted application's config digest moves.
  Date: 2026-11-18

- Decision: The release-only CronJob renders `schedule: "0 0 31 2 *"` (31 February) with
  `suspend: true`.
  Rationale: Kubernetes requires a schedule. A date that never occurs means an out-of-band
  unsuspend still starts nothing, and inventory status reports that edit as configuration drift.
  The consumer never writes this value; the IR's objection is to a consumer workaround. M4
  confirms the API server accepts it; if it refuses, use `0 0 1 1 *` and record that here.
  Date: 2026-11-18

- Decision: The review evidence is one application-scope override per release-only hook,
  `hookTrigger/TASK = release-only`. The per-release hook scope gains nothing.
  Rationale: Overrides already appear in the versioned deploy preview and the saved review, so no
  contract schema changes. Leaving the hook scope alone lets the change happen under an accepted
  tag without rerunning the migration.
  Date: 2026-11-18

- Decision: Only a task in the aggregate Application's `tasks` list may be release-only.
  Rationale: A task attached to a Service is never run as a hook, so a release-only one would
  never run at all.
  Date: 2026-11-18


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare deploys an application from a typed Haskell config program. `nagarectl app deploy` loads the
`Application` value, compiles it into reviewed inventory scopes (sets of native Kubernetes objects
with recorded digests), and either previews them (`--dry-run`), saves a review (`--save-plan DIR`,
applied later with `nagarectl inventory apply DIR --yes`), or applies them.

Terms used below:

- A task is `Nagare.Dsl.Task.Task` in `cli/nagare-dsl/src/Nagare/Dsl/Task.hs`. It has a required
  `schedule :: Schedule` and renders to one `batch/v1` CronJob named `nagare-task-NAME`
  (`cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs`, `cronJobValue`).
- A hook is a task in `Application.tasks` (`cli/nagare-dsl/src/Nagare/Dsl/Application.hs`). For
  each hook, `compileApplicationHooks` in
  `cli/nagarectl/src/Nagare/Inventory/Application/Tasks.hs` builds a Job from the task's reviewed
  CronJob bytes with `jobFromCronJob` (`cli/nagarectl/src/Nagare/Inventory/TaskRun.hs`), which
  copies only the CronJob's labels and `spec.jobTemplate.spec`. The Job lives in its own scope,
  named from the CronJob's resource ID and the release tag, with a completion proof (a
  `DeclaredOperation` of kind `PreDeployHook`). The Service, workers and other CronJobs are ordered
  after that proof. Retrying an accepted tag verifies the completed Job and does not rerun it.
- The application scope holds the hook's CronJob itself. `compileApplicationDeployment` in
  `cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs` compiles the base application without
  hooks, then adds the hook CronJobs with `compileTaskMembers` and the hook scopes.
- Scope overrides are the reviewed command-line inputs recorded on a scope (`tag`,
  `imageResource`, `hook/TASK` with the affected resources). `nagarectl app deploy` builds them in
  `cli/nagarectl/app/Nagare/Cli/Commands/Application.hs`. The base compile accepts a fixed list of
  keys, and the hook path strips `hook/` keys before calling it.
- The deploy preview is the versioned document `DeployPreview` built by `deployPreview` in
  `cli/nagarectl/src/Nagare/Contract/Project.hs`; it prints each scope's config digest and
  overrides.
- A rendered document is the output of `nagarectl app render`, consumed by
  `app deploy --rendered PATH`. Its JSON comes from `taskJSON` in
  `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` and is decoded by `toTask` in
  `cli/nagare-dsl/src/Nagare/Dsl/Load/Task.hs`.

Existing suspension: `cli/nagarectl/src/Nagare/Inventory/TaskLifecycle.hs` backs
`task delete --save-plan`. Its first stage sets `spec.suspend: true` on the accepted CronJob and
records `operational.task-suspend.ID` in the scope overrides. `app deploy` recompiles the scope from
the config, which has no suspension, so its next review restores the unsuspended CronJob. That is
the gap Kotei measured. `taskSuspended` in the same module reads `spec.suspend` from accepted bytes.

Updates reach the cluster through server-side apply with field manager `nagare-inventory`
(`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`), so a later review that drops
`suspend` removes the field and Kubernetes defaults it to false.

The data fence (`cli/nagarectl/src/Nagare/Inventory/DataFence/ScheduledWriter.hs`) saves a CronJob's
`suspend` value before it suspends the schedule and restores the saved value afterwards, and its
spec digest excludes `suspend`. A CronJob that starts suspended is restored to suspended.

Relevant ADRs:

- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): desired
  state is composed from typed scopes; an out-of-band `kubectl patch` is not an accepted change.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): defects
  are found by the effect interpreters; a native run only confirms. An in-place update of a plain
  object needs a unit test, not recorded API traces.
- [ADR 38](../adr/0038-a-workload-inherits-its-app-s-managed-store-unless-it-opts-out.md): a task
  with `NoManagedEnv` receives only the keys it references. IR-44's isolation stays as it is.

No ADR covers task triggers. This plan adds none; the decisions above are local to the task model.

Ceremony: this change loses no data and touches no release upgrade, IAM or guardrail path. It needs
unit tests plus one native confirmation, because a native CronJob field changes.


## Plan of Work

### M1. The typed trigger

In `cli/nagare-dsl/src/Nagare/Dsl/Task.hs`, add `TaskTrigger` and replace the `schedule` field of
`Task` with `trigger`. `scheduledTask` keeps its signature and sets `OnSchedule`. Add a preset
`releaseHook :: Text -> Text -> Text -> Either Text Task` (task name, application name, command)
that builds an image-inheriting release-only task with `managedEnv = NoManagedEnv`. `mkTask` refuses
a release-only task with no `app`.

In `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` (`taskJSON`) and
`cli/nagare-dsl/src/Nagare/Dsl/Load/Task.hs` (`JsonTask`, `toTask`): a scheduled task keeps
`"schedule": "CRON"` and emits no new key. A release-only task emits `"schedule": null` and
`"trigger": "release-only"`. The decoder accepts exactly one of the two and reports any other
combination as a `MarshalError` on `trigger`.

In `cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs` (`cronJobValue`, `taskKeyRanks`): a release-only
task renders the placeholder schedule and `suspend: true` directly after `schedule`. A scheduled
task renders no `suspend` key.

In `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` (`mkApplication`): refuse a release-only task in
`service.tasks`.

Update every `schedule = ...` record literal in tests and fixtures (`git grep -n "schedule = " cli`)
to `trigger = OnSchedule ...`. Tests in `cli/nagare-dsl/test/Spec.hs`, `LoadSpec.hs` and
`ApplicationSpec.hs`: the release-only CronJob bytes (a new golden), the JSON round trip, both
decoder refusals, the `mkApplication` refusal, and the existing scheduled goldens passing
unmodified.

### M2. Compile, review evidence and refusals

In `cli/nagarectl/app/Nagare/Cli/Commands/Application.hs`, add `hookTrigger/TASK = release-only` to
`scopeInputOverrides` for each release-only hook. In `compileApplicationDeployment`, require the set
of `hookTrigger/` keys to equal the release-only hooks, strip them with the `hook/` keys before the
base compile, and keep them on the application scope.

Refuse a release-only task in the two callers that compile tasks which are not hooks:
`compileApplicationTasks` (`.../Application/Tasks.hs`) and the Service path in
`cli/nagarectl/src/Nagare/Inventory/Application/Service.hs`. One shared check, error code
`release-only-task-is-not-a-hook`.

In `cli/nagarectl/src/Nagare/Task/Discover.hs` (`rowFromItem`), print `suspended` in the schedule
column when `spec.suspend` is true.

Tests, beside the existing hook test in `cli/nagarectl/test/AppDeploySpec.hs` ("reviewed app
deployment silently skipped a pre-deploy hook", near line 2019) and
`cli/nagarectl/test/AppDatabaseTaskSpec.hs`:

- The release-only CronJob's accepted bytes satisfy `taskSuspended == Right True`.
- With the same tag, the scheduled and release-only compiles produce an equal hook scope and equal
  hook Job bytes; only the CronJob member and the config digest of the application scope differ.
- Compiling the release-only input twice gives equal scopes (the IR's restoring review is gone).
- A hook with `NoManagedEnv` and a named maintenance key: only the hook CronJob and Job reference
  the Secret; no Service or worker bytes do.
- `deployPreview` shows `hookTrigger/TASK` in `application.overrides`
  (`cli/nagarectl/test/Nagare/Test/ContractCommands.hs`).
- Both refusals, and a missing or extra `hookTrigger/` override.

### M3. Interpreter proof

In `cli/nagarectl/test/WorkloadControlsInventorySpec.hs`, next to `resumeKeepsCompletedHook`, run
against the model world (`cli/nagarectl/test/Nagare/Test/World/`, where a CronJob has
`ScheduleTicks` semantics):

- A failing release-only hook: no Service or worker is created.
- A successful release, then an identical accepted retry: the hook ran once and the original proof
  is still the accepted one.
- Apply the scheduled fixture, then its release-only review: the CronJob is updated, not deleted or
  recreated, and reads `suspend: true`.
- Across those runs the release-only CronJob produced no scheduled run, and an ordinary scheduled
  task in the same world still ticks.

If the world ticks a suspended CronJob, fix the world from the Kubernetes rule (a suspended CronJob
starts no Job) before trusting these tests.

### M4. Documentation and native confirmation

Document the trigger in `docs/user/scheduled-tasks.md` (a "Release-only tasks" section, and correct
the statement that every task has a schedule), `docs/user/deploying-apps.md` (the hook paragraph
near line 128), `docs/user/config-reference.md` and `CHANGELOG.md`. State three things an operator
needs: `task run` still runs a release-only task as a separate reviewed action; changing a
release-only task back to a schedule that has no `startingDeadlineSeconds` may start a missed run at
once; a consumer upgrading replaces `schedule = s` with `trigger = OnSchedule s`.

Then confirm once on a disposable `mode=local` context, after completing
[`docs/runbooks/before-a-native-run.md`](../runbooks/before-a-native-run.md); see Concrete Steps.

### M5. Close the request

Set IR-46's `status` and add the landed revision to
`docs/improvement-requests/declare-release-migration-hooks-without-periodic-execution.md` and its
`log.md`. Tell Kotei the revision to qualify; Kotei owns that qualification.


## Concrete Steps

All commands run from the repository root.

Per commit:

```bash
just gate-commit
```

Focused runs while developing:

```bash
cabal test nagare-dsl-test --project-dir=cli/nagare-dsl --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /hook/' --test-show-details=direct
```

Check the test-suite names against the two `.cabal` files first; the nagarectl form is the one the
justfile uses.

Before landing:

```bash
just gate-fast
just land HEAD
```

Native confirmation (M4), on a local context built per
[`docs/user/local-development.md`](../user/local-development.md), with a fixture application whose
`tasks` list holds one hook named `migrate`. `IMAGE` is the accepted image resource ID.

```bash
# 1. Scheduled baseline.
nagarectl app deploy --file nagare/Config.hs --tag v1 --image-resource IMAGE \
  --hook-no-data-effects migrate --save-plan review-scheduled
nagarectl inventory apply review-scheduled --yes
kubectl -n personal get cronjob nagare-task-migrate -o jsonpath='{.metadata.uid} {.spec.suspend}'

# 2. Change the task to release-only, same tag.
nagarectl app render --file nagare/Config.hs --out app.rendered.json
nagarectl app deploy --rendered app.rendered.json --tag v1 --image-resource IMAGE \
  --hook-no-data-effects migrate --dry-run --contract v1
nagarectl app deploy --rendered app.rendered.json --tag v1 --image-resource IMAGE \
  --hook-no-data-effects migrate --save-plan review-release-only
nagarectl inventory apply review-release-only --yes
kubectl -n personal get cronjob nagare-task-migrate \
  -o jsonpath='{.metadata.uid} {.spec.suspend} {.spec.schedule}'

# 3. Identical deploy again.
nagarectl app deploy --rendered app.rendered.json --tag v1 --image-resource IMAGE \
  --hook-no-data-effects migrate --save-plan review-repeat
kubectl -n personal get jobs -l nagare.dev/task=migrate
```

Take the exact flag spellings from `nagarectl app deploy --help` and `nagarectl app render --help`.
Expected: step 1 prints a UID and no `suspend`; step 2's preview lists
`hookTrigger/migrate: release-only` under `application.overrides`, its review changes only the
CronJob, and the last line prints the same UID followed by `true 0 0 31 2 *`; step 3's review
changes nothing; the Job list holds exactly one Job, the `-hook-` Job from step 1.


## Validation and Acceptance

IR-46's criteria map to evidence as follows.

- AC-1: M1's golden and M2's `taskSuspended` test show the accepted native object; M4 step 2 shows
  the live cluster. No other object in the scopes carries a schedule for the hook.
- AC-2: M3's four interpreter tests, plus the unchanged scheduled goldens from M1.
- AC-3: M3's transition test and M4 steps 2 and 3. The consumer runs only `app deploy` and
  `inventory apply`.
- AC-4: M1's round trip, M2's preview and isolation tests, M4's `render` then `--rendered` run, and
  the documentation.

The plan is accepted when `just gate-fast` is green on the landed commit, the post-land full gate is
green, and the M4 transcript is recorded under Progress.


## Idempotence and Recovery

Every step is a reviewed save-then-apply and can be repeated; an identical review changes nothing.
To undo the trigger change for an application, declare `OnSchedule` again and deploy: server-side
apply removes `suspend`. A failed hook leaves the serving workloads on the previous release, as
today. The native confirmation uses a disposable local context; delete the context to clean up.


## Interfaces and Dependencies

In `cli/nagare-dsl/src/Nagare/Dsl/Task.hs`:

```haskell
-- | What starts a task. 'ReleaseOnly' is valid only for a task in an
-- Application's @tasks@ list, which @app deploy@ runs as a pre-deploy hook.
data TaskTrigger
  = OnSchedule !Schedule
  | ReleaseOnly
  deriving stock (Generic, Eq, Show)

data Task = Task
  { name :: !ServiceName
  , logicalKey :: !(Maybe LogicalKey)
  , namespace :: !Namespace
  , trigger :: !TaskTrigger
  -- remaining fields unchanged
  }

releaseHook :: Text -> Text -> Text -> Either Text Task
```

Rendered-document JSON for a release-only task:

```json
{"kind": "Task", "name": "migrate", "schedule": null, "trigger": "release-only"}
```

(other keys as today). Application-scope override: `hookTrigger/TASK` with value `release-only`.

Kotei (`mori://shinzui/kotei`) consumes the landed revision and owns its own qualification,
migration stages and recovery rehearsals. IR-44's secret isolation and IR-45
(`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-45`) are not changed by this plan.
