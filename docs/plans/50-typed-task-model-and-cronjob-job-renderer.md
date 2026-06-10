---
id: 50
slug: typed-task-model-and-cronjob-job-renderer
title: "Typed Task model and CronJob/Job renderer"
kind: exec-plan
created_at: 2026-06-10T16:50:01Z
intention: "intention_01kts6qyg4ezsbj500ksjr90r1"
master_plan: "docs/masterplans/10-scheduled-tasks-for-nagare.md"
---

# Typed Task model and CronJob/Job renderer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare is a small, single-node personal "platform as a service" (PaaS) written in
Haskell. Its users describe what they want to run — a web app, a static site, a
managed database — by writing a small Haskell file called `Config.hs`. That file
builds a *typed value* (for example a `Deployment` or a `Database`), prints it as
JSON, and a command-line tool named `nagarectl` reads the JSON and turns it into
Kubernetes YAML that it applies to the cluster. "Typed" here means: every field is
constructed through a *smart constructor* (a function like `mkServiceName :: Text ->
Either Text ServiceName`) that rejects illegal values up front, so a misspelled name
or an unpinned image tag is a *compile-time or load-time error*, never a broken
cluster object discovered later.

Today Nagare can run *long-lived* things (web apps as Knative Services) and *stateful*
things (databases as StatefulSets), but it has no way to run work **on a schedule**
(a nightly cleanup, an hourly sync) or **once on demand** (a data migration). The only
escape hatch is hand-writing a Kubernetes *CronJob* or *Job* — exactly the raw
Kubernetes that the typed DSL exists to hide.

This ExecPlan delivers the **typed `Task` model and its renderer**: the foundation of
the larger "Scheduled Tasks" initiative described in the parent MasterPlan at
`docs/masterplans/10-scheduled-tasks-for-nagare.md`. After this plan a developer of
Nagare can:

- Write a `Task` value in Haskell — "run `python manage.py cleanup` every night at
  03:00, in a given image, with these environment variables" — and have it validated
  by smart constructors so an illegal cron string or an empty command cannot be
  written down.
- Print that `Task` as JSON (`{"kind":"Task", ...}`) and read it back, re-validated,
  with precise per-field error messages.
- Render that `Task` to a deterministic Kubernetes **CronJob** YAML document (and reuse
  its embedded **Job** template), byte-for-byte stable so a golden-file test can pin it.

A **CronJob** is a standard Kubernetes object that, on a cron schedule like `0 3 * * *`,
creates a **Job**, which runs one or more **Pods** to completion. A **Job** is the
"run-to-completion" primitive — unlike a web service, it finishes. The cron schedule is
*just a field* on the CronJob: remove it and the CronJob's `spec.jobTemplate.spec` *is*
the Job a one-off run uses. That is why one model and one renderer serve both scheduled
and one-off execution.

The work here is **pure**: it lives entirely inside the `cli/nagare-dsl/` package, adds
two new modules and some serialization, touches no live cluster, and is verified offline
by unit tests, a JSON round-trip, and golden-file YAML comparisons. The CLI commands
(`nagarectl task run/list/logs/delete`) and the deploy-time app-association semantics are
*separate* later plans (EP-51 and EP-52); this plan defines the contracts they import.

The user-visible proof at the end of this plan: `cabal test nagare-dsl-test` passes with
new `Task` tests, a `runghc` of a `Task` fixture prints valid `{"kind":"Task"}` JSON, and
a rendered CronJob YAML snippet shows the correct name, labels, schedule, command, and —
for an app-associated task — an `envFrom` block and an `nagare.dev/app` label.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — typed `Task` model + JSON round-trip:

- [x] Create `cli/nagare-dsl/src/Nagare/Dsl/Task.hs` with the `Task` record, the
      `Schedule` newtype + `mkSchedule`, the `ConcurrencyPolicy` and `RestartPolicy`
      enums, `mkTask`, and the `scheduledTask` preset.
- [x] Register `Nagare.Dsl.Task` in the `library` `exposed-modules` of
      `cli/nagare-dsl/nagare-dsl.cabal`.
- [x] Add `emitTask` / `encodeTask` (with `"kind":"Task"`) to
      `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`.
- [x] Add `JsonTask` / `toTask` / `decodeTask` / `loadTask` to
      `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`.
- [x] `cabal build` succeeds; a `runghc` of the `Task` fixture prints `{...,"kind":"Task",...}`.

Milestone 2 — renderer + goldens (standalone task):

- [x] Create `cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs` with `renderTask`,
      `taskJobSpecValue`, `taskCronJobName`, and the deterministic key comparator.
- [x] Register `Nagare.Dsl.Task.Render` in the `library` `exposed-modules`.
- [x] Add `test/fixtures/task/standalone/nagare/Config.hs` and the golden
      `test/golden/task-standalone.cronjob.yaml`.
- [x] Wire the standalone `Task` round-trip + render tests into
      `cli/nagare-dsl/test/Spec.hs`; `cabal test nagare-dsl-test` passes (232 tests); no
      existing golden changed (only the two new `task-*.yaml` files appear).

Milestone 3 — app-associated rendering shape (IP5 envFrom + label):

- [x] Add `test/fixtures/task/app-associated/nagare/Config.hs` (an inheriting task).
- [x] Add the golden `test/golden/task-app-associated.cronjob.yaml` showing the
      `envFrom` block and the `nagare.dev/app` label.
- [x] Add the cross-field invariant (image-inheritance requires an app) to `mkTask`/`toTask`
      and a negative test for it (an inheriting task with no app → `MarshalError "task"`).
- [x] `cabal test nagare-dsl-test` passes; rendered snippets recorded in Outcomes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`zipWithM` could not be named locally as `zipWithM`** without colliding — the custom
  prelude (`Nagare.Dsl.Prelude`) re-exports `Control.Monad` symbols via `lens`/`base`, and
  `Control.Monad.zipWithM` is in scope through the GHC2024 implicit `Prelude` chain. The local
  helper was renamed `zipWithE` to avoid the ambiguity. No behavior change; it is the same
  short-circuit-on-first-`Left` fold the plan described.
- **`aeson`'s `encode` emits object keys alphabetically**, so the emitted `{"kind":"Task",...}`
  JSON is alphabetically ordered (`"app"` first, `"kind"` in the middle), not in declaration
  order. This is irrelevant to correctness — `decodeTask` reads keys by name — and the
  *rendered YAML* (the golden) uses the deterministic rank-table comparator, so manifest bytes
  are stable regardless of JSON key order. Recorded so EP-51/EP-52 don't expect a `"kind"`-first
  JSON line.
- **The plan's last round-trip test had an inconsistent body** (it asserted `Right` for a case
  labelled "fails to decode"). Split into two precise tests: (1) a task with its own
  command+image and no app decodes to `Right`; (2) an inheriting task (no image, no app) with
  only a command fails with `MarshalError "task"` (the cross-field invariant). Both pass.


## Decision Log

Record every decision made while working on the plan.

- Decision: Introduce a dedicated `Schedule` newtype with a validating `mkSchedule ::
  Text -> Either Text Schedule`, rather than carrying the cron string as a raw `Text`.
  Rationale: The whole point of the DSL is that illegal values cannot be written down.
  A cron expression is exactly the kind of string that is easy to get subtly wrong
  ("every minute" vs. a typo that runs never). Hiding the constructor and validating the
  five fields at construction puts cron-string safety on the same footing as
  `mkServiceName` / `mkEngineVersion`. This is the cron-schedule validation rule named
  in MasterPlan IP1.
  Date: 2026-06-10

- Decision: One renderer produces both the CronJob *and* its embedded Job template, and
  `taskJobSpecValue :: Task -> Value` exposes the bare Job `.spec`.
  Rationale: The CronJob's `spec.jobTemplate.spec` *is* the Job a one-off run uses
  (`kubectl create job --from=cronjob/...`). Splitting CronJob and Job rendering would
  force two definitions of the same pod template — the cross-plan coupling the parent
  MasterPlan forbids. Exposing the bare `.spec` lets EP-51's one-off run and EP-52's
  env-injection reuse the exact same value. This is MasterPlan IP2.
  Date: 2026-06-10

- Decision: The `Task` carries `taskApp :: Maybe ServiceName` in *this* plan (EP-50, the
  IP1 *shape*), but the *deploy-time semantics* of that field — resolving the app's
  pushed image tag and its managed env/secret resource names — live in EP-52 (IP5).
  Rationale: The model must compile and round-trip on its own, and the renderer must be
  golden-testable offline, but image-tag and managed-resource resolution are only knowable
  at deploy time in the CLI package. Keeping the field here while deferring its semantics
  mirrors how `Deployment.databases` (the IP5 field of MasterPlan 9) was shaped in the
  model plan while EP-46 owned the injection. The renderer here emits the *structural*
  `envFrom` block (referencing `nagare-env-<app>-runtime` / `nagare-secret-<app>-runtime`,
  `optional: true`) whenever `taskApp` is set, so EP-52 has a populated shape to resolve
  against rather than a hole to cut.
  Date: 2026-06-10

- Decision: Reproduce the proven CronJob/Job field layout of
  `cli/nagarectl/src/Nagare/Database/Backup.hs` (`renderBackupCronJob`,
  `backupJobSpecValue`) rather than inventing a new shape.
  Rationale: That backup machinery already renders a `batch/v1` CronJob and Job that run
  on the live `tan-nb-exp` cluster; its key set (`schedule`, `concurrencyPolicy`,
  `successfulJobsHistoryLimit`, `failedJobsHistoryLimit`, `jobTemplate.spec.backoffLimit`,
  `template.spec.restartPolicy`, `containers`) is the verified contract. Following it is
  the lowest-risk path and keeps EP-50 aligned with EP-49's spike findings. We do *not*
  refactor the backup code onto `Task` (recorded as a possible future cleanup in the
  MasterPlan), only mirror its shape.
  Date: 2026-06-10

- Decision: Use `Data.Yaml.Pretty.encodePretty` with a local rank-table key comparator
  (the `dbConfig` pattern from `Nagare.Dsl.Database.Render`), *not*
  `Data.Yaml.encode` (the unordered encoder the backup module uses).
  Rationale: Golden files must be byte-stable across machines and library versions.
  `Data.Yaml.encode` orders keys however the Aeson `Object` (a hash map) iterates, which
  is not a stable contract; `encodePretty` with an explicit comparator pins the order.
  The database renderer already proves this pattern works for a complex multi-document
  shape, so we reuse its approach exactly.
  Date: 2026-06-10

- Decision: Validate `taskBackoffLimit >= 0`, `taskTimeoutSeconds > 0` (when present),
  `taskStartingDeadlineSeconds > 0` (when present), and require *either* a non-empty
  `taskCommand` *or* an app reference with image inheritance, at construction (`mkTask`)
  and again at load (`toTask`).
  Rationale: These mirror the existing house pattern (`mkScale`, `mkPort`, the volumes
  uniqueness check enforced at load in `Nagare.Dsl.Load.toVolumes`). The "command or
  inheriting app" rule is a genuine cross-field invariant — like the volumes-uniqueness
  check, it cannot be expressed by a single field's smart constructor, so it is enforced
  in `mkTask` and re-checked in `toTask`.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome: the typed `Task` model and its renderer ship, fully offline-tested.** Against the
