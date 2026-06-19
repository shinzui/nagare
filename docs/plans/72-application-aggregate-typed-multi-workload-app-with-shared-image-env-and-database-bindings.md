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


## Context and Orientation

This work lives entirely in the `nagare-dsl` **library**, the pure typed-deployment model
that backs `nagarectl`. The library has no cluster access; everything here is verifiable
offline. Assume the reader knows nothing about the codebase; every file below is named by its
full path from the repository root `/Users/shinzui/Keikaku/bokuno/nagare`.

**The repository.** Nagare is a single-node k3s/Knative personal PaaS written in Haskell with
`cabal`. The library package is `cli/nagare-dsl/`; its cabal file is
`cli/nagare-dsl/nagare-dsl.cabal`. The house language edition is **GHC2024** with a fixed
extension set (`cli/nagare-dsl/nagare-dsl.cabal`, the `common common` stanza:
`DeriveAnyClass`, `DuplicateRecordFields`, `MultilineStrings`, `OverloadedLabels`,
`OverloadedStrings`).

**The maximal-safety pattern.** Each constrained leaf type is a `newtype` whose data
constructor is **hidden**; the module exposes a validating smart constructor
`mkX :: ... -> Either Text X` plus a read-only accessor `xText`/`xInt`. Code outside the
module therefore cannot construct an invalid value. Where a record has cross-field invariants
a single field type cannot express, the module exposes a `mkRecord :: Record -> Either Text
Record` re-validation function (e.g. `mkScale`, `mkHealthCheck`, `mkTask`). The `Application`
follows exactly this discipline: its smart constructor `mkApplication` enforces the
*cross-workload* invariants.

**The workload types this aggregate composes** (all under `cli/nagare-dsl/src/Nagare/Dsl/`):

- `Types.hs` — the request-driven `Deployment` record and the shared leaf types. Relevant
  fields of `data Deployment`: `name :: ServiceName`, `namespace :: Namespace`,
  `image :: ImageRef`, `build :: BuildSpec`, `domains :: [DomainSpec]`, `port :: Port`,
  `env :: Map EnvName ScopedEnvVar`, `resources :: Maybe Resources`, `scale :: Maybe Scale`,
  `healthCheck :: Maybe HealthCheck`, `volumes :: [Volume]`, `databases :: [DatabaseName]`,
  `tasks :: [Task]`, `cdn :: Maybe Cdn`. Leaf smart constructors used below:
  `mkServiceName`, `serviceNameText`; `mkNamespace`, `defaultNamespace`, `namespaceText`;
  `mkImageRef`, `imageRefText`; `mkEnvName`, `envNameText`; `mkSecretName`, `secretNameText`;
  `mkDatabaseName`, `databaseNameText`; the `EnvVar` sum type (`EnvLiteral` / `EnvSecretRef`)
  and `ScopedEnvVar` / `runtimeScoped` / `scopedEnv`. `ImageRef` derives `Eq` and `Ord`, so
  image agreement is a simple `==` comparison.

- `Worker.hs` — `data Worker` with fields `name :: ServiceName`, `namespace :: Namespace`,
  `image :: ImageRef`, `build :: BuildSpec`, `command :: Maybe Command`,
  `replicas :: Replicas`, `env :: Map EnvName ScopedEnvVar`, `resources :: Maybe Resources`,
  `volumes :: [Volume]`, `databases :: [DatabaseName]`. The preset `webWorker :: Text -> Text
  -> Either String Worker`. **Note for EP-3 integration**: EP-3
  (`docs/plans/74-worker-health-and-liveness-probes.md`) will add an optional liveness field
  to this record; because the `Application` carries `Worker` values *as-is*, that field will
  flow through this aggregate automatically with no change here.

- `Database.hs` — `data Database` with `dbName :: DatabaseName`, `engine :: Engine`,
  `version :: EngineVersion`, `namespace :: Namespace`, `size :: Quantity`,
  `resources :: Maybe Resources`, `retention :: RetentionPolicy`. `Engine = Postgres | Redis
  | ClickHouse`. `databaseNameText :: DatabaseName -> Text` is re-exported here.

- `Task.hs` — `data Task` (`taskName :: ServiceName`, `taskNamespace :: Namespace`,
  `taskSchedule :: Schedule`, `taskImage :: Maybe ImageRef`, `taskApp :: Maybe ServiceName`,
  `taskCommand :: [Text]`, `taskArgs :: [Text]`, `taskEnv`, `taskResources`, and the policy
  / history fields), with `mkTask :: Task -> Either Text Task`. A `Task` that inherits an
  app's image carries `taskImage = Nothing` and `taskApp = Just <name>`; the existing
  deploy-level invariant in `Load.hs` (`checkTaskApp`) already requires `taskApp` to name the
  enclosing app.

