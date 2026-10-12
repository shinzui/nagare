---
id: 72
slug: application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings
title: "Application aggregate: typed multi-workload app with shared image, env, and database bindings"
kind: exec-plan
created_at: 2026-06-19T00:36:47Z
intention: "intention_01kvemvx2reyn9qa49qks2dpcj"
master_plan: "docs/masterplans/14-multi-workload-applications-for-nagare.md"
---

# Application aggregate: typed multi-workload app with shared image, env, and database bindings

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [72-application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/72-application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today a developer who runs a single logical app made of several workloads — a web
Service, a few background Workers, a managed Database, and a migration Task — must write
**four-plus separate `nagare/Config.hs` files**, each repeating the same name prefix,
namespace, image repository, env/secret set, and database binding, and deploy them with
four-plus separate commands. There is no shared identity, no single place the shared
bindings live, and nothing that catches a worker pointing at a database the app never
declared.

After this change, a developer describes the whole app as **one typed `Application`** value
in a single `nagare/Config.hs`, declares the **image**, the **env/secret set**, and the
**database bindings once** on the `Application`, and the platform validates that those
shared bindings flow down consistently to every workload it bundles. Illegal shapes — a
worker disagreeing with the service on the shared image, a worker referencing a database the
app never declared, two workloads with the same name — are **rejected at config-load time
with a precise message**, the same maximal-safety discipline as the rest of the Nagare DSL.
Every workload the aggregate carries is stamped with one shared identity label,
`nagare.dev/app: <name>`, so the whole app can later be deployed, listed, and torn down as a
unit.

You can see it working entirely **offline**: a valid multi-workload `Application` survives a
JSON emit → decode round-trip byte-identically (`cabal test nagare-dsl`), an `Application`
config that references an undeclared database fails to load with
`field 'databases' failed validation: ... not declared on the application`, and a worked
example under `cluster/examples/multi-workload-app/` loads to the expected `Application`.

This plan (EP-1) delivers **only the type and its loader/emitter**. It does **not** render
Kubernetes objects or deploy anything — that is EP-2
(`docs/plans/73-orchestrated-release-nagarectl-app-deploy-with-ordered-rollout-and-pre-deploy-migration-hooks.md`).
The existing single-workload types and commands (`Deployment`, `Worker`, `Database`,
`Task`; `deploy`, `worker deploy`, `db`, `task`) stay **unchanged**; the `Application`
*composes* them.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-06-18): `Nagare.Dsl.Application` module created and exposed in `nagare-dsl.cabal`,
      with the `Application` record, the `nagare.dev/app` label helper (`appLabelKey`/`appLabel`),
      the `mkApplication` smart constructor, and the shared-binding validation rules (image
      agreement, declared databases, unique names, namespace agreement).
- [x] M1 (2026-06-18): unit tests for `mkApplication` (happy path, image disagreement,
      undeclared-database rejection, duplicate workload/database name rejection, namespace
      disagreement) pass under `cabal test nagare-dsl-test --test-options='--pattern "mkApplication"'`.
- [x] M2 (2026-06-18): `emitApplication` / `encodeApplication` + `applicationJSON` added to
      `Nagare.Dsl.Config` and `JsonApplication` / `toApplication` / `decodeApplication` /
      `loadApplication` added to `Nagare.Dsl.Load`, with the `"kind": "Application"`
      discriminator. Each embedded workload reuses its existing per-kind encoder/marshaller;
      `toApplication` re-runs `mkApplication` for defence in depth.
- [x] M2 (2026-06-18): emit → decode round-trip tests pass (multi-workload + service-less
      `Application` decode byte-identically; kind discrimination both ways vs `Deployment`; the
      undeclared-database / image-disagreement / duplicate-name failures are reported as a precise
      `MarshalError "application"`).
- [x] M3 (2026-06-18): `cli/nagare-dsl/test/fixtures/application/nagare/Config.hs` and
      `cluster/examples/multi-workload-app/nagare/Config.hs` (+ `README.md`) exist and load via
      `loadApplication` through the `runghc` harness; the fixture-load test asserts `Right multiApp`
      and the example-load test asserts `Right`. (Golden round-trip bytes deferred — the M2
      `decodeApplication . encodeApplication == Right` round-trip already pins the wire shape
      behaviorally; no `test/golden/application.json` was added.)
