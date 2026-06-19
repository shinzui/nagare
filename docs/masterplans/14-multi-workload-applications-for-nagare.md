---
id: 14
slug: multi-workload-applications-for-nagare
title: "Multi-Workload Applications for Nagare"
kind: master-plan
created_at: 2026-06-19T00:36:39Z
intention: "intention_01kvemvx2reyn9qa49qks2dpcj"
---

# Multi-Workload Applications for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Nagare's mental model has been **one project = one Knative Service** since the typed-DSL
initiative (`docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md`). Over
time, side-car workload kinds were bolted on as independent commands: managed databases
(`docs/masterplans/9-managed-databases-for-nagare.md`, `nagarectl db`), scheduled tasks
(`docs/masterplans/10-scheduled-tasks-for-nagare.md`, `nagarectl task`), and most recently
**workers** — a headless `apps/v1` Deployment for continuous background processes —
delivered as the `Worker` DSL type and `nagarectl worker deploy` (see
`docs/user/workers.md`). Each kind has its own `nagare/Config.hs`, its own `emit*`
function, and its own deploy subcommand.

The Worker type closed the last *single-workload* gap. But it exposed a new one: there is
no abstraction for an application that is **several workloads at once**. The forcing
function is `shinzui/kizashi` (`/Users/shinzui/Keikaku/bokuno/kizashi`), a single logical
app that is, in Nagare terms, **six objects across four kinds**: one Knative Service (the
`kizashi serve` HTTP API), three Workers (`kizashi worker`, `kizashi escalation-worker`,
`kizashi agent-worker` — all NOTIFY/timer background loops), one managed Postgres, and one
migration Task (`kizashi-migrate`, which must run *before* the service and workers boot
because the server no longer self-heals its schema). Today that is 4+ separate config
files repeating the same name prefix, namespace, image repository, and database binding,
deployed by 4+ separate commands with no shared identity, no ordering, and no unit of
rollback. This MasterPlan adds the missing layer *above* the workload.


## Vision & Scope

After this initiative, a developer describes a multi-workload app as **one typed
`Application`** in a single `nagare/Config.hs`, deploys it with **one command**
(`nagarectl app deploy`), and the platform fans it out into the correct Kubernetes
objects in the correct order, under one shared identity.

User-visible behaviors enabled:

- **One typed aggregate.** A new `Application` value (in the `nagare-dsl` library) names
  the app once and bundles an optional web `Service`, a list of `Worker`s, a list of
  managed `Database` bindings, and a list of `Task`s. The shared **image**, **env/secret
  set**, and **database bindings** are declared once on the `Application` and flow down to
  every workload, instead of being copy-pasted per workload. Illegal shapes (a worker and
  the service disagreeing on the image, a database referenced by a workload but not
  declared on the app, a duplicate workload name) are rejected at config-load time with a
  precise message, the same maximal-safety discipline as the rest of the DSL.

- **One deploy command with correct ordering.** `nagarectl app deploy` builds and pushes
  the shared image once, then rolls the app out in dependency order: **pre-deploy hooks
  first** (a declared migration Task runs to completion and must succeed), **then** the
  managed databases are ensured, **then** the Service and Workers are applied and waited
  on. A failed pre-deploy hook aborts the release before any Service or Worker is touched.
  This makes "run migrations before the new code boots" a first-class, enforced property
  rather than a manual runbook step.

- **One identity and one rollback unit.** Every object the app renders carries a shared
  `nagare.dev/app: <name>` label (alongside the existing per-kind labels), so the whole
  app can be listed, inspected, and torn down as a unit, and so an external system of
  record (kotei — see the cross-repo integration point below) can treat the release as one
  thing.

- **Workers that fail safely.** A `Worker` gains an optional **liveness/health** probe
  (exec- or TCP-based, since workers are headless and have no HTTP port), so a hung loop —
  not just a crashed process — is detected and restarted. This is a correctness
  prerequisite for running real background workers like kizashi's three reactors.

**In scope:** the `Application` aggregate type and its loader/emitter; `nagarectl app
deploy` (and the minimal `app` read commands needed to see an aggregate, e.g. `app
status`) with ordered rollout and pre-deploy hooks; worker liveness probes. The existing
single-workload commands (`deploy`, `worker deploy`, `db`, `task`) continue to work
unchanged — the aggregate composes them, it does not replace them.

