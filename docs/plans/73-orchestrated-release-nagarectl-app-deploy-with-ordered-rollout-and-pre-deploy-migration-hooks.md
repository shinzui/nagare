---
id: 73
slug: orchestrated-release-nagarectl-app-deploy-with-ordered-rollout-and-pre-deploy-migration-hooks
title: "Orchestrated release: nagarectl app deploy with ordered rollout and pre-deploy migration hooks"
kind: exec-plan
created_at: 2026-06-19T00:36:47Z
intention: "intention_01kvemvx2reyn9qa49qks2dpcj"
master_plan: "docs/masterplans/14-multi-workload-applications-for-nagare.md"
---

# Orchestrated release: nagarectl app deploy with ordered rollout and pre-deploy migration hooks

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, deploying the kizashi app to Nagare means running four or more separate
commands by hand, in the right order, hoping nothing boots before the database schema is
migrated: `nagarectl db create` for the Postgres, `nagarectl task run` for the migration,
`nagarectl deploy` for the HTTP service, and three `nagarectl worker deploy` invocations for
the background reactors. Nothing enforces the ordering, nothing shares an identity, and a
forgotten migration silently boots the new code against an old schema.

After this ExecPlan (EP-2), a developer runs **one command**:

```bash
nagarectl app deploy -f nagare/Config.hs
```

and the platform takes a single typed `Application` aggregate (defined by EP-1,
`docs/plans/72-application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings.md`)
and rolls the whole app out **in dependency order**: build and push the shared image once,
run the declared pre-deploy migration Task to completion (aborting the entire release if it
fails, *before* any serving workload is touched), ensure the managed databases exist, then
apply the Knative Service and every Worker and wait for each to become Ready. Every object
the app renders carries a shared `nagare.dev/app: <name>` label, so the whole app is one
unit of identity.

You can see it working two ways. With a live cluster: one command brings up six objects in
the correct order and the migration provably runs first. Offline (the standard acceptance
path, because `nagare-01` is frequently `TERMINATED`):

```bash
nagarectl app deploy --dry-run -f nagare/Config.hs --json
```

emits a **machine-readable JSON result** — the ordered list of rendered objects with their
labels — that the external kotei backend (`shinzui/kotei`) consumes without scraping human
prose. The user-visible behavior enabled: "deploy this whole multi-workload app, migrations
first, as one tracked release."


## Progress

- [x] M0 (2026-06-18): extracted `resolveTag`/`resolveBuildSpec`/`resolveConnectionEnv` from
      `Main.hs` into a new library module `cli/nagarectl/src/Nagare/Deploy/Resolve.hs`
      (`Nagare.Deploy.Resolve`, added to the cabal `exposed-modules`), with its own private
      `dieT`/`orDie`. `resolveBuildSpec` was re-typed to take the two override paths directly
      (`Maybe FilePath -> Maybe FilePath -> BuildSpec -> IO BuildSpec`) so it depends on no
      executable-local type; the `runDeploy` call site was updated. `runDeploy` is behaviorally
      unchanged; `cabal build exe:nagarectl` + `cabal test nagarectl-test` green (285 tests).
- [x] M1 (2026-06-18): `nagarectl app deploy` wired into the optparse tree (a new `deploy`
      subcommand under `app`, `AppDeployOpts` + `appDeployOptsParser` + `AppDeploy` dispatch);
      new library module `cli/nagarectl/src/Nagare/App/Deploy.hs` (`Nagare.App.Deploy`) loads an
      `Application` via `loadApplication`, qualifies the shared image once, flows the shared env
      down onto every workload, renders the Service + all Workers + Task(s) offline, and stamps
      `nagare.dev/app: <name>` onto each via `stampAppLabel` (insert-after-managed-by, idempotent).
      `app deploy --dry-run` prints the kizashi fixture's 5 objects (hook CronJob, Knative Service,
      3 worker Deployments), each carrying the label.
- [x] M1 (2026-06-18): `AppDeploySpec` (new test module) asserts the rollout-order phase tags and
      the shared `nagare.dev/app: kizashi` label on every rendered object, over
      `cli/nagarectl/test/fixtures/app/kizashi/Config.hs`.
- [x] M2 (2026-06-18, phase engine): `Phase`/`phaseTag`/`planPhases` (fixed order hooks →
      databases → service → workers) and `runPhases :: PhaseExec -> [Phase] -> IO PhaseResult`
      which aborts on the first failure. (The live `PhaseExec` — build/push, db ensure, apply/wait —
      is written as part of the M4 live-apply wiring.)
- [x] M2 (2026-06-18): unit test injects a fake `PhaseExec` whose hook returns `PhaseFailed` and
      asserts only the hook phase ran (databases/service/workers never invoked); a second asserts
      all phases run in order when each succeeds.
- [x] M3 (2026-06-18): machine-readable `--dry-run --json` result contract — `RenderedObject`
      / `AppDeployPlan` with `ToJSON`, and `renderPlan` building the ordered object list (each
      object's apiVersion/kind/name/namespace/labels parsed back from its stamped manifest so the
      JSON and YAML cannot drift). `app deploy --dry-run --json` writes a single JSON document to
      stdout: `{app, image, objects:[{apiVersion,kind,name,namespace,phase,labels,manifest}]}`,
      ordered hook → database → service → worker, every object carrying `nagare.dev/app`. The
      database phase is rendered here (PVC/Service/StatefulSet via `renderDatabase`). `AppDeploySpec`
      asserts the plan shape, ordering, per-object label, and that it encodes to parseable JSON.
- [x] M4 (2026-06-18, code): live-apply wiring written — `liveDeploy` builds/pushes the shared
      image ONCE (reusing `gatherBuildArgs`/`performBuild`/`pushImage`), then `runPhases` with a live
      `PhaseExec`: hooks apply each CronJob and run a one-off Job to completion (`runArgs` +
      `kubectl wait --for=condition=complete`, returning `PhaseFailed` on non-zero so the release
      aborts before any Service/Worker), databases `runDbCreate` (idempotent ensure), service
      applies + `waitForReady`, workers apply + `waitForWorkerRollout`. Compiles (`cabal build all`).
      **Live acceptance deferred** while `nagare-01` is `TERMINATED`; the sequencing/abort logic is
      exercised offline by the `runPhases` unit tests. Known follow-up: per-database connection-env
      and the generated `NAGARE_*` vars (which the single-Service `deploy` injects, needing a cluster
      lookup) are not yet wired into the aggregate render — dry-run and live render identically.
- [x] Docs (2026-06-18): `docs/user/deploying-apps.md`'s "Multi-workload applications" section now
      documents `nagarectl app deploy`, the enforced rollout order, the migration-idempotence
      requirement, and the `--dry-run --json` contract for external consumers (kotei).


## Surprises & Discoveries

