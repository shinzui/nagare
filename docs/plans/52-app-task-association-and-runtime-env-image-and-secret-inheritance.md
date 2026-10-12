---
id: 52
slug: app-task-association-and-runtime-env-image-and-secret-inheritance
title: "App-task association and runtime env image and secret inheritance"
kind: exec-plan
created_at: 2026-06-10T16:50:01Z
intention: "intention_01kts6qyg4ezsbj500ksjr90r1"
master_plan: "docs/masterplans/10-scheduled-tasks-for-nagare.md"
---

# App-task association and runtime env image and secret inheritance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [52-app-task-association-and-runtime-env-image-and-secret-inheritance.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/52-app-task-association-and-runtime-env-image-and-secret-inheritance.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare is a small single-node "platform as a service" (PaaS) written in Haskell. A user
describes what they want to run — a web app, a static site, a managed database, and (after
the parent initiative) a scheduled task — by writing a typed Haskell file `Config.hs` that
prints a JSON value. A command-line tool named `nagarectl` reads that JSON and turns it into
Kubernetes YAML, which it applies to one cluster.

The parent MasterPlan (`docs/masterplans/10-scheduled-tasks-for-nagare.md`) adds **scheduled
tasks**: a named unit of work (a command, a cron schedule, an image) that Nagare renders into
a Kubernetes **CronJob** (an object that creates a **Job** — a run-to-completion pod — on a
schedule). A sibling plan,
`docs/plans/50-typed-task-model-and-cronjob-job-renderer.md` (EP-50), already defines the
typed `Task` value, its JSON round-trip, and a pure renderer that turns a `Task` into a
deterministic CronJob. Another sibling,
`docs/plans/51-nagarectl-task-lifecycle-commands-and-deploy-time-provisioning.md` (EP-51),
adds the `nagarectl task list/run/logs/delete` commands and applies declared CronJobs at
deploy time.

This plan, **EP-52**, delivers the one capability the others deliberately left as a hole: a
task that **runs in an app's world**. After this change, a user who has an app named `notes`
can write, in `notes`'s `nagare/Config.hs`, a task that says "every night at 03:00, run
`python manage.py cleanup`, inheriting `notes`'s image and `notes`'s runtime environment and
secrets" — *without* re-declaring the image tag, the database connection strings, or any of
the secrets the app already has. When they run `nagarectl deploy`, the rendered CronJob's
container uses the *exact same* `image:tag` the app's own pods are getting this deploy, and
gains the *exact same* runtime configuration and secrets the app's container sees. The task's
pods can therefore connect to the same database, read the same feature flags, and run the same
code as the live app, because they literally share the app's image and the app's managed
configuration.

Concretely, "inherit the app's world" means three deploy-time substitutions into the task's
Job template:

1. **The image.** When the task carries no explicit image (`taskImage = Nothing` in the typed
   model), the rendered container's `image:` is set to the app's resolved `image:tag` — the
   same tag the app's Knative Service gets this run (a timestamp like `20260602-120000`,
   computed at deploy time and not knowable when the config is written).
2. **The runtime environment and secrets.** The container gains an `envFrom:` block referencing
   the app's managed runtime ConfigMap `nagare-env-<app>-runtime` and managed runtime Secret
   `nagare-secret-<app>-runtime` (each `optional: true`), exactly as the app's own container
   references them. These two Kubernetes objects are where Nagare stores an app's runtime
   configuration (the ConfigMap, for non-secret values) and runtime secrets (the Secret); a
   container with `envFrom` against them receives every key as an environment variable.
3. **Predefined task variables.** Every task run also receives a small set of `NAGARE_*`
   identity variables that describe the run itself — at minimum `NAGARE_TASK_NAME` and a
   per-run `NAGARE_RUN_ID` — so task code can log which task and which run it is, mirroring how
   apps receive `NAGARE_SERVICE_NAME`/`NAGARE_RELEASE_ID` today.