**Serialization (the emit → decode round-trip).** `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`
turns a validated value into JSON bytes on stdout. For each kind it exposes a pair:
`emitX :: X -> IO ()` (writes `LBS.putStr (encodeX x)`) and `encodeX :: X -> LBS.ByteString`
(`encode . xJSON`, where `xJSON :: X -> Data.Aeson.Value` builds the wire object). The
encoders use the `lens`/`generic-lens` `^.` accessors with `OverloadedLabels` (`dep ^. #name`)
**inside the library** (the library *does* enable `OverloadedLabels`; only the *config files*
the loader runs do not — see below). Shared sub-encoders already exist and must be reused:
`buildSpecJSON`, `volumeJSON`, `scopedEnvJSON`, `scopeTokensJSON`, and the per-kind
`taskJSON` / `workerJSON` / `databaseJSON`. The discriminator pattern: kinded objects emit a
top-level `"kind"` (`"Worker"`, `"Database"`, `"Task"`, `"StaticSite"`, `"ServerSite"`); a
bare `Deployment` emits no `"kind"`.

`cli/nagare-dsl/src/Nagare/Dsl/Load.hs` reads those bytes back. For each kind there is: a
`JsonX` intermediate record with a `FromJSON` instance (every optional field given a default
so a partial object becomes a precise `MarshalError`, not an opaque aeson parse error); a
`toX :: JsonX -> Either LoadError X` marshaller that re-runs **every** smart constructor as
defence in depth (and re-checks cross-field invariants); a `decodeX :: ByteString -> Either
LoadError X` that reads the `"kind"` discriminator via `JsonKindEnvelope` and dispatches; and
a `loadX :: FilePath -> IO (Either LoadError X)` that calls `runConfig` and then `decodeX`.
The error type is `data LoadError = FileNotFound | CompileError | MissingBinding | MarshalError
Text Text | UnexpectedKind Text Text` with `renderLoadError :: LoadError -> Text`.

**The loader's compile-and-run contract** (`runConfig`, `Load.hs`): a config `Config.hs` is
compiled and run with `runghc -XGHC2024 -i<configDir> <path>`. Crucially **`-XGHC2024` does
not enable `OverloadedLabels`**, so config files use **plain record updates**
(`base {replicas = ...}`), never `#field` lenses. Empty stdout means the config never called
an `emit*` helper (`MissingBinding`). See `cli/nagare-dsl/test/fixtures/worker/nagare/Config.hs`
for the canonical shape: a `Config.hs` that builds a value in `Either String`, then
`main = either (ioError . userError) emit* value`.

**Tests** live in `cli/nagare-dsl/test/`. The main driver is `test/Spec.hs`
(`Test.Tasty.defaultMain` over a `testGroup` per concern); per-kind specs are separate modules
(`WorkerSpec.hs`, `LoadSpec.hs`, `StaticSpec.hs`, `ServerSpec.hs`, `CdnSpec.hs`) listed in the
`other-modules` of the `test-suite` stanza in `nagare-dsl.cabal`. The conventions to mirror
(see `test/WorkerSpec.hs`): a local `unsafe :: Either Text a -> a` to unwrap known-valid
fixtures; `decodeX (toStrict (encodeX value)) @?= Right value` for round-trips; a
`case decodeY (...) of Left (UnexpectedKind ...) -> pure (); other -> assertFailure ...`
for kind discrimination; and a `loadX "test/fixtures/<kind>/nagare/Config.hs"` test that
exercises the full `runghc` harness against a fixture. Golden files live in `test/golden/`;
fixtures live in `test/fixtures/<kind>/nagare/Config.hs`. Worked examples live under
`cluster/examples/<name>/nagare/Config.hs` (e.g. `cluster/examples/queue-worker/`), and
`test/Spec.hs`'s `presetsGoldenTests` shows how a spec loads an example via a relative path
(`"../../cluster/examples/<name>/nagare/Config.hs"`).

**Developer-facing model.** `docs/user/deploying-apps.md` and `docs/user/workers.md` describe
the one-project-one-workload mental model this plan extends. EP-2 owns the
`nagarectl app deploy` developer story; this plan touches docs only minimally (M3).


## Plan of Work

The work is three independently-verifiable milestones, each finishing with `cabal test
nagare-dsl` green. M1 delivers the type and its validation (pure, no JSON). M2 delivers the
emit/encode and loader/decode round-trip (the wire contract). M3 delivers a worked example
and an end-to-end load test through the `runghc` harness, plus an optional doc note.

All file paths are under `/Users/shinzui/Keikaku/bokuno/nagare`. New/edited source files:

- New: `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` (the type, smart constructor, validation,
  label helper).
- Edit: `cli/nagare-dsl/nagare-dsl.cabal` (expose the module; add it to the test suite's
  `other-modules`).
- Edit: `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` (add `emitApplication` / `encodeApplication`
  + `applicationJSON`).
- Edit: `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` (add `JsonApplication` + `toApplication` +
  `decodeApplication` + `loadApplication`).
- New: `cli/nagare-dsl/test/ApplicationSpec.hs` (unit, round-trip, load tests).
- Edit: `cli/nagare-dsl/test/Spec.hs` (import and add `applicationTests` to the top group).
- New: `cli/nagare-dsl/test/fixtures/application/nagare/Config.hs` (the load-harness fixture).
- New: `cluster/examples/multi-workload-app/nagare/Config.hs` (+ a short `README.md`).
- Edit (optional): `docs/user/deploying-apps.md`.