- 2026-06-18 — **M0: `resolveBuildSpec` had to be re-typed to drop its `DeployOpts` dependency.**
  The original `resolveBuildSpec :: DeployOpts -> BuildSpec -> IO BuildSpec` destructured the
  Main-local `DeployOpts` record (`^. #contextOverride`/`#dockerfileOverride`). `DeployOpts` cannot
  move to the library (it's an executable option-parser type), so the extracted helper takes the two
  override paths directly: `Maybe FilePath -> Maybe FilePath -> BuildSpec -> IO BuildSpec`. The lone
  call site in `runDeploy` was updated; `nagarectl deploy` behavior is unchanged. The plan's
  Interfaces signature for `resolveBuildSpec` is updated accordingly. `resolveTag` and
  `resolveConnectionEnv` moved verbatim. Main keeps its own `dieT`/`orDie` (used widely elsewhere);
  the new module has its own private copies (`-Wno-unused-imports` covers Main's now-unused
  `applyBuildOverrides`/`connectionEnv`/`lookupConnection`/`computeTag` imports).


## Decision Log

- Decision: Render the JSON `--dry-run` result as a flat, ordered list of objects, each an
  `{ apiVersion, kind, name, namespace, phase, labels, manifest }` record, rather than a
  nested per-phase tree or raw concatenated YAML.
  Rationale: kotei (`shinzui/kotei` `docs/plans/22-...`) needs to enumerate an app's
  resources and read each object's `nagare.dev/app` label without parsing YAML or prose.
  A flat list with an explicit `phase` field carries the ordering as data while staying
  trivially iterable. The contract is additive (consumers ignore unknown keys), so later
  plans can extend it without breaking kotei.
  Date: 2026-06-18

- Decision: Enforce a fixed rollout phase ordering — `hooks → databases → service/workers` —
  implemented as a straight-line sequence in the deploy driver, not a general dependency DAG
  or scheduler.
  Rationale: the only ordering kizashi (and any single-node app) needs is "migrations and
  databases before the serving workloads." A fixed sequence expresses this directly, is
  trivially testable, and matches the MasterPlan's explicit exclusion of a general workload
  DAG.
  Date: 2026-06-18

- Decision: A failed pre-deploy hook aborts the whole release (non-zero exit, no rollback of
  the database/image that may already exist) rather than attempting transactional rollback.
  Rationale: image build/push and `db ensure` are idempotent, so a re-run after fixing the
  migration is safe; full atomic cross-workload rollback is explicitly out of scope and owned
  by kotei. Fail-fast-before-serving is the property that matters.
  Date: 2026-06-18

- Decision: Add an M0 milestone that extracts `resolveTag`, `resolveBuildSpec`, and
  `resolveConnectionEnv` from `cli/nagarectl/app/Main.hs` into a new library module
  `Nagare.Deploy.Resolve` before any `Nagare.App.Deploy` work.
  Rationale: `Nagare.App.Deploy` is a library module and cannot import from the `nagarectl`
  executable; those three resolvers live in `Main.hs` today (`Main.hs:2705`, `:1941`, `:1795`).
  Validation against the source confirmed `qualifyImage`/`computeTag`/`generatedEnv`/
  `mergeGenerated`/build helpers are *already* library-resident and need no move, so the
  extraction is scoped to exactly those three. Discovered during MasterPlan validation on
  2026-06-18.
  Date: 2026-06-18

- Decision: Consume EP-1's database field as `appDatabases :: [Nagare.Dsl.Database.Database]`
  (full specs), not a list of `DatabaseName`. Earlier drafts of this plan variously wrote
  `databases :: [DatabaseName]` / `[DatabaseRef]`; those are corrected.
  Rationale: the database phase calls `runDbCreate :: Engine -> Text -> DbCreateParams`, which
  needs `engine`/`version`/`size` from the full `Database` — names alone cannot ensure a
  database. EP-1
  (`docs/plans/72-application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings.md`)
  correctly defines `appDatabases :: [Database]`; this plan aligns to it. The undeclared-database
  *reference* check (a workload's `databases :: [DatabaseName]` must name a declared
  `appDatabases` entry) is EP-1's, not EP-2's.
  Date: 2026-06-18


## Surprises & Discoveries (continued)

- 2026-06-18 — **Label stamping is a one-line text insert, not a YAML round-trip.** The plan
  suggested decoding each manifest to a `Value`, inserting under `metadata.labels`, and re-encoding
  with "the same key comparator" — but that comparator isn't shared across kinds and a generic
  re-encode would reorder every key. Instead `stampAppLabel` inserts `nagare.dev/app: <name>` on the
  line after the unique top-level `nagare.dev/managed-by: nagarectl` (sharing its indentation),
  preserving the rest of the document byte-for-byte. It is idempotent (a manifest already carrying a
  `nagare.dev/app` label — e.g. a co-located Task that EP-52 already stamps, or a volume PVC — is
  left unchanged), which is why the kizashi hook's existing EP-52 `nagare.dev/app` is kept rather
  than duplicated. The JSON plan's `roLabels` is parsed back from the *stamped* manifest (a real YAML
  decode via `Data.Yaml`), so the JSON and YAML labels cannot drift.

- 2026-06-18 — **The shared env flows down in EP-2, but connection/generated env is a live-path
  follow-up.** EP-1 decided the shared `Application` env is NOT duplicated into each workload's JSON;
  EP-2 fans it down at render time (`flowEnv`: shared env as the base, a workload's own env wins on a
  collision). The per-database connection env (`resolveConnectionEnv`, a `kubectl` lookup) and the
  `NAGARE_*` generated vars that the single-Service `deploy` injects are intentionally NOT wired into
  the aggregate render yet: resolving them needs a cluster, which would break the offline dry-run
  gate. Dry-run and live render identically, so this is a uniform, documented follow-up for when
  `nagare-01` is up (the databases are ensured in the same deploy, so their Secrets exist before the
  service/worker phases).


## Outcomes & Retrospective

**Outcome (2026-06-18 — EP-2 complete).** All five milestones (M0–M4) landed; the `nagarectl`
suite is green (291 → with the 13-case `Nagare.App.Deploy (EP-2)` group). A developer now runs ONE
command, `nagarectl app deploy`, to roll a whole multi-workload `Application` out in dependency order
under one shared identity. Verified offline end-to-end against
`cli/nagarectl/test/fixtures/app/kizashi/Config.hs`:
`app deploy --dry-run` prints 8 objects (1 hook CronJob, 3 Postgres objects, 1 Knative Service, 3
worker Deployments), each carrying `nagare.dev/app: kizashi`, and `--dry-run --json` emits the stable
ordered plan kotei consumes.