original purpose, all three observable proofs hold:

- **The model rejects illegal tasks.** `cabal test nagare-dsl-test` passes the `mkSchedule`
  group (4-field cron, out-of-range minute, garbage each `Left`), the `mkTask invariants` group
  (inheriting-image-with-no-app, negative backoff, zero timeout each `Left`), and kind
  discrimination (a `Task` decoded as a `Deployment` is `UnexpectedKind`, and vice-versa).
- **The JSON round-trips end-to-end.** `runghc` of both fixtures prints valid
  `{...,"kind":"Task",...}` JSON, and `decodeTask (toStrict (encodeTask t)) == Right t` holds
  for both the standalone and app-associated tasks.
- **The renderer produces the right CronJob.** Two golden tests pin byte-stable manifests. The
  standalone golden (`test/golden/task-standalone.cronjob.yaml`) is a `batch/v1` CronJob named
  `nagare-task-cleanup`, schedule `0 3 * * *`, `concurrencyPolicy: Forbid`, a `jobTemplate.spec`
  with `backoffLimit: 0`, `activeDeadlineSeconds: 600`, `restartPolicy: Never`, and one
  container running `python manage.py cleanup` with a `DRY_RUN` env var. The app-associated
  golden (`task-app-associated.cronjob.yaml`) omits `image:`, carries the `envFrom` block
  referencing `nagare-env-notes-runtime` / `nagare-secret-notes-runtime` (each `optional: true`),
  and stamps `nagare.dev/app: notes` on every metadata block.

Total suite: 232 tests pass; no existing golden changed.

**Interfaces delivered for downstream plans.** `Nagare.Dsl.Task` (IP1: `Task`, `Schedule`,
`mkSchedule`, `mkTask`, `scheduledTask`, the policy enums + token/parse helpers,
`taskResourceName`), `Nagare.Dsl.Config` (`emitTask`/`encodeTask`, the `"kind":"Task"` JSON),
`Nagare.Dsl.Load` (`decodeTask`/`loadTask`), and `Nagare.Dsl.Task.Render` (IP2/IP3:
`renderTask`, `taskJobSpecValue` — the bare Job `.spec` EP-51's one-off run and EP-52's
injection reuse — and `taskCronJobName`). The rendered shape matches the EP-49 spike's
verified CronJob/Job exactly.

**Gaps / deferred (by design).** The `image:` key is omitted for app-associated tasks and
`taskJobSpecValue` emits the structural `envFrom` referencing the managed resources by name;
EP-52 owns resolving the inherited image tag and is the plan that makes those resources exist
at deploy time. The CLI verbs (`task list/run/logs/delete`) and deploy-time provisioning are
EP-51. Nothing here touches the cluster.


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before editing.

### The package you will work in

All work happens inside one Haskell package: `cli/nagare-dsl/`. Its build file is
`cli/nagare-dsl/nagare-dsl.cabal`. Source modules live under
`cli/nagare-dsl/src/Nagare/Dsl/`. Tests live under `cli/nagare-dsl/test/`. You build and
test from the package directory:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build
cabal test nagare-dsl-test
```

The compiler is GHC 9.12.3 with the `GHC2024` language edition and these always-on
extensions (declared in the `common` stanza of the cabal file, so you do *not* repeat
them per-module): `DeriveAnyClass`, `DuplicateRecordFields`, `MultilineStrings`,
`OverloadedLabels`, `OverloadedStrings`. The available dependencies are `aeson`,
`bytestring`, `containers` (which gives you `Data.Map` and `Data.Set`), `text`, `yaml`,
`generic-lens`, and `lens`.

### The "config as a program" idea

A Nagare project ships a Haskell file `Config.hs` whose `main` builds a typed value and
prints it as JSON to standard output (stdout). The loader runs that file with `runghc`
(an interpreter that compiles-and-runs a Haskell source file), captures the printed JSON,
and decodes it back into the typed value, **re-running every smart constructor** as a
defence-in-depth check. You will follow this pattern exactly for `Task`.

### The smart-constructor pattern (read this carefully)

A "smart constructor" is a function that validates input and returns
`Either Text X` — `Left "<message>"` on failure or `Right x` on success — where `X` is a
type whose *real* data constructor is hidden (not exported), so the only way to make an
`X` is through the validating function. The canonical example lives in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`. For instance `ServiceName`:

```haskell
newtype ServiceName = ServiceName Text
  deriving stock (Generic, Eq, Ord, Show)

mkServiceName :: Text -> Either Text ServiceName
mkServiceName t
  | Text.null t = Left "service name must not be empty"
  | Text.length t > 63 = Left ("service name too long ...")
  | ... = ...
  | otherwise = Right (ServiceName t)

serviceNameText :: ServiceName -> Text
serviceNameText (ServiceName t) = t
```

The module's export list exposes the *type* `ServiceName`, the *smart constructor*
`mkServiceName`, and the *accessor* `serviceNameText`, but **not** the constructor
`ServiceName`. Code outside the module therefore cannot build an invalid `ServiceName`.

The richest example of this style for a whole resource is
`cli/nagare-dsl/src/Nagare/Dsl/Database.hs`. Read it before writing `Task.hs`: it shows
an enum (`Engine`), a validated newtype with a hidden constructor (`EngineVersion` +
`mkEngineVersion`, which rejects empty, `"latest"`, spaces, and colons), a plain record
whose safety comes from its field *types* (`Database`, which is *not* hidden — the parent
MasterPlan and this plan both note that `Deployment` and `Database` get their safety from
field types, not from hiding the record), and a deterministic name helper (`dbSecretName`).

### The types you must *reuse*, not redefine

`cli/nagare-dsl/src/Nagare/Dsl/Types.hs` already defines the building blocks your `Task`
reuses. **Do not create your own versions of these:**

- `ServiceName` / `mkServiceName` / `serviceNameText` — a DNS-1123 label (lowercase
  letters, digits, hyphens; 1–63 chars; no leading/trailing hyphen). Used for the task
  name *and* the referenced app name.
- `Namespace` / `mkNamespace` / `namespaceText` / `defaultNamespace` (`"personal"`).
- `ImageRef` / `mkImageRef` / `imageRefText` — a container image *repository path with no
  tag* (rejects a `:` because the tag is appended separately at render time).
- `Quantity` / `mkQuantity` / `quantityText` and `Resources { cpu, memory, cpuLimit,
  memoryLimit }` (all `Maybe Quantity`) — CPU/memory requests and limits.
- `EnvName` / `mkEnvName` / `envNameText`; `SecretName` / `mkSecretName` /
  `secretNameText`.
- `EnvVar = EnvLiteral Text | EnvSecretRef SecretName` — the env value sum type that makes
  "literal XOR secret reference" unrepresentable as both at once.
- `EnvScope = Runtime | Build | Preview` and `ScopedEnvVar { value :: EnvVar, scopes ::
  Set EnvScope }` with smart constructors `runtimeScoped` (defaults to `{Runtime}`) and
  `scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar` (rejects the empty
  set). A task's env is a `Map EnvName ScopedEnvVar`, exactly like `Deployment.env`.

### The serialization pipeline

`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` turns a typed value into JSON on stdout.
`emitDatabase :: Database -> IO ()` calls `LBS.putStr (encodeDatabase db)` where
`encodeDatabase = encode . databaseJSON`. The JSON object carries a top-level
discriminator `"kind": "Database"`. A plain `Deployment` carries *no* `kind`. You add
`emitTask` / `encodeTask` whose JSON object carries `"kind": "Task"`. Note how env maps
are serialized: `"env" .= map envJSON (Map.toAscList (dep ^. #env))` — using
`Map.toAscList` to get a deterministic, name-sorted order. You will do the same.

`cli/nagare-dsl/src/Nagare/Dsl/Load.hs` is the decode side. It defines `LoadError`, whose
relevant variants are `MarshalError !Text !Text` (a field name and a message — e.g.
`MarshalError "schedule" "cron must have 5 fields"`) and `UnexpectedKind !Text !Text`
(expected kind, actual kind). For each resource there is an intermediate "Json…" record
with a `FromJSON` instance using `o .: "field"` (required) / `o .:? "field"` (optional)
/ `.!= default` (default when absent), and a `to…` function that re-runs the smart
constructors, mapping each `Left` to a precise `MarshalError` via the local helper
`mapLeft`. `decodeDatabase :: ByteString -> Either LoadError Database` first reads a
minimal `JsonKindEnvelope` (just the `kind`), checks it is `"Database"` (else
`UnexpectedKind`), then decodes the full `JsonDatabase` and calls `toDatabase`. You add
`JsonTask` / `toTask` / `decodeTask` / `loadTask` following this template precisely.

### The renderer pipeline

`cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs` is your renderer template. It builds
Aeson `Value`s with `object [ "key" .= value, ... ]` and serializes each with
`YP.encodePretty dbConfig . theValue` where `YP` is `Data.Yaml.Pretty` and `dbConfig`
fixes the YAML key order:

```haskell
dbConfig :: YP.Config
dbConfig = YP.setConfCompare keyCompare YP.defConfig

keyCompare :: Text -> Text -> Ordering
keyCompare a b = compare (rank a, a) (rank b, b)
  where
    rank k = maybe maxBound id (lookup k ranks)
    ranks = [ ("apiVersion", 0), ("kind", 1), ("metadata", 2), ("spec", 3), ... ]
```

Keys with a listed rank sort by rank; unlisted keys fall to `maxBound` and then sort
alphabetically. This deterministic ordering is what makes the rendered bytes stable, so a
golden test can pin them. Note `import Nagare.Dsl.Prelude hiding ((.=))` at the top of the
render module: the custom prelude (`cli/nagare-dsl/src/Nagare/Dsl/Prelude.hs`) re-exports
the `lens` operators, and `(.=)` collides with Aeson's `(.=)`, so you hide the lens one and
import Aeson's. The prelude also re-exports `Text`, `Generic`, `fromMaybe`, etc.

The proven CronJob/Job *shape* you must reproduce is in
`cli/nagarectl/src/Nagare/Database/Backup.hs`. Two functions matter (you cannot import
them — they live in a different package and embed backup-specific containers — so you
*reproduce the layout* in your own renderer):

`backupJobSpecValue` (~lines 131–151) is the Job `.spec`:

```haskell
object
  [ "backoffLimit" .= (0 :: Int)
  , "template" .= object
      [ "metadata" .= object ["labels" .= labelsValue i]
      , "spec" .= object
          [ "restartPolicy" .= ("Never" :: Text)
          , "containers" .= toJSON [theContainer]
          , ...
          ]
      ]
  ]
```

`renderBackupCronJob` (~lines 283–298) wraps it as a CronJob:

```haskell
object
  [ "apiVersion" .= ("batch/v1" :: Text)
  , "kind" .= ("CronJob" :: Text)
  , "metadata" .= jobMetadata (bciBase i)
  , "spec" .= object
      [ "schedule" .= bciSchedule i
      , "concurrencyPolicy" .= ("Forbid" :: Text)
      , "successfulJobsHistoryLimit" .= (3 :: Int)
      , "failedJobsHistoryLimit" .= (1 :: Int)
      , "jobTemplate" .= object ["spec" .= backupJobSpecValue (bciBase i)]
      ]
  ]
```