### Milestone M1 — the `Application` type, smart constructor, and validation

**Scope.** Create `cli/nagare-dsl/src/Nagare/Dsl/Application.hs`. Define the `Application`
record, an `AppName` newtype (or reuse `ServiceName` — see below), the `appLabelKey` /
`appLabel` helpers, and `mkApplication` enforcing the three cross-workload invariants. Add the
module to `nagare-dsl.cabal`'s `exposed-modules`. No JSON yet.

**What will exist at the end.** A compilable module exporting `Application(..)`,
`mkApplication`, the label helpers, and the accessors; unit tests in a new
`test/ApplicationSpec.hs` proving the validation accepts the happy path and rejects each
illegal shape.

**The record.** Reuse `ServiceName` for the app's name (a DNS-1123 label is exactly a
Kubernetes object name, and the per-app label value must be a label-safe string — the same
rule the existing workloads already satisfy). Define, in `Application.hs`:

```haskell
-- | A multi-workload application: one shared identity that bundles an optional
-- web Service, a list of Workers, a list of managed Databases, and a list of
-- Tasks, with the image / env / database bindings declared ONCE here and
-- validated to agree with every embedded workload. There is no hidden
-- constructor; the safety guarantee comes from the field types plus the
-- cross-workload invariants enforced by 'mkApplication'.
data Application = Application
  { appName :: !ServiceName
  -- ^ the shared identity; the value of the 'nagare.dev/app' label.
  , namespace :: !Namespace
  -- ^ the shared namespace; every embedded workload must agree (re-checked).
  , image :: !ImageRef
  -- ^ the shared image repository, declared once; every embedded workload's
  -- own image must equal this (the 'image agreement' invariant).
  , env :: !(Map EnvName ScopedEnvVar)
  -- ^ the shared env/secret set declared once on the app. EP-2 fans this down
  -- into every rendered object; the type carries it as the single source of
  -- truth and does not duplicate it into each embedded workload's JSON.
  , appDatabases :: ![Database]
  -- ^ the managed databases this app owns. A workload may only reference a
  -- database whose 'dbName' appears here (the 'declared databases' invariant).
  , service :: !(Maybe Deployment)
  -- ^ the optional request-driven web Service. 'Nothing' for an app with no
  -- HTTP front (e.g. workers + a migration task only).
  , workers :: ![Worker]
  -- ^ the background workers. Carried AS-IS so EP-3's liveness field flows
  -- through automatically.
  , tasks :: ![Task]
  -- ^ co-located tasks (e.g. a migration task that EP-2 runs as a pre-deploy
  -- hook). A task that inherits the app image has taskImage = Nothing and
  -- taskApp = Just appName.
  }
  deriving stock (Generic, Eq, Show)
```

Imports: `Deployment` (and the leaf types/constructors) from `Nagare.Dsl.Types`; `Worker(..)`
from `Nagare.Dsl.Worker`; `Database(..)`, `databaseNameText` from `Nagare.Dsl.Database`;
`Task(..)`, `taskName`, `taskApp`, `taskImage` from `Nagare.Dsl.Task`; `Map` from
`Data.Map`; `Set` from `Data.Set`. Follow the existing module-header doc-comment style.

**The label helper.**

```haskell
-- | The shared-identity label KEY every object an Application renders carries.
-- Introduced here (EP-1); stamped onto rendered objects by EP-2.
appLabelKey :: Text
appLabelKey = "nagare.dev/app"

-- | The (key, value) shared-identity label for an Application:
-- @("nagare.dev/app", <appName>)@.
appLabel :: Application -> (Text, Text)
appLabel app = (appLabelKey, serviceNameText (appName app))
```

**The smart constructor and validation.** `mkApplication :: Application -> Either Text
Application` re-validates the three cross-workload invariants and returns the value unchanged
on success (mirroring `mkTask` / `mkScale`). Define the helper accessors that flatten the
workloads:

- *Image agreement.* Collect every embedded workload's image: `image <$> service` (when
  present), `map (\w -> w.image) workers`, and — for tasks — only the tasks that pin their
  own `taskImage` (an image-inheriting task carries `Nothing` and is exempt). Reject if any
  differs from the app's `image`, naming the offending workload:
  `Left ("workload '" <> nm <> "' declares image '" <> got <> "' but the application's shared
  image is '" <> want <> "'")`.
- *Declared databases.* Build the set `declared = Set.fromList (map dbName appDatabases)`.
  Collect every `DatabaseName` referenced by any workload: `databases` of the service (when
  present) plus `databases` of each worker. Reject the first reference not in `declared`:
  `Left ("workload references database '" <> nm <> "' which is not declared on the
  application")`.
- *Unique names.* The embedded *workload* names are: the service's `name` (when present), each
  worker's `name`, and each task's `taskName` — all `ServiceName`s. Reject the first duplicate
  across that combined list: `Left ("duplicate workload name: " <> nm)`. Separately reject a
  duplicate `dbName` across `appDatabases`: `Left ("duplicate database name: " <> nm)`. Also
  reject a database name that collides with a workload name *only if that proves confusing* —
  keep it simple: validate the two namespaces (workloads, databases) independently, matching
  how the rest of the DSL keeps Service names and Database names in separate spaces.