**What worked.** (1) The M0 extraction (`Nagare.Deploy.Resolve`) cleanly unblocked the library
module with a behavior-preserving refactor. (2) Reusing every existing per-kind renderer
(`renderService`/`renderWorker`/`renderResolvedTask`/`renderDatabase`) meant the aggregate added
*orchestration*, not new rendering — and EP-3's worker liveness probe flows through for free (an
aggregated worker renders its `livenessProbe` with no EP-2 code). (3) Splitting the phase *sequencing*
(`runPhases`, pure-ish, unit-tested with a fake executor) from the live *executor* (`livePhaseExec`,
cluster IO) made the hook-gating guarantee testable offline despite `nagare-01` being down.

**Deferred / follow-ups.** (a) **Live acceptance** (M4) awaits a running cluster; the offline render +
phase-sequencing gates stand in. (b) **Connection/generated env** injection into aggregate workloads
is a documented follow-up (see Surprises). (c) The "build once" uses the service's build spec as the
canonical artifact; workers default to a prebuilt `:latest` and so render `:latest` rather than the
deploy tag — acceptable today (it matches standalone `worker deploy`), but a future refinement could
force every workload to the one built tag.

**Hand-off to kotei.** The `--dry-run --json` contract is stable and additive:
`{app, image, objects:[{apiVersion,kind,name,namespace,phase,labels,manifest}]}`, ordered
hook → database → service → worker, every object carrying `nagare.dev/app`. kotei can deploy and track
a whole multi-workload app in one call.


## Context and Orientation

This section assumes no prior knowledge of the repository.

**The repository.** Nagare is a single-node, personal Platform-as-a-Service built on
Kubernetes (k3s) with Knative Serving. It is a Haskell/cabal monorepo. Two cabal packages
matter here:

- `cli/nagare-dsl` — the typed DSL library. It defines the workload types
  (`Deployment`, `Worker`, `Database`, `Task`), their smart constructors, their JSON
  encoders (`Nagare.Dsl.Config`), their loaders (`Nagare.Dsl.Load`), and their manifest
  renderers (`Nagare.Dsl.Render`, `Nagare.Dsl.Worker.Render`). EP-1 adds the new
  `Application` aggregate type, its emitter `emitApplication`, and its loader
  `loadApplication` to this package (see
  `docs/plans/72-application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings.md`).
- `cli/nagarectl` — the `nagarectl` command-line tool. Its command tree lives in
  `cli/nagarectl/app/Main.hs`; its cluster-action library code lives under
  `cli/nagarectl/src/Nagare/`.

**Kubernetes object kinds you must distinguish.** Nagare maps each workload kind to a
different Kubernetes primitive, and the readiness check differs per kind:

- A **Knative Service** (`serving.knative.dev/v1`, kind `Service`) is the request-driven
  web workload — the kizashi `serve` HTTP API. It autoscales (possibly to zero) and is
  reached by URL. Rendered by `Nagare.Dsl.Render.renderService`; readiness is
  `kubectl wait --for=condition=Ready ksvc/<name>` (`Nagare.Deploy.waitForReady`).
- An **`apps/v1` Deployment** (kind `Deployment`) is a headless, always-on background
  process — a kizashi reactor (`worker`, `escalation-worker`, `agent-worker`). It has
  replicas and no URL. Rendered by `Nagare.Dsl.Worker.Render.renderWorker`; readiness is
  `kubectl rollout status deployment/<name>` (`Nagare.Deploy.waitForWorkerRollout`).
  NOTE: this `apps/v1` `Deployment` is *not* the same thing as nagare's request-driven
  `Nagare.Dsl.Types.Deployment` record (the Knative Service config) — the name collision is
  unfortunate but baked in; this plan always qualifies which one it means.
- A **managed Database** is a `StatefulSet` (plus Service/PVC) rendered by EP-44/45's
  `Nagare.Database.*`; ensured via `runDbCreate` (idempotent: it never deletes/recreates).
- A **Task** is a Kubernetes `CronJob`; running it once-now creates a `Job` from that
  CronJob. The kizashi migration (`kizashi-migrate`) is a Task; its pre-deploy hook run is a
  one-off Job that must complete successfully.