- [x] M3 (2026-06-18): `docs/user/deploying-apps.md` gained a short "Multi-workload applications"
      section pointing at the example and naming `nagarectl app deploy` (EP-2). The doc set already
      cross-links workload kinds (Scheduled tasks, Managed databases), so the condition held.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-18 — **The test-suite target is `nagare-dsl-test`, not `nagare-dsl`.** The plan's
  Concrete Steps say `cabal test nagare-dsl`, but `cabal test` resolves `nagare-dsl` to the
  *library* and errors (`Cabal-7043`). The runnable command is `cabal test nagare-dsl-test`
  (the `test-suite` stanza name). All acceptance commands below should use `nagare-dsl-test`.

- 2026-06-18 — **`worker1 {image = ...}` record updates are `-Wambiguous-fields`.** Because
  `ApplicationSpec` imports `Types`/`Worker`/`Database`/`Task`, the labels `image`/`namespace`/`env`
  are in scope from multiple record types, so a bare record update on a `Worker` triggers
  `-Wambiguous-fields` (the type-directed disambiguation GHC warns it will drop). Fixed by using
  the house-idiom `&`/`.~` with `#field` generic-lens optics (as `Presets.hs` does), which meant
  adding `lens`/`generic-lens` to the `test-suite` `build-depends` (they were already library
  deps and in the build plan — no new package enters the project). See Decision Log.

- 2026-06-18 — **`applicationJSON` canonicalizes list order by name, so a round-trip fixture must
  be pre-sorted.** As the plan specifies (matching `deploymentJSON`'s task sort), the encoder sorts
  `workers`/`databases`/`tasks` by name for deterministic bytes. The decoder preserves that sorted
  order, so `decodeApplication (encode app) == Right app` holds only when `app`'s lists are already
  name-sorted — i.e. the canonical form is the sorted one. The `multiApp` fixture's workers were
  reordered to `[kizashi-agent-worker, kizashi-worker]` to make the round-trip an identity. (The
  existing single-element `Deployment`/`Worker`/`Task` round-trip fixtures never surfaced this.)

- 2026-06-18 — **A multi-workload `Config.hs` must use QUALIFIED imports for the embedded
  workload records (affects any future multi-kind config / EP-2 docs).** The loader runs configs
  under `runghc -XGHC2024`, which does **not** enable `DuplicateRecordFields`. An `Application`
  config necessarily builds an `Application` record *and* embedded `Database`/`Worker` records, and
  the labels `namespace`/`image` are shared across all three — so a single unqualified scope makes
  every use of `namespace` an "Ambiguous occurrence". The fixture and example resolve this by
  importing `Nagare.Dsl.Database qualified as DB` and `Nagare.Dsl.Worker qualified as W` and building
  those records with qualified field names (`DB.Database { DB.namespace = ... }`,
  `w {W.databases = ...}`), while the `Application` record stays unqualified (its fields are then the
  only unqualified `namespace`/`image`/`env` in scope). `Task` needs no qualification (all its fields
  are `task`-prefixed and unique). The plan's M3 fixture sketch (which `import`ed `Nagare.Dsl.Types`
  wholesale) would not have compiled; this qualified-import shape is the correct template, and EP-2's
  developer-facing example/docs should follow it. Verified by running the fixture directly under the
  loader's exact invocation (`runghc -XGHC2024 -i<dir> <Config.hs>`); it emits the expected JSON.

## Decision Log

Record every decision made while working on the plan.

- Decision: The `Application` record carries the shared identity and shared bindings at the
  top level (`appName`, `namespace`, `image`, `env`, `databases`) and embeds the existing
  workload values **as-is**: `service :: Maybe Deployment`, `workers :: [Worker]`,
  `appDatabases :: [Database]`, `tasks :: [Task]`. It does not redefine or wrap the workload
  types.
  Rationale: composing the proven `Deployment`/`Worker`/`Database`/`Task` types (rather than
  re-modelling their fields) means every per-kind smart constructor, JSON encoder, and future
  field (e.g. EP-3's `Worker` liveness probe,
  `docs/plans/74-worker-health-and-liveness-probes.md`) flows through the aggregate
  automatically with no re-wiring. The aggregate's job is *cross-workload* invariants, not
  re-implementing per-workload ones.
  Date: 2026-06-19

- Decision: The aggregate validates three cross-workload invariants in `mkApplication`
  (and re-checks them in the loader's marshalling step, as defence in depth, exactly as
  `toDeployment` re-checks co-located tasks): (1) **image agreement** — every embedded
  workload's `image` must equal the `Application`'s shared `image`; (2) **declared databases**
  — every `DatabaseName` any workload references via its `databases` field must appear in the
  app's `appDatabases` set (matched by `dbName`); (3) **unique workload names** — no two
  embedded workloads (the service plus all workers plus all tasks) may share a `ServiceName`,
  and no two managed databases may share a `DatabaseName`.
  Rationale: these are precisely the "illegal shapes" the MasterPlan's headline guarantee
  names; each is a cross-field property a single workload's own constructor cannot see.
  Date: 2026-06-19