- *Namespace agreement (cheap belt-and-braces).* Optionally reject any embedded workload whose
  `namespace` differs from the app's `namespace`. Implement this; it costs one comparison per
  workload and prevents a class of confusing partial deploys. Message:
  `Left ("workload '" <> nm <> "' is in namespace '" <> got <> "' but the application's
  namespace is '" <> want <> "'")`.

Use a local `firstDuplicate :: Ord a => [a] -> Maybe a` (copy the one in `Load.hs`, or define
it here) and a local `tshow`. Keep every message precise and quoting the offending value, to
match the existing error style.

**Optional preset (nice-to-have, do if cheap).** A `mkApplicationFrom :: Text -> Text ->
Either Text Application` that takes a name and image, defaults `namespace = defaultNamespace`,
empty env / databases / workers / tasks, and `service = Nothing`, then runs `mkApplication`.
This is the `webService`/`webWorker` analogue and makes a minimal example one line. Only add
it if it does not balloon the milestone.

**Cabal.** In `cli/nagare-dsl/nagare-dsl.cabal`, add `Nagare.Dsl.Application` to the library
`exposed-modules` list. Alphabetically it sorts **before** `Nagare.Dsl.Build`, so it goes at
the head of the `Nagare.Dsl.*` block (the current first entry is `Nagare.Dsl.Build`, followed
by `Nagare.Dsl.Cdn.Types`, `Nagare.Dsl.Config`, …). Ordering is cosmetic; the build does not
depend on it.

**Tests (M1 portion of `test/ApplicationSpec.hs`).** A `testGroup "mkApplication"` with cases:
the happy multi-workload value yields `Right`; a worker whose `image` differs from the shared
image yields `Left` containing `"shared image"`; a worker referencing an undeclared database
yields `Left` containing `"not declared"`; two workers sharing a name yield `Left` containing
`"duplicate workload name"`; two databases sharing a name yield `Left` containing `"duplicate
database name"`. Use the `unsafe`/`assertLeftContains` helpers copied from `WorkerSpec.hs`.

**Acceptance.** `cabal test nagare-dsl` is green; the new `mkApplication` group runs and
passes. (Round-trip and load tests come in M2/M3.)

### Milestone M2 — emit/encode and loader/decode round-trip

**Scope.** Add the wire contract: `emitApplication`/`encodeApplication`/`applicationJSON` in
`Config.hs`, and `JsonApplication`/`toApplication`/`decodeApplication`/`loadApplication` in
`Load.hs`, with a `"kind": "Application"` discriminator. Re-run **all** validation in
`toApplication` (defence in depth), so a hand-written or tampered JSON that violates an
invariant is rejected with a precise `MarshalError`.

**What will exist at the end.** `decodeApplication (toStrict (encodeApplication app)) ==
Right app` for any valid `Application`; kind discrimination against `Deployment`/`Worker`;
and the three invariants enforced at the loader boundary too.

**Encoder (`Config.hs`).** Add to the module export list `emitApplication`,
`encodeApplication`. Mirror `emitWorker`/`encodeWorker`:

```haskell
emitApplication :: Application -> IO ()
emitApplication app = LBS.putStr (encodeApplication app)

encodeApplication :: Application -> LBS.ByteString
encodeApplication = encode . applicationJSON
```

`applicationJSON :: Application -> Value` builds:

```haskell
applicationJSON :: Application -> Value
applicationJSON app =
  object
    [ "kind"      .= ("Application" :: Text)
    , "name"      .= serviceNameText (app ^. #appName)
    , "namespace" .= namespaceText (app ^. #namespace)
    , "image"     .= imageRefText (app ^. #image)
    , "env"       .= map scopedEnvJSON (Map.toAscList (app ^. #env))
    , "databases" .= map databaseJSON (sortOn (databaseNameText . dbName) (app ^. #appDatabases))
    , "service"   .= fmap deploymentJSON (app ^. #service)
    , "workers"   .= map workerJSON (sortOn (serviceNameText . workerName) (app ^. #workers))
    , "tasks"     .= map taskJSON (sortOn taskName (app ^. #tasks))
    ]
```

Reuse the **existing** `databaseJSON`, `deploymentJSON`, `workerJSON`, `taskJSON`,
`scopedEnvJSON` already in `Config.hs` — do not write new per-workload encoders. (The
embedded `deploymentJSON` already emits its own `databases`/`tasks`/`env`; the shared `env`
at the aggregate level is encoded once and is the single source of truth — EP-2 fans it
down. The embedded objects keep their own fields verbatim so they round-trip unchanged.)
Sort the lists deterministically (by name) exactly as `deploymentJSON` already sorts `tasks`,
so the bytes are stable for golden comparison. `workerName`/`dbName` accessors: use the
record selectors (`name` on `Worker`, `dbName` on `Database`) via the `^. #...` lenses to
avoid the `DuplicateRecordFields` ambiguity, or qualify; match whatever the surrounding code
in `Config.hs` does (it uses `w ^. #name`, `db ^. #dbName`).