### The golden-test harness

`cli/nagare-dsl/test/Spec.hs` is the test entry point. It uses `Test.Tasty` with
`Test.Tasty.Golden`'s `goldenVsString`:

```haskell
goldenVsString
  "renderStatefulSet postgres"               -- test name
  "test/golden/db-postgres.statefulset.yaml"  -- golden file (relative to package dir)
  (pure (fromStrict (renderStatefulSet pgDb))) -- IO ByteString of the actual output
```

On the first run (or with `--accept`) the golden file is *written*; thereafter the test
fails if the bytes differ. `fromStrict`/`toStrict` convert between strict and lazy
`ByteString`. Fixture configs live under `cli/nagare-dsl/test/fixtures/`, with one
`Config.hs` per resource (see `test/fixtures/database/postgres/nagare/Config.hs`). Golden
YAML files live under `cli/nagare-dsl/test/golden/` (e.g. `db-postgres.statefulset.yaml`,
shown in this plan's Concrete Steps for reference).

### What this plan is and is not

This plan defines MasterPlan Integration Points **IP1** (the typed `Task` model and its
`"kind":"Task"` JSON shape), **IP2** (the rendered CronJob and embedded Job template), and
**IP3** (the naming/label contract: CronJob named `nagare-task-<name>`; labels
`nagare.dev/managed-by: nagarectl`, `nagare.dev/task: <name>`, and `nagare.dev/app:
<app>` when an app is referenced). It defines the *field shape* of **IP5**'s app reference
(`taskApp :: Maybe ServiceName`) and emits the structural `envFrom` block, but the
deploy-time *resolution* of an app's image tag and managed resources is owned by EP-52.
This plan touches no live cluster and adds no CLI command — those are EP-51 and EP-52,
whose plan files are `docs/plans/51-nagarectl-task-lifecycle-commands-and-deploy-time-provisioning.md`
and `docs/plans/52-app-task-association-and-runtime-env-image-and-secret-inheritance.md`.


## Plan of Work

The work proceeds in three independently verifiable milestones. Each one ends with a
command you can run and an observable result.

### Milestone 1 — the typed `Task` model and its JSON round-trip

**Scope.** Create the new module `cli/nagare-dsl/src/Nagare/Dsl/Task.hs` holding the
validated `Task` record, the `Schedule` newtype with `mkSchedule`, the
`ConcurrencyPolicy` and `RestartPolicy` enums, the `mkTask` smart constructor, and a
`scheduledTask` convenience preset. Register the module in the cabal file. Add
`emitTask`/`encodeTask` to `Config.hs` (emitting `"kind":"Task"`) and
`JsonTask`/`toTask`/`decodeTask`/`loadTask` to `Load.hs`.

**What exists at the end.** A compiling `Task` type that cannot hold an illegal value,
and a JSON emit→decode round-trip that re-validates every field. You can write a `Task` in
a fixture `Config.hs`, run it with `runghc`, and see `{"kind":"Task", ...}` JSON; you can
decode that JSON back to the identical `Task`.

**Commands & acceptance.**

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build
runghc -XGHC2024 -itest/fixtures/task/standalone/nagare test/fixtures/task/standalone/nagare/Config.hs
```

The `cabal build` succeeds with no errors. The `runghc` line prints a single line of JSON
beginning `{"kind":"Task",`. A unit test (added in M2's wiring, but exercised here) shows
`decodeTask (toStrict (encodeTask standaloneTask)) == Right standaloneTask`.

### Milestone 2 — the renderer and standalone golden

**Scope.** Create `cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs` with `renderTask :: Task
-> ByteString` (one `batch/v1` CronJob), `taskJobSpecValue :: Task -> Value` (the bare Job
`.spec`, exposed for EP-51/EP-52 reuse), `taskCronJobName :: Text -> Text`
(`"nagare-task-" <> name`), and the deterministic key comparator. Register the module.
Add the standalone fixture and golden, and wire the round-trip + render tests into
`test/Spec.hs`.

**What exists at the end.** A pure renderer that turns a `Task` into a deterministic
CronJob YAML document carrying the IP3 name and labels, the schedule, the container
command/args, the Runtime-scoped inline env, and the resources. A golden test pins the
bytes.

**Commands & acceptance.**

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test nagare-dsl-test
```

All tests pass, including the new `Task` group, and **no existing golden file changes**
(verify with `git status` showing only *new* `test/golden/task-*.yaml` files, never a
modified `db-*.yaml` or `*.service.yaml`).

### Milestone 3 — the app-associated rendering shape (IP5 envFrom + label)

**Scope.** Add the app-associated fixture and golden. When `taskApp` is `Just app`, the
rendered Job template gains an `envFrom` block referencing `nagare-env-<app>-runtime`
(ConfigMap) and `nagare-secret-<app>-runtime` (Secret), each `optional: true`, and every
rendered object additionally carries the label `nagare.dev/app: <app>`. Add the cross-field
load-time invariant that image inheritance (`taskImage = Nothing`) requires `taskApp =
Just _`, with a negative test.

**What exists at the end.** Proof that an app-associated task renders the inheritance shape
EP-52 will resolve against, and that the model rejects an inheriting task with no app to
inherit from. The golden shows the `envFrom` and `nagare.dev/app` label.

**Commands & acceptance.**

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test nagare-dsl-test
```

All tests pass. The golden `test/golden/task-app-associated.cronjob.yaml` contains an
`envFrom:` block and a `nagare.dev/app:` label; the standalone golden does *not*.


## Concrete Steps

This section gives the exact module skeletons, cabal edits, fixtures, commands, and
expected transcripts. Follow them in order. Lines marked `-- ...` indicate where you fill
in straightforwardly from the surrounding pattern; everything load-bearing is spelled out.

### Step 1 — create `cli/nagare-dsl/src/Nagare/Dsl/Task.hs`

Create the file with this content. It mirrors `Nagare.Dsl.Database` in structure: an
enum or two, a validated newtype with a hidden constructor (`Schedule`), a plain record
whose safety comes from field types (`Task`), a smart constructor (`mkTask`) that also
enforces a cross-field invariant, a preset (`scheduledTask`), and a deterministic name
helper.

```haskell
-- | The typed scheduled-task model (MasterPlan 10, IP1). A 'Task' names a unit
-- of work, a validated cron 'Schedule', the command to run, and the image and
-- environment to run it in. Every constrained field goes through a smart
-- constructor, so an illegal task (bad name, malformed cron, negative backoff,
-- a task with neither a command nor an inheriting app) cannot be written down.
--
-- Reuses 'ServiceName', 'Namespace', 'ImageRef', 'Quantity', 'Resources',
-- 'EnvName', 'ScopedEnvVar' from "Nagare.Dsl.Types"; it does not duplicate them.
--
-- The CronJob/Job shapes this model renders to (in "Nagare.Dsl.Task.Render")
-- reproduce the proven backup machinery in
-- @cli/nagarectl/src/Nagare/Database/Backup.hs@, verified on the live cluster.
module Nagare.Dsl.Task
  ( -- * Schedule
    Schedule
  , mkSchedule
  , scheduleText

    -- * Policies
  , ConcurrencyPolicy (..)
  , concurrencyPolicyToken
  , parseConcurrencyPolicy
  , RestartPolicy (..)
  , restartPolicyToken
  , parseRestartPolicy

    -- * Task
  , Task (..)
  , mkTask

    -- * Presets
  , scheduledTask

    -- * Naming (IP3)
  , taskResourceName
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isDigit)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Types
  ( EnvName
  , ImageRef
  , Namespace
  , Resources
  , ScopedEnvVar
  , ServiceName
  , defaultNamespace
  , mkImageRef
  , mkServiceName
  )

-- ---------------------------------------------------------------------------
-- Schedule

-- | A validated 5-field cron expression: @minute hour day-of-month month
-- day-of-week@. The constructor is hidden; use 'mkSchedule'.
--
-- Each of the five fields independently accepts:
--
--   * @*@ — "every value in this field's range";
--   * a single number within the field's range (minute 0-59, hour 0-23,
--     day-of-month 1-31, month 1-12, day-of-week 0-6);
--   * a range @a-b@ where @a@ and @b@ are in range and @a <= b@;
--   * a comma list of any of the above, e.g. @1,15,30@ or @mon-style@ numbers;
--   * a step @*\/n@ or @a-b\/n@ where @n >= 1@.
--
-- This is a pragmatic subset of cron that covers every schedule Nagare needs
-- (Kubernetes itself accepts the same grammar). Named months/days
-- (@JAN@, @MON@) and the @\@daily@ macros are deliberately NOT accepted so the
-- one rendered form is unambiguous.
newtype Schedule = Schedule Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Schedule'. Splits on spaces into exactly five
-- fields and validates each against its range, rejecting empty input and any
-- malformed field with a precise message.
mkSchedule :: Text -> Either Text Schedule
mkSchedule raw
  | Text.null trimmed = Left "schedule must not be empty"
  | length fields /= 5 =
      Left
        ( "schedule must have exactly 5 space-separated fields "
            <> "(minute hour day-of-month month day-of-week), got "
            <> tshow (length fields)
            <> ": "
            <> trimmed
        )
  | otherwise =
      case zipWithM validateField fieldRanges fields of
        Left err -> Left err
        Right _ -> Right (Schedule (Text.unwords fields))
  where
    trimmed = Text.strip raw
    fields = Text.words trimmed
    -- (field label, minimum, maximum) for the five cron positions.
    fieldRanges :: [(Text, Int, Int)]
    fieldRanges =
      [ ("minute", 0, 59)
      , ("hour", 0, 23)
      , ("day-of-month", 1, 31)
      , ("month", 1, 12)
      , ("day-of-week", 0, 6)
      ]

scheduleText :: Schedule -> Text
scheduleText (Schedule t) = t

-- | Validate one cron field (a comma list of terms) against its range.
validateField :: (Text, Int, Int) -> Text -> Either Text ()
validateField (label, lo, hi) field
  | Text.null field = Left ("cron " <> label <> " field is empty")
  | otherwise = mapM_ (validateTerm label lo hi) (Text.splitOn "," field)

-- | Validate one comma-separated term: @*@, @*\/n@, @a@, @a-b@, or @a-b\/n@.
validateTerm :: Text -> Int -> Int -> Text -> Either Text ()
validateTerm label lo hi term =
  case Text.splitOn "/" term of
    [base] -> validateBase base
    [base, stepT] -> validateBase base >> validateStep stepT
    _ -> Left ("cron " <> label <> " term has too many '/': " <> term)
  where
    validateBase "*" = Right ()
    validateBase b =
      case Text.splitOn "-" b of
        [oneT] -> validateNum oneT >> Right ()
        [aT, bT] -> do
          a <- validateNum aT
          c <- validateNum bT
          if a <= c
            then Right ()
            else Left ("cron " <> label <> " range start > end: " <> b)
        _ -> Left ("cron " <> label <> " term malformed: " <> b)
    validateNum t = case readInRange t of
      Just n -> Right n
      Nothing ->
        Left
          ( "cron " <> label <> " value out of range " <> tshow lo <> "-" <> tshow hi
              <> " (or not a number): " <> t
          )
    readInRange t = do
      n <- readIntT t
      if n >= lo && n <= hi then Just n else Nothing
    validateStep stepT = case readIntT stepT of
      Just n | n >= 1 -> Right ()
      _ -> Left ("cron " <> label <> " step must be >= 1: " <> stepT)

-- | Parse a non-negative decimal 'Int' from 'Text', or 'Nothing'.
readIntT :: Text -> Maybe Int
readIntT t
  | not (Text.null t) && Text.all isDigit t = Just (Text.foldl' step 0 t)
  | otherwise = Nothing
  where
    step acc c = acc * 10 + (fromEnum c - fromEnum '0')

-- | Like 'mapM' for the 'Either' monad over the two zipped lists, short-circuit
-- on the first 'Left'. (Defined locally to avoid pulling in extra imports.)
zipWithM :: (a -> b -> Either e c) -> [a] -> [b] -> Either e [c]
zipWithM f xs ys = sequence (zipWith f xs ys)

-- ---------------------------------------------------------------------------
-- Policies

-- | What Kubernetes does when a scheduled run would overlap a still-running one.
-- 'Forbid' (the safe default) skips the new run; 'Allow' runs both; 'Replace'
-- cancels the running one and starts the new one. Renders to
-- @spec.concurrencyPolicy@.
data ConcurrencyPolicy = Forbid | Allow | Replace
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | The exact token Kubernetes expects in @concurrencyPolicy@ (and the JSON).
concurrencyPolicyToken :: ConcurrencyPolicy -> Text
concurrencyPolicyToken Forbid = "Forbid"
concurrencyPolicyToken Allow = "Allow"
concurrencyPolicyToken Replace = "Replace"

parseConcurrencyPolicy :: Text -> Maybe ConcurrencyPolicy
parseConcurrencyPolicy "Forbid" = Just Forbid
parseConcurrencyPolicy "Allow" = Just Allow
parseConcurrencyPolicy "Replace" = Just Replace
parseConcurrencyPolicy _ = Nothing

-- | The pod's restart policy. A batch task uses 'Never' (the default; each
-- failed pod is replaced by the Job controller per 'taskBackoffLimit') or
-- 'OnFailure' (the kubelet restarts the container in place). Renders to
-- @template.spec.restartPolicy@.
data RestartPolicy = Never | OnFailure
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

restartPolicyToken :: RestartPolicy -> Text
restartPolicyToken Never = "Never"
restartPolicyToken OnFailure = "OnFailure"

parseRestartPolicy :: Text -> Maybe RestartPolicy
parseRestartPolicy "Never" = Just Never
parseRestartPolicy "OnFailure" = Just OnFailure
parseRestartPolicy _ = Nothing

-- ---------------------------------------------------------------------------
-- Task

-- | A scheduled task. There is no hidden constructor for 'Task' — like
-- 'Nagare.Dsl.Types.Deployment' and 'Nagare.Dsl.Database.Database', the safety
-- guarantee comes from the field types and from 'mkTask' (which enforces the
-- one cross-field invariant a single field type cannot: a task must have either
-- a command or an inheriting app+image).
data Task = Task
  { taskName :: !ServiceName
  -- ^ DNS-1123 label; the CronJob is named @nagare-task-\<taskName\>@ (IP3).
  , taskNamespace :: !Namespace
  , taskSchedule :: !Schedule
  -- ^ Validated 5-field cron expression.
  , taskImage :: !(Maybe ImageRef)
  -- ^ The image to run in. 'Nothing' means "inherit the referenced app's
  -- image", which is only valid when 'taskApp' is 'Just' (enforced in 'mkTask'
  -- and re-checked at load). EP-52 resolves the inherited tag at deploy time.
  , taskApp :: !(Maybe ServiceName)
  -- ^ The app whose image/env this task may inherit (IP5 shape). When 'Just',
  -- the renderer stamps the @nagare.dev/app@ label and an @envFrom@ block; EP-52
  -- owns the deploy-time resolution of the inherited image and resource names.
  , taskCommand :: ![Text]
  -- ^ The container @command@ (the entrypoint to override). May be empty only
  -- when the task inherits an app's image (then the image's own entrypoint runs).
  , taskArgs :: ![Text]
  -- ^ The container @args@.
  , taskEnv :: !(Map EnvName ScopedEnvVar)
  -- ^ Inline env. Only 'Runtime'-scoped entries render into the container (the
  -- renderer filters, matching how the app renderer treats build-only vars).
  , taskResources :: !(Maybe Resources)
  , taskTimeoutSeconds :: !(Maybe Int)
  -- ^ Hard wall-clock limit; renders as @jobTemplate.spec.activeDeadlineSeconds@.
  -- Must be @> 0@ when present.
  , taskConcurrencyPolicy :: !ConcurrencyPolicy
  -- ^ Default 'Forbid'.
  , taskRestartPolicy :: !RestartPolicy
  -- ^ Default 'Never'.
  , taskBackoffLimit :: !Int
  -- ^ Retries before the Job is marked failed; @>= 0@; default 0.
  , taskSuccessfulJobsHistoryLimit :: !Int
  -- ^ Default 3.
  , taskFailedJobsHistoryLimit :: !Int
  -- ^ Default 1.
  , taskStartingDeadlineSeconds :: !(Maybe Int)
  -- ^ Optional; @> 0@ when present; renders as @spec.startingDeadlineSeconds@.
  }
  deriving stock (Generic, Eq, Show)