You can see it working without a live cluster. After this plan, deploying an app whose
`Config.hs` declares an inheriting task and passing `--dry-run` (which prints the rendered
manifests instead of applying them) shows, under a `--- Task CronJob manifest ---` banner, a
CronJob whose container carries the resolved `image: gcr.io/myproject/notes:20260602-120000`,
the two `envFrom` references, the `nagare.dev/app: notes` label (so EP-51's `task list notes`
finds it), and the predefined `NAGARE_TASK_NAME`/`NAGARE_RUN_ID` env entries. The unit tests
prove the pure image-resolution helper offline by passing the resolved tag in directly (the
same way the managed-database backup feature passes a `now :: UTCTime` in so its rendering is
testable without a cluster).

This plan **owns** the parent MasterPlan's Integration Point IP5 (the app↔task association and
inheritance contract). It **hard-depends** on EP-50 (it consumes EP-50's `Task` type, the
`taskApp`/`taskImage` fields, and the `taskJobSpecValue`/`renderTask` renderer) and
**soft-depends** on EP-51 (the most natural way to exercise an inheriting task end-to-end is
through EP-51's `task` CLI, but this plan is fully implementable and testable through the
renderer and `nagarectl deploy --dry-run` alone).

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone M1 — typed association, load-time invariants, JSON round-trip (pure DSL):

- [x] Add `tasks :: ![Task]` to the `Deployment` record in
      `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` (default `[]`), via a
      `Nagare/Dsl/Task.hs-boot` to break the Types↔Task import cycle (see Surprises).
- [x] Serialize `tasks` in `deploymentJSON` as a `taskJSON` array, name-sorted (`sortOn
      taskName`) for determinism.
- [x] Decode `tasks` in `Load.hs` (`JsonDeployment` gains `jdTasks :: [JsonTask]`;
      `toDeployment` runs `toTask` per element) and add the two deploy-level cross-task
      invariants (no duplicate task name; a task's `taskApp`, when present, names the
      enclosing app).
- [x] EP-50's per-task invariant (`taskImage = Nothing` requires `taskApp = Just _`) is
      re-run by `mapM toTask`; added deploy-level round-trip + two negative tests.
- [x] `cabal build` and `cabal test nagare-dsl-test` pass (235 tests); no golden changed.

Milestone M2 — deploy-time image/env/label/predefined-var resolution (CLI):

- [x] Create `cli/nagarectl/src/Nagare/Task/Resolve.hs` with pure `resolveTaskImage`,
      `predefinedTaskEnv`, and `renderResolvedTask`; register it in `nagarectl.cabal`.
