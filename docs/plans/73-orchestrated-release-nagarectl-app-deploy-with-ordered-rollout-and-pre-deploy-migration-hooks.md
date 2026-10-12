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

Full plan before trimming: [73-orchestrated-release-nagarectl-app-deploy-with-ordered-rollout-and-pre-deploy-migration-hooks.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/73-orchestrated-release-nagarectl-app-deploy-with-ordered-rollout-and-pre-deploy-migration-hooks.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