-- | Validate an assembled 'Task'. Re-checks the numeric bounds the field types
-- cannot ('taskBackoffLimit' >= 0, positive timeouts/deadlines) and the one
-- cross-field invariant: a task must have a non-empty 'taskCommand' OR inherit
-- an app's image ('taskImage' == Nothing AND 'taskApp' == Just). Also rejects
-- image inheritance with no app to inherit from.
mkTask :: Task -> Either Text Task
mkTask t
  | taskBackoffLimit t < 0 =
      Left ("backoffLimit must be >= 0, got: " <> tshow (taskBackoffLimit t))
  | taskSuccessfulJobsHistoryLimit t < 0 =
      Left "successfulJobsHistoryLimit must be >= 0"
  | taskFailedJobsHistoryLimit t < 0 =
      Left "failedJobsHistoryLimit must be >= 0"
  | maybe False (<= 0) (taskTimeoutSeconds t) =
      Left "timeoutSeconds must be > 0 when set"
  | maybe False (<= 0) (taskStartingDeadlineSeconds t) =
      Left "startingDeadlineSeconds must be > 0 when set"
  | isNothing (taskImage t) && isNothing (taskApp t) =
      Left "a task with no image must reference an app to inherit its image from"
  | null (taskCommand t) && isNothing (taskApp t) =
      Left "a task must have a command, or reference an app to inherit its entrypoint"
  | otherwise = Right t

-- ---------------------------------------------------------------------------
-- Preset

-- | Build a standalone scheduled task from a name, a cron schedule, an image,
-- and a single-word command, filling sensible defaults (namespace @personal@,
-- no app, no args, no env, no resources, 'Forbid'/'Never', backoff 0, history
-- 3/1). Mirrors 'Nagare.Dsl.Presets.webService' in style: every constrained
-- field goes through its smart constructor, and the result is validated by
-- 'mkTask'. The @command@ is split on spaces into 'taskCommand'.
scheduledTask :: Text -> Text -> Text -> Text -> Either Text Task
scheduledTask nameT scheduleT imageT commandT = do
  n <- mkServiceName nameT
  sched <- mkSchedule scheduleT
  img <- mkImageRef imageT
  mkTask
    Task
      { taskName = n
      , taskNamespace = defaultNamespace
      , taskSchedule = sched
      , taskImage = Just img
      , taskApp = Nothing
      , taskCommand = Text.words commandT
      , taskArgs = []
      , taskEnv = Map.empty
      , taskResources = Nothing
      , taskTimeoutSeconds = Nothing
      , taskConcurrencyPolicy = Forbid
      , taskRestartPolicy = Never
      , taskBackoffLimit = 0
      , taskSuccessfulJobsHistoryLimit = 3
      , taskFailedJobsHistoryLimit = 1
      , taskStartingDeadlineSeconds = Nothing
      }

-- ---------------------------------------------------------------------------
-- Naming (IP3)

-- | The deterministic CronJob/Job resource name for a task (IP3):
-- @taskResourceName "cleanup" == "nagare-task-cleanup"@. Mirrors the backup
-- CronJob's @nagare-dbbackup-\<name\>@ and the @nagare-\<kind\>-\<name\>@
-- convention used throughout the renderers. EP-51 discovers tasks by the IP3
-- labels, not this name, but uses this name for @kubectl create job --from@.
taskResourceName :: Text -> Text
taskResourceName n = "nagare-task-" <> n

-- Internal: show an Int as Text for error messages.
tshow :: (Show a) => a -> Text
tshow = Text.pack . show
```

A note on `isNothing`/`isJust`: the custom prelude (`Nagare.Dsl.Prelude`) re-exports both
from `Data.Maybe`, so they are in scope without an extra import. `guard`, `when`, etc., are
also re-exported there if you need them.

### Step 2 — register `Nagare.Dsl.Task` in the cabal file

Edit `cli/nagare-dsl/nagare-dsl.cabal`. In the `library` stanza's `exposed-modules`, add
`Nagare.Dsl.Task` (alphabetical order keeps `Nagare.Dsl.Static.Types` before it and
`Nagare.Dsl.Types` after it). After this step the list reads:

```text
  exposed-modules:
    Nagare.Dsl.Build
    Nagare.Dsl.Config
    Nagare.Dsl.Database
    Nagare.Dsl.Database.Render
    Nagare.Dsl.Load
    Nagare.Dsl.Path
    Nagare.Dsl.Prelude
    Nagare.Dsl.Presets
    Nagare.Dsl.Render
    Nagare.Dsl.Server.Render
    Nagare.Dsl.Server.Types
    Nagare.Dsl.Static.Render
    Nagare.Dsl.Static.Types
    Nagare.Dsl.Task
    Nagare.Dsl.Task.Render
    Nagare.Dsl.Types
```

(You add both `Nagare.Dsl.Task` now and `Nagare.Dsl.Task.Render` in Step 5; adding both at
once is fine since `cabal build` only fails if a *listed* module file is missing — so add
`Nagare.Dsl.Task.Render` only after Step 5 creates its file, or create an empty stub
first. The simplest path: add `Nagare.Dsl.Task` here in M1, and `Nagare.Dsl.Task.Render`
in M2.)

### Step 3 — add `emitTask` / `encodeTask` to `Config.hs`

Edit `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`. Add `emitTask` and `encodeTask` to the
export list, add `import Nagare.Dsl.Task`, and add the functions plus the `taskJSON`
helper. The env serialization reuses the existing `scopeTokensJSON` helper already in this
module (it maps a `ScopedEnvVar` to its capitalized scope tokens). The env entries reuse
the same shape `deploymentJSON` uses (a list of objects with `varName`/`kind`/value/
`scopes`).

```haskell
-- In the export list, after emitDatabase / encodeDatabase:
  , emitTask
  , encodeTask

-- In the imports:
import Nagare.Dsl.Task