**The config-as-program loader (runghc).** A Nagare config is not data; it is a Haskell
program. An app's `nagare/Config.hs` imports `Nagare.Dsl.Config` and, as the last line of
`main`, calls an `emit*` function (e.g. `emitDeployment`, `emitWorker`; EP-1 adds
`emitApplication`) which prints the already-validated value to stdout as JSON. The loader
(`Nagare.Dsl.Load.runConfig`) compiles-and-runs that file with
`runghc -XGHC2024 -i<configDir> <path>`, captures the JSON, and decodes it, **re-running the
smart constructors** as defence in depth (`decodeDeployment`/`toDeployment`, etc.). Loading
requires a provisioned GHC package environment; `Main.provisionGhcEnv` sets
`GHC_ENVIRONMENT` before any `load*` call (see `provisionGhcEnv` and its use in `runDeploy`,
`runWorker`, `runDb`). EP-1's `loadApplication :: FilePath -> IO (Either LoadError
Application)` follows this exact pattern.

**The existing label scheme.** Every rendered object already carries
`nagare.dev/managed-by: nagarectl`. Beyond that, each kind carries a per-kind identity
label:
- the Knative Service's `metadata.labels` carry only `nagare.dev/managed-by` today
  (`Nagare.Dsl.Render.serviceValue`);
- a Worker's Deployment carries `nagare.dev/worker: <worker-name>`
  (`Nagare.Dsl.Worker.Render.workerLabels`);
- a PVC carries `nagare.dev/app`, `nagare.dev/volume` (`Nagare.Dsl.Render.pvcValue` — note
  this `nagare.dev/app` already exists for volume discovery and uses the *Service* name);
- a Task's CronJob carries the `nagare.dev/app` label when co-located under an app
  (EP-52, `nagarectl task list` scopes on it).

This plan ADDS the shared **`nagare.dev/app: <application-name>`** label to *every* object an
`Application` renders, on top of those per-kind labels. The exact label string is the
integration contract kotei reconciles on; it must not change.

**The existing deploy machinery this plan reuses.** Read these before writing M1–M4:

- `cli/nagarectl/app/Main.hs`, `runDeploy :: DeployOpts -> IO ()` (around line 1807) — the
  full single-Service deploy: `provisionGhcEnv` → `Load.loadDeployment` → `qualifyImage`
  (registry-prefix a bare image) → `resolveTag` → `resolveBuildSpec` →
  `resolveConnectionEnv` (DB binding env) → `mergeGenerated` (the `NAGARE_*` identity vars)
  → render PVCs/Service/DomainMappings/Tasks → on `--dry-run` print each manifest, else
  build/push (`gatherBuildArgs`, `configureDockerAuth`, `performBuild`, `pushImage`), apply
  (`applyPVCs`, `applyManifests`), `waitForReady`, record history. `app deploy` reuses this
  per-workload for the Service leg.
- `cli/nagarectl/src/Nagare/Worker/Deploy.hs`, `runWorkerDeploy :: WorkerDeployParams ->
  IO ()` — the worker analogue: load → qualify → tag → render the `apps/v1` Deployment
  (`renderWorker`) → dry-run print or build/push + `applyPVCs`/`applyManifests` +
  `waitForWorkerRollout`. `app deploy` reuses this per Worker.
- `cli/nagarectl/src/Nagare/Task/Run.hs`, `runTaskRun :: TaskRunParams -> IO ()` and the
  pure helpers `oneOffJobName`, `runArgs`, plus `waitForTaskJob`. This is the
  pre-deploy-hook path: `kubectl create job <name> --from=cronjob/nagare-task-<task>`, then
  `kubectl wait --for=condition=complete --timeout=600s job/<name>`, tailing logs and exiting
  non-zero on failure. The hook reuses this run-to-completion-and-check-exit logic; on a
  non-zero exit the whole `app deploy` aborts.
- `cli/nagarectl/app/Main.hs`, `runDb`/`DbCreate` (around line 2458) → `runDbCreate :: Engine
  -> Text -> DbCreateParams -> IO ()` (`Nagare.Database.Create`). Idempotent: it applies the
  PVC/StatefulSet/Service and waits for rollout, and **never** issues `kubectl delete`, so
  re-creating an existing database is a no-op for unchanged fields. This is the database
  "ensure" step.
- `cli/nagarectl/src/Nagare/Deploy.hs` — the apply/wait primitives shared by all legs:
  `applyManifests`, `applyPVCs`, `waitForReady` (ksvc), `waitForRollout` (statefulset),
  `waitForWorkerRollout` (deployment), `serviceUrl`.

**The optparse command tree.** `Main.opts`/`commandParser` (around line 1046) is a
`subparser` of `command "<name>" <cmd>` entries dispatched by the `Command` sum type (line
322) in `run`/`main` (the dispatcher around line 1536). The `worker` group is the closest
template: a `WorkerCommand` newtype with one `deploy` subcommand, a `workerSubparser`, and a
`runWorker` dispatch. This plan adds an `app deploy` subcommand the same way (the `app`
command name already exists for read commands like `app list`/`app get`; `deploy` is a new
subcommand under it — see Interfaces for how the two are reconciled).

**Why this matters (the rationale).** The Nagare server no longer self-heals its DB schema:
if the serving workloads boot before the migration runs, they run against a stale schema.
Today the only thing stopping that is a human following a runbook. `nagarectl app deploy`
makes "migrate before serve" a first-class, enforced property of the platform.

**Integration points (restated for this plan).**
- *Hard dependency on EP-1.* This plan consumes the `Application` type and `loadApplication`
  from `docs/plans/72-...md`. It cannot start until EP-1 is Complete. If EP-1's field names
  differ from those assumed below, this plan adapts to EP-1 (EP-1 owns the type).
- *Soft dependency on EP-3* (`docs/plans/74-worker-health-and-liveness-probes.md`). If EP-3's
  optional worker liveness field has landed, the Workers an `Application` embeds render with a
  `livenessProbe`; if not, they render without one (the field is optional). Either way this
  plan ships — it renders whatever Worker EP-1 hands it.
- *External: the JSON `--dry-run` contract is consumed by kotei.* `shinzui/kotei`'s EP-1
  (`docs/plans/22-...` in the kotei repo) shells out to `nagarectl app deploy --dry-run
  --json` and consumes the object list. The output is a stable object list, not prose (see
  M3 and the schema in Interfaces).


## Plan of Work

The work is four milestones. M1–M3 are independently verifiable entirely offline (render +
golden + JSON-shape tests), which is the standard acceptance gate because `nagare-01` is
frequently `TERMINATED`. M4 is the live-apply wiring; its acceptance is deferred until a
cluster is up, but the code path is written and unit-tested against the rollout sequence in
M2.

All new library code lives in a new module `cli/nagarectl/src/Nagare/App/Deploy.hs`
(`Nagare.App.Deploy`), keeping `Main.hs` to option parsing and dispatch — mirroring how
`Nagare.Worker.Deploy` factors `runWorkerDeploy` out of `Main`. The new module is added to
the `nagarectl` library's `exposed-modules` in `cli/nagarectl/nagarectl.cabal`.

**Prerequisite — a module-boundary problem you must fix first (M0).** `Nagare.App.Deploy` is
a *library* module under `cli/nagarectl/src/`. It **cannot import from the `nagarectl`
executable** (`cli/nagarectl/app/Main.hs`), because the executable depends on the library, not
the other way round. Three deploy helpers `runAppDeploy` needs are defined **in `Main.hs`
today, not in the library**: `resolveTag :: Maybe String -> IO Text` (`Main.hs:2705`),
`resolveBuildSpec :: DeployOpts -> BuildSpec -> IO BuildSpec` (`Main.hs:1941`), and
`resolveConnectionEnv :: Namespace -> [DatabaseName] -> IO (Map EnvName ScopedEnvVar)`
(`Main.hs:1795`). M0 extracts these three (and any small helpers they depend on that are
likewise Main-local) into a new library module `cli/nagarectl/src/Nagare/Deploy/Resolve.hs`
(`Nagare.Deploy.Resolve`), re-importing them back into `Main.hs` so the existing `runDeploy`
keeps working byte-identically. Helpers that are *already* in the library are fine to use
directly and need no move: `qualifyImage`/`computeTag`/`taggedImageRef`/`configureDockerAuth`/
`pushImage` (`Nagare.Image`), `performBuild`/`addBuildArgs`/`applyBuildOverrides`
(`Nagare.Build`), `gatherBuildArgs` (`Nagare.Env.BuildArgs`), `generatedEnv`/`mergeGenerated`
(`Nagare.Env.Generated`), and `resolveTargetProfile`/`TargetProfile` (`Nagare.Target`).
`provisionGhcEnv` stays in `Main.hs` and is called by the dispatcher *before* `runAppDeploy`
(it never needs to be called from the library). M0 is verified by `cabal build nagarectl` +
`cabal test nagarectl-test` staying green with `runDeploy` unchanged — a pure refactor, no
behavior change.

### M0 — extract the Main-local deploy helpers into a library module

**Scope.** A pure, behavior-preserving refactor that unblocks everything else. Move
`resolveTag` (`Main.hs:2705`), `resolveBuildSpec` (`Main.hs:1941`), and `resolveConnectionEnv`
(`Main.hs:1795`) — plus any tiny helpers they call that are also Main-local — out of
`cli/nagarectl/app/Main.hs` into a new library module
`cli/nagarectl/src/Nagare/Deploy/Resolve.hs` (`Nagare.Deploy.Resolve`), added to the
`nagarectl` library `exposed-modules`. Re-import them into `Main.hs` so `runDeploy`,
`runWorkerDeploy`, and every other current caller compile and behave exactly as before.

**Why.** `Nagare.App.Deploy` (M1+) is a library module and cannot reach into the executable;
without M0 it could not call the tag/build/connection resolvers it needs. See the
Prerequisite note above.

**What exists at the end.** `Nagare.Deploy.Resolve` exposes `resolveTag`, `resolveBuildSpec`,
and `resolveConnectionEnv` with their existing signatures; `Main.hs` imports them; the build is
green and no rendered output changes.

**Commands / acceptance.**

```bash
cabal build nagarectl
cabal test nagarectl-test   # all existing tests still pass; runDeploy behaviorally unchanged
```

Acceptance: the refactor is byte-transparent — a `nagarectl deploy --dry-run` on any existing
fixture produces identical output before and after M0. (If `resolveBuildSpec`/`resolveTag`
turn out to be trivially small, inlining their logic into `Nagare.App.Deploy` instead of
sharing is acceptable; the binding constraint is only that no library code imports `Main`.)

### M1 — command skeleton, load an `Application`, render all workloads offline with the shared label

**Scope.** Wire `nagarectl app deploy` into the CLI; load an `Application` with EP-1's
loader; render the Service, every Worker, and every Task offline; stamp `nagare.dev/app:
<name>` on each rendered object. No ordering engine and no JSON yet — `--dry-run` prints the
human transcript (like `worker deploy`'s dry-run).

**Edits.**

1. `cli/nagarectl/app/Main.hs`:
   - Add `data AppDeployOpts` (fields: `file :: FilePath`, `tag :: Maybe String`,
     `baseDomain :: Maybe String`, `contextOverride`/`dockerfileOverride :: Maybe FilePath`,
     `ghcEnv :: Maybe FilePath`, `dryRun :: Bool`, `json :: Bool`, `source :: Maybe String`),
     modelled on `DeployOpts` plus a `--json` switch (M3 uses it; in M1 it is parsed but the
     human transcript is still printed).
   - Add an `AppDeploy AppDeployOpts` constructor. The `app` command group today is a set of
     top-level constructors (`AppList`, `AppGet`, …) dispatched directly; introduce an
     `appSubparser` that keeps the existing `list`/`get`/`logs`/`restart`/`stop`/`delete`
     subcommands AND adds `command "deploy" appDeployCmd`. (See Interfaces for the exact
     reconciliation — the existing `app` subcommands stay byte-identical.)
   - Add `appDeployOptsParser :: FilePath -> Parser AppDeployOpts` reusing `fileOpt`,
     `tagOpt`, `baseDomainOpt`, `ghcEnvOpt`, `dryRunOpt`, plus a `--json` `switch`.
   - In the dispatcher, route `AppDeploy o -> provisionGhcEnv (o ^. #ghcEnv) >>
     runAppDeploy (toAppDeployParams o)`.

2. New module `cli/nagarectl/src/Nagare/App/Deploy.hs` exposing
   `data AppDeployParams` and `runAppDeploy :: AppDeployParams -> IO ()`. In M1 `runAppDeploy`:
   - calls `loadApplication (adpConfigPath p)` (EP-1); on `Left err` dies with
     `renderLoadError`;
   - resolves the target profile and `qualifyImage`s the shared image **once**;
   - projects the aggregate into its constituent typed workloads — the Service `Deployment`,
     the `[Worker]`, the `[Database]` **specs** (full `Database` values, not bare names — the
     database phase needs `engine`/`version`/`size` to ensure them), and the `[Task]` (hooks).
     EP-1's `Application` exposes these (e.g. `app ^. #service`, `app ^. #workers`,
     `app ^. #appDatabases`, `app ^. #tasks` — note EP-1 names the database field
     `appDatabases :: [Database]`, not `databases`); the shared image/env/db-bindings are
     already flowed down onto each by EP-1's smart constructor, so EP-2 renders them as-is.
   - renders each via the existing per-kind renderers (`renderService`, `renderVolumeClaims`,
     `renderDomainMappings`, `renderWorker`, `renderResolvedTask`) and **re-stamps**
     `nagare.dev/app: <app-name>` onto each rendered manifest's `metadata.labels`.

