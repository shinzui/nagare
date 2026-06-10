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


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before editing. All
paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/nagare`.

### The two packages

The work spans two Haskell packages built with GHC 9.12 (language edition `GHC2024`):

- `cli/nagare-dsl/` — the **pure** DSL package (build file
  `cli/nagare-dsl/nagare-dsl.cabal`). It defines the typed models (`Deployment`, `Database`,
  `Task`), their JSON serialization, and the YAML renderers. No module here touches a live
  cluster. Build and test from the package directory:

  ```bash
  cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
  cabal build
  cabal test nagare-dsl-test
  ```

- `cli/nagarectl/` — the **CLI** package (build file `cli/nagarectl/nagarectl.cabal`). It
  defines the `nagarectl` executable, the `deploy` path, and everything cluster-aware
  (resolving image tags, shelling out to `kubectl`). Build and test from its directory:

  ```bash
  cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
  cabal build
  cabal test nagarectl-test
  ```

This plan touches the pure package for the typed association (M1) and the CLI package for the
deploy-time resolution (M2/M3).

### What "inherit the app's world" means, in files

An app named `<app>` is rendered by `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` into a Knative
Service whose container references two managed Kubernetes objects:

- a **runtime ConfigMap** named `nagare-env-<app>-runtime`, built by the helper
  `managedConfigMapName <app> Runtime` (lines ~81–83 of `Render.hs`), holding the app's
  non-secret runtime configuration as key/value pairs; and
- a **runtime Secret** named `nagare-secret-<app>-runtime`, built by `managedSecretName <app>
  Runtime` (lines ~86–88), holding the app's runtime secrets.

The app's container references both with an `envFrom:` block (the helper `envFromField`, lines
~363–375 of `Render.hs`):

```haskell
envFromField :: Text -> [Pair]
envFromField app =
  [ "envFrom"
      .= toJSON
        [ object ["configMapRef" .= object ["name" .= managedConfigMapName app Runtime, "optional" .= True]]
        , object ["secretRef" .= object ["name" .= managedSecretName app Runtime, "optional" .= True]]
        ]
  ]
```

`envFrom` tells Kubernetes: "for this container, import every key of these objects as an
environment variable." `optional: true` means the container still starts if the object does
not exist yet (an app whose store was never written still deploys). A task that "inherits the
app's world" gains the **identical** `envFrom` block — the same two object names, each
`optional: true` — so the task's pods see the same runtime configuration and secrets the app
sees. This is precisely the shape EP-50's renderer already emits for a task whose `taskApp` is
set (see `envFromPairs` in `docs/plans/50-typed-task-model-and-cronjob-job-renderer.md`, which
reproduces these two names verbatim).

### The typed `Task` (from EP-50, the hard dependency)

`docs/plans/50-typed-task-model-and-cronjob-job-renderer.md` defines, in the module
`Nagare.Dsl.Task` (file `cli/nagare-dsl/src/Nagare/Dsl/Task.hs`), the record:

```haskell
data Task = Task
  { taskName                       :: ServiceName
  , taskNamespace                  :: Namespace
  , taskSchedule                   :: Schedule
  , taskImage                      :: Maybe ImageRef      -- Nothing = inherit app image
  , taskApp                        :: Maybe ServiceName   -- the associated app
  , taskCommand                    :: [Text]
  , taskArgs                       :: [Text]
  , taskEnv                        :: Map EnvName ScopedEnvVar
  , taskResources                  :: Maybe Resources
  , taskTimeoutSeconds             :: Maybe Int
  , taskConcurrencyPolicy          :: ConcurrencyPolicy
  , taskRestartPolicy              :: RestartPolicy
  , taskBackoffLimit               :: Int
  , taskSuccessfulJobsHistoryLimit :: Int
  , taskFailedJobsHistoryLimit     :: Int
  , taskStartingDeadlineSeconds    :: Maybe Int
  }