- [x] Wire task resolution into `runDeploy`: per declared task resolve the inherited image
      tag (or pin an explicit image to `effTag`), merge the predefined `NAGARE_*` env, render,
      and apply alongside the Service/PVCs/databases; print under a banner in `--dry-run`.
      (This also satisfies EP-51's deferred M3 — a single render-and-apply call site.)
- [x] Offline unit tests for `resolveTaskImage`, `predefinedTaskEnv`, render demonstration,
      and the golden `cli/nagarectl/test/golden/task-app-resolved.cronjob.yaml` (resolved tag,
      two `envFrom` refs, `nagare.dev/app` label, predefined vars incl. `NAGARE_RUN_ID`).
- [x] `cabal test nagarectl-test` passes (226 tests); captured the `deploy --dry-run`
      transcript showing the resolved CronJob.

Milestone M3 — documented inherited-variable contract + end-to-end dry run:

- [x] The inherited-variable contract table and precedence rule are filled in Interfaces and
      Dependencies (consumed by EP-53).
- [x] Captured the end-to-end `nagarectl deploy --dry-run` of the app-with-task fixture
      producing the correct CronJob; the live (non-dry-run) on-VM provisioning check is
      documented and deferred (EP-48 precedent).

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **A module import cycle the plan dismissed is real; resolved with an `.hs-boot`.** The plan
  asserted "no cycle exists because `Nagare.Dsl.Task` imports only leaf newtypes." It does not:
  `Nagare.Dsl.Task` imports `Nagare.Dsl.Types` (for `ServiceName`, `Namespace`, `ImageRef`,
  `Resources`, `ScopedEnvVar`, `EnvName`), so adding `import Nagare.Dsl.Task (Task)` to
  `Types.hs` cycles. (The `databases :: [DatabaseName]` precedent avoids this because
  `DatabaseName` is a leaf newtype defined *in* `Types.hs`, not imported.) Fixed with
  `cli/nagare-dsl/src/Nagare/Dsl/Task.hs-boot` exporting `Task` abstractly plus `instance Eq
  Task` / `instance Show Task` (the instances `Deployment`'s `deriving stock (Eq, Show)` needs;
  `Generic Deployment` treats `Task` opaquely, so no `Generic Task` boot instance is required).
  `Types.hs` uses `import {-# SOURCE #-} Nagare.Dsl.Task (Task)`. Builds cleanly.
- **`renderResolvedTask` uses in-memory `Value` patching, not YAML post-processing (plan
  option 1) nor envelope duplication (option 2).** Instead, EP-50's renderer was extended to
  export `cronJobValue :: Task -> Value` and `encodeCronJob :: Value -> ByteString`. EP-52
  builds `encodeCronJob (patchContainer inject (cronJobValue (withPredef t)))`, where
  `patchContainer` walks the fixed path `spec.jobTemplate.spec.template.spec.containers[0]` and
  `inject` sets `image` and appends the `NAGARE_RUN_ID` field-ref env entry. This keeps EP-50
  the single owner of the manifest shape *and* avoids a decode/re-encode round-trip — the
  cleanest of the three. (Recorded as the resolution of the plan's "pick one and record it"
  note. EP-50's two new exports are additive.)
- **`Data.Aeson.KeyMap` exports neither `alter` nor `adjust`** (only `alterF`, `insert`,
  `lookup`, `delete`). `patchContainer`/`injectImageAndRunId` implement both via
  `lookup`+`insert`.
- **The plan's `tk & #env %~ …` setter is wrong — `Task`'s field is `taskEnv`, so the label is
  `#taskEnv`.** `runDeploy` uses `tk & #taskEnv %~ mergeGenerated (predefinedTaskEnv tk)`; the
  offline tests use the equivalent record update `tk {taskEnv = mergeGenerated (predefinedTaskEnv
  tk) (taskEnv tk)}` to avoid pulling generic-lens labels into the test module.
- **`NAGARE_RUN_ID` renders at the *end* of the container `env:` list, not name-sorted.** The
  three predefined literals (`NAGARE_APP`, `NAGARE_NAMESPACE`, `NAGARE_TASK_NAME`) are
  name-sorted by EP-50's renderer (they live in the `ScopedEnvVar` map), then `NAGARE_RUN_ID`
  (a Downward-API field-ref, which the typed env map cannot represent) is appended after. The
  plan's illustrative golden showed it name-sorted; the actual golden
  (`cli/nagarectl/test/golden/task-app-resolved.cronjob.yaml`) pins the append-at-end order. All
  the load-bearing facts (resolved image, both `envFrom`, the label, every `NAGARE_*` entry, the
  `fieldRef` to `metadata.name`) are present and asserted.
- **EP-52 implements EP-51's deferred M3.** EP-51 left deploy-time provisioning to whichever
  plan owns the `Deployment.tasks` field; that is EP-52. `runDeploy` now has the single
  render-and-apply call site, using `renderResolvedTask` (the resolved values), so there is no
  duplicate provisioning loop.

## Decision Log

Record every decision made while working on the plan.

- Decision: The pure renderer (EP-50's `Nagare.Dsl.Task.Render`) emits the *structure* of
  inheritance (the `envFrom` block, the `nagare.dev/app` label, and — for an inheriting task —
  an *absent* `image:` key); EP-52's deploy-time code fills the one *value* the renderer cannot
  know: the app's resolved `image:tag`. The division is: EP-50 owns `renderTask :: Task ->
  ByteString` and `taskJobSpecValue :: Task -> Value` (both pure, taking only the typed model);
  EP-52 owns `renderResolvedTask :: Task -> Text -> ByteString` (a thin wrapper that, when the
  task inherits, injects the resolved `image:tag` into the container before encoding).
  Rationale: image-tag resolution is only knowable at deploy time in the CLI package (it is a
  timestamp computed this run, or `--tag`), exactly the concern the MasterPlan isolated into
  EP-52. Keeping EP-50 pure and golden-testable while EP-52 owns the value substitution mirrors
  MasterPlan 9, where EP-44's renderer was pure and EP-46 injected the deploy-time database
  connection env. The two plans cannot double-render or drift because EP-50 never emits an
  `image:` for an inheriting task (it has nothing to put there) and EP-52 never re-emits the
  envFrom/labels (it reuses EP-50's rendered structure and only patches the image).
  Date: 2026-06-10

- Decision: Add `tasks :: ![Task]` to the `Deployment` record (co-location), in addition to
  the `taskApp :: Maybe ServiceName` field EP-50 already carries on `Task`.
  Rationale: `Deployment.databases :: [DatabaseName]` is the established model for an app
  declaring the resources it owns, and the parent MasterPlan's Vision describes a user writing
  the task "in the `notes` app's image, with the `notes` app's runtime environment" in the same
  config they already use for the app. Co-locating an app's tasks under `Deployment.tasks` lets
  `nagarectl deploy` provision them in the same pass that resolves the app's image tag (so the
  inherited tag is exactly the tag the app is getting this run) without a separate task config
  or a second deploy command. `taskApp` on the `Task` still carries the *association* (it drives
  the `nagare.dev/app` label and the envFrom names); `Deployment.tasks` carries the
  *co-location* (which tasks deploy with which app). A standalone task config (a `Task` emitted
  on its own via EP-50's `emitTask`) remains valid for tasks deployed independently; this plan
  only adds the app-co-located path.
  Date: 2026-06-10

- Decision: Inherited env precedence is exactly Kubernetes' native `envFrom`-before-`env` rule.
  Values from the app's managed ConfigMap/Secret (via `envFrom`) are applied first; the task's
  own inline `env:` entries and the predefined `NAGARE_*` task variables (rendered inline) are
  applied after and therefore win on a name collision.
  Rationale: Kubernetes resolves a container's environment by first expanding every `envFrom`
  source in order, then applying each inline `env` entry, with later sources overriding earlier
  ones. The app renderer's own container relies on this (see the comment on `envFromField` in
  `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`: "Kubernetes applies envFrom before the inline env
  list, so inline DSL env … overrides managed env of the same key"). Reusing the identical rule
  for tasks means an inheriting task behaves like a thin wrapper around the app's container —
  the same inherited values, with the task free to override any single variable inline — and we
  invent no second precedence mechanism. The predefined `NAGARE_TASK_NAME`/`NAGARE_RUN_ID` use a
  reserved `NAGARE_*` prefix that cannot collide with an app's runtime keys, so they always take
  effect.
  Date: 2026-06-10

- Decision: The predefined task variables are `NAGARE_TASK_NAME`, `NAGARE_RUN_ID`, `NAGARE_APP`
  (present only when the task references an app), and `NAGARE_NAMESPACE`.
  Rationale: `NAGARE_TASK_NAME` and `NAGARE_RUN_ID` are named explicitly by MasterPlan IP5 as
  the minimum set. `NAGARE_RUN_ID` is *per run*: a scheduled CronJob run and a one-off
  `task run` each get a distinct id, so logs can be correlated to a single execution. Because a
  CronJob's pod-template env is fixed at apply time (the renderer cannot know the per-run id when
  it writes the CronJob), `NAGARE_RUN_ID` is rendered using Kubernetes' Downward API to read the
  pod's own name (`metadata.name`), which is unique per Job pod — giving a genuinely per-run
  value without the renderer needing a clock. `NAGARE_APP` and `NAGARE_NAMESPACE` round out the
  identity (mirroring the app's `NAGARE_SERVICE_NAME`/`NAGARE_NAMESPACE`) and are cheap literals
  the deploy step already knows. The set follows the generated-variable pattern in
  `cli/nagarectl/src/Nagare/Env/Generated.hs` (`generatedEnv`): a pure function producing inline
  `{Runtime}`-scoped entries with the reserved `NAGARE_*` prefix.
  Date: 2026-06-10

- Decision: `renderResolvedTask` patches EP-50's CronJob `Value` in memory (neither the plan's
  "option 1" byte post-processing nor "option 2" envelope duplication). EP-50's
  `Nagare.Dsl.Task.Render` was extended to export `cronJobValue :: Task -> Value` and
  `encodeCronJob :: Value -> ByteString`; EP-52 computes `encodeCronJob (patchContainer inject
  (cronJobValue (withPredef t)))`, where `patchContainer` walks the fixed container path and
  `inject` sets `image` and appends the `NAGARE_RUN_ID` field-ref.
  Rationale: this keeps EP-50 the single owner of the manifest shape and key order (no
  duplicated envelope) AND avoids a fragile YAML decode/re-encode round-trip. The two EP-50
  exports are purely additive. The plan explicitly permitted asking EP-50 (a sibling plan in
  this MasterPlan) to expose a render seam; this is the minimal such seam.
  Date: 2026-06-10

- Decision: When a task carries an explicit image (`taskImage = Just <ref>`), EP-52 still
  appends the deploy tag to it the same way the app renderer does — `imageRefText ref <> ":" <>
  effTag` — so an explicit-image task deployed with an app is pinned to the same release tag,
  rather than the renderer emitting a bare untagged repository path.
  Rationale: EP-50's pure renderer emits the bare repository path for an explicit image (it has
  no tag), exactly as the app renderer takes the bare `ImageRef` and appends the resolved tag at
  render time (`containerValue` in `Nagare.Dsl.Render` builds `imageRefText (dep ^. #image) <>
  ":" <> resolveImageTag …`). An untagged image would deploy `:latest` implicitly, which the DSL
  forbids elsewhere (`mkImageRef` rejects a `:` precisely so the tag is always appended
  separately). Pinning the explicit-image task to the deploy tag keeps task images as
  deterministic and reproducible as app images.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome: a task can run "in an app's world" end-to-end.** Against the original purpose, all
four proofs hold:

- **Typed association round-trips (M1).** `Deployment` carries `tasks :: [Task]`; an app config
  co-locates its tasks, emits a `Deployment` JSON whose `tasks` array carries each task, and
  decodes back — re-validating every task — to the identical value. The deploy-level invariants
  (no duplicate task name; a task's `taskApp` must name the enclosing app) reject bad configs
  with `MarshalError "tasks"`. 235 dsl tests pass.
- **Image resolved + env inherited (M2).** `resolveTaskImage` gives an inheriting task the app's
  `repo:tag` verbatim and pins an explicit-image task to the deploy tag; `predefinedTaskEnv`
  yields `NAGARE_TASK_NAME`/`NAGARE_NAMESPACE`/`NAGARE_APP` (the last only when associated).
  `renderResolvedTask` injects the resolved image and the `NAGARE_RUN_ID` Downward-API entry.
  226 nagarectl tests pass.
- **The golden pins the resolved manifest.** `cli/nagarectl/test/golden/task-app-resolved.cronjob.yaml`
  shows `image: gcr.io/myproject/notes:20260602-120000`, the two `optional: true` `envFrom`
  refs, the `nagare.dev/app: notes` label, and the predefined env (`NAGARE_RUN_ID` as a
  `fieldRef` to `metadata.name`).
- **End-to-end dry run (M2/M3).** `nagarectl deploy --dry-run -f …/app-with-task/nagare/Config.hs
  --tag 20260602-120000` prints a `--- Task CronJob manifest ---` banner with the resolved tag,
  inherited `envFrom`, app label, and predefined vars — the IP5 acceptance excerpt. An app with
  no tasks produces no banner and applies nothing extra.

**Interfaces delivered.** `Deployment.tasks` (co-location), `Nagare.Task.Resolve`
(`resolveTaskImage`/`predefinedTaskEnv`/`renderResolvedTask`), and the runDeploy provisioning.
The inherited-variable contract table and precedence rule are published in Interfaces and
Dependencies (consumed by EP-53). EP-50 gained two additive exports (`cronJobValue`,
`encodeCronJob`).

**Gaps / deferred.** The live (non-dry-run) on-VM provisioning check is deferred per the EP-48
precedent (the cluster API is reachable only on the VM); the dry-run transcript plus the
EP-49-verified `envFrom`/Downward-API substrate cover the behavior. A live one-off run proving
inherited env reaches the pod uses EP-51's `nagarectl task run`, also deferred.