**Explicitly excluded:** full atomic/transactional rollback across workloads (kotei owns
release-level rollback semantics — see `shinzui/kotei`
`docs/masterplans/7-full-stack-nagare-deployment-management.md`); multi-node or HA
concerns (Nagare is single-node by design); a general dependency DAG between arbitrary
workloads (we support the one ordering relationship that matters — pre-deploy hooks and
databases before serving workloads — not arbitrary inter-worker ordering); and any change
to how images are built (the `BuildSpec` from
`docs/masterplans/4-application-build-modes-for-nagare.md` is reused as-is).


## Decomposition Strategy

The work splits into three streams by functional concern, chosen to minimize hard
dependencies and keep each stream independently verifiable via `--dry-run` render tests
(the project's standard offline acceptance gate, since `nagare-01` is frequently
`TERMINATED`).

- **EP-1 — the type.** The `Application` aggregate is the foundational artifact everything
  else consumes. It is pure DSL + JSON round-trip + loader work in `nagare-dsl`, verifiable
  entirely offline with golden/round-trip tests. It also subsumes the "shared env/secret/DB
  binding" gap, because the aggregate is precisely where shared bindings live. Isolating it
  first means EP-2 has a stable type to render.

- **EP-2 — the orchestration.** `nagarectl app deploy` is where the aggregate becomes
  cluster actions: render every workload, sequence the rollout (hooks → databases →
  service/workers), and report. It is the only stream that touches `nagarectl`'s deploy
  machinery and the only one with an unavoidable hard dependency (it needs EP-1's type to
  consume).

- **EP-3 — worker liveness.** Adding a health/liveness probe to the `Worker` type and its
  renderer is orthogonal to aggregation: it improves a single workload kind and is valuable
  even for a standalone `nagarectl worker deploy`. It is separated so it can land in
  parallel with EP-1 and is not gated on the aggregate. Its only coupling is that the
  `Worker` embedded in an `Application` should carry the same new field — an integration
  point, not a dependency.

**Alternatives considered.** (a) *Fold worker liveness into EP-1* — rejected: it has no
relationship to aggregation and would bloat the foundational type plan. (b) *Make the
aggregate a thin "list of existing config files" rather than a real type* — rejected: it
would lose the headline guarantees (shared-binding validation, single identity) that are
the whole point, and push consistency back onto the developer. (c) *A general workload
dependency DAG* — rejected as over-engineering for a single-node personal PaaS; the only
ordering anyone needs is "migrations and databases before serving workloads," which a fixed
phase ordering expresses without a scheduler.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Application aggregate: typed multi-workload app with shared image, env, and database bindings | docs/plans/72-application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings.md | None | None | Complete |
| 2 | Orchestrated release: `nagarectl app deploy` with ordered rollout and pre-deploy migration hooks | docs/plans/73-orchestrated-release-nagarectl-app-deploy-with-ordered-rollout-and-pre-deploy-migration-hooks.md | EP-1 | EP-3 | Complete |
| 3 | Worker health and liveness probes | docs/plans/74-worker-health-and-liveness-probes.md | None | EP-1 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

EP-1 has no dependencies and must land first among the type-bearing work: it defines the
`Application` record, its JSON encoding, its loader (`emitApplication`/`loadApplication`),
and the shared-binding validation. EP-2 has a **hard** dependency on EP-1 because `nagarectl
app deploy` loads and renders an `Application`; it cannot be written against a type that does
not exist. EP-2 has a **soft** dependency on EP-3: if EP-3 has landed, the workers rendered
by the aggregate automatically gain liveness probes; if not, EP-2 still ships and renders
workers without them (the field is optional). EP-3 has no hard dependency and can be
implemented in parallel with EP-1; its **soft** dependency on EP-1 is only that, once both
land, the `Worker` carried inside an `Application` must expose the same liveness field — a
one-line wiring concern, not a blocker.

Parallelism: EP-1 and EP-3 can proceed simultaneously. EP-2 starts once EP-1 is Complete.


## Integration Points