- Decision: A new top-level JSON `"kind": "Application"` discriminator (matching the
  `Worker`/`Database`/`Task` convention) selects the aggregate, and `decodeApplication`
  rejects any other kind (or a kind-less `Deployment`) as `UnexpectedKind`. The shared env is
  encoded once at the aggregate level and is **not** duplicated into each embedded workload's
  JSON; the embedded workloads serialize with their existing encoders unchanged.
  Rationale: consistency with the existing per-kind loaders, and keeping the shared bindings
  the single source of truth on the wire (EP-2 is what fans the shared env down into rendered
  objects; the type only validates and carries it).
  Date: 2026-06-19

- Decision: The aggregate's declared-database field is `appDatabases :: ![Database]` — full
  `Database` specs, not a list of `DatabaseName`. The undeclared-database invariant compares
  each workload's `databases :: [DatabaseName]` against the *set of names* drawn from
  `appDatabases`.
  Rationale: EP-2
  (`docs/plans/73-orchestrated-release-nagarectl-app-deploy-with-ordered-rollout-and-pre-deploy-migration-hooks.md`)
  must `runDbCreate` each declared database during its database rollout phase, which needs the
  full spec (`engine`, `version`, `size`); bare names would be insufficient. EP-2 consumes this
  field by the name `appDatabases` (it was reconciled to match during MasterPlan validation on
  2026-06-18). This plan is the definer; EP-2 must not re-type or rename the field without
  updating this plan's encoder/decoder and tests.
  Date: 2026-06-19

- Decision: The shared identity label is the constant string key `nagare.dev/app`, and the
  module exposes `appLabel :: Application -> (Text, Text)` returning `("nagare.dev/app",
  <appName>)`. EP-1 only *introduces* the key (so EP-2 and kotei share one definition); EP-2
  is what stamps it onto every rendered object.
  Rationale: the MasterPlan's Integration Points fix this label as the contract kotei relies
  on; defining the key once in the type module avoids a stringly-typed drift between EP-2's
  renderer and the discovery side.
  Date: 2026-06-19

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-18 — EP-1 complete).** All three milestones landed and the full
`nagare-dsl` suite is green (`cabal test nagare-dsl-test`, 301 tests, including the 15 new
`Nagare.Dsl.Application (EP-1)` cases). The purpose is met: a multi-workload app is now describable
as one typed `Application` in a single `Config.hs`, with the image / env / database bindings
declared once and validated to agree with every embedded workload. The four headline guarantees are
behaviorally proven (not just "it compiles"):

- **Image agreement, declared databases, unique names, namespace agreement** are enforced by
  `mkApplication` and re-enforced at the loader boundary (`toApplication` re-runs `mkApplication`),
  each with a negative test asserting the precise message / `MarshalError "application"`.
- **One wire contract**: a valid multi-workload and a service-less `Application` round-trip
  byte-identically through `emitApplication` → `decodeApplication`; kind discrimination holds both
  ways against a bare `Deployment`.
- **One shared identity**: `appLabelKey`/`appLabel` define `nagare.dev/app` once for EP-2 to stamp.
- **End-to-end**: a `runghc` fixture and the `cluster/examples/multi-workload-app/` example both load
  to a validated `Application`.

**Design choices that held.** Composing the existing `Deployment`/`Worker`/`Database`/`Task` types
*as-is* (rather than re-modelling them) meant the aggregate's encoder/decoder reuses every per-kind
`*JSON`/`to*` helper unchanged — so EP-3's forthcoming `Worker` liveness field will flow through the
aggregate automatically, with at most a fixture refresh. The declared-database field is
`appDatabases :: [Database]` (full specs), as pinned for EP-2's `runDbCreate` phase.

**Gaps / deferrals (none blocking).** (1) The JSON golden test was deferred: the emit→decode
round-trip already pins the wire shape, and a golden would add a maintenance burden EP-3 would have
to refresh. (2) `mkApplicationFrom` (the optional one-line preset) was not added — the example/fixture
build the full record directly, and no caller needs the preset yet; EP-2 can add it if the CLI wants
a minimal-app constructor.

**Hand-off note for EP-2 / EP-3.** Authoring a multi-workload `Config.hs` requires qualified imports
for the embedded `Database`/`Worker` records under `runghc -XGHC2024` (no `DuplicateRecordFields`);
see Surprises & Discoveries. The fixture/example are the canonical template.