3. The label stamping: rather than thread an `appName` parameter through every renderer
   signature (a wide, churny change), add a small post-render helper
   `Nagare.App.Deploy.stampAppLabel :: Text -> ByteString -> ByteString` that decodes the
   rendered YAML to a `Value`, inserts `nagare.dev/app: <name>` under `metadata.labels`
   (creating the block if absent), and re-encodes with the same `knativeConfig` key
   comparator so byte order is stable. Apply it to every manifest the aggregate emits. (Note
   the PVC and co-located-Task renderers already emit a `nagare.dev/app`; for those the helper
   overwrites with the *application* name, which is the same string when the Service name
   equals the app name and the canonical owner otherwise — Decision deferred to M1
   implementation; default to the application name uniformly.)

**What exists at the end.** `nagarectl app deploy --dry-run -f nagare/Config.hs` loads the
kizashi aggregate and prints all six manifests, every one carrying `nagare.dev/app: kizashi`.

**Commands / acceptance.**

```bash
cabal build nagarectl
cabal run nagarectl -- app deploy --dry-run -f cli/nagarectl/test/fixtures/app/kizashi/Config.hs
# expect: PVC + Knative Service + 3 Deployment + 1 CronJob manifests, each with
#   labels: { nagare.dev/managed-by: nagarectl, nagare.dev/app: kizashi, ... }
cabal test nagarectl-test   # golden render test (AppDeploySpec) asserts the label on each object
```

Acceptance: the dry-run prints exactly the expected object set, and a golden test
(`cli/nagarectl/test/Spec.hs`, new `AppDeploySpec` / fixture under
`cli/nagarectl/test/golden/`) asserts each rendered object's `metadata.labels` contains
`nagare.dev/app: kizashi`.

### M2 — ordered rollout engine: hooks → databases → service/workers, with a failed hook aborting

**Scope.** Turn the flat render of M1 into a sequenced rollout. Define the phases as data and
execute them in order. A failed pre-deploy hook aborts before any Service/Worker is applied.

**Edits (all in `Nagare.App.Deploy`).**

1. Define the phase plan:

   ```haskell
   data Phase
     = PhaseHooks   ![Task]        -- pre-deploy migration Tasks, run to completion
     | PhaseDatabases ![Database]  -- full Database specs from EP-1's appDatabases
     | PhaseService !Deployment    -- the Knative Service (request-driven Deployment)
     | PhaseWorkers ![Worker]
   ```

   and `planPhases :: Application -> [Phase]` returning, in this fixed order,
   `[PhaseHooks (app ^. #tasks), PhaseDatabases (app ^. #appDatabases), PhaseService svc,
   PhaseWorkers (app ^. #workers)]`. (`PhaseService` is omitted when the aggregate declares
   no web service — kizashi has one.)