- **The `Application` record** (`cli/nagare-dsl/src/Nagare/Dsl/Application.hs`, new).
  Defined by **EP-1**. Consumed by **EP-2** (renders and deploys it) and referenced by
  **EP-3** (the `Worker` it embeds gains the liveness field). EP-1 owns the field set,
  the smart constructor, the JSON round-trip, and the shared-binding validation rules.
  Later plans must not add fields without updating EP-1's encoder/decoder and golden tests.
  The declared-database field is **`appDatabases :: [Database]`** — full `Database` specs,
  not bare `DatabaseName`s — because **EP-2**'s database rollout phase calls `runDbCreate`,
  which needs `engine`/`version`/`size`. EP-2 consumes the field under that exact name and
  type (reconciled during the validation pass — see Decision Log).

- **The shared identity label `nagare.dev/app: <name>`.** Introduced by **EP-1** (decided)
  and applied by **EP-2**'s renderer to every object an `Application` produces, in addition
  to the existing `nagare.dev/managed-by: nagarectl`, `nagare.dev/worker`, and
  `nagare.dev/database` labels. This label is the contract the kotei integration relies on
  to discover and reconcile an app's resources as a unit.

- **The `Worker` liveness field** (`cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`). Defined by
  **EP-3** as an optional field on the existing `Worker` record and rendered into the
  `apps/v1` Deployment's `livenessProbe`. **EP-1**'s `Application` embeds `Worker` values,
  so the field is automatically available on aggregated workers; **EP-2** renders it. The
  three plans must agree on the field's name and shape; EP-3 is the definer.

- **External / cross-repo: `nagarectl app deploy` and the Application aggregate are
  consumed by kotei.** `shinzui/kotei`
  (`docs/masterplans/7-full-stack-nagare-deployment-management.md`, its EP-1
  `docs/plans/22-workload-aware-nagare-deployment-backend-worker-db-and-task.md`) drives
  Nagare as its deployment backend. Today kotei shells out to `nagarectl deploy` only.
  Once `nagarectl app deploy` exists and emits a stable, machine-readable result (the
  rendered object list with their `nagare.dev/app` labels, ideally as JSON on `--dry-run`),
  kotei can deploy and track an entire multi-workload app in one call. EP-2 should treat
  "a non-interactive, parseable deploy result" as an explicit requirement so the kotei
  backend is not forced to scrape human prose. This is the seam between the two
  MasterPlans; neither blocks the other, but EP-2's output contract should be designed with
  kotei's consumption in mind.


## Progress

- [x] EP-1 (2026-06-18): `Application` record, smart constructor, and shared-binding validation in `nagare-dsl`
- [x] EP-1 (2026-06-18): `emitApplication` / loader and JSON round-trip + load tests (JSON golden deferred — round-trip pins the wire shape)
- [x] EP-2 (2026-06-18): `nagarectl app deploy` renders all workloads with the shared `nagare.dev/app` label (M1)
- [x] EP-2 (2026-06-18): ordered rollout — pre-deploy hooks and databases before service/workers; failed hook aborts (M2; live apply M4, acceptance deferred while nagare-01 is TERMINATED)
- [x] EP-2 (2026-06-18): machine-readable `--dry-run --json` output contract for external consumers (kotei) (M3)
- [x] EP-3 (2026-06-18): optional liveness/health probe field on `Worker` (`WorkerProbe` exec/TCP/HTTP + `ProbeTiming`), with JSON round-trip
- [x] EP-3 (2026-06-18): renderer emits `livenessProbe` (and `startupProbe`) on the `apps/v1` Deployment; golden test + no-probe byte-identity proven


## Surprises & Discoveries

- 2026-06-18 — **EP-2 complete; the soft dependency on EP-3 cost zero wiring, as predicted.**
  `nagarectl app deploy` ships (M0–M4): the library module `Nagare.App.Deploy` loads an
  `Application`, qualifies the shared image once, fans the shared env down, renders every workload
  with its EXISTING per-kind renderer, stamps `nagare.dev/app` on each, sequences the rollout
  (`planPhases`/`runPhases`, hook-gated), and emits the `--dry-run --json` kotei contract. Because the
  aggregate reuses `renderWorker`, **EP-3's `livenessProbe` flows through an aggregated worker with no
  EP-2 code** — confirming the integration-point design. Two notes: (1) **live apply (M4) acceptance
  is deferred** while `nagare-01` is `TERMINATED` (the phase sequencing + hook-abort are unit-tested
  offline with a fake executor); (2) **connection/generated env injection** into aggregate workloads
  is a documented follow-up (it needs a cluster lookup, which would break the offline dry-run gate) —
  the shared *app* env does flow down. This closes the initiative: all three EPs are Complete.