```

`taskImage = Nothing` means "inherit the referenced app's image"; `taskApp = Just <app>`
records the association. EP-50 enforces, at construction (`mkTask`) and again at load
(`toTask`), the cross-field invariant that `taskImage = Nothing` is only legal when `taskApp =
Just _` (you cannot inherit an image with no app to inherit it from). EP-52 implements and
verifies the *deploy-time half* of that contract: actually substituting the app's resolved tag.

EP-50 also provides the renderer module `Nagare.Dsl.Task.Render` (file
`cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs`) exporting:

```haskell
renderTask       :: Task -> ByteString  -- one batch/v1 CronJob, deterministic bytes
taskJobSpecValue :: Task -> Value       -- the bare Job .spec (reused by EP-51/EP-52)
taskCronJobName  :: Task -> Text        -- "nagare-task-" <> taskName  (IP3)
```

Reading EP-50's renderer (in `docs/plans/50-typed-task-model-and-cronjob-job-renderer.md`, the
`Nagare.Dsl.Task.Render` source): the container is built by `containerValue`, whose `image:`
key is emitted by `imagePairs` — and `imagePairs` emits the key **only** when `taskImage` is
`Just`; for an inheriting task it emits nothing, leaving a hole EP-52 fills. The `envFrom`
block (`envFromPairs`) and the `nagare.dev/app` label (`taskLabels`) are emitted whenever
`taskApp` is set, with no deploy-time input required. This is the seam this plan exploits.

### How an app's image tag is resolved at deploy time

The image tag is only known at deploy. `cli/nagarectl/src/Nagare/Image.hs` defines `computeTag
:: IO Text` (a timestamp like `20260602-120000` from the current time) and `taggedImageRef ::
ImageRef -> Text -> Text` (`imageRefText ref <> ":" <> tag`). `cli/nagarectl/app/Main.hs`'s
`resolveTag :: Maybe String -> IO Text` (lines ~2035–2037) returns `--tag` when given, else
`computeTag`.

`cli/nagare-dsl/src/Nagare/Dsl/Build.hs` defines `resolveImageTag :: BuildSpec -> Text ->
Text`: a `PrebuiltImage` carries its own tag; a built image uses the deploy tag the CLI
computed. The app's container therefore deploys at `imageRefText (dep ^. #image) <> ":" <>
resolveImageTag (dep ^. #build) imageTag` — this string is what EP-52 must reuse for an
inheriting task so it runs the app's current code.

`runDeploy` in `cli/nagarectl/app/Main.hs` (lines ~1284–1371) is the deploy path. It:

1. loads the typed `Deployment` (`Load.loadDeployment`);
2. resolves the tag (`imageTag <- resolveTag (dopts ^. #tag)`) and the build spec
   (`spec <- resolveBuildSpec dopts (dep ^. #build)`);
3. resolves managed-database connection env and merges generated `NAGARE_*` env into the app's
   env map (lines ~1301–1319), producing `dep'`;
4. computes `effTag = resolveImageTag spec imageTag` (line ~1321) — **this is the resolved tag
   an inheriting task must reuse**;
5. renders the PVCs, the Service, and the DomainMappings;
6. in `--dry-run` (lines ~1333–1345) prints each manifest under a `--- … manifest ---` banner;
   otherwise builds/pushes the image and applies the manifests with
   `applyPVCs`/`applyManifests` (from `cli/nagarectl/src/Nagare/Deploy.hs`).

`applyManifests :: [ByteString] -> IO ()` (in `cli/nagarectl/src/Nagare/Deploy.hs`, lines
~39–45) writes each manifest to a temp file and runs `kubectl apply -f`, which is idempotent.
EP-51 already plans to hook declared task CronJobs into both the dry-run print and the live
apply here; this plan resolves the *values* in those CronJobs (the inherited tag, the
predefined env) before they are applied. The two plans coordinate at this one call site (see
Interfaces and Dependencies).

### The generated-variable pattern (for predefined task vars)

`cli/nagarectl/src/Nagare/Env/Generated.hs` (module `Nagare.Env.Generated`) is the template
for the predefined task variables. It defines a pure `generatedEnv :: GeneratedContext -> Map
EnvName ScopedEnvVar` that builds the `NAGARE_*` identity variables as inline `{Runtime}`
`EnvLiteral`s, plus `mergeGenerated :: Map EnvName ScopedEnvVar -> Map EnvName ScopedEnvVar ->
Map EnvName ScopedEnvVar` (a left-biased `Data.Map.union`, so generated entries win over
same-named user entries). The local helper `envName :: Text -> EnvName` forces a known-valid
`mkEnvName` result, `error`ing on the unreachable failure for totality. EP-52's
`predefinedTaskEnv` follows this shape exactly, but one of its variables (`NAGARE_RUN_ID`) is
*not* a plain literal — it is a Downward-API reference to the pod's own name, so it must be
modelled and rendered slightly differently (see Concrete Steps M2).

### The `Deployment` record and its `databases` reference field

`cli/nagare-dsl/src/Nagare/Dsl/Types.hs` defines `Deployment` (line ~578). It already carries
cross-resource reference fields: `volumes :: [Volume]` (line ~604) and `databases ::
[DatabaseName]` (line ~609, "Names of managed databases this app connects to … EP-46 resolves
each name … at deploy time"). This is the established model for an app declaring resources it
owns. This plan adds `tasks :: [Task]` to that record, defaulting to `[]`, exactly mirroring
how `databases` was added (default `[]`, round-tripping through the same emit/decode path, no
behavior change for an app that declares none).

### The serialization and load paths

`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` turns a `Deployment` into JSON (`deploymentJSON`),
emitting each scoped env entry and each reference field. EP-50 adds `taskJSON :: Task -> Value`
to this same module (used by `emitTask` for a standalone task); this plan reuses `taskJSON` to
serialize each element of `Deployment.tasks` as a nested array.

`cli/nagare-dsl/src/Nagare/Dsl/Load.hs` decodes JSON back into typed values, re-running every
smart constructor (defence in depth). Its intermediate record `JsonDeployment` has a `FromJSON`
instance and a `toDeployment :: JsonDeployment -> Either LoadError Deployment` marshaller. EP-50
adds `JsonTask`/`toTask`; this plan adds a `jdTasks :: [JsonTask]` field to `JsonDeployment` and
runs `toTask` over it in `toDeployment` (so each co-located task is re-validated at load,
exactly as `databases` re-runs `mkDatabaseName`).

### What this plan is and is not

This plan owns **IP5** (the app↔task association and inheritance contract). It defines the
typed co-location (`Deployment.tasks`), the deploy-time resolution of the inherited image tag,
the predefined task variables, and the precedence rule. It does **not** redefine the `Task`
type or its renderer (EP-50 owns those) and does **not** add the `task` CLI commands (EP-51
owns those). It coordinates with EP-51 at the single `runDeploy` task-provisioning call site:
this plan resolves the values; EP-51 (or this plan's M2, whichever lands first) wires the
rendered CronJobs into the apply pass. If EP-51 lands its provisioning loop first, M2 inserts
the value resolution into that loop; if this plan lands first, M2 adds the loop and EP-51
reuses it. Either way there is exactly one place that renders-and-applies declared task
CronJobs.


## Plan of Work

The work proceeds in three independently verifiable milestones.

### Milestone M1 — the typed association, load-time invariants, and JSON round-trip

**Scope.** Add `tasks :: ![Task]` to the `Deployment` record, serialize and decode it (each
element round-tripping through EP-50's `taskJSON`/`toTask`), and enforce two deploy-level
invariants at load: no two co-located tasks share a name, and a co-located task whose `taskApp`
is set names the enclosing app (it would be confusing to deploy a task under app `notes` that
claims `taskApp = Just other`). EP-50 already enforces the per-task cross-field invariant
(inherit-image requires an app); this milestone verifies it holds through the deployment path
and adds a deployment-level round-trip test.

**What exists at the end.** An app's `Config.hs` can declare `tasks = [...]`, emit a
`Deployment` JSON whose `tasks` array carries each task, and decode it back — re-validating
every task — to the identical `Deployment`. This is pure DSL work, fully offline-testable.

**Commands & acceptance.**

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build
cabal test nagare-dsl-test
```

`cabal build` succeeds; the new deployment round-trip test passes; a `runghc` of the
app-with-task fixture (added in M2's fixtures, exercised here) prints a `Deployment` JSON whose
`"tasks"` array contains the inheriting task with `"image":null` and `"app":"notes"`.

### Milestone M2 — deploy-time image/env/label/predefined-var resolution

**Scope.** Create `cli/nagarectl/src/Nagare/Task/Resolve.hs` holding the pure resolution
helpers, and wire them into `runDeploy`. For each task in `dep ^. #tasks`: resolve the
container image (inherit the app's `effTag` when `taskImage = Nothing`, else pin the explicit
image to `effTag`), merge the predefined `NAGARE_*` task variables, render the CronJob, and
apply it alongside the Service / PVCs / databases (printing it under a banner in `--dry-run`).

**What exists at the end.** `nagarectl deploy --dry-run` of an app declaring an inheriting task
prints a CronJob whose container shows the resolved `image: <repo>:<tag>`, the two `envFrom`
references, the `nagare.dev/app: <app>` label, and the predefined env entries.

**Commands & acceptance.**

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal build
cabal test nagarectl-test
```

The test suite passes, including the `resolveTaskImage`/`predefinedTaskEnv`/render tests; the
golden in `cli/nagare-dsl/test/golden/task-app-resolved.cronjob.yaml` shows the resolved tag.
The `--dry-run` transcript in Concrete Steps shows the CronJob.

### Milestone M3 — the documented inherited-variable contract and an end-to-end dry run

**Scope.** Publish the inherited-variable contract table and the precedence rule (consumed by
EP-53), and capture an end-to-end `nagarectl deploy --dry-run` of an app-with-task. Document
the live (non-dry-run) provisioning check on the VM `nagare-01`, deferred-with-instructions per
the EP-48 precedent.

**What exists at the end.** A precise table of where each task variable comes from (the app's
runtime ConfigMap/Secret via `envFrom`; Nagare-generated per run) and the precedence order, and
a reproduced transcript proving an app-with-task renders the correct manifest.

**Commands & acceptance.** The `deploy --dry-run` transcript in Concrete Steps reproduces; the
inherited-variable table is filled in Interfaces and Dependencies; the on-VM live steps are
documented (deferred).


## Concrete Steps

This section gives the exact edits, fixtures, commands, and expected transcripts. Follow them
in order. Lines marked `-- ...` indicate where you fill in straightforwardly from the
surrounding pattern; everything load-bearing is spelled out.

### Step 1 (M1) — add `tasks` to the `Deployment` record

Edit `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`. Import the `Task` type (add to the existing
imports near the top of the module — `Nagare.Dsl.Types` does not currently import
`Nagare.Dsl.Task`, so add `import Nagare.Dsl.Task (Task)`; there is no import cycle because
`Nagare.Dsl.Task` imports only from `Nagare.Dsl.Types`'s building blocks, not from `Deployment`
— if a cycle does arise, move `Task` into `Nagare.Dsl.Types` is *not* an option; instead keep
`tasks` typed as `[Task]` by ensuring `Nagare.Dsl.Task` does not import `Nagare.Dsl.Types`'
`Deployment`; per EP-50 it imports only the leaf newtypes, so no cycle exists).

Add the field to the `Deployment` record, right after `databases` (line ~609):

```haskell
  , databases :: ![DatabaseName]
  -- | Scheduled tasks co-located with this app (MasterPlan 10, IP5). Empty (the
  -- backward-compatible default) means the app declares no tasks. Each 'Task'
  -- renders to a CronJob at deploy time; a task with @taskImage = Nothing@
  -- inherits this app's resolved image tag and its managed runtime env/secret.
  -- EP-52 resolves the inherited values in @cli/nagarectl@.
  , tasks :: ![Task]
  }
  deriving stock (Generic, Eq, Show)
```

`Task` derives `Eq` and `Show` (EP-50), so `Deployment`'s derived `Eq`/`Show` still compile.

### Step 2 (M1) — serialize `tasks` in `Config.hs`

Edit `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`. In `deploymentJSON`, add a `"tasks"` key
emitting each task via the existing `taskJSON` helper (added by EP-50 in this same module),
name-sorted for determinism. Place it near the `"databases"` key:

```haskell
    , "databases" .= map databaseNameText (dep ^. #databases)
    , "tasks" .= map taskJSON (sortOn taskName (dep ^. #tasks))
```

`sortOn` comes from `Data.List` (import it if not already imported); `taskName` is the `Task`
accessor (EP-50 exports it). Sorting by name makes the serialized array order independent of
the order the config author wrote the tasks, so the JSON (and any golden built from it) is
deterministic. `taskJSON` already exists in `Config.hs` (EP-50, used by `emitTask`); reuse it —
do not write a second task serializer.

### Step 3 (M1) — decode `tasks` in `Load.hs`

Edit `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`. Add a `jdTasks :: ![JsonTask]` field to the
`JsonDeployment` record and its `FromJSON` instance (defaulting to `[]` when absent), then run
`toTask` over it in `toDeployment`, and finally enforce the two deploy-level invariants.

In the `JsonDeployment` record, add:

```haskell
  , jdTasks :: ![JsonTask]
```

In its `FromJSON` instance, add (after the `jdDatabases` line):

```haskell
      <*> o .:? "tasks" .!= []
```

In `toDeployment`, decode and validate the tasks, then add the cross-task checks:

```haskell
  tasks' <- mapM toTask (jdTasks j)
  -- Deploy-level invariant 1: no two co-located tasks share a name.
  case firstDuplicate (map (serviceNameText . taskName) tasks') of
    Just dup -> Left (MarshalError "tasks" ("duplicate task name: " <> dup))
    Nothing -> Right ()
  -- Deploy-level invariant 2: a co-located task that names an app must name THIS app.
  let thisApp = serviceNameText name'   -- name' is the Deployment's own ServiceName
  forM_ tasks' $ \tk ->
    case taskApp tk of
      Just a
        | serviceNameText a /= thisApp ->
            Left
              ( MarshalError
                  "tasks"
                  ( "task '" <> serviceNameText (taskName tk)
                      <> "' references app '" <> serviceNameText a
                      <> "' but is co-located under app '" <> thisApp <> "'"
                  )
              )
      _ -> Right ()
```

Then add `tasks = tasks'` to the assembled `Deployment` record in `toDeployment`. The helper
`firstDuplicate` returns the first element that appears twice (or `Nothing`):

```haskell
-- | The first element that appears more than once in the list, in order, or
-- 'Nothing' when all elements are unique. Used to reject duplicate task names.
firstDuplicate :: (Ord a) => [a] -> Maybe a
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (x : xs)
      | x `Set.member` seen = Just x
      | otherwise = go (Set.insert x seen) xs
```

`Set` is `Data.Set` (import `qualified` if not already; `Load.hs` already uses `Data.Map`, add
`import Data.Set qualified as Set`). `forM_` and `mapM` come from the prelude. `toTask` is
exported by `Nagare.Dsl.Load` (EP-50 added it there). `taskApp`/`taskName` are exported by
`Nagare.Dsl.Task`; add `import Nagare.Dsl.Task` if not already present (EP-50 added it).

Note on the invariant placement: EP-50 already enforces, inside `toTask`, that `taskImage =
Nothing` requires `taskApp = Just _`. That per-task check runs automatically here because
`mapM toTask` re-runs it. The two *new* checks above are genuinely cross-task / cross-resource
(a uniqueness check and a consistency check between a task's `taskApp` and the enclosing app),
which a single task's smart constructor cannot express — exactly like the volumes-uniqueness
check the loader already performs.

### Step 4 (M1) — build and round-trip test

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build
```

Add a deployment-with-tasks round-trip test to `cli/nagare-dsl/test/Spec.hs`. Reuse EP-50's
`appTask` fixture value (an inheriting task associated with the `notes` app) and attach it to a
`notes` deployment, then assert the round-trip is lossless:

```haskell
-- | A `notes` deployment that co-locates EP-50's inheriting `sync` task.
notesWithTask :: Deployment
notesWithTask = helloDep { name = unsafe (mkServiceName "notes"), tasks = [appTask] }

deploymentTaskTests :: [TestTree]
deploymentTaskTests =
  [ testCase "deployment with a co-located task round-trips" $
      decodeDeployment (toStrict (encodeDeployment notesWithTask)) @?= Right notesWithTask
  , testCase "a task naming a different app fails to load" $
      case decodeDeployment (toStrict (encodeDeployment badAppTaskDep)) of
        Left (MarshalError "tasks" _) -> pure ()
        other -> assertFailure ("expected MarshalError tasks, got: " <> show other)
  ]
  where
    -- a deployment under app `notes` whose task claims taskApp = Just "other"
    badAppTaskDep =
      helloDep
        { name = unsafe (mkServiceName "notes")
        , tasks = [appTask { taskApp = Just (unsafe (mkServiceName "other")) }]
        }
```

`helloDep`, `unsafe`, `encodeDeployment`, `decodeDeployment` are existing test helpers/imports
in `Spec.hs`; `appTask` is EP-50's fixture. `taskApp` setter syntax uses the record-update form
because `Task` exposes its fields. Register `deploymentTaskTests` in `main`'s `testGroup` list.

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test nagare-dsl-test
```

Expected: the new cases pass; **no existing golden file changes** (verify with `git status` —
only new test code, no modified `*.yaml` goldens).

### Step 5 (M2) — create `cli/nagarectl/src/Nagare/Task/Resolve.hs`

Create the module holding the pure resolution helpers. It imports EP-50's `Task` and renderer
and `nagare-dsl`'s leaf types; it performs no IO.

```haskell
{-# LANGUAGE PackageImports #-}

-- | Deploy-time resolution of an app-associated task (MasterPlan 10, EP-52, IP5).
--
-- EP-50's pure renderer ('Nagare.Dsl.Task.Render') emits the *structure* of
-- inheritance: an absent @image:@ key for an inheriting task, the @envFrom@ block
-- referencing the app's managed runtime ConfigMap/Secret, and the
-- @nagare.dev/app@ label. This module fills the one *value* the pure renderer
-- cannot know — the app's resolved @image:tag@ for this deploy — and adds the
-- predefined @NAGARE_*@ task variables, following the generated-variable pattern
-- in "Nagare.Env.Generated". It is pure (no IO): the resolved tag is passed in,
-- exactly as @Nagare.Database.Backup@ takes a @now :: UTCTime@, so rendering is
-- testable without a cluster.
module Nagare.Task.Resolve
  ( resolveTaskImage
  , predefinedTaskEnv
  , renderResolvedTask
  ) where

import Nagare.Dsl.Prelude

import Data.Aeson (Value (Object, String), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Task
  ( Task
  , taskApp
  , taskImage
  , taskName
  , taskNamespace
  )
import Nagare.Dsl.Task.Render (renderTask)
import Nagare.Dsl.Types
  ( EnvName
  , EnvVar (EnvLiteral)
  , ScopedEnvVar
  , imageRefText
  , mkEnvName
  , namespaceText
  , runtimeScoped
  , serviceNameText
  )

-- | The fully resolved @image:tag@ string for a task's container at deploy time.
--
--   * When the task carries its own image (@taskImage = Just ref@), the tag the
--     app is deploying this run is appended: @imageRefText ref <> ":" <> tag@.
--     This pins an explicit-image task to the same release as the app (Decision
--     Log), rather than deploying an untagged @:latest@.
--   * When the task inherits (@taskImage = Nothing@), the app's full resolved
--     image reference is used verbatim. The caller passes the SAME string the
--     app's own container gets this run (@imageRefText (dep ^. #image) <> ":" <>
--     effTag@), so the task runs the app's current code.
--
-- The @appImageTagged@ argument is the app's resolved @repo:tag@ (already
-- including the tag); @deployTag@ is the bare tag, used only to pin an explicit
-- task image.
resolveTaskImage
  :: Text       -- ^ the app's resolved image reference, @repo:tag@ (for inheritance)
  -> Text       -- ^ the bare deploy tag, @tag@ (to pin an explicit task image)
  -> Task
  -> Text
resolveTaskImage appImageTagged deployTag t =
  case taskImage t of
    Just ref -> imageRefText ref <> ":" <> deployTag
    Nothing -> appImageTagged

-- | The predefined @NAGARE_*@ variables injected into every task run, following
-- the generated-variable pattern in "Nagare.Env.Generated". @NAGARE_TASK_NAME@,
-- @NAGARE_NAMESPACE@, and (when the task references an app) @NAGARE_APP@ are
-- inline literals. @NAGARE_RUN_ID@ is NOT a literal: a CronJob's pod-template env
-- is fixed at apply time, so a genuinely per-run value comes from Kubernetes'
-- Downward API reading the pod's own (unique-per-Job) name. It is therefore
-- returned separately as a raw env entry (see 'runIdEnvEntry') rather than in the
-- typed 'ScopedEnvVar' map, because 'ScopedEnvVar' models only literals and
-- Secret refs, not field refs.
predefinedTaskEnv :: Task -> Map EnvName ScopedEnvVar
predefinedTaskEnv t =
  Map.fromList (fixed <> appEntry)
  where
    lit name v = (envName name, runtimeScoped (EnvLiteral v))
    fixed =
      [ lit "NAGARE_TASK_NAME" (serviceNameText (taskName t))
      , lit "NAGARE_NAMESPACE" (namespaceText (taskNamespace t))
      ]
    appEntry = case taskApp t of
      Just a -> [lit "NAGARE_APP" (serviceNameText a)]
      Nothing -> []

-- | The @NAGARE_RUN_ID@ container env entry, as a raw Kubernetes env object using
-- the Downward API to read the pod's own name (unique per Job run). Injected into
-- the rendered container's @env:@ list by 'renderResolvedTask'.
runIdEnvEntry :: Value
runIdEnvEntry =
  object
    [ "name" .= ("NAGARE_RUN_ID" :: Text)
    , "valueFrom" .= object ["fieldRef" .= object ["fieldPath" .= ("metadata.name" :: Text)]]
    ]

-- | Render a task to its CronJob bytes WITH the deploy-time values resolved: the
-- inherited (or explicit-and-tagged) image substituted into the container, the
-- predefined @NAGARE_*@ literals merged into the task's inline env (the task's own
-- inline env wins on a collision, but @NAGARE_*@ is reserved so none collide), and
-- the @NAGARE_RUN_ID@ Downward-API entry appended.
--
-- Implementation note: rather than re-deriving the whole manifest, this reuses
-- EP-50's 'renderTask' on a task value whose inline env has been augmented with the
-- predefined literals, then post-processes the decoded YAML to (a) set the
-- container @image@ to the resolved reference and (b) append the @NAGARE_RUN_ID@
-- field-ref env entry. Because EP-50's renderer omits @image@ for an inheriting
-- task and emits a stable container shape, this patch is deterministic.
renderResolvedTask
  :: Text     -- ^ the app's resolved image reference, @repo:tag@
  -> Text     -- ^ the bare deploy tag
  -> (Task -> Task)
  -- ^ how to augment the task's inline env with 'predefinedTaskEnv' (the caller
  -- supplies a setter that unions 'predefinedTaskEnv t' into 'taskEnv t', so this
  -- module needs no record-update knowledge of the Task field shape)
  -> Task
  -> ByteString
renderResolvedTask appImageTagged deployTag withPredefEnv t =
  patchManifest (resolveTaskImage appImageTagged deployTag t) (renderTask (withPredefEnv t))
```

Two simplifications are acceptable here and either is fine; pick one and record it in the
Decision Log when you implement:

1. **Post-process the YAML bytes** (`patchManifest`) — decode EP-50's `renderTask` output back
   to a `Value`, walk to the single container, set its `image` key and append the
   `NAGARE_RUN_ID` env entry, and re-encode with EP-50's ordered encoder. This keeps EP-50 as
   the single source of the manifest shape (no duplicated rendering) at the cost of a
   decode/patch/encode round-trip.

2. **Render from a Value directly** — call EP-50's `taskJobSpecValue` to get the bare Job
   `.spec` `Value`, inject the `image` and `NAGARE_RUN_ID` there, and wrap it in the CronJob
   envelope yourself. This avoids the round-trip but duplicates the CronJob envelope EP-50
   already writes.

The plan recommends **option 1** (post-process) because it guarantees the resolved CronJob is
byte-identical to EP-50's golden except for the two injected values, so the golden diff is
minimal and EP-50 stays the single owner of the manifest shape. The `patchManifest`/`envName`
helpers:

```haskell
-- | Set the single container's @image@ and append the @NAGARE_RUN_ID@ field-ref
-- env entry in a rendered task CronJob. Reuses EP-50's deterministic encoder by
-- decoding, patching, and re-encoding through 'renderTask''s value path. (In
-- practice this is implemented by exposing a small @patchContainer@ over the
-- decoded 'Value'; the exact YAML library calls mirror
-- 'Nagare.Dsl.Database.Render' / EP-50's render module.)
patchManifest :: Text -> ByteString -> ByteString
patchManifest = ...   -- see note: decode -> set image -> append env -> encode

envName :: Text -> EnvName
envName t = either (\e -> error ("EP-52 task env name invalid: " <> show e)) id (mkEnvName t)
```

A novice note on `patchManifest`: the cleanest implementation re-uses EP-50's encoder. If
EP-50 exposes only `renderTask :: Task -> ByteString` and `taskJobSpecValue :: Task -> Value`,
prefer building the final `Value` from `taskJobSpecValue` and EP-50's `cronJobValue`-equivalent
metadata, injecting `image`/`NAGARE_RUN_ID` into the container `Value` *before* encoding — this
is option 2 and avoids a decode round-trip. To keep a single owner of the manifest shape while
still doing the injection pre-encode, the lowest-risk path is to ask EP-50 (a sibling plan in
the same MasterPlan) to expose a `renderTaskWith :: (Value -> Value) -> Task -> ByteString` (a
renderer that applies a container-`Value` transform before encoding). If that coordination is
out of scope when you implement, use option 1 (post-process the bytes) — it needs nothing from
EP-50 beyond `renderTask`. **Record which path you took in the Decision Log.**

Register the module in `cli/nagarectl/nagarectl.cabal` under the `library` stanza's
`exposed-modules` (alphabetical, near the other `Nagare.Task.*` modules EP-51 adds):

```text
    Nagare.Task.Resolve
```

(It is `exposed`, not `other-modules`, so the test suite can import it.)

### Step 6 (M2) — wire task resolution into `runDeploy`

Edit `cli/nagarectl/app/Main.hs`. Add imports near the other `Nagare.*` imports:

```haskell
import Nagare.Task.Resolve (predefinedTaskEnv, renderResolvedTask)
```

In `runDeploy`, after `effTag` is computed (line ~1321) and `dep'` exists, compute the app's
resolved image reference and render each declared task's CronJob. Add, right after the existing
`let effTag = … ; ref = imageRef dep' effTag ; … ; ns = …` block:

```haskell
  -- EP-52: render each co-located task's CronJob with deploy-time values resolved.
  -- The app's resolved image reference is the SAME string the app's own container
  -- gets this run, so an inheriting task runs the app's current code.
  let appImageTagged = imageRefText (dep' ^. #image) <> ":" <> effTag
      -- merge the predefined NAGARE_* task vars into each task's inline env; the
      -- task's own env wins on a (non-NAGARE) collision (left-biased mergeGenerated).
      withPredef tk = tk & #env %~ mergeGenerated (predefinedTaskEnv tk)
      taskBytes =
        [ renderResolvedTask appImageTagged effTag withPredef tk
        | tk <- dep' ^. #tasks
        ]
```

Here `tk & #env %~ mergeGenerated (predefinedTaskEnv tk)` is the setter `renderResolvedTask`
expects: it unions the predefined `NAGARE_*` map (left, winning) over the task's inline env.
`mergeGenerated` is already imported (`Nagare.Env.Generated`). The lens label `#env` works on
`Task` because it derives `Generic` (EP-50) and the package enables generic-lens labels.

Then add the task CronJobs to both the dry-run print and the live apply. In the `--dry-run`
branch (after the DomainMapping print loop, ~line 1343):

```haskell
      forM_ taskBytes $ \tb -> do
        BC.putStrLn "--- Task CronJob manifest ---"
        BC.putStr tb
```

In the live branch (after `applyManifests (svcBytes : dmBytes)`, ~line 1361):

```haskell
      unless (null taskBytes) (applyManifests taskBytes)
```

`applyManifests` is idempotent (`kubectl apply -f`), so re-deploying an app re-applies the same
CronJobs harmlessly. An app with no declared tasks produces an empty `taskBytes` and behaves
byte-identically to before this plan (no extra output, no extra apply). `unless`/`forM_` come
from the prelude.

Coordination with EP-51: if EP-51's deploy-time provisioning loop already exists at this call
site when you implement, do **not** add a second loop — replace EP-51's `renderTask tk` call
with `renderResolvedTask appImageTagged effTag withPredef tk` so the applied CronJob carries the
resolved values. There must be exactly one place that renders-and-applies declared task
CronJobs.

### Step 7 (M2) — fixtures, unit tests, and the golden

Create the app-with-task fixture `cli/nagarectl/test/fixtures/app-with-task/nagare/Config.hs`
(used by the dry-run transcript; the offline unit tests use in-memory values). It declares the
`notes` app with one inheriting task:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | A `notes` app that co-locates an inheriting scheduled task: every 15 minutes
-- run `python manage.py sync` in `notes`'s own image (taskImage = Nothing), with
-- `notes`'s runtime env/secret (envFrom) and the predefined NAGARE_* task vars.
module Main (main) where

import Data.Map qualified as Map
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Task (Task (..), ConcurrencyPolicy (Forbid), RestartPolicy (Never), mkSchedule, mkTask)
import Nagare.Dsl.Types
  ( Deployment (..)
  , mkImageRef
  , mkNamespace
  , mkPort
  , mkServiceName
  )

dep :: Either String Deployment
dep = mapLeft show $ do
  appName <- mkServiceName "notes"
  ns <- mkNamespace "personal"
  img <- mkImageRef "gcr.io/myproject/notes"
  prt <- mkPort 8080
  bld <- defaultBuild
  sched <- mkSchedule "*/15 * * * *"
  syncTask <-
    mkTask
      Task
        { taskName = appName `seq` undefined  -- replaced below; see note
        , ..
        }
  -- (In the real fixture, build the Task with its own smart-constructed name
  -- `sync`, taskImage = Nothing, taskApp = Just appName, taskCommand = python
  -- manage.py sync, schedule sched, defaults otherwise — mirroring EP-50's
  -- `appTask` test fixture.)
  pure
    Deployment
      { name = appName
      , namespace = ns
      , image = img
      , build = bld
      , domains = []
      , port = prt
      , env = Map.empty
      , resources = Nothing
      , scale = Nothing
      , healthCheck = Nothing
      , volumes = []
      , databases = []
      , tasks = [syncTask]
      }

main :: IO ()
main = either (ioError . userError) emitDeployment dep

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right
```

The `taskName = … undefined` placeholder above is only to keep the snippet short; in the real
fixture construct the task exactly like EP-50's `appTask` (a fully smart-constructed `sync`
task with `taskImage = Nothing`, `taskApp = Just appName`). The `..` record-wildcard line is
illustrative — write the full `Task` record explicitly, as EP-50's fixtures do. Confirm the
fixture emits valid JSON:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
runghc -XGHC2024 -i../nagare-dsl/src \
  test/fixtures/app-with-task/nagare/Config.hs | head -c 60
```

Expected: the bytes begin `{"name":"notes",` (a `Deployment` carries no top-level `kind`) and
the output contains `"tasks":[{"kind":"Task","name":"sync","image":null,"app":"notes"`.

Add unit tests to `cli/nagarectl/test/Spec.hs`. Add imports:

```haskell
import Nagare.Task.Resolve (predefinedTaskEnv, renderResolvedTask, resolveTaskImage)
```

Add a `taskResolveTests` group (reuse the existing `unsafe`/`assertInfix` helpers and EP-50's
`appTask`/`standaloneTask` shapes built in-place):

```haskell
taskResolveTests :: [TestTree]
taskResolveTests =
  [ testCase "inheriting task uses the app's resolved image:tag verbatim" $
      resolveTaskImage "gcr.io/myproject/notes:20260602-120000" "20260602-120000" inheritTask
        @?= "gcr.io/myproject/notes:20260602-120000"
  , testCase "explicit-image task is pinned to the deploy tag" $
      resolveTaskImage "gcr.io/myproject/notes:20260602-120000" "20260602-120000" ownImageTask
        @?= "gcr.io/myproject/other:20260602-120000"
  , testCase "predefined env carries NAGARE_TASK_NAME / NAGARE_NAMESPACE / NAGARE_APP" $ do
      let m = predefinedTaskEnv inheritTask
      classify m "NAGARE_TASK_NAME" @?= Just (Left "sync")
      classify m "NAGARE_NAMESPACE" @?= Just (Left "personal")
      classify m "NAGARE_APP"       @?= Just (Left "notes")
  , testCase "standalone task gets no NAGARE_APP" $
      classify (predefinedTaskEnv ownImageTask) "NAGARE_APP" @?= Nothing
  , testCase "rendered CronJob shows resolved tag, both envFrom, app label, NAGARE_RUN_ID" $ do
      let yaml = renderResolvedTask "gcr.io/myproject/notes:20260602-120000" "20260602-120000"
                   (\tk -> tk & #env %~ mergeGenerated (predefinedTaskEnv tk)) inheritTask
      assertInfix "gcr.io/myproject/notes:20260602-120000" yaml
      assertInfix "nagare-env-notes-runtime" yaml
      assertInfix "nagare-secret-notes-runtime" yaml
      assertInfix "nagare.dev/app: notes" yaml
      assertInfix "NAGARE_TASK_NAME" yaml
      assertInfix "NAGARE_RUN_ID" yaml
      assertInfix "metadata.name" yaml
  ]
  where
    inheritTask = ...   -- EP-50's appTask: name "sync", image Nothing, app Just "notes"
    ownImageTask = ...  -- a "sync" task with taskImage = Just (mkImageRef "gcr.io/myproject/other"), taskApp = Nothing
```

`classify :: Map EnvName ScopedEnvVar -> Text -> Maybe (Either Text Text)` is the helper EP-46's
tests already use (it returns `Left literal` or `Right secretName`); if it is not in `Spec.hs`,
copy it from `docs/plans/46-generated-database-connection-env-injection-for-apps.md` (M1 test
helper). `assertInfix yaml` checks a substring appears in the rendered bytes (existing helper).

Add the render golden. The clean way is a golden in the **dsl** package's `test/golden/`
directory so it sits beside EP-50's task goldens, generated from the same `renderResolvedTask`
called in a dsl-package test — but `renderResolvedTask` lives in `cli/nagarectl`. To keep the
golden where the other task goldens live without moving the resolver, generate it from the
`nagarectl` test suite into a `nagarectl`-local golden directory
`cli/nagarectl/test/golden/task-app-resolved.cronjob.yaml`:

```haskell
  , goldenVsString
      "renderResolvedTask app-associated"
      "test/golden/task-app-resolved.cronjob.yaml"
      ( pure
          ( fromStrict
              ( renderResolvedTask
                  "gcr.io/myproject/notes:20260602-120000"
                  "20260602-120000"
                  (\tk -> tk & #env %~ mergeGenerated (predefinedTaskEnv tk))
                  inheritTask
              )
          )
      )
```

If the `nagarectl` test suite does not yet depend on `tasty-golden`, add it to the
`test-suite nagarectl-test` `build-depends` in `cli/nagarectl/nagarectl.cabal` (the dsl suite
already uses it; it is the same dependency). Generate the golden, then **read it** before
committing:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal test nagarectl-test --test-options=--accept
```

The golden should read like EP-50's `task-app-associated.cronjob.yaml` but with the resolved
`image:` filled in and the predefined env added:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-sync
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: sync
    nagare.dev/app: notes
spec:
  schedule: '*/15 * * * *'
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        metadata:
          labels:
            nagare.dev/managed-by: nagarectl
            nagare.dev/task: sync
            nagare.dev/app: notes
        spec:
          restartPolicy: Never
          containers:
          - name: sync
            image: gcr.io/myproject/notes:20260602-120000
            command:
            - python
            - manage.py
            - sync
            envFrom:
            - configMapRef:
                name: nagare-env-notes-runtime
                optional: true
            - secretRef:
                name: nagare-secret-notes-runtime
                optional: true
            env:
            - name: NAGARE_APP
              value: notes
            - name: NAGARE_NAMESPACE
              value: personal
            - name: NAGARE_RUN_ID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NAGARE_TASK_NAME
              value: sync
```

(Exact YAML quoting of `'*/15 * * * *'` is whatever the pretty-printer chooses; the
load-bearing facts are the resolved `image:` tag, the two `envFrom` names with `optional:
true`, the `nagare.dev/app: notes` label, and the `NAGARE_TASK_NAME`/`NAGARE_RUN_ID` entries —
`NAGARE_RUN_ID` as a `fieldRef` to `metadata.name`. The exact env ordering is name-sorted, so
`NAGARE_RUN_ID` sorts before `NAGARE_TASK_NAME`.)

Run the full suite:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal test nagarectl-test
```

Expected: all tests pass, including the new `taskResolveTests` group and the golden.

### Step 8 (M2/M3) — the deploy dry-run transcript

From the repo root, deploy the app-with-task fixture with `--dry-run`:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cli/nagarectl/test/fixtures/app-with-task/nagare/Config.hs \
  --base-domain apps.example.com \
  --tag 20260602-120000 \
  --dry-run
```

Expected (abbreviated) — after the Knative Service manifest, the task CronJob appears under its
banner with the resolved image and inheritance shape:

```text
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: notes
  ...
--- Task CronJob manifest ---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-sync
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: sync
    nagare.dev/app: notes
spec:
  schedule: '*/15 * * * *'
  ...
      template:
        spec:
          containers:
          - name: sync
            image: gcr.io/myproject/notes:20260602-120000
            command:
            - python
            - manage.py
            - sync
            envFrom:
            - configMapRef:
                name: nagare-env-notes-runtime
                optional: true
            - secretRef:
                name: nagare-secret-notes-runtime
                optional: true
            env:
            - name: NAGARE_APP
              value: notes
            - name: NAGARE_NAMESPACE
              value: personal
            - name: NAGARE_RUN_ID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NAGARE_TASK_NAME
              value: sync
Build mode: ...
URL: https://notes.personal.apps.example.com
```

This is the human-observable IP5 proof: the task's `image:` is the app's `--tag` value, the
two `envFrom` refs name the app's runtime ConfigMap/Secret, the `nagare.dev/app` label is set,
and the predefined task vars are present.

### Step 9 (M3) — the on-VM live provisioning check (deferred-with-instructions)

The offline suite and the dry-run transcript prove the rendering; a live check confirms the
CronJob is actually applied. Per repo memory (`scripts/iap-ssh.sh`, deploy user, start the VM
first; do not use the GKE default kubectl context) and the EP-48 precedent of deferring live
legs, do this once a real `notes` app exists on the cluster `tan-nb-exp`:

```bash
# from the repo root, with the GCP env from .envrc active (direnv allow once)
# 1) start the VM if stopped, then deploy the app-with-task for real (no --dry-run):
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cli/nagarectl/test/fixtures/app-with-task/nagare/Config.hs \
  --base-domain apps.example.com

# 2) confirm the CronJob was applied with the resolved image and labels:
scripts/iap-ssh.sh ssh nagare-01 -- kubectl get cronjob nagare-task-sync \
  -n personal -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}'
# expected: gcr.io/myproject/notes:<the deploy tag>

scripts/iap-ssh.sh ssh nagare-01 -- kubectl get cronjob nagare-task-sync \
  -n personal -o jsonpath='{.metadata.labels.nagare\.dev/app}'
# expected: notes
```

A live one-off run of the inheriting task (proving the inherited env actually reaches the pod)
uses EP-51's `nagarectl task run notes sync`; defer it to EP-51's live leg.


## Validation and Acceptance

Acceptance is behavioral, phrased as observable input/output, not "the code compiles."

**Proof 1 — the typed association round-trips and re-validates (M1, run the tests).** From
`cli/nagare-dsl`, `cabal test nagare-dsl-test` passes the new deployment-with-task round-trip
case (`decodeDeployment (toStrict (encodeDeployment notesWithTask)) == Right notesWithTask`) and
the negative case (a co-located task naming a different app fails to load with `MarshalError
"tasks" …`). This proves the association is carried through the whole serialization path and
that the deploy-level invariants are enforced at load. The per-task invariant (inherit-image
requires an app) is re-run by `mapM toTask` and is already covered by EP-50's negative test.

**Proof 2 — the image is resolved and the env inherited (M2, run the tests).** From
`cli/nagarectl`, `cabal test nagarectl-test` passes `resolveTaskImage` (an inheriting task gets
the app's `repo:tag` verbatim; an explicit-image task is pinned to the deploy tag),
`predefinedTaskEnv` (the `NAGARE_*` literals, with `NAGARE_APP` only when associated), and the
render-demonstration case (the rendered bytes contain the resolved tag, both `envFrom` names,
the `nagare.dev/app` label, and `NAGARE_TASK_NAME`/`NAGARE_RUN_ID`). These fail before this plan
(the functions do not exist) and pass after. The image resolver is pure and takes the resolved
tag as an argument (like `Nagare.Database.Backup` takes `now`), so it is tested with no cluster.

**Proof 3 — the golden pins the resolved manifest (M2, golden diff).** The golden
`cli/nagarectl/test/golden/task-app-resolved.cronjob.yaml` is byte-pinned: it shows `image:
gcr.io/myproject/notes:20260602-120000` (resolved), the two `optional: true` `envFrom` refs,
the `nagare.dev/app: notes` label, and the predefined env entries (`NAGARE_RUN_ID` as a
`fieldRef` to `metadata.name`). It differs from EP-50's `task-app-associated.cronjob.yaml` in
exactly the injected values (the present `image:` and the predefined `env:` entries), proving
EP-52 fills the hole EP-50 left.

**Proof 4 — the end-to-end dry run (M2/M3, human-observable).** `nagarectl deploy --dry-run -f
…/app-with-task/nagare/Config.hs --tag 20260602-120000` prints a `--- Task CronJob manifest ---`
banner with the CronJob carrying the resolved tag, the inherited `envFrom`, the app label, and
the predefined vars — the IP5 acceptance excerpt the MasterPlan calls for. An app with no
declared tasks produces no task banner and applies no extra object, byte-identical to before
this plan.

The exact test commands are `cabal test nagare-dsl-test` (from `cli/nagare-dsl`) and `cabal
test nagarectl-test` (from `cli/nagarectl`). A failing `tasty-hunit` test prints the failed
assertion and the offending value; an `assertInfix` failure dumps the full rendered YAML so you
can see what was emitted; a golden failure prints the diff between the committed golden and the
current output.


## Idempotence and Recovery

`resolveTaskImage`, `predefinedTaskEnv`, and `renderResolvedTask` are pure total functions:
calling them repeatedly with the same inputs yields byte-identical results, so re-rendering and
re-deploying the same app-with-task against the same `--tag` produces an identical CronJob
manifest. The only IO this plan adds on the deploy path is the extra `applyManifests taskBytes`
call, which runs `kubectl apply -f` — idempotent: re-applying an identical CronJob is a no-op
for unchanged fields and never deletes a running Job.

If a deploy fails partway (for example the Service applied but the task CronJob did not), re-run
`nagarectl deploy`: `kubectl apply` reconciles each object to the desired state, so the second
run applies the CronJob without disturbing the already-applied Service. Nothing is left in a
half-resolved state, because the image tag and predefined env are resolved *before* any apply
(in `--dry-run` you can inspect the exact manifest first).

All edits are additive. `Deployment.tasks` defaults to `[]`, so an existing app config that
declares no tasks deploys exactly as before (no `tasks` key required in its JSON — the loader
defaults it via `.!= []`). To roll back, revert the commits: the new field, the new module, and
the call-site additions are additive, and reverting restores the previous (no-task) behavior
with no migration.

The golden file is safe to regenerate: after an intentional change to the resolver or the
predefined-var set, run `cabal test nagarectl-test --test-options=--accept` and **read the
file** before committing (never accept blindly — a golden that changed unexpectedly is the test
catching a regression). To discard a wrongly-accepted golden, `git checkout --
cli/nagarectl/test/golden/task-app-resolved.cronjob.yaml` restores the committed version, or
`git clean` removes a not-yet-committed new golden.

Commits made while implementing this plan must carry the trailers:

```text
MasterPlan: docs/masterplans/10-scheduled-tasks-for-nagare.md
ExecPlan: docs/plans/52-app-task-association-and-runtime-env-image-and-secret-inheritance.md
Intention: intention_01kts6qyg4ezsbj500ksjr90r1
```

Commit each milestone on the current branch (no feature branch): `feat(dsl): EP-52 …` for M1
(the typed association in `nagare-dsl`), `feat(cli): EP-52 …` for M2 (the deploy-time
resolution in `nagarectl`), `docs(tasks): EP-52 …` for M3 (the contract docs), each with the
three trailers above.


## Interfaces and Dependencies

This plan adds one `nagare-dsl` field, one `nagarectl` module, and wiring at one `runDeploy`
call site. It introduces no new third-party dependency: `nagare-dsl` already depends on
`aeson`/`containers`/`text`/`yaml`, and `nagarectl` already depends on those plus `nagare-dsl`,
`generic-lens`, and the `cradle`/`kubectl` machinery.

### Hard dependency — EP-50

This plan cannot compile without `docs/plans/50-typed-task-model-and-cronjob-job-renderer.md`.
From EP-50 it consumes, by full module path:

- `Nagare.Dsl.Task.Task` (the typed record) and its accessors `taskName`, `taskNamespace`,
  `taskApp`, `taskImage`, `taskEnv`, plus `mkTask`, `mkSchedule`, the `ConcurrencyPolicy`/
  `RestartPolicy` enums — used to build co-located tasks and to read the association fields.
- `Nagare.Dsl.Task.Render.renderTask :: Task -> ByteString` and (for option 2)
  `taskJobSpecValue :: Task -> Value` — the pure manifest renderer EP-52 resolves values into.
- `Nagare.Dsl.Config.taskJSON :: Task -> Value` (EP-50 added it) — reused to serialize each
  element of `Deployment.tasks`.
- `Nagare.Dsl.Load.toTask :: JsonTask -> Either LoadError Task` and the `JsonTask` decoder —
  reused to re-validate each co-located task at load.

EP-50 owns the per-task cross-field invariant (`taskImage = Nothing` requires `taskApp = Just
_`), enforced in `mkTask`/`toTask`. EP-52 owns the deploy-time *value* resolution of that
inheritance.

### Soft dependency — EP-51

`docs/plans/51-nagarectl-task-lifecycle-commands-and-deploy-time-provisioning.md` adds the
`nagarectl task` CLI and a deploy-time provisioning loop. EP-52 is fully implementable and
testable through the renderer and `nagarectl deploy --dry-run` alone, but the two plans share
the single `runDeploy` task-provisioning call site: whichever lands first owns the loop, and the
other reconciles to a single render-and-apply path using `renderResolvedTask` (not bare
`renderTask`) so applied CronJobs carry the resolved values. A live one-off run of an inheriting
task (proving inherited env reaches the pod) uses EP-51's `nagarectl task run <app> <task>`.

### The final IP5 contract (consumed by EP-51 and EP-53)

**The association fields.**

```haskell
-- On the Task (EP-50, the shape; EP-52 the semantics):
taskApp   :: Task -> Maybe ServiceName   -- the associated app (drives the label + envFrom names)
taskImage :: Task -> Maybe ImageRef      -- Nothing = inherit the app's image

-- On the Deployment (EP-52, co-location):
tasks :: Deployment -> [Task]            -- tasks deployed in the same pass as this app
```

`taskApp` carries the association used by the renderer (the `nagare.dev/app` label and the
`nagare-env-<app>-runtime`/`nagare-secret-<app>-runtime` envFrom names). `Deployment.tasks`
carries co-location (which tasks deploy with which app, so the inherited tag is exactly the
tag the app gets this run). A standalone `Task` (EP-50's `emitTask`) remains valid for tasks
deployed independently of an app; the app-co-located path is additive.

**The resolution function signatures** (`Nagare.Task.Resolve`, in `cli/nagarectl`):

```haskell
-- The fully resolved repo:tag for a task's container. Inheriting tasks get the
-- app's resolved reference verbatim; explicit-image tasks are pinned to the tag.
resolveTaskImage :: Text -> Text -> Task -> Text   -- appImageTagged, deployTag, task

-- The predefined NAGARE_* task variables (literals): NAGARE_TASK_NAME,
-- NAGARE_NAMESPACE, and NAGARE_APP (only when associated). NAGARE_RUN_ID is a
-- per-run Downward-API fieldRef injected by renderResolvedTask, not a literal here.
predefinedTaskEnv :: Task -> Map EnvName ScopedEnvVar

-- The task CronJob bytes with deploy-time values resolved: the inherited (or
-- pinned) image substituted, the predefined env merged, NAGARE_RUN_ID appended.
renderResolvedTask :: Text -> Text -> (Task -> Task) -> Task -> ByteString
```

**The inherited-variable contract (the table EP-53 publishes).** For a task associated with
app `<app>` (i.e. `taskApp = Just <app>`) in namespace `<ns>`, a task run sees these
environment variables, from these sources:

| Variable | Source | Kind | Notes |
| --- | --- | --- | --- |
| every key of `nagare-env-<app>-runtime` | the app's managed runtime ConfigMap, via `envFrom` | inherited | `optional: true`; the app's non-secret runtime config |
| every key of `nagare-secret-<app>-runtime` | the app's managed runtime Secret, via `envFrom` | inherited | `optional: true`; the app's runtime secrets (incl. any DB connection secrets the app injected) |
| the task's own inline `env:` entries | the task's `taskEnv` (`{Runtime}`-scoped only) | declared | rendered inline; override inherited keys of the same name |
| `NAGARE_TASK_NAME` | Nagare-generated | literal | the task name (e.g. `sync`) |
| `NAGARE_NAMESPACE` | Nagare-generated | literal | the task's namespace (e.g. `personal`) |
| `NAGARE_APP` | Nagare-generated | literal | the associated app name; absent for app-less tasks |
| `NAGARE_RUN_ID` | Nagare-generated, per run | Downward-API `fieldRef` | the pod's own `metadata.name`, unique per Job pod — distinguishes a scheduled run from a one-off `task run` |

A task with **no** app association (`taskApp = Nothing`) sees none of the `envFrom` inheritance
and no `NAGARE_APP`; it still receives `NAGARE_TASK_NAME`, `NAGARE_NAMESPACE`, and
`NAGARE_RUN_ID`.

**The precedence rule.** Kubernetes resolves a container's environment by expanding every
`envFrom` source first (in order: the ConfigMap then the Secret), then applying each inline
`env` entry, with later sources overriding earlier ones. Therefore:

1. inherited values (from the app's runtime ConfigMap and Secret via `envFrom`) are applied
   first;
2. the task's own inline `env:` entries are applied after and **win** on a name collision (a
   task can override any single inherited variable by declaring it inline);
3. the predefined `NAGARE_*` variables are rendered inline and so also override the inherited
   `envFrom` of the same name — but the `NAGARE_*` prefix is reserved (it cannot collide with
   an app's runtime keys), so in practice they simply always take effect.

This is the identical rule the app renderer relies on for its own container (`envFromField` in
`cli/nagare-dsl/src/Nagare/Dsl/Render.hs`: "Kubernetes applies envFrom before the inline env
list, so inline DSL env … overrides managed env of the same key"). An inheriting task is, by
construction, a thin wrapper around the app's container: the same inherited world, with the
task free to override any single variable inline.