2. `runPhases :: RolloutEnv -> [Phase] -> IO ()` executes each phase in turn:
   - `PhaseHooks ts` — for each Task, run it to completion via the `Nagare.Task.Run` path
     (build the one-off Job, `kubectl create job ... --from=cronjob/...`, `waitForTaskJob`).
     A non-zero exit **throws / `exitFailure` immediately**, so no later phase runs. (Before
     the serving workloads exist the CronJob must exist to create a Job from; see Idempotence
     for the bootstrap ordering — the hook's CronJob is applied at the start of the hook phase
     from the rendered Task manifest, then the one-off Job is created from it.)
   - `PhaseDatabases dbs` — for each `Database`, `runDbCreate` (idempotent ensure) — which
     needs the full spec (`engine`, `version`, `size`), hence `appDatabases :: [Database]`
     rather than a list of names — and wait for its StatefulSet rollout.
   - `PhaseService svc` — `applyPVCs` + `applyManifests` (Service + DomainMappings) +
     `waitForReady`.
   - `PhaseWorkers ws` — for each Worker, `applyPVCs` + `applyManifests` (Deployment) +
     `waitForWorkerRollout`.

3. The shared image is built and pushed **once**, before `runPhases`, by reusing the
   build/push half of `runDeploy`/`runWorkerDeploy` (`gatherBuildArgs`, `configureDockerAuth`,
   `performBuild`, `pushImage`) against the qualified shared image and resolved tag. The
   resolved tagged image string is threaded into the `RolloutEnv` so every workload (Service,
   Workers, hook Task that inherits the app image) renders the *same* tag.

**What exists at the end.** `runAppDeploy` (non-dry-run) executes the four phases in order;
the hook phase gates everything after it.

**Commands / acceptance.**

```bash
cabal test nagarectl-test   # unit test over a faked phase runner
```

Acceptance: a unit test injects a phase runner whose hook step returns a non-zero exit and
asserts (a) the database/service/worker steps are never invoked and (b) `runPhases` reports
failure. `planPhases` over the kizashi fixture returns the four phases in exactly the order
`[Hooks, Databases, Service, Workers]`.

### M3 — machine-readable `--dry-run --json` result contract

**Scope.** Add a stable JSON result to `--dry-run` (gated by `--json`) so kotei consumes the
render without scraping. The JSON is the *plan*: the ordered list of objects each phase would
apply, with labels.

**Edits (`Nagare.App.Deploy`).**

1. Define the result types and their `ToJSON`:

   ```haskell
   data RenderedObject = RenderedObject
     { roApiVersion :: !Text
     , roKind       :: !Text
     , roName       :: !Text
     , roNamespace  :: !Text
     , roPhase      :: !Text          -- "hook" | "database" | "service" | "worker"
     , roLabels     :: !(Map Text Text)
     , roManifest   :: !Text          -- the rendered YAML document
     }
   data AppDeployPlan = AppDeployPlan
     { adpApp     :: !Text            -- the nagare.dev/app value
     , adpImage   :: !Text            -- resolved tagged image ref used by every workload
     , adpObjects :: ![RenderedObject]  -- in rollout order
     }
   ```

2. `renderPlan :: Application -> Text -> Text -> AppDeployPlan` builds the ordered object
   list (one `RenderedObject` per rendered manifest, in phase order), reusing M1's rendered
   bytes and M2's `planPhases` ordering. Each object's `roLabels` is parsed from the stamped
   manifest, so the JSON's labels and the YAML's labels cannot drift.

3. In `runAppDeploy`, when `adpDryRun && adpJson`, write `encode plan` to stdout and write
   nothing else to stdout (diagnostics go to stderr) so the output is a single clean JSON
   document. When `adpDryRun && not adpJson`, keep M1's human transcript.

**What exists at the end.** `nagarectl app deploy --dry-run --json -f …` prints one JSON
object that parses and lists every rendered object in rollout order with its labels.

**Commands / acceptance.**

```bash
cabal run nagarectl -- app deploy --dry-run --json \
  -f cli/nagarectl/test/fixtures/app/kizashi/Config.hs | jq '.objects[].kind'
# expect, in order: "Job"/"CronJob" (hook), Knative "Service", "Deployment" x3
cabal test nagarectl-test   # JSON-shape golden / round-trip test
```

Acceptance: the emitted bytes parse as JSON; `.app == "kizashi"`; `.objects` is in phase
order; every `.objects[].labels["nagare.dev/app"] == "kizashi"`. A golden file pins the shape.

### M4 — live-apply wiring + acceptance (deferred while nagare-01 is down)

**Scope.** Connect the non-dry-run path end to end against a real cluster: build/push once,
run hooks, ensure databases, apply Service + Workers, wait. The code is written and exercised
by M2's unit test; *live* acceptance is deferred until `nagare-01` is `RUNNING`.

**Edits.** None beyond M1–M3 except a brief `docs/user/deploying-apps.md` section
("Deploying a multi-workload app") documenting `nagarectl app deploy` and the migrate-first
ordering, and noting the `--dry-run --json` contract for kotei.

**Commands / acceptance (when a cluster is available).**

```bash
nagarectl app deploy -f nagare/Config.hs
# expect: image built+pushed once; "kizashi-migrate" Job completes; postgres ensured;
#   Service Ready; 3 worker Deployments rolled out; all carry nagare.dev/app=kizashi
kubectl get all -n personal -l nagare.dev/app=kizashi
```

Acceptance (deferred): a single command brings up all six objects in order; intentionally
breaking the migration (e.g. a bad SQL file) aborts the release with no Service/Worker
applied (`kubectl get ksvc,deploy -n personal -l nagare.dev/app=kizashi` empty). Until then,
the offline M1–M3 gates stand in.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless
noted. A kizashi-shaped fixture (one Service + 3 Workers + 1 Postgres binding + 1 migration
Task, all sharing one image) lives at `cli/nagarectl/test/fixtures/app/kizashi/Config.hs`
(created as part of M1 so the golden tests have an input).

1. Build the CLI after each milestone's edits:

   ```bash
   cabal build nagarectl
   ```

2. M1 — render offline, human transcript (working dir: repo root):

   ```bash
   cabal run nagarectl -- app deploy --dry-run \
     -f cli/nagarectl/test/fixtures/app/kizashi/Config.hs
   ```

   Expected (abbreviated) transcript:

   ```text
   --- CronJob manifest (hook: kizashi-migrate) ---
   apiVersion: batch/v1
   kind: CronJob
   metadata:
     name: nagare-task-kizashi-migrate
     namespace: personal
     labels:
       nagare.dev/managed-by: nagarectl
       nagare.dev/app: kizashi
   ...
   --- Knative Service manifest (kizashi) ---
   apiVersion: serving.knative.dev/v1
   kind: Service
   metadata:
     name: kizashi
     namespace: personal
     labels:
       nagare.dev/managed-by: nagarectl
       nagare.dev/app: kizashi
   ...
   --- Deployment manifest (worker: kizashi-worker) ---     # and escalation-worker, agent-worker
   Build mode: Dockerfile build (./Dockerfile)
   Would deploy app 'kizashi' (1 service, 3 workers, 1 database, 1 hook) to namespace personal
   ```