- 2026-06-18 — **EP-3 complete; the EP-1↔EP-3 soft dependency cost zero wiring (affects EP-2).**
  EP-3 added `liveness :: Maybe WorkerProbe` to `Worker` (exec/TCP/HTTP probe, rendered as a
  `livenessProbe`/`startupProbe` on the `apps/v1` Deployment). Because EP-1's `Application` embeds
  `Worker` as-is and its encoder/decoder reuse `workerJSON`/`toWorker`, the new field flowed through
  the aggregate with **no change to EP-1's code** — only EP-1's fixtures saw a new `"liveness":null`
  byte, and they still round-trip. The backward-compat guarantee held exactly (existing worker
  goldens did not change; a no-probe worker emits no probe). **Consequence for EP-2:** aggregated
  workers render their probe via the same `renderWorker` EP-2 will call, so EP-2 needs no probe-aware
  wiring. EP-3 was implemented before EP-2 specifically so EP-2 renders liveness for free.

- 2026-06-18 — **EP-1 complete; the integration contract is implemented as specified (affects
  EP-2, EP-3).** `Nagare.Dsl.Application` ships with `appDatabases :: [Database]` (full specs, as
  pinned), the `appLabelKey`/`appLabel` helpers defining `nagare.dev/app` once, and the
  `emitApplication`/`encodeApplication` + `decodeApplication`/`loadApplication` wire contract. The
  aggregate embeds `Deployment`/`Worker`/`Database`/`Task` **as-is** and its encoder/decoder reuse
  every per-kind helper unchanged — so **EP-3's `Worker` liveness field will flow through the
  aggregate automatically** (at most a fixture refresh), and **EP-2** can `loadApplication` and
  render each embedded workload with its existing renderer. Two consumption notes for EP-2:
  (a) the test-suite target is `nagare-dsl-test`, not `nagare-dsl` (`cabal test nagare-dsl` errors
  `Cabal-7043`); (b) `applicationJSON` **canonicalizes list order by name** (sorts
  `workers`/`databases`/`tasks`), so any JSON consumer (kotei) sees deterministic, name-sorted
  output — EP-2's `--dry-run` JSON inherits this for free.