**Decoder (`Load.hs`).** Add `decodeApplication` and `loadApplication` to the module export
list. Define the intermediate:

```haskell
data JsonApplication = JsonApplication
  { jaName      :: !Text
  , jaNamespace :: !Text
  , jaImage     :: !Text
  , jaEnv       :: ![JsonEnvEntry]
  , jaDatabases :: ![JsonDatabase]   -- reuse the existing JsonDatabase
  , jaService   :: !(Maybe JsonDeployment)
  , jaWorkers   :: ![JsonWorker]     -- reuse the existing JsonWorker
  , jaTasks     :: ![JsonTask]       -- reuse the existing JsonTask
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonApplication where
  parseJSON = withObject "Application" $ \o ->
    JsonApplication
      <$> o .:  "name"
      <*> o .:  "namespace"
      <*> o .:  "image"
      <*> o .:? "env"       .!= []
      <*> o .:? "databases" .!= []
      <*> o .:? "service"
      <*> o .:? "workers"   .!= []
      <*> o .:? "tasks"     .!= []
```

`JsonDeployment`, `JsonWorker`, `JsonDatabase`, `JsonTask`, and `JsonEnvEntry` already exist in
`Load.hs` with their `FromJSON` instances — reuse them so the embedded objects decode exactly
as they do standalone. The embedded `JsonDeployment`/`JsonWorker` carry their own `"image"`
fields (the per-workload image), which is what the agreement check compares against.

`toApplication :: JsonApplication -> Either LoadError Application` marshals each part with the
**existing** `toDeployment` / `toWorker` / `toDatabase` / `toTask` (re-running every leaf
constructor), then enforces the cross-workload invariants — preferably by calling
`mkApplication` on the assembled record and mapping its `Left Text` to
`MarshalError "application" msg`, so the validation lives in one place:

```haskell
toApplication :: JsonApplication -> Either LoadError Application
toApplication j = do
  name'  <- mapLeft (MarshalError "name")      $ mkServiceName (jaName j)
  ns'    <- mapLeft (MarshalError "namespace") $ mkNamespace (jaNamespace j)
  img'   <- mapLeft (MarshalError "image")     $ mkImageRef (jaImage j)
  env'   <- mapM toEnvEntry (jaEnv j)
  dbs'   <- traverse toDatabase (jaDatabases j)
  svc'   <- traverse toDeployment (jaService j)
  wks'   <- traverse toWorker (jaWorkers j)
  tks'   <- traverse toTask (jaTasks j)
  let assembled = Application
        { appName = name', namespace = ns', image = img'
        , env = Map.fromList env', appDatabases = dbs'
        , service = svc', workers = wks', tasks = tks'
        }
  mapLeft (MarshalError "application") (mkApplication assembled)
```

Then:

```haskell
decodeApplication :: ByteString -> Either LoadError Application
decodeApplication bs =
  case eitherDecodeStrict bs of
    Left perr -> Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right envelope -> case jkeKind envelope of
      Just "Application" -> case eitherDecodeStrict bs of
        Left perr -> Left (MarshalError "json" ("could not decode application: " <> Text.pack perr))
        Right ja  -> toApplication ja
      Just other -> Left (UnexpectedKind "Application" other)
      Nothing    -> Left (UnexpectedKind "Application" "<none>")

loadApplication :: FilePath -> IO (Either LoadError Application)
loadApplication path = fmap (>>= decodeApplication) (runConfig path)
```

Import `Application(..)`, `mkApplication` from `Nagare.Dsl.Application` at the top of
`Load.hs` (and `Config.hs`). `toDeployment`, `toWorker`, `toDatabase`, `toTask`,
`toEnvEntry`, `mapLeft` already exist in `Load.hs`.

**Tests (M2 portion of `test/ApplicationSpec.hs`).** Add `testGroup "JSON round-trip and kind
discrimination"`:
- `decodeApplication (toStrict (encodeApplication multiApp)) @?= Right multiApp` for a fixture
  `multiApp` with a service, two workers, one database, and one inheriting task.
- `decodeApplication (toStrict (encodeApplication serviceLessApp)) @?= Right serviceLessApp`
  for a `service = Nothing` workers-plus-task app.