-- New functions (place after encodeDatabase):

-- | Serialize a 'Task' to JSON and write it to stdout. Call this as the last
-- line of a task project's @Config.hs@ @main@. The top-level @"kind": "Task"@
-- discriminator lets the loader dispatch and report a precise
-- 'Nagare.Dsl.Load.UnexpectedKind' if a Task config is run under the wrong
-- command.
emitTask :: Task -> IO ()
emitTask t = LBS.putStr (encodeTask t)

-- | The exact JSON bytes 'emitTask' writes (exposed for the round-trip test).
encodeTask :: Task -> LBS.ByteString
encodeTask = encode . taskJSON

-- | The JSON shape the loader reads back (see 'Nagare.Dsl.Load.decodeTask').
taskJSON :: Task -> Value
taskJSON t =
  object
    [ "kind" .= ("Task" :: Text)
    , "name" .= serviceNameText (taskName t)
    , "namespace" .= namespaceText (taskNamespace t)
    , "schedule" .= scheduleText (taskSchedule t)
    , "image" .= fmap imageRefText (taskImage t)
    , "app" .= fmap serviceNameText (taskApp t)
    , "command" .= taskCommand t
    , "args" .= taskArgs t
    , "env" .= map taskEnvJSON (Map.toAscList (taskEnv t))
    , "cpuRequest" .= fmap quantityText (res >>= (^. #cpu))
    , "memoryRequest" .= fmap quantityText (res >>= (^. #memory))
    , "cpuLimit" .= fmap quantityText (res >>= (^. #cpuLimit))
    , "memoryLimit" .= fmap quantityText (res >>= (^. #memoryLimit))
    , "timeoutSeconds" .= taskTimeoutSeconds t
    , "concurrencyPolicy" .= concurrencyPolicyToken (taskConcurrencyPolicy t)
    , "restartPolicy" .= restartPolicyToken (taskRestartPolicy t)
    , "backoffLimit" .= taskBackoffLimit t
    , "successfulJobsHistoryLimit" .= taskSuccessfulJobsHistoryLimit t
    , "failedJobsHistoryLimit" .= taskFailedJobsHistoryLimit t
    , "startingDeadlineSeconds" .= taskStartingDeadlineSeconds t
    ]
  where
    res = taskResources t
    taskEnvJSON (n, sev) = case sev ^. #value of
      EnvLiteral lit ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("Literal" :: Text)
          , "value" .= lit
          , "scopes" .= scopeTokensJSON sev
          ]
      EnvSecretRef sn ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("SecretRef" :: Text)
          , "secretName" .= secretNameText sn
          , "scopes" .= scopeTokensJSON sev
          ]
```

Note: `Map` is already imported in `Config.hs` as `Data.Map.Strict qualified as Map`, and
`(^. #field)` access works because `Config.hs` already enables `Data.Generics.Labels` via
the `PackageImports`-qualified `import "generic-lens" Data.Generics.Labels ()`. The `Task`
record fields are accessed by their named accessors (`taskName t`, `taskResources t`)
since `Task` exports its accessors; the `^. #cpu`/`^. #value` lens access is only used on
`Resources` and `ScopedEnvVar`, exactly as the existing `deploymentJSON` does.

### Step 4 — add `JsonTask` / `toTask` / `decodeTask` / `loadTask` to `Load.hs`

Edit `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`. Add `decodeTask` and `loadTask` to the
export list, add `import Nagare.Dsl.Task`, and add the intermediate record, its `FromJSON`
instance, the marshaller, and the decode/load entry points. The env decoding reuses the
existing `toEnvEntry` helper already in this module (it handles `JsonEnvEntry`); the
resource decoding follows the `toDbResources` pattern.

```haskell
-- In the export list, after decodeDatabase:
  , loadTask
  , decodeTask

-- In the imports:
import Nagare.Dsl.Task

-- New intermediate record + instance (place near JsonDatabase):

data JsonTask = JsonTask
  { jtName :: !Text
  , jtNamespace :: !Text
  , jtSchedule :: !Text
  , jtImage :: !(Maybe Text)
  , jtApp :: !(Maybe Text)
  , jtCommand :: ![Text]
  , jtArgs :: ![Text]
  , jtEnv :: ![JsonEnvEntry]
  , jtCpuRequest :: !(Maybe Text)
  , jtMemoryRequest :: !(Maybe Text)
  , jtCpuLimit :: !(Maybe Text)
  , jtMemoryLimit :: !(Maybe Text)
  , jtTimeoutSeconds :: !(Maybe Int)
  , jtConcurrencyPolicy :: !(Maybe Text)
  , jtRestartPolicy :: !(Maybe Text)
  , jtBackoffLimit :: !(Maybe Int)
  , jtSuccessfulJobsHistoryLimit :: !(Maybe Int)
  , jtFailedJobsHistoryLimit :: !(Maybe Int)
  , jtStartingDeadlineSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonTask where
  parseJSON = withObject "Task" $ \o ->
    JsonTask
      <$> o .: "name"
      <*> o .: "namespace"
      <*> o .: "schedule"
      <*> o .:? "image"
      <*> o .:? "app"
      <*> o .:? "command" .!= []
      <*> o .:? "args" .!= []
      <*> o .:? "env" .!= []
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "cpuLimit"
      <*> o .:? "memoryLimit"
      <*> o .:? "timeoutSeconds"
      <*> o .:? "concurrencyPolicy"
      <*> o .:? "restartPolicy"
      <*> o .:? "backoffLimit"
      <*> o .:? "successfulJobsHistoryLimit"
      <*> o .:? "failedJobsHistoryLimit"
      <*> o .:? "startingDeadlineSeconds"

-- | Re-validate a decoded task: re-run every smart constructor, decode the
-- enum tokens, default the numeric fields, and finally re-check the assembled
-- record with 'mkTask' (which enforces the bounds and the command-or-app
-- cross-field invariant). Any failure is a precise 'MarshalError' keyed by the
-- field.
toTask :: JsonTask -> Either LoadError Task
toTask j = do
  name' <- mapLeft (MarshalError "name") $ mkServiceName (jtName j)
  ns' <- mapLeft (MarshalError "namespace") $ mkNamespace (jtNamespace j)
  sched' <- mapLeft (MarshalError "schedule") $ mkSchedule (jtSchedule j)
  img' <- traverse (mapLeft (MarshalError "image") . mkImageRef) (jtImage j)
  app' <- traverse (mapLeft (MarshalError "app") . mkServiceName) (jtApp j)
  env' <- mapM toEnvEntry (jtEnv j)
  res' <- toTaskResources j
  cp' <- case parseConcurrencyPolicy (fromMaybe "Forbid" (jtConcurrencyPolicy j)) of
    Just p -> Right p
    Nothing ->
      Left
        ( MarshalError
            "concurrencyPolicy"
            ("unknown concurrency policy: " <> fromMaybe "" (jtConcurrencyPolicy j))
        )
  rp' <- case parseRestartPolicy (fromMaybe "Never" (jtRestartPolicy j)) of
    Just p -> Right p
    Nothing ->
      Left
        ( MarshalError
            "restartPolicy"
            ("unknown restart policy: " <> fromMaybe "" (jtRestartPolicy j))
        )
  mapLeft (MarshalError "task") $
    mkTask
      Task
        { taskName = name'
        , taskNamespace = ns'
        , taskSchedule = sched'
        , taskImage = img'
        , taskApp = app'
        , taskCommand = jtCommand j
        , taskArgs = jtArgs j
        , taskEnv = Map.fromList env'
        , taskResources = res'
        , taskTimeoutSeconds = jtTimeoutSeconds j
        , taskConcurrencyPolicy = cp'
        , taskRestartPolicy = rp'
        , taskBackoffLimit = fromMaybe 0 (jtBackoffLimit j)
        , taskSuccessfulJobsHistoryLimit = fromMaybe 3 (jtSuccessfulJobsHistoryLimit j)
        , taskFailedJobsHistoryLimit = fromMaybe 1 (jtFailedJobsHistoryLimit j)
        , taskStartingDeadlineSeconds = jtStartingDeadlineSeconds j
        }

toTaskResources :: JsonTask -> Either LoadError (Maybe Resources)
toTaskResources j =
  case (jtCpuRequest j, jtMemoryRequest j, jtCpuLimit j, jtMemoryLimit j) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Nothing
    (c, m, cl, ml) -> do
      c' <- traverse (mapLeft (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (mapLeft (MarshalError "memoryRequest") . mkQuantity) m
      cl' <- traverse (mapLeft (MarshalError "cpuLimit") . mkQuantity) cl
      ml' <- traverse (mapLeft (MarshalError "memoryLimit") . mkQuantity) ml
      Right (Just Resources {cpu = c', memory = m', cpuLimit = cl', memoryLimit = ml'})

-- | Decode the JSON a task config emits (via 'Nagare.Dsl.Config.emitTask') into
-- a validated 'Task'. The top-level @kind@ is checked first: a missing or
-- non-@Task@ kind is 'UnexpectedKind'.
decodeTask :: ByteString -> Either LoadError Task
decodeTask bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right envelope -> case jkeKind envelope of
      Just "Task" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode task: " <> Text.pack perr))
        Right jt -> toTask jt
      Just other -> Left (UnexpectedKind "Task" other)
      Nothing -> Left (UnexpectedKind "Task" "<none>")

-- | Load a 'Task' from a Haskell config-as-program source file. The config must
-- print its JSON via 'Nagare.Dsl.Config.emitTask'. A config that emits a
-- different shape is reported as 'UnexpectedKind'. Used by EP-51's @task@ CLI.
loadTask :: FilePath -> IO (Either LoadError Task)
loadTask path = fmap (>>= decodeTask) (runConfig path)
```

`mkServiceName`, `mkNamespace`, `mkQuantity`, `mkImageRef` and the `Resources`/`Task`
records are already in scope in `Load.hs` (it imports `Nagare.Dsl.Types` and now
`Nagare.Dsl.Task`). `toEnvEntry`, `mapLeft`, `runConfig`, `jkeKind`, and `JsonEnvEntry`
already exist in the module.

After Steps 1–4, build and smoke-test M1:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build
```

Expected: a clean build (warnings about unused imports are suppressed by
`-Wno-unused-imports` in the cabal `common` stanza).

### Step 5 — create `cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs`

Create the renderer. It reproduces the `Nagare.Dsl.Database.Render` pipeline
(`YP.encodePretty` + a rank-table comparator) and the `Nagare.Database.Backup`
CronJob/Job field layout.

```haskell
{-# LANGUAGE PackageImports #-}

-- | Render a 'Task' to its Kubernetes manifest (MasterPlan 10, IP2): a single
-- @batch/v1@ CronJob whose @spec.jobTemplate.spec@ is the Job template a one-off
-- run reuses. The shape reproduces the proven backup machinery in
-- @cli/nagarectl/src/Nagare/Database/Backup.hs@ (@renderBackupCronJob@,
-- @backupJobSpecValue@). Every rendered object carries the IP3 labels
-- @nagare.dev/managed-by@, @nagare.dev/task@, and — when the task references an
-- app — @nagare.dev/app@.
--
-- The bare Job @.spec@ is exposed as 'taskJobSpecValue' so EP-51's one-off run
-- and EP-52's env-injection reuse the exact same value. When 'taskApp' is set,
-- the template includes an @envFrom@ block referencing the app's managed runtime
-- ConfigMap/Secret (@nagare-env-\<app\>-runtime@ / @nagare-secret-\<app\>-runtime@,
-- @optional: true@); EP-52 owns resolving the inherited image tag at deploy time.
module Nagare.Dsl.Task.Render
  ( renderTask
  , taskJobSpecValue
  , taskCronJobName
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import "generic-lens" Data.Generics.Labels ()

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Task
import Nagare.Dsl.Types
  ( EnvScope (Runtime)
  , EnvVar (EnvLiteral, EnvSecretRef)
  , Resources
  , ScopedEnvVar
  , envNameText
  , imageRefText
  , namespaceText
  , quantityText
  , secretNameText
  , serviceNameText
  )

-- ---------------------------------------------------------------------------
-- Names (IP3)

-- | The CronJob (and one-off Job) name for a task: @nagare-task-\<name\>@.
taskCronJobName :: Task -> Text
taskCronJobName t = taskResourceName (serviceNameText (taskName t))

-- ---------------------------------------------------------------------------
-- Top-level: one CronJob document.

txt :: Text -> Text
txt = id

-- | Render the @batch/v1@ CronJob for a task. Deterministic key order via
-- 'taskConfig' makes the bytes golden-stable.
renderTask :: Task -> ByteString
renderTask = YP.encodePretty taskConfig . cronJobValue

cronJobValue :: Task -> Value
cronJobValue t =
  object
    [ "apiVersion" .= txt "batch/v1"
    , "kind" .= txt "CronJob"
    , "metadata" .= metadataValue (taskCronJobName t) t
    , "spec"
        .= object
          ( [ "schedule" .= scheduleText (taskSchedule t)
            , "concurrencyPolicy" .= concurrencyPolicyToken (taskConcurrencyPolicy t)
            , "successfulJobsHistoryLimit" .= taskSuccessfulJobsHistoryLimit t
            , "failedJobsHistoryLimit" .= taskFailedJobsHistoryLimit t
            ]
              <> startingDeadlinePairs t
              <> ["jobTemplate" .= object ["spec" .= taskJobSpecValue t]]
          )
    ]

startingDeadlinePairs :: Task -> [Pair]
startingDeadlinePairs t = case taskStartingDeadlineSeconds t of
  Just n -> ["startingDeadlineSeconds" .= n]
  Nothing -> []

-- | The Job @.spec@ body (backoffLimit + optional activeDeadlineSeconds + the
-- pod template with the single container). Reused verbatim as the CronJob's
-- @jobTemplate.spec@ AND exposed so a one-off run (EP-51) can wrap it in a bare
-- @batch/v1@ Job, and EP-52 can inject the resolved image and envFrom.
taskJobSpecValue :: Task -> Value
taskJobSpecValue t =
  object
    ( [ "backoffLimit" .= taskBackoffLimit t ]
        <> activeDeadlinePairs t
        <> [ "template"
              .= object
                [ "metadata" .= object ["labels" .= taskLabels t]
                , "spec"
                    .= object
                      [ "restartPolicy" .= restartPolicyToken (taskRestartPolicy t)
                      , "containers" .= toJSON [containerValue t]
                      ]
                ]
           ]
    )

activeDeadlinePairs :: Task -> [Pair]
activeDeadlinePairs t = case taskTimeoutSeconds t of
  Just n -> ["activeDeadlineSeconds" .= n]
  Nothing -> []

-- ---------------------------------------------------------------------------
-- Container.

containerValue :: Task -> Value
containerValue t =
  object
    ( [ "name" .= serviceNameText (taskName t) ]
        <> imagePairs t
        <> commandPairs t
        <> argsPairs t
        <> envFromPairs t
        <> envPairs t
        <> resourcesPairs (taskResources t)
    )

-- | The container @image@. When the task carries its own image it renders
-- verbatim (the deploy tag is appended by the CLI at apply time, mirroring how
-- the app renderer appends a tag — here the renderer emits the bare repo path,
-- and EP-52/EP-51 append the tag). When the task inherits an app's image, the
-- key is OMITTED here; EP-52 fills it at deploy time from the app's pushed tag.
imagePairs :: Task -> [Pair]
imagePairs t = case taskImage t of
  Just img -> ["image" .= imageRefText img]
  Nothing -> []

commandPairs :: Task -> [Pair]
commandPairs t
  | null (taskCommand t) = []
  | otherwise = ["command" .= toJSON (taskCommand t)]

argsPairs :: Task -> [Pair]
argsPairs t
  | null (taskArgs t) = []
  | otherwise = ["args" .= toJSON (taskArgs t)]

-- | The @envFrom@ block (IP5 shape). Present ONLY when the task references an
-- app: it pulls the app's managed runtime ConfigMap and Secret, each
-- @optional: true@ so a task can run before those resources exist. This mirrors
-- @Nagare.Dsl.Render.envFromField@ for app containers. EP-52 owns populating the
-- referenced resources at deploy time.
envFromPairs :: Task -> [Pair]
envFromPairs t = case taskApp t of
  Nothing -> []
  Just app ->
    let a = serviceNameText app
     in [ "envFrom"
            .= toJSON
              [ object
                  [ "configMapRef"
                      .= object ["name" .= ("nagare-env-" <> a <> "-runtime"), "optional" .= True]
                  ]
              , object
                  [ "secretRef"
                      .= object ["name" .= ("nagare-secret-" <> a <> "-runtime"), "optional" .= True]
                  ]
              ]
        ]

-- | The inline container @env@: only 'Runtime'-scoped entries render (matching
-- how the app renderer drops build-only vars). Sorted by name via
-- 'Map.toAscList' for determinism. Omitted entirely when no Runtime entries
-- remain.
envPairs :: Task -> [Pair]
envPairs t
  | null entries = []
  | otherwise = ["env" .= toJSON entries]
  where
    entries =
      [ envEntry (envNameText n) sev
      | (n, sev) <- Map.toAscList (taskEnv t)
      , Set.member Runtime (sev ^. #scopes)
      ]

envEntry :: Text -> ScopedEnvVar -> Value
envEntry n sev = case sev ^. #value of
  EnvLiteral lit -> object ["name" .= n, "value" .= lit]
  EnvSecretRef sn ->
    object
      [ "name" .= n
      , "valueFrom" .= object ["secretKeyRef" .= object ["name" .= secretNameText sn, "key" .= n]]
      ]

-- | The @resources@ block (same requests/limits shape the DB renderer uses):
-- each sub-block omitted when empty; the whole block omitted when absent.
resourcesPairs :: Maybe Resources -> [Pair]
resourcesPairs Nothing = []
resourcesPairs (Just res)
  | null reqs && null lims = []
  | otherwise = ["resources" .= object (reqBlock <> limBlock)]
  where
    reqs = quantities (res ^. #cpu) (res ^. #memory)
    lims = quantities (res ^. #cpuLimit) (res ^. #memoryLimit)
    reqBlock = if null reqs then [] else ["requests" .= object reqs]
    limBlock = if null lims then [] else ["limits" .= object lims]
    quantities mc mm =
      maybe [] (\q -> ["cpu" .= quantityText q]) mc
        <> maybe [] (\q -> ["memory" .= quantityText q]) mm

-- ---------------------------------------------------------------------------
-- Labels (IP3) and metadata.

-- | The IP3 labels stamped on every rendered object. @nagare.dev/app@ appears
-- only when the task references an app.
taskLabels :: Task -> Value
taskLabels t =
  object
    ( [ "nagare.dev/managed-by" .= txt "nagarectl"
      , "nagare.dev/task" .= serviceNameText (taskName t)
      ]
        <> case taskApp t of
          Just app -> ["nagare.dev/app" .= serviceNameText app]
          Nothing -> []
    )

metadataValue :: Text -> Task -> Value
metadataValue n t =
  object
    [ "name" .= n
    , "namespace" .= namespaceText (taskNamespace t)
    , "labels" .= taskLabels t
    ]

-- ---------------------------------------------------------------------------
-- YAML key ordering (mirrors Nagare.Dsl.Database.Render.dbConfig).

taskConfig :: YP.Config
taskConfig = YP.setConfCompare keyCompare YP.defConfig

keyCompare :: Text -> Text -> Ordering
keyCompare a b = compare (rank a, a) (rank b, b)
  where
    rank :: Text -> Int
    rank k = maybe maxBound id (lookup k ranks)
    ranks :: [(Text, Int)]
    ranks =
      [ -- top-level document keys
        ("apiVersion", 0)
      , ("kind", 1)
      , ("metadata", 2)
      , ("spec", 3)
      , -- metadata
        ("name", 0)
      , ("namespace", 1)
      , ("labels", 2)
      , -- labels (non-alphabetical contract order)
        ("nagare.dev/managed-by", 0)
      , ("nagare.dev/task", 1)
      , ("nagare.dev/app", 2)
      , -- CronJob spec
        ("schedule", 0)
      , ("concurrencyPolicy", 1)
      , ("successfulJobsHistoryLimit", 2)
      , ("failedJobsHistoryLimit", 3)
      , ("startingDeadlineSeconds", 4)
      , ("jobTemplate", 5)
      , -- Job spec
        ("backoffLimit", 0)
      , ("activeDeadlineSeconds", 1)
      , ("template", 2)
      , -- pod spec
        ("restartPolicy", 0)
      , ("containers", 1)
      , -- container
        ("image", 1)
      , ("command", 2)
      , ("args", 3)
      , ("envFrom", 4)
      , ("env", 5)
      , ("resources", 6)
      , -- envFrom entry
        ("configMapRef", 0)
      , ("secretRef", 1)
      , ("optional", 1)
      , -- env entry
        ("value", 1)
      , ("valueFrom", 2)
      , ("secretKeyRef", 0)
      , ("key", 1)
      , -- resources
        ("requests", 0)
      , ("limits", 1)
      , ("cpu", 0)
      , ("memory", 1)
      ]
```

Then add `Nagare.Dsl.Task.Render` to the cabal `exposed-modules` (per Step 2's note) and
rebuild:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build
```

### Step 6 — add the standalone fixture

Create the directory and file `cli/nagare-dsl/test/fixtures/task/standalone/nagare/Config.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | A standalone scheduled-task descriptor — the config-as-program surface a
-- task author ships. @nagarectl@/the loader compiles-and-runs it; every field
-- is built through EP-50's smart constructors, so a bad value is a compile-time
-- or load-time error. This task runs in its own image with its own env; it does
-- not reference an app.
module Main (main) where

import Data.Map qualified as Map
import Nagare.Dsl.Config (emitTask)
import Nagare.Dsl.Task
import Nagare.Dsl.Types
  ( EnvVar (EnvLiteral)
  , mkEnvName
  , mkImageRef
  , mkNamespace
  , runtimeScoped
  )

task :: Either String Task
task = mapLeft show $ do
  n <- mkServiceNameE "cleanup"
  ns <- mkNamespace "personal"
  sched <- mkSchedule "0 3 * * *"
  img <- mkImageRef "gcr.io/myproject/notes"
  varName <- mkEnvName "DRY_RUN"
  mkTask
    Task
      { taskName = n
      , taskNamespace = ns
      , taskSchedule = sched
      , taskImage = Just img
      , taskApp = Nothing
      , taskCommand = ["python", "manage.py", "cleanup"]
      , taskArgs = []
      , taskEnv = Map.fromList [(varName, runtimeScoped (EnvLiteral "false"))]
      , taskResources = Nothing
      , taskTimeoutSeconds = Just 600
      , taskConcurrencyPolicy = Forbid
      , taskRestartPolicy = Never
      , taskBackoffLimit = 0
      , taskSuccessfulJobsHistoryLimit = 3
      , taskFailedJobsHistoryLimit = 1
      , taskStartingDeadlineSeconds = Nothing
      }
  where
    mkServiceNameE = mkServiceName'
    mkServiceName' = \s -> mapLeftToText (Nagare.Dsl.Types.mkServiceName s)
    -- (see note below; in practice import mkServiceName directly)

main :: IO ()
main = case task of
  Left err -> ioError (userError err)
  Right t -> emitTask t

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right
```

The fiddly `mkServiceName` wrapper above is only to keep the example honest about imports.
In the real fixture, import `mkServiceName` from `Nagare.Dsl.Types` and use it directly,
exactly like the database fixtures import `mkNamespace`/`mkQuantity`. The clean form:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Map qualified as Map
import Nagare.Dsl.Config (emitTask)
import Nagare.Dsl.Task
import Nagare.Dsl.Types
  ( EnvVar (EnvLiteral)
  , mkEnvName
  , mkImageRef
  , mkNamespace
  , mkServiceName
  , runtimeScoped
  )

task :: Either String Task
task = mapLeft show $ do
  n <- mkServiceName "cleanup"
  ns <- mkNamespace "personal"
  sched <- mkSchedule "0 3 * * *"
  img <- mkImageRef "gcr.io/myproject/notes"
  varName <- mkEnvName "DRY_RUN"
  mkTask
    Task
      { taskName = n
      , taskNamespace = ns
      , taskSchedule = sched
      , taskImage = Just img
      , taskApp = Nothing
      , taskCommand = ["python", "manage.py", "cleanup"]
      , taskArgs = []
      , taskEnv = Map.fromList [(varName, runtimeScoped (EnvLiteral "false"))]
      , taskResources = Nothing
      , taskTimeoutSeconds = Just 600
      , taskConcurrencyPolicy = Forbid
      , taskRestartPolicy = Never
      , taskBackoffLimit = 0
      , taskSuccessfulJobsHistoryLimit = 3
      , taskFailedJobsHistoryLimit = 1
      , taskStartingDeadlineSeconds = Nothing
      }

main :: IO ()
main = case task of
  Left err -> ioError (userError err)
  Right t -> emitTask t

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right
```

Use the **clean form**. Smoke-test the JSON:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
runghc -XGHC2024 -itest/fixtures/task/standalone/nagare test/fixtures/task/standalone/nagare/Config.hs
```

Expected output (a single line; reformatted here for reading):

```json
{"kind":"Task","name":"cleanup","namespace":"personal","schedule":"0 3 * * *",
 "image":"gcr.io/myproject/notes","app":null,
 "command":["python","manage.py","cleanup"],"args":[],
 "env":[{"varName":"DRY_RUN","kind":"Literal","value":"false","scopes":["Runtime"]}],
 "cpuRequest":null,"memoryRequest":null,"cpuLimit":null,"memoryLimit":null,
 "timeoutSeconds":600,"concurrencyPolicy":"Forbid","restartPolicy":"Never",
 "backoffLimit":0,"successfulJobsHistoryLimit":3,"failedJobsHistoryLimit":1,
 "startingDeadlineSeconds":null}
```

### Step 7 — wire `Task` tests into `test/Spec.hs` and generate the standalone golden

Edit `cli/nagare-dsl/test/Spec.hs`. Add imports and a `taskTests` group, and register it in
`main`'s `testGroup` list. Add these imports near the existing ones:

```haskell
import Nagare.Dsl.Config (encodeDatabase, encodeDeployment, encodeTask)
import Nagare.Dsl.Load (LoadError (..), decodeDatabase, decodeDeployment, decodeTask, loadDeployment)
import Nagare.Dsl.Task
import Nagare.Dsl.Task.Render (renderTask)
```

Add a fixture value and the test group:

```haskell
-- | A standalone scheduled task, assembled through smart constructors. Mirrors
-- test/fixtures/task/standalone/nagare/Config.hs.
standaloneTask :: Task
standaloneTask =
  unsafe $
    mkTask
      Task
        { taskName = unsafe (mkServiceName "cleanup")
        , taskNamespace = unsafe (mkNamespace "personal")
        , taskSchedule = unsafe (mkSchedule "0 3 * * *")
        , taskImage = Just (unsafe (mkImageRef "gcr.io/myproject/notes"))
        , taskApp = Nothing
        , taskCommand = ["python", "manage.py", "cleanup"]
        , taskArgs = []
        , taskEnv =
            Map.fromList
              [(unsafe (mkEnvName "DRY_RUN"), runtimeScoped (EnvLiteral "false"))]
        , taskResources = Nothing
        , taskTimeoutSeconds = Just 600
        , taskConcurrencyPolicy = Forbid
        , taskRestartPolicy = Never
        , taskBackoffLimit = 0
        , taskSuccessfulJobsHistoryLimit = 3
        , taskFailedJobsHistoryLimit = 1
        , taskStartingDeadlineSeconds = Nothing
        }

-- | A task associated with the @notes@ app: it inherits @notes@'s image
-- (taskImage = Nothing) and its runtime env/secret (rendered as envFrom), and
-- carries the nagare.dev/app label.
appTask :: Task
appTask =
  unsafe $
    mkTask
      Task
        { taskName = unsafe (mkServiceName "sync")
        , taskNamespace = unsafe (mkNamespace "personal")
        , taskSchedule = unsafe (mkSchedule "*/15 * * * *")
        , taskImage = Nothing
        , taskApp = Just (unsafe (mkServiceName "notes"))
        , taskCommand = ["python", "manage.py", "sync"]
        , taskArgs = []
        , taskEnv = Map.empty
        , taskResources = Nothing
        , taskTimeoutSeconds = Nothing
        , taskConcurrencyPolicy = Forbid
        , taskRestartPolicy = Never
        , taskBackoffLimit = 2
        , taskSuccessfulJobsHistoryLimit = 3
        , taskFailedJobsHistoryLimit = 1
        , taskStartingDeadlineSeconds = Nothing
        }

taskTests :: [TestTree]
taskTests =
  [ testGroup
      "mkSchedule"
      [ testCase "accepts 0 3 * * *" $ assertRight (mkSchedule "0 3 * * *")
      , testCase "accepts a step */15 * * * *" $ assertRight (mkSchedule "*/15 * * * *")
      , testCase "accepts a list and range 1,15 0-6 * * 1-5" $
          assertRight (mkSchedule "1,15 0-6 * * 1-5")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkSchedule "")
      , testCase "rejects 4 fields" $ assertLeftContains "5" (mkSchedule "0 3 * *")
      , testCase "rejects out-of-range minute" $ assertLeftContains "minute" (mkSchedule "60 3 * * *")
      , testCase "rejects garbage" $ assertLeftContains "minute" (mkSchedule "x 3 * * *")
      ]
  , testGroup
      "mkTask invariants"
      [ testCase "rejects inheriting image with no app" $
          assertLeftContains "inherit" (mkTask standaloneTask {taskImage = Nothing, taskApp = Nothing})
      , testCase "rejects negative backoffLimit" $
          assertLeftContains ">= 0" (mkTask standaloneTask {taskBackoffLimit = -1})
      , testCase "rejects non-positive timeout" $
          assertLeftContains "> 0" (mkTask standaloneTask {taskTimeoutSeconds = Just 0})
      ]
  , testGroup
      "JSON round-trip and kind discrimination"
      [ testCase "standalone task survives emit -> decode round-trip" $
          decodeTask (toStrict (encodeTask standaloneTask)) @?= Right standaloneTask
      , testCase "app-associated task round-trips" $
          decodeTask (toStrict (encodeTask appTask)) @?= Right appTask
      , testCase "decoding a Task as a Deployment is UnexpectedKind" $
          case decodeDeployment (toStrict (encodeTask standaloneTask)) of
            Left (UnexpectedKind "Deployment" "Task") -> pure ()
            other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
      , testCase "decoding a Deployment as a Task is UnexpectedKind" $
          case decodeTask (toStrict (encodeDeployment helloDep)) of
            Left (UnexpectedKind "Task" "<none>") -> pure ()
            other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
      , testCase "an inheriting task with no app fails to decode (MarshalError task)" $
          case decodeTask
            "{\"kind\":\"Task\",\"name\":\"x\",\"namespace\":\"personal\",\"schedule\":\"0 3 * * *\",\"command\":[\"echo\"]}" of
            Right _ -> pure ()
            other -> assertFailure ("expected Right (own command, no app), got: " <> show other)
      ]
  , testGroup
      "renderer goldens"
      [ goldenVsString "renderTask standalone" "test/golden/task-standalone.cronjob.yaml" $
          pure (fromStrict (renderTask standaloneTask))
      , goldenVsString "renderTask app-associated" "test/golden/task-app-associated.cronjob.yaml" $
          pure (fromStrict (renderTask appTask))
      ]
  ]
```

Register the group in `main`:

```haskell
      , testGroup "Nagare.Dsl.Task (EP-50)" taskTests
```

Now generate the golden files. `tasty-golden` writes a missing golden on first run via the
`--accept` flag:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test nagare-dsl-test --test-options=--accept
```

This creates `test/golden/task-standalone.cronjob.yaml` and
`test/golden/task-app-associated.cronjob.yaml`. **Open both and read them** to confirm they
are correct before committing — `--accept` blindly trusts the current output. The standalone
golden should read like this:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-cleanup
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: cleanup
spec:
  schedule: 0 3 * * *
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 600
      template:
        metadata:
          labels:
            nagare.dev/managed-by: nagarectl
            nagare.dev/task: cleanup
        spec:
          restartPolicy: Never
          containers:
          - name: cleanup
            image: gcr.io/myproject/notes
            command:
            - python
            - manage.py
            - cleanup
            env:
            - name: DRY_RUN
              value: 'false'
```

### Step 8 — the app-associated golden (M3)

The `task-app-associated.cronjob.yaml` golden (written in Step 7 by `--accept`) should show
the inheritance shape: **no** `image:` key (inherited at deploy time by EP-52), an
`envFrom:` block, and the `nagare.dev/app: notes` label on every metadata block:

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
```

(Exact quoting of `'*/15 * * * *'` and `'false'` is whatever the YAML pretty-printer
chooses; accept what it emits and pin it as the golden. The structural keys — `envFrom`,
the two `*Ref` names, `optional: true`, the absent `image`, the `nagare.dev/app` label —
are what matter.)

### Step 9 — full test run

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test nagare-dsl-test
```

Expected tail of the transcript:

```text
nagare-dsl
  Nagare.Dsl.Types: ...all pass...
  Nagare.Dsl.Database (EP-44): ...all pass...
  Nagare.Dsl.Task (EP-50)
    mkSchedule
      accepts 0 3 * * *:                         OK
      accepts a step */15 * * * *:               OK
      accepts a list and range 1,15 0-6 * * 1-5: OK
      rejects empty:                             OK
      rejects 4 fields:                          OK
      rejects out-of-range minute:               OK
      rejects garbage:                           OK
    mkTask invariants:                           OK (3 tests)
    JSON round-trip and kind discrimination:     OK (5 tests)
    renderer goldens
      renderTask standalone:                     OK
      renderTask app-associated:                 OK
  ...

All N tests passed (0.NNs)
```

Confirm no existing golden changed:

```bash
git -C /Users/shinzui/Keikaku/bokuno/nagare status --porcelain
```

The only golden-file lines should be the two **new** files
`cli/nagare-dsl/test/golden/task-standalone.cronjob.yaml` and
`cli/nagare-dsl/test/golden/task-app-associated.cronjob.yaml` (shown as untracked/added,
never modified). No `db-*.yaml`, `hello.*`, `rich.*`, `preset-*`, `server-site.*`, or
`static-site.*` golden may appear as modified.


## Validation and Acceptance

Acceptance is behavioral, not "the code compiles." There are three observable proofs.

**Proof 1 — the model rejects illegal tasks (run the tests).** From
`cli/nagare-dsl`, `cabal test nagare-dsl-test` passes the `mkSchedule` group (a 4-field
cron, an out-of-range minute, and pure garbage are each `Left`), the `mkTask invariants`
group (an inheriting task with no app, a negative backoff, and a zero timeout are each
`Left`), and the round-trip group. This proves the typed model does real work: invalid
input cannot become a `Task`.

**Proof 2 — the JSON round-trips through `runghc` (end-to-end).** Run the fixture as a
program and decode its output in one shell pipeline. This proves the *whole* serialization
path — `emitTask` → JSON on stdout → `decodeTask` re-validating — not just an in-memory
equality:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
runghc -XGHC2024 -itest/fixtures/task/standalone/nagare \
  test/fixtures/task/standalone/nagare/Config.hs | head -c 40
```

Expected: the bytes begin `{"kind":"Task","name":"cleanup"`. (The in-process equality
`decodeTask (toStrict (encodeTask standaloneTask)) == Right standaloneTask` is the unit
test that asserts the round-trip is lossless.)

**Proof 3 — the renderer produces the right CronJob (golden diff).** The two golden tests
pin the rendered bytes. To *see* the rendered manifest for the standalone task without the
test harness, you can read the golden directly after Step 7:

```bash
cat /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl/test/golden/task-standalone.cronjob.yaml
```

Expected: a `batch/v1` CronJob named `nagare-task-cleanup`, schedule `0 3 * * *`,
`concurrencyPolicy: Forbid`, a `jobTemplate.spec` with `backoffLimit: 0`,
`activeDeadlineSeconds: 600`, `restartPolicy: Never`, and a single container running
`python manage.py cleanup` with the `DRY_RUN` env var. The app-associated golden shows the
`envFrom` block, no `image`, and the `nagare.dev/app: notes` label.

To regenerate goldens after an intentional renderer change, run with `--accept`
(`cabal test nagare-dsl-test --test-options=--accept`) and re-read the files. Never accept
blindly: a golden that changed unexpectedly is the test catching a regression.


## Idempotence and Recovery

Every step in this plan is safe to repeat. The edits are additive: new modules, new
exports, new test fixtures, and new golden files. Re-running `cabal build` or
`cabal test nagare-dsl-test` is idempotent. The `runghc` smoke test reads a fixture and
writes nothing.

If `cabal build` fails with "module `Nagare.Dsl.Task.Render` is a member of `exposed-modules`
but its source file was not found," you added the cabal entry before creating the file —
either create the file (Step 5) or remove the entry until then. This is the one ordering
trap; the cabal note in Step 2 calls it out.

If a golden test fails on first run because the golden does not exist yet, run once with
`--test-options=--accept` to create it, then **read the file** and confirm it matches the
expected YAML in Steps 7–8 before relying on it. If a golden test fails *after* the golden
exists, that is the test doing its job: either you changed the renderer (re-accept
deliberately and inspect the diff) or you introduced a regression (fix the renderer). To
discard a wrongly-accepted golden, `git checkout -- <path>` restores the committed version,
or `git clean -- <path>` removes a not-yet-committed new golden.

If the `mkSchedule` validator rejects a cron string you believe is valid, recall the
deliberately-restricted grammar: only `*`, plain numbers in range, `a-b` ranges, comma
lists, and `*/n` or `a-b/n` steps are accepted; named months/days (`JAN`, `MON`) and the
`@daily` macros are rejected on purpose (Decision Log). Widen the grammar only with a new
test and a Decision-Log entry.

Commits made while implementing this plan must carry the trailers:

```text
MasterPlan: docs/masterplans/10-scheduled-tasks-for-nagare.md
ExecPlan: docs/plans/50-typed-task-model-and-cronjob-job-renderer.md
Intention: intention_01kts6qyg4ezsbj500ksjr90r1
```


## Interfaces and Dependencies

This plan depends only on what already ships in the `cli/nagare-dsl/` package: `aeson`
(JSON `object`/`.=`/`toJSON`, `eitherDecodeStrict`, `FromJSON`), `yaml` (the
`Data.Yaml.Pretty` ordered encoder), `containers` (`Data.Map`, `Data.Set`), `text`,
`bytestring`, and `generic-lens` (the `#field` lens labels). It reuses, and must not
redefine, the smart-constructed types in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`
(`ServiceName`, `Namespace`, `ImageRef`, `Quantity`, `Resources`, `EnvName`, `EnvVar`,
`EnvScope`, `ScopedEnvVar`, `SecretName`, and their constructors/accessors). It
soft-depends on the spike `docs/plans/49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md`
only so the rendered CronJob/Job shapes match what that spike proves on the live cluster;
nothing here imports the spike.

These are the final signatures the later plans (EP-51, EP-52, EP-53) import. They are the
concrete form of MasterPlan Integration Points IP1, IP2, and IP3.

**`Nagare.Dsl.Task` (IP1 — the typed model and validation):**

```haskell
-- Schedule (validated 5-field cron)
data Schedule
mkSchedule   :: Text -> Either Text Schedule
scheduleText :: Schedule -> Text

-- Policies
data ConcurrencyPolicy = Forbid | Allow | Replace
concurrencyPolicyToken  :: ConcurrencyPolicy -> Text
parseConcurrencyPolicy  :: Text -> Maybe ConcurrencyPolicy
data RestartPolicy = Never | OnFailure
restartPolicyToken :: RestartPolicy -> Text
parseRestartPolicy :: Text -> Maybe RestartPolicy

-- The task record (no hidden constructor; safety from field types + mkTask)
data Task = Task
  { taskName                       :: ServiceName
  , taskNamespace                  :: Namespace
  , taskSchedule                   :: Schedule
  , taskImage                      :: Maybe ImageRef      -- Nothing = inherit app image
  , taskApp                        :: Maybe ServiceName   -- IP5 shape; EP-52 owns semantics
  , taskCommand                    :: [Text]
  , taskArgs                       :: [Text]
  , taskEnv                        :: Map EnvName ScopedEnvVar
  , taskResources                  :: Maybe Resources
  , taskTimeoutSeconds             :: Maybe Int           -- renders activeDeadlineSeconds
  , taskConcurrencyPolicy          :: ConcurrencyPolicy   -- default Forbid
  , taskRestartPolicy              :: RestartPolicy        -- default Never
  , taskBackoffLimit               :: Int                  -- >= 0, default 0
  , taskSuccessfulJobsHistoryLimit :: Int                  -- default 3
  , taskFailedJobsHistoryLimit     :: Int                  -- default 1
  , taskStartingDeadlineSeconds    :: Maybe Int
  }

mkTask           :: Task -> Either Text Task   -- bounds + command-or-app invariant
scheduledTask    :: Text -> Text -> Text -> Text -> Either Text Task  -- name sched image cmd
taskResourceName :: Text -> Text               -- "nagare-task-" <> name  (IP3)
```

**`Nagare.Dsl.Config` (IP1 — the JSON shape):**

```haskell
emitTask   :: Task -> IO ()             -- prints {"kind":"Task", ...} to stdout
encodeTask :: Task -> LBS.ByteString    -- the exact bytes (for round-trip tests)
```

The JSON object carries the discriminator `"kind": "Task"` and these keys: `name`,
`namespace`, `schedule`, `image` (nullable), `app` (nullable), `command`, `args`, `env`
(array of `{varName, kind, value|secretName, scopes}`), `cpuRequest`/`memoryRequest`/
`cpuLimit`/`memoryLimit` (all nullable), `timeoutSeconds` (nullable),
`concurrencyPolicy`, `restartPolicy`, `backoffLimit`, `successfulJobsHistoryLimit`,
`failedJobsHistoryLimit`, `startingDeadlineSeconds` (nullable).

**`Nagare.Dsl.Load` (IP1 — the decode/re-validate path):**

```haskell
decodeTask :: ByteString -> Either LoadError Task  -- checks kind, re-runs constructors
loadTask   :: FilePath  -> IO (Either LoadError Task)  -- runghc the Config.hs, then decode
```

`decodeTask` reports a missing/other `kind` as `UnexpectedKind "Task" <got>`, an invalid
field as `MarshalError "<field>" "<message>"` (e.g. `MarshalError "schedule" ...`,
`MarshalError "task" "...inherit..."` for the cross-field invariant). EP-51's task CLI
calls `loadTask` to provision declared tasks; EP-52's app deploy path loads tasks
associated with an app.

**`Nagare.Dsl.Task.Render` (IP2 — the rendered shapes; IP3 — names/labels):**

```haskell
renderTask       :: Task -> ByteString  -- one batch/v1 CronJob, deterministic bytes
taskJobSpecValue :: Task -> Value       -- the bare Job .spec (EP-51 one-off; EP-52 inject)
taskCronJobName  :: Task -> Text        -- "nagare-task-" <> taskName  (IP3)
```

The rendered CronJob is named `nagare-task-<taskName>` and every object carries the labels
`nagare.dev/managed-by: nagarectl`, `nagare.dev/task: <taskName>`, and — when `taskApp` is
`Just app` — `nagare.dev/app: <app>`. The `spec` has `schedule`, `concurrencyPolicy`,
`successfulJobsHistoryLimit`, `failedJobsHistoryLimit`, optional `startingDeadlineSeconds`,
and `jobTemplate.spec = taskJobSpecValue task`. The Job `.spec` has `backoffLimit`,
optional `activeDeadlineSeconds`, and `template.spec` with `restartPolicy` and one
`containers` entry (`name`, optional `image`, optional `command`/`args`, optional
`envFrom` when an app is referenced, optional Runtime-scoped `env`, optional `resources`).
EP-51 discovers these CronJobs by the IP3 label selector
`nagare.dev/managed-by=nagarectl,nagare.dev/task` and derives one-off Jobs via
`kubectl create job --from=cronjob/nagare-task-<task>`; EP-52 fills the inherited `image`
and resolves the `envFrom` resources at deploy time.