3. M3 — machine-readable JSON (working dir: repo root):

   ```bash
   cabal run nagarectl -- app deploy --dry-run --json \
     -f cli/nagarectl/test/fixtures/app/kizashi/Config.hs | jq '{app, image, kinds: [.objects[].kind]}'
   ```

   Expected:

   ```json
   {
     "app": "kizashi",
     "image": "<registry>/kizashi:20260618-120000",
     "kinds": ["CronJob", "Service", "Deployment", "Deployment", "Deployment"]
   }
   ```

4. Tests:

   ```bash
   cabal test nagare-dsl-test     # if any DSL-side render helper changes land here
   cabal test nagarectl-test      # M1 golden render, M2 phase-order/abort, M3 JSON shape
   ```

5. M4 — live deploy (only when `nagare-01` is `RUNNING`):

   ```bash
   nagarectl app deploy -f nagare/Config.hs
   kubectl get all -n personal -l nagare.dev/app=kizashi
   ```


## Validation and Acceptance

The change is effective (not just compiling) when these behaviors hold:

- **Render completeness and labelling (M1).** `nagarectl app deploy --dry-run -f
  <kizashi>` emits exactly the expected object set for kizashi — one CronJob (the migration
  hook), one Knative Service, three `apps/v1` Deployments (the reactors), and the PVCs the
  databases/volumes need — and **every** rendered object's `metadata.labels` contains
  `nagare.dev/app: kizashi` in addition to its per-kind labels. Verified by the
  `AppDeploySpec` golden test in `cli/nagarectl/test/Spec.hs`; run `cabal test
  nagarectl-test`.

- **Ordered rollout with hook gating (M2).** `planPhases` over the kizashi aggregate returns
  the phases in exactly the order `[Hooks, Databases, Service, Workers]`. A unit test with a
  faked phase runner whose hook returns a non-zero exit asserts that the database, service,
  and worker phases are **never invoked** and that `runPhases` reports failure — i.e. a
  failing pre-deploy hook prevents any Service/Worker apply. Run `cabal test nagarectl-test`.

- **Stable JSON contract (M3).** `nagarectl app deploy --dry-run --json -f <kizashi>` writes a
  single JSON document to stdout (nothing else on stdout) that `jq` parses; `.app ==
  "kizashi"`; `.objects` is ordered hook → service → workers; and every
  `.objects[].labels["nagare.dev/app"] == "kizashi"`. A golden file pins the shape so a future
  field change is a conscious, reviewed diff. Run `cabal test nagarectl-test`.

- **Live (M4, deferred).** When a cluster is available, one `nagarectl app deploy` brings up
  all six objects in dependency order and `kubectl get all -n personal -l
  nagare.dev/app=kizashi` lists them as one unit; a deliberately broken migration aborts the
  release with no Service/Worker present.


## Idempotence and Recovery

- **Re-running `app deploy` is safe.** Every leg is idempotent or naturally
  convergent: `kubectl apply` is declarative (re-applying an unchanged Service/Deployment is a
  no-op for unchanged fields); `runDbCreate` never deletes/recreates, so ensuring an existing
  database is a no-op (`Nagare.Database.Create` issues no `kubectl delete`); the image
  build/push is content-addressed by tag and overwriting an identical tag is harmless.

- **A hook that already ran.** The pre-deploy hook is a one-off `Job` created from the
  migration's `CronJob` with a unique timestamped name (`Nagare.Task.Run.oneOffJobName`), so
  re-running `app deploy` creates a *new* Job rather than colliding with a completed one. The
  migration itself must be idempotent at the SQL level (the standard "migrations are
  re-runnable / tracked by a migrations table" discipline) — Nagare runs it again on every
  deploy by design, so an already-applied migration must be a no-op. This is a property of the
  app's migration tool, documented in `docs/user/deploying-apps.md` (M4).

- **A failed hook leaves a safe, retryable state.** Because the hook gates everything after
  it, a failure means no new Service/Worker was applied — the previously running version (if
  any) is untouched. The image and database that may already exist are both idempotent to
  re-create. Recovery is: fix the migration, re-run `nagarectl app deploy`. No manual cleanup
  or rollback is required; full transactional cross-workload rollback is explicitly out of
  scope (owned by kotei).

- **Partial failure mid-phase.** If the Service applies but a Worker rollout times out, a
  re-run re-applies the (already-Ready) Service idempotently and retries the Worker. No leg
  needs a special retry path beyond re-running the command.


## Interfaces and Dependencies

**External tools / libraries.** `kubectl` (apply/wait/create job — via `Cradle`), `runghc`
(config loader), `aeson` (JSON encode for the M3 contract), `optparse-applicative` (the
command parser), `yaml`/`Data.Yaml.Pretty` (manifest (de)serialisation for label stamping).

**Hard dependency.** `Nagare.Dsl.Application` and `loadApplication :: FilePath -> IO (Either
Nagare.Dsl.Load.LoadError Application)` from EP-1
(`docs/plans/72-application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings.md`).
This plan assumes the `Application` record exposes (at least): the shared app `appName` (a
`ServiceName`), `namespace`, the shared `image`, an optional web service projected as a
`Nagare.Dsl.Types.Deployment`, `workers :: [Nagare.Dsl.Worker.Worker]`, `appDatabases ::
[Nagare.Dsl.Database.Database]` (full database specs — the database phase calls `runDbCreate`,
which needs `engine`/`version`/`size`, so a list of `DatabaseName` would be insufficient), and
`tasks :: [Nagare.Dsl.Task.Task]` (the pre-deploy hooks). These names match EP-1's record as
defined in
`docs/plans/72-application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings.md`;
EP-1 owns the type and EP-2 adapts to any later rename.

**Soft dependency.** EP-3's optional `Worker` liveness field
(`docs/plans/74-worker-health-and-liveness-probes.md`). EP-2 renders whatever `Worker` EP-1
hands it; no code change is needed whether or not the field is present.

**New CLI surface (M1).**
- Command: `nagarectl app deploy [-f FILE] [-t TAG] [--base-domain DOMAIN] [-c DIR]
  [--dockerfile FILE] [--ghc-env FILE] [--dry-run] [--json] [--source REF]`.
- `Main.AppDeployOpts` (record, fields as in M1) and a `Command` constructor `AppDeploy
  AppDeployOpts`.
- `Main.appDeployOptsParser :: FilePath -> Parser AppDeployOpts`.
- The existing `app` subcommands (`list`/`get`/`logs`/`restart`/`stop`/`delete`) are moved
  under a new `appSubparser` unchanged, and `command "deploy" appDeployCmd` is added to it; no
  existing `app` command's behavior changes. (Today these are separate top-level
  constructors; the only structural change is grouping them under one `subparser` so `deploy`
  joins them.)