- 2026-06-18 — **Multi-workload `Config.hs` files need qualified imports for embedded records
  (affects EP-2's developer-facing example and docs).** The loader runs configs under
  `runghc -XGHC2024`, which does NOT enable `DuplicateRecordFields`; an `Application` config builds
  an `Application` record plus embedded `Database`/`Worker` records whose `namespace`/`image` labels
  collide. The fixture and `cluster/examples/multi-workload-app/` resolve this by importing
  `Nagare.Dsl.Database qualified as DB` / `Nagare.Dsl.Worker qualified as W` and qualifying those
  records' fields, keeping the `Application` record unqualified. EP-2's `app deploy` docs/examples
  must follow this template (see EP-1's Surprises & Discoveries for the full pattern).

- 2026-06-18 — **Library/executable boundary blocks EP-2's reuse plan (affects EP-2).** A
  validation pass that fact-checked every concrete code claim against the source found that
  EP-2's planned library module `Nagare.App.Deploy` (under `cli/nagarectl/src/`) cannot import
  three deploy helpers it relies on — `resolveTag`, `resolveBuildSpec`, `resolveConnectionEnv`
  — because they are defined in the `nagarectl` *executable* `cli/nagarectl/app/Main.hs`
  (`:2705`, `:1941`, `:1795`), and the executable depends on the library, not vice-versa. EP-2
  gained a prerequisite milestone **M0** to extract them into `Nagare.Deploy.Resolve` first.
  The other reused helpers (`qualifyImage`, `computeTag`, `generatedEnv`, `mergeGenerated`,
  `performBuild`, `gatherBuildArgs`, `resolveTargetProfile`) are already library-resident, so
  the extraction is scoped to exactly those three.

- 2026-06-18 — **EP-1↔EP-2 database-field mismatch (affects EP-1, EP-2).** EP-1 defines the
  declared databases as `appDatabases :: [Database]`, but EP-2's draft variously referenced
  `app ^. #databases`, `[DatabaseName]`, and an undefined `DatabaseRef`. Because the database
  phase must `runDbCreate` (needs the full spec), `[Database]` is correct; EP-2 was reconciled
  to consume `appDatabases :: [Database]` throughout, and EP-1 pinned the type in its Decision
  Log as the definer.

- 2026-06-18 — **Validation otherwise clean.** The remainder of the plans' concrete claims —
  record fields and smart-constructor names across `Types`/`Worker`/`Database`/`Task`, the
  `Config`/`Load` encoder-decoder-loader architecture, the `runghc -XGHC2024` config-as-program
  contract, the `nagarectl` command tree (the `app` read-commands already exist; `worker
  deploy` is the right template), the per-kind renderers, and the kizashi workload shape
  (1 service, 3 reactors, Postgres, separate `kizashi-migrate`, no schema self-heal) — all
  verified correct against the source. Minor precision fixes were applied: EP-3's `keyCompare`
  rank is integer-typed (no fractional `5.5`), EP-1's cabal module-slot note, and an EP-2 test
  command that named the wrong suite.


## Decision Log

- Decision: Decompose into three streams — Application aggregate (EP-1), orchestrated
  `nagarectl app deploy` with ordered hooks (EP-2), and worker liveness probes (EP-3).
  Rationale: groups by functional concern, keeps EP-1 the only foundational type
  dependency, and lets worker liveness (EP-3) land in parallel without gating the
  aggregate. The shared-binding/DRY gap is folded into EP-1 because the aggregate is where
  shared bindings naturally live.
  Date: 2026-06-19

- Decision: Support a fixed rollout phase ordering (pre-deploy hooks → databases →
  service/workers) rather than a general inter-workload dependency DAG.
  Rationale: the only ordering a single-node personal PaaS app needs is "migrations and
  databases before the serving workloads," which kizashi exemplifies. A general scheduler
  is unjustified complexity.
  Date: 2026-06-19

- Decision: Keep the existing single-workload commands (`deploy`, `worker deploy`, `db`,
  `task`) working unchanged; the `Application` aggregate composes them rather than
  replacing them.
  Rationale: preserves backward compatibility for the many single-Service apps and lets the
  aggregate reuse the proven per-kind renderers.
  Date: 2026-06-19

- Decision: EP-2's `nagarectl app deploy` must emit a machine-readable result (JSON on
  `--dry-run`) so the kotei backend
  (`shinzui/kotei` `docs/masterplans/7-full-stack-nagare-deployment-management.md`) can
  consume it without scraping prose.
  Rationale: kizashi is meant to be deployed *through* kotei; designing the output contract
  now avoids a brittle scraping seam later.
  Date: 2026-06-19

- Decision: EP-2 carries a prerequisite milestone (M0) that extracts the deploy resolvers
  `resolveTag`/`resolveBuildSpec`/`resolveConnectionEnv` from the `nagarectl` executable's
  `Main.hs` into a library module `Nagare.Deploy.Resolve` before any `Nagare.App.Deploy` work.
  Rationale: the new orchestration code is a library module and cannot import from the
  executable; validation confirmed those three helpers are the only Main-local ones EP-2 needs.
  Date: 2026-06-18

- Decision: The aggregate's declared-database field is `appDatabases :: [Database]` (full
  specs); EP-2 consumes it under that name/type. EP-1 is the definer.
  Rationale: EP-2's database phase calls `runDbCreate`, which needs `engine`/`version`/`size`;
  bare `DatabaseName`s would not suffice. This resolves an EP-1↔EP-2 drift found during
  validation. Workloads still *reference* databases by `DatabaseName`; EP-1 validates those
  references against the declared `appDatabases` set.
  Date: 2026-06-18


## Outcomes & Retrospective

**Outcome (2026-06-18 — initiative complete).** All three Exec-Plans are Complete. Nagare now has
the layer *above* the workload: a developer describes a multi-workload app as **one typed
`Application`** in a single `nagare/Config.hs` and deploys it with **one command**,
`nagarectl app deploy`, which fans it out into the correct Kubernetes objects in the correct order
under one shared identity. The four headline behaviors from Vision & Scope all landed:

- **One typed aggregate (EP-1).** `Nagare.Dsl.Application` bundles an optional Service, Workers,
  managed Databases (`appDatabases :: [Database]`), and Tasks, with the shared image / env / database
  bindings declared once and validated to agree with every workload (image agreement, declared
  databases, unique names, namespace agreement) at config-load time. JSON round-trips; a runghc
  fixture and a `cluster/examples/multi-workload-app/` example load to a validated value.
- **One deploy command with correct ordering (EP-2).** `nagarectl app deploy` builds the shared image
  once and rolls out in fixed phases — pre-deploy hooks → databases → service → workers — with a
  failed migration hook aborting before any serving workload is touched.
- **One identity / one rollback unit (EP-2).** Every rendered object carries `nagare.dev/app: <name>`
  (key defined once by EP-1, stamped by EP-2), and `--dry-run --json` emits the stable ordered object
  list kotei consumes.
- **Workers that fail safely (EP-3).** A `Worker` gained an optional exec/TCP/HTTP `livenessProbe`
  (and `startupProbe`), rendered into its `apps/v1` Deployment, so a hung loop is restarted.

**What the decomposition got right.** Isolating EP-1 (the type) first gave EP-2 a stable thing to
render and EP-3 a stable thing to extend. Building EP-3 *before* EP-2 (both were unblocked once EP-1
landed) meant EP-2's aggregated workers render liveness probes for free — the soft dependency cost
zero wiring, exactly as the Dependency Graph predicted. Reusing the proven per-kind renderers
throughout meant each EP added *one* new capability (a type, a probe, an orchestrator) rather than
re-modelling existing ones.

**Verification posture.** Everything is verified offline (the standard gate, since `nagare-01` is
frequently `TERMINATED`): `cabal test nagare-dsl-test` (319) and `cabal test nagarectl-test` (291, incl.
the 13-case `Nagare.App.Deploy` group) are green, and the kizashi-shaped fixtures exercise the full
`Config.hs → load → render → label → JSON` path. EP-2's **live apply acceptance is the one deferred
item**, awaiting a running cluster.

**Deferred / follow-ups (none blocking).** (1) EP-2 live-apply acceptance on `nagare-01`. (2) Wiring
per-database connection env and the `NAGARE_*` generated vars into aggregate workloads (needs a
cluster lookup; documented in EP-2). (3) An optional refinement to force every workload to the one
built image tag (today prebuilt workers render `:latest`). (4) The kotei backend (`shinzui/kotei`)
can now adopt the `app deploy --dry-run --json` contract.


## Revision Notes

- 2026-06-18 — **Initiative implemented; all three Exec-Plans Complete.** EP-1 (Application aggregate),
  EP-3 (worker liveness probes), and EP-2 (orchestrated `nagarectl app deploy`, M0–M4) all landed and
  are recorded Complete in the Exec-Plan Registry and Progress. EP-3 was implemented before EP-2 (both
  unblocked once EP-1 completed) so EP-2's aggregated workers render liveness probes for free.
  Offline test suites green (`nagare-dsl-test` 319, `nagarectl-test` 291); EP-2's live-apply
  acceptance is the single deferred item (no cluster). See each child plan's Outcomes & Retrospective
  and this document's Outcomes & Retrospective / Surprises & Discoveries for detail.

- 2026-06-18 — Validation pass (no implementation yet). Fact-checked every concrete code claim
  in EP-1/EP-2/EP-3 against the source and reconciled cross-plan drift. Changes: (1) EP-2 gained
  milestone **M0** (extract `resolveTag`/`resolveBuildSpec`/`resolveConnectionEnv` from `Main.hs`
  into `Nagare.Deploy.Resolve`) to fix a library-cannot-import-executable boundary;
  (2) EP-1↔EP-2 reconciled on `appDatabases :: [Database]` (full specs, needed by `runDbCreate`);
  (3) EP-2 M1 test command corrected to `nagarectl-test`; (4) EP-1 cabal module-slot note fixed;
  (5) EP-3 `keyCompare` rank guidance corrected to integer ranks. Recorded in Surprises &
  Discoveries, the Decision Log, the Integration Points, and each child plan's own Revision
  Notes. No Exec-Plan Registry status changes (all remain Not Started).
