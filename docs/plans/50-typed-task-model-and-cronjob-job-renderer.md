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

Full plan before trimming: [50-typed-task-model-and-cronjob-job-renderer.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/50-typed-task-model-and-cronjob-job-renderer.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- **Two additive exports added later for EP-52.** While implementing
  `docs/plans/52-...` (the deploy-time resolver), `Nagare.Dsl.Task.Render` gained two exports —
  `cronJobValue :: Task -> Value` (the un-encoded CronJob) and `encodeCronJob :: Value ->
  ByteString` (the deterministic ordered encoder) — and `renderTask` was refactored to
  `encodeCronJob . cronJobValue` (byte-identical output; the goldens are unchanged). This lets
  EP-52 patch the container `Value` (inject the resolved image and `NAGARE_RUN_ID`) and re-encode
  byte-stably, keeping this module the single owner of the manifest shape. Purely additive; no
  behavior change to the standalone/app-associated goldens.

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