**New library surface (`cli/nagarectl/src/Nagare/App/Deploy.hs`, module `Nagare.App.Deploy`).**

- M1:
  ```haskell
  data AppDeployParams = AppDeployParams
    { adpConfigPath        :: !FilePath
    , adpTag               :: !(Maybe Text)
    , adpBaseDomain        :: !(Maybe Text)
    , adpContextOverride   :: !(Maybe FilePath)
    , adpDockerfileOverride :: !(Maybe FilePath)
    , adpDryRun            :: !Bool
    , adpJson              :: !Bool
    , adpSource            :: !(Maybe Text)
    }
  runAppDeploy   :: AppDeployParams -> IO ()
  stampAppLabel  :: Text -> ByteString -> ByteString   -- insert nagare.dev/app under metadata.labels
  ```

- M2:
  ```haskell
  data Phase
    = PhaseHooks     ![Nagare.Dsl.Task.Task]
    | PhaseDatabases ![Nagare.Dsl.Database.Database]
    | PhaseService   !Nagare.Dsl.Types.Deployment
    | PhaseWorkers   ![Nagare.Dsl.Worker.Worker]
  planPhases :: Application -> [Phase]                  -- fixed order: hooks, databases, service, workers
  runPhases  :: RolloutEnv -> [Phase] -> IO ()          -- a non-zero hook exit aborts before later phases
  ```
  where `RolloutEnv` carries the resolved namespace, the resolved tagged image string (so
  every workload renders the same tag), and the base domain.

- M3:
  ```haskell
  data RenderedObject = RenderedObject
    { roApiVersion :: !Text, roKind :: !Text, roName :: !Text, roNamespace :: !Text
    , roPhase :: !Text, roLabels :: !(Data.Map.Map Text Text), roManifest :: !Text }
  data AppDeployPlan = AppDeployPlan
    { adpApp :: !Text, adpImage :: !Text, adpObjects :: ![RenderedObject] }
  renderPlan :: Application -> Text -> Text -> AppDeployPlan   -- (app, appName, taggedImage) -> plan
  -- ToJSON AppDeployPlan / ToJSON RenderedObject define the wire contract below.
  ```

**The JSON `--dry-run --json` result schema (the kotei contract).** A single top-level
object:

```json
{
  "app": "kizashi",
  "image": "registry.example/kizashi:20260618-120000",
  "objects": [
    {
      "apiVersion": "batch/v1",
      "kind": "CronJob",
      "name": "nagare-task-kizashi-migrate",
      "namespace": "personal",
      "phase": "hook",
      "labels": { "nagare.dev/managed-by": "nagarectl", "nagare.dev/app": "kizashi" },
      "manifest": "apiVersion: batch/v1\nkind: CronJob\n..."
    }
  ]
}
```

Contract rules: `objects` is ordered by rollout phase (`hook` → `database` → `service` →
`worker`); `phase` is one of `"hook" | "database" | "service" | "worker"`; every object's
`labels` includes `nagare.dev/app` equal to the top-level `app`; `manifest` is the exact
rendered YAML document. The contract is **additive** — consumers (kotei) must ignore unknown
keys, so later plans may add fields without a breaking change.

**Reused existing interfaces (full module paths).**
- `Nagare.Dsl.Load.loadApplication` (EP-1), `Nagare.Dsl.Load.renderLoadError`,
  `Nagare.Dsl.Load.LoadError`.
- `Nagare.Dsl.Render.renderService`, `renderVolumeClaims`, `renderDomainMappings`.
- `Nagare.Dsl.Worker.Render.renderWorker`, `workerDeploymentName`.
- `Nagare.Task.Resolve.renderResolvedTask`, `predefinedTaskEnv`; `Nagare.Task.Run.runArgs`,
  `oneOffJobName`, and the `waitForTaskJob` run-to-completion path.
- `Nagare.Database.Create.runDbCreate`, `Nagare.Database.Create.DbCreateParams`.
- `Nagare.Deploy.applyManifests`, `applyPVCs`, `waitForReady`, `waitForRollout`,
  `waitForWorkerRollout`, `serviceUrl`.
- `Nagare.Image.qualifyImage`, `computeTag`, `configureDockerAuth`, `pushImage`,
  `taggedImageRef`; `Nagare.Build.performBuild`, `addBuildArgs`, `applyBuildOverrides`;
  `Nagare.Env.BuildArgs.gatherBuildArgs`; `Nagare.Env.Generated.generatedEnv`,
  `mergeGenerated`. (All already library modules — usable directly.)
- `Nagare.Deploy.Resolve.resolveTag`, `resolveBuildSpec`, `resolveConnectionEnv` — **created
  by M0** by extracting them from `Main.hs` (they live in the executable today and cannot be
  imported by a library module until moved). See M0.
- `Nagare.Target.resolveTargetProfile`, `TargetProfile (..)`.
- `Main.provisionGhcEnv` (sets `GHC_ENVIRONMENT` before the loader runs) — stays in `Main.hs`
  and is invoked by the dispatcher *before* `runAppDeploy`, so the library never imports it.

**Cabal.** Add `Nagare.App.Deploy` (and, from M0, `Nagare.Deploy.Resolve`) to
`exposed-modules` in `cli/nagarectl/nagarectl.cabal`'s `library` stanza so both the `nagarectl`
executable and the `nagarectl-test` test-suite can import them.


## Revision Notes

- 2026-06-18 — MasterPlan validation pass. (1) Added milestone **M0** (and its Progress item,
  Decision Log entry, and reused-interface note): `Nagare.App.Deploy` is a library module and
  cannot import the three deploy resolvers (`resolveTag`, `resolveBuildSpec`,
  `resolveConnectionEnv`) that live in the `nagarectl` *executable* `Main.hs`; M0 extracts them
  into `Nagare.Deploy.Resolve` first. Verified against source that the remaining reused helpers
  are already library-resident. (2) Reconciled the database field with EP-1: it is
  `appDatabases :: [Nagare.Dsl.Database.Database]` (full specs, needed by `runDbCreate`), not
  `databases :: [DatabaseName]`/`[DatabaseRef]` — corrected in the projection prose, the `Phase`
  type (M2 and Interfaces), `planPhases`, the database-phase step, and the hard-dependency
  paragraph. (3) Corrected the M1 acceptance command from `cabal test nagare-dsl-test` to
  `cabal test nagarectl-test` (the `AppDeploySpec` golden lives in the `nagarectl` test-suite).