- decoding an `Application`'s bytes via `decodeDeployment` is `UnexpectedKind "Deployment"
  "Application"`; decoding a `Deployment`'s bytes via `decodeApplication` is `UnexpectedKind
  "Application" "<none>"`.
- an undeclared-database JSON (a `workers` entry whose `databases` names a db not in the
  top-level `databases`) decodes to `Left (MarshalError "application" msg)` with `msg`
  containing `"not declared"`.
- an image-disagreement JSON decodes to `Left (MarshalError "application" msg)` with `msg`
  containing `"shared image"`.
- a duplicate-workload-name JSON decodes to `Left (MarshalError "application" msg)` with `msg`
  containing `"duplicate workload name"`.

**Acceptance.** `cabal test nagare-dsl` green with the round-trip and failure cases passing.

### Milestone M3 — worked example, end-to-end load test, and doc note

**Scope.** Prove the full `Config.hs → emitApplication → loadApplication` path through the
`runghc` harness, and add a developer-facing worked example modelled on `shinzui/kizashi`'s
shape (a service + workers + a database + a migration task).

**The load-harness fixture** `cli/nagare-dsl/test/fixtures/application/nagare/Config.hs`. A
self-contained config that builds an `Application` in `Either String` and emits it. It must
use **plain record updates** (no `#field` lenses), because the loader runs it under
`runghc -XGHC2024` which has no `OverloadedLabels`. Shape (mirrors
`test/fixtures/worker/nagare/Config.hs`):

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Database (Database (..), Engine (..), mkDatabaseName, mkEngineVersion)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task (Task (..), mkSchedule, mkTask)
import Nagare.Dsl.Types
import Nagare.Dsl.Worker (Worker (..), mkCommand, mkReplicas, webWorker)

-- build each part in Either String, assemble, validate via mkApplication.
-- (full body in the implementation; every constrained field goes through its
-- smart constructor and the shared image string is reused for service + workers.)
```

The fixture's service, two workers, and migration task must all carry the **same** image
string the `Application` declares, and the database the workers reference must be declared in
`appDatabases` — i.e. it must be a *valid* `Application`, so `loadApplication` returns `Right`.

**The example** `cluster/examples/multi-workload-app/nagare/Config.hs` (+ a short `README.md`
explaining "one app, four kinds, one identity", modelled on
`cluster/examples/queue-worker/README.md`). Same plain-record-update discipline. Use
`gcr.io/knative-samples/helloworld-go` (a public, pullable image) so any `examples-compile`
flake check needs no private registry, exactly as the `queue-worker` example does. This is the
near-copy of kizashi's shape the MasterPlan motivates: one `serve` Service, a couple of
NOTIFY-loop Workers, one Postgres `Database`, and one image-inheriting migration `Task`.

**Tests (M3 portion of `test/ApplicationSpec.hs`).** Add `testGroup "loadApplication
(config-as-program)"`:
- `loadApplication "test/fixtures/application/nagare/Config.hs"` returns `Right expectedApp`,
  where `expectedApp` is the same value assembled in-spec through smart constructors (mirrors
  `WorkerSpec.hs`'s `loadWorker` test).
- the example loads too: `loadApplication "../../cluster/examples/multi-workload-app/nagare/Config.hs"`
  returns `Right` (mirrors `Spec.hs`'s `presetsGoldenTests` relative-path convention).

Optionally add a golden-bytes test (`goldenVsString` against a
`test/golden/application.json`) of `encodeApplication expectedApp` so the wire shape is pinned;
follow the `goldenVsString` pattern already used throughout `Spec.hs`/`WorkerSpec.hs`.

**Doc note (optional).** If the doc set already cross-links workload kinds, add a short
"Multi-workload Application" subsection to `docs/user/deploying-apps.md` pointing at the new
example and noting that `nagarectl app deploy` (EP-2) is what deploys it. Keep it to a
paragraph; the full developer story is EP-2's.

**Wiring `test/Spec.hs` and cabal.** Add `import ApplicationSpec (applicationTests)` to
`test/Spec.hs` and `applicationTests` to the top-level `testGroup "nagare-dsl" [...]` list.
Add `ApplicationSpec` to the `test-suite nagare-dsl-test` `other-modules` in
`nagare-dsl.cabal`.

**Acceptance.** `cabal test nagare-dsl` green, including the `loadApplication` fixture and
example tests (which spawn `runghc`).


## Concrete Steps

Run everything from the library package directory unless noted:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
```

**M1.** Create `src/Nagare/Dsl/Application.hs`, add the module to `nagare-dsl.cabal`'s
`exposed-modules`, create `test/ApplicationSpec.hs` (M1 group only), add it to the test
suite's `other-modules`, and wire `applicationTests` into `test/Spec.hs`. Then build the
library to catch type errors before running tests:

```bash
cabal build nagare-dsl
```

Expected (abridged): a clean build, e.g.

```text
[ 1 of 22] Compiling Nagare.Dsl.Application ( src/Nagare/Dsl/Application.hs, ... )
...
Linking ...
```

Run the suite, narrowing to the new group with tasty's `--pattern`:

```bash
cabal test nagare-dsl --test-options='--pattern "mkApplication"'
```

Expected:

```text
nagare-dsl
  Nagare.Dsl.Application (EP-1)
    mkApplication
      accepts a valid multi-workload application: OK
      rejects a worker disagreeing on the shared image: OK
      rejects a reference to an undeclared database: OK
      rejects two workloads with the same name: OK
      rejects two databases with the same name: OK

All N tests passed
```

**M2.** Add `emitApplication`/`encodeApplication`/`applicationJSON` to
`src/Nagare/Dsl/Config.hs` and `JsonApplication`/`toApplication`/`decodeApplication`/
`loadApplication` to `src/Nagare/Dsl/Load.hs`. Add the M2 round-trip group to
`test/ApplicationSpec.hs`. Then:

```bash
cabal test nagare-dsl --test-options='--pattern "round-trip"'
```

Expected (the Application group among the others that match "round-trip"):

```text
  Nagare.Dsl.Application (EP-1)
    JSON round-trip and kind discrimination
      multi-workload application survives emit -> decode round-trip: OK
      service-less application round-trips: OK
      decoding an Application as a Deployment is UnexpectedKind: OK
      decoding a Deployment as an Application is UnexpectedKind: OK
      undeclared database rejected as MarshalError application: OK
      image disagreement rejected as MarshalError application: OK
      duplicate workload name rejected as MarshalError application: OK
```

**M3.** Create `test/fixtures/application/nagare/Config.hs`,
`cluster/examples/multi-workload-app/nagare/Config.hs` (+ `README.md`), add the M3 load group,
optionally the golden. Run the whole suite (the load tests spawn `runghc`, so run the full
suite, not just a pattern, to confirm nothing else regressed):

```bash
cabal test nagare-dsl
```

Expected tail:

```text
  Nagare.Dsl.Application (EP-1)
    loadApplication (config-as-program)
      loadApplication fixture returns the expected Application: OK
      multi-workload-app example loads: OK

All NNN tests passed
```

If you add the JSON golden and the encoder output legitimately changes, refresh it with
tasty-golden's accept flag (then eyeball the diff before committing):

```bash
cabal test nagare-dsl --test-options='--accept --pattern "application JSON golden"'
```


## Validation and Acceptance

Acceptance is behavioral, expressed as inputs and outputs, and is fully offline.

1. **A valid multi-workload Application round-trips byte-identically.** Given `multiApp`
   (a service named `kizashi-serve`, two workers `kizashi-worker`/`kizashi-agent-worker`, one
   Postgres database `kizashi-db`, one migration task `kizashi-migrate` inheriting the app
   image), `decodeApplication (toStrict (encodeApplication multiApp)) == Right multiApp`.
   This proves the wire shape carries every field and the embedded workloads survive
   unchanged.

2. **An app config that references an undeclared database fails to load with a precise
   message.** Given JSON where a `workers` entry has `"databases": ["ghost-db"]` but the
   top-level `"databases"` does not declare `ghost-db`, `decodeApplication` returns
   `Left (MarshalError "application" msg)` with `msg` containing `"database 'ghost-db' which
   is not declared on the application"`. Through `renderLoadError` this surfaces as
   `nagare: field 'application' failed validation: ... 'ghost-db' ... not declared ...`.

3. **A workload disagreeing on the shared image is rejected.** Given JSON whose `service` has a
   different `"image"` than the top-level `"image"`, `decodeApplication` returns
   `Left (MarshalError "application" msg)` with `msg` containing `"shared image"`.

4. **Duplicate workload names are rejected.** Given two `workers` with the same `"name"`,
   `decodeApplication` returns `Left (MarshalError "application" msg)` with `msg` containing
   `"duplicate workload name"`. Likewise two `databases` with the same `"name"` give
   `"duplicate database name"`.

5. **Kind discrimination holds both ways.** `decodeApplication` on a `Deployment`'s bytes
   (which carry no `"kind"`) is `UnexpectedKind "Application" "<none>"`; `decodeDeployment` on
   an `Application`'s bytes is `UnexpectedKind "Deployment" "Application"`. This proves an
   `Application` config run under the wrong command fails precisely rather than being misread.

6. **The full config-as-program path works.** `loadApplication
   "test/fixtures/application/nagare/Config.hs"` returns `Right expectedApp`, and the
   `cluster/examples/multi-workload-app/` example loads to `Right`. This exercises `runghc`,
   the `emitApplication` stdout contract, and the decoder end to end.

7. **Effective beyond compilation.** The image-agreement, declared-database, and unique-name
   tests demonstrate behavior a mere "it compiles" cannot: each is a *cross-workload* property
   that only fails at validation, and the negative tests show the failure is reported with the
   right field and a human-readable message.

Test command for the whole acceptance set: `cabal test nagare-dsl` from
`/Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl`, all groups green.


## Idempotence and Recovery

Every step here is **pure and repeatable**; nothing touches a cluster, a registry, or any
mutable external state. Re-running `cabal build`/`cabal test` any number of times is safe and
deterministic (the encoders sort lists by name, so the bytes are stable across runs).

- **Golden files.** If a golden test fails after an intentional encoder change, regenerate with
  `--test-options='--accept'` (scoped by `--pattern`), then review the `git diff` of the
  `test/golden/` file before committing. An accidental golden change is recovered by
  `git checkout -- cli/nagare-dsl/test/golden/<file>`.
- **The new module / edits.** All edits are additive (a new module, new functions, new test
  group, new fixtures/examples) and do not modify the existing `Deployment`/`Worker`/
  `Database`/`Task` types, encoders, or loaders. If a milestone goes wrong, `git checkout --`
  the touched files (`Application.hs`, the cabal file, `Config.hs`, `Load.hs`, the spec, the
  fixtures) restores a green tree; nothing is left in a half-applied cluster state because no
  cluster is involved.
- **Loader harness.** A failing `loadApplication` test that prints a `CompileError` means the
  fixture/example `Config.hs` did not compile under `runghc -XGHC2024` — most often because it
  used a `#field` lens (no `OverloadedLabels` there). The fix is to switch to plain record
  updates; re-running the single test reproduces the diagnostic deterministically.


## Interfaces and Dependencies

**Libraries used (already in `nagare-dsl.cabal`):** `aeson` (JSON encode/decode),
`bytestring` (`LBS.ByteString` wire bytes), `containers` (`Data.Map`/`Data.Set` for `env`,
declared-database set, duplicate detection), `text`, `lens`/`generic-lens` (the `^. #field`
accessors inside the library), and for tests `tasty`/`tasty-hunit`/`tasty-golden`. No new
dependency is required.

**Module added:** `Nagare.Dsl.Application` (`cli/nagare-dsl/src/Nagare/Dsl/Application.hs`),
depending on `Nagare.Dsl.Types`, `Nagare.Dsl.Worker`, `Nagare.Dsl.Database`,
`Nagare.Dsl.Task`. It must **not** import `Config` or `Load` (those depend on it), preventing
an import cycle.

**Signatures that must exist at the end of each milestone** (full module paths):

End of **M1** — in `Nagare.Dsl.Application`:

```haskell
data Application = Application
  { appName      :: !ServiceName
  , namespace    :: !Namespace
  , image        :: !ImageRef
  , env          :: !(Map EnvName ScopedEnvVar)
  , appDatabases :: ![Database]
  , service      :: !(Maybe Deployment)
  , workers      :: ![Worker]
  , tasks        :: ![Task]
  }
  deriving stock (Generic, Eq, Show)

mkApplication :: Application -> Either Text Application
appLabelKey   :: Text                       -- "nagare.dev/app"
appLabel      :: Application -> (Text, Text) -- ("nagare.dev/app", <appName>)
-- optional: mkApplicationFrom :: Text -> Text -> Either Text Application
```

End of **M2** — in `Nagare.Dsl.Config`:

```haskell
emitApplication   :: Application -> IO ()
encodeApplication :: Application -> Data.ByteString.Lazy.ByteString
```

and in `Nagare.Dsl.Load`:

```haskell
decodeApplication :: Data.ByteString.ByteString -> Either LoadError Application
loadApplication   :: FilePath -> IO (Either LoadError Application)
```

(plus the internal `data JsonApplication` + its `FromJSON` instance and `toApplication ::
JsonApplication -> Either LoadError Application`, which reuse the existing `toDeployment` /
`toWorker` / `toDatabase` / `toTask` marshallers).

End of **M3** — the test module `ApplicationSpec` exporting `applicationTests :: TestTree`,
wired into `Nagare.Dsl` test `Spec.hs`; the fixture
`cli/nagare-dsl/test/fixtures/application/nagare/Config.hs`; and the example
`cluster/examples/multi-workload-app/nagare/Config.hs`.

**Integration points honored (by path):**

- **EP-2** (`docs/plans/73-orchestrated-release-nagarectl-app-deploy-with-ordered-rollout-and-pre-deploy-migration-hooks.md`)
  consumes `Application` via `loadApplication`, renders every embedded workload, and stamps
  `appLabel`'s `nagare.dev/app: <name>` onto each rendered object. EP-1 introduces the label
  key and the type; EP-2 applies it and adds the ordered rollout (pre-deploy hooks → databases
  → service/workers). EP-1 must not add fields to `Application` later without updating this
  plan's encoder/decoder and tests.
- **EP-3** (`docs/plans/74-worker-health-and-liveness-probes.md`) adds an optional liveness
  field to `Nagare.Dsl.Worker.Worker`. Because `Application` carries `Worker` values **as-is**
  (Decision Log), that field flows through `applicationJSON`/`toApplication` (which reuse
  `workerJSON`/`toWorker`) automatically once EP-3 lands; no change is needed here beyond a
  fixture refresh if the round-trip golden pins the new field.
- **External / kotei** (`shinzui/kotei`,
  `docs/masterplans/7-full-stack-nagare-deployment-management.md`): the `nagare.dev/app` label
  EP-1 defines is the contract kotei uses to discover and reconcile an app's resources as a
  unit. EP-1 only fixes the key; EP-2 owns the machine-readable deploy output kotei consumes.


## Revision Notes

- 2026-06-18 — MasterPlan validation pass. Pinned the declared-database field as
  `appDatabases :: [Database]` (full specs) with a Decision Log entry, because EP-2's database
  rollout phase needs `engine`/`version`/`size` to `runDbCreate`; EP-2 was reconciled to consume
  the field under this exact name and type. Corrected the cabal `exposed-modules` placement note
  (`Nagare.Dsl.Application` sorts before `Nagare.Dsl.Build`, not between `Cdn.Types` and
  `Config`). No change to the type's field set, encoder/decoder, or tests.
