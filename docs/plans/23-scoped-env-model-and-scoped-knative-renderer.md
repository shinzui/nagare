---
id: 23
slug: scoped-env-model-and-scoped-knative-renderer
title: "Scoped env model and scoped Knative renderer"
kind: exec-plan
created_at: 2026-06-09T23:52:37Z
intention: "intention_01ktqcj5aseb1rx94fh6npnydv"
master_plan: "docs/masterplans/5-environment-and-secret-management-for-nagare.md"
---

# Scoped env model and scoped Knative renderer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [23-scoped-env-model-and-scoped-knative-renderer.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

This plan is the foundation of the "Environment and Secret Management" initiative
(parent MasterPlan: `docs/masterplans/5-environment-and-secret-management-for-nagare.md`).
It changes the typed deployment model in the `nagare-dsl` Haskell library so that every
environment variable carries a set of *scopes* — when it applies — and so that every
rendered Knative `Service` reaches out to a per-app managed environment store.

Concretely, after this change a config author can say "this variable is only needed at
build time, not in the running container," and the production manifest will leave it out
of the container's inline `env:`. And every rendered `Service` gains an `envFrom:` block
that pulls additional variables from a Kubernetes ConfigMap and Secret named for the app,
so an operator can add or change variables later (in a future plan, EP-24/EP-25) without
editing Haskell or rebuilding the image. Both abilities are new; today every variable is
unconditionally a runtime variable baked inline, and there is no managed store.

Two terms used throughout, defined here so the reader needs no outside context:

- **Knative `Service`** is the single YAML resource Nagare deploys for an app. It contains
  a pod template whose `spec.template.spec.containers[0]` lists the container `image`,
  `ports`, `env` (inline variables), `envFrom` (variables pulled from external sources),
  and `resources`. We render this YAML in Haskell; there is no `kubectl` in this plan.
- **`envFrom`** is the Kubernetes container field that says "import all keys from this
  ConfigMap and/or Secret as environment variables." With `optional: true`, the container
  still starts if the referenced ConfigMap/Secret does not exist. Kubernetes applies
  `envFrom` *first* and the inline `env:` list *second*, so an inline variable overrides a
  managed one of the same name. That precedence is part of the contract this plan owns.

### Before / after of a rendered Service

Today, a config with a runtime variable `API_BASE` and a (hypothetical) build-only
variable `BUILD_TOKEN` renders every variable inline and has no `envFrom`:

```yaml
# BEFORE (current behavior): all env inline, no envFrom, no scope concept
spec:
  template:
    spec:
      containers:
      - image: gcr.io/myproject/notes:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: API_BASE
          value: https://api.example.com
        - name: BUILD_TOKEN          # leaks a build-only value into the runtime container
          value: abc123
```

After this change, `BUILD_TOKEN` (scoped `{Build}` only) is excluded from the runtime
container's inline `env:`, and the container gains an `envFrom:` block that references the
app's Runtime-scoped managed ConfigMap and Secret:

```yaml
# AFTER (this plan): scope-filtered inline env + envFrom to the managed store
spec:
  template:
    spec:
      containers:
      - image: gcr.io/myproject/notes:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: API_BASE
          value: https://api.example.com
        envFrom:
        - configMapRef:
            name: nagare-env-notes-runtime
            optional: true
        - secretRef:
            name: nagare-secret-notes-runtime
            optional: true
```

`BUILD_TOKEN` no longer appears in the running container. The two `envFrom` references are
the managed store for the app named `notes`; `optional: true` means the app still deploys
even though no plan has created those resources yet (that is EP-24/EP-25). A config author
who writes a plain variable with no scope still gets the old behavior: the variable defaults
to scope `{Runtime}` and renders inline exactly as before. The only universally visible new
output is the `envFrom` block, which now appears on every app and server-site Service.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `EnvScope` and `ScopedEnvVar` to `Nagare.Dsl.Types`, with the
      non-empty-set invariant, `runtimeScoped`, and `scopedEnv`; export them. (2026-06-09)
- [x] M1: Change `Deployment.env` and `ServerSite.env` to `Map EnvName ScopedEnvVar`. (2026-06-09)
- [x] M1: Update `Nagare.Dsl.Presets.secretEnv` to produce a Runtime-scoped entry. (2026-06-09)
- [x] M1: Update example/fixture configs and in-test fixtures so they compile with the
      default `{Runtime}` scope; document each touched file. Touched:
      `cluster/examples/hello-knative-service/nagare/Config.hs`,
      `cli/nagare-dsl/test/fixtures/nagare/Config.hs`,
      `cli/nagare-dsl/test/fixtures/server-site/nagare/Config.hs`,
      `cli/nagare-dsl/test/Spec.hs`, `cli/nagare-dsl/test/ServerSpec.hs`.
      `cluster/examples/preset-app-b/nagare/Config.hs` needed no edit (uses `secretEnv`). (2026-06-09)
- [x] M1: `cabal build` succeeds; existing golden tests still pass byte-for-byte
      (all 135 tests pass, no `envFrom` yet). (2026-06-09)
- [x] M2: Add `"scopes"` to the emitted JSON in `Nagare.Dsl.Config`
      (`envJSON`/`envEntryJSON`, via shared `scopeTokensJSON`); decode it in
      `Nagare.Dsl.Load` (`JsonEnvEntry.jeScopes`/`parseScope`/`toEnvEntry`) with
      missing/empty defaulting to `{Runtime}` and unknown tokens rejected via a
      `MarshalError "env.<var>.scopes"`. (2026-06-09)
- [x] M2: Unit tests for round-trip: scopes survive emit→decode (Spec.hs
      `scopedEnvTests`); missing/empty default to Runtime, a multi-scope entry
      decodes to both, and an unknown scope token yields a `MarshalError`
      (LoadSpec.hs). 142 tests pass. (2026-06-09)
- [x] M3: Add `scopeToken`, `managedConfigMapName`, `managedSecretName`; export them
      from `Nagare.Dsl.Render`. `Server/Render.hs` imports and reuses them. (2026-06-09)
- [x] M3: Scope-filter the inline `env:` (Runtime-only) and add the always-present
      `envFrom` block in both `Nagare.Dsl.Render` and `Nagare.Dsl.Server.Render`;
      placed `envFrom` (rank 3) between `env` (2) and `resources` (4) in `keyCompare`,
      plus `optional`/`configMapRef`/`secretRef` ranks. (2026-06-09)
- [x] M3: Updated the 4 affected goldens (hello, preset-app-a, preset-app-b,
      server-site) — diff is exactly the inserted `envFrom` block — and added a new
      `test/golden/build-only.service.yaml` proving `BUILD_TOKEN` ({Build}) is
      excluded from inline `env:` while `API_BASE` and the `envFrom` refs remain.
      `static-site.service.yaml` and the DomainMapping/Dockerfile goldens are
      unchanged. Full `cabal test` green (143 tests); `nagarectl` builds and its 52
      tests pass against the updated library. (2026-06-09)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)

## Decision Log

Record every decision made while working on the plan.

- Decision: Model scope as `data EnvScope = Runtime | Build | Preview` and attach a
  `Set EnvScope` to each entry via `data ScopedEnvVar = ScopedEnvVar { value :: EnvVar,
  scopes :: Set EnvScope }`, keeping the existing `EnvVar = EnvLiteral | EnvSecretRef`
  sum type untouched.
  Rationale: a set most directly expresses "a variable can apply to several phases"; it
  preserves the headline safety invariant (an env value is a literal *or* a secret ref,
  never both, enforced by the compiler); and it defaults cleanly to `{Runtime}` so every
  existing config keeps compiling. This mirrors IP1 in the parent MasterPlan verbatim.
  Date: 2026-06-09

- Decision: Make the non-empty-scopes invariant a runtime-checked smart-constructor rule
  (`scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar`, rejecting the empty
  set) plus a total convenience constructor (`runtimeScoped :: EnvVar -> ScopedEnvVar`)
  that always yields `{Runtime}`, rather than a `NonEmpty`-of-scope type.
  Rationale: `Set` is the natural carrier for "membership, deduplicated, unordered," and
  there is no standard "non-empty set"; a validating constructor plus a guaranteed-valid
  default constructor gives the same safety with a far simpler type. The decoder defaults a
  missing/empty scope list to `{Runtime}`, so the invariant is also restored on load.
  Date: 2026-06-09

- Decision: Emit `envFrom` referencing the Runtime managed ConfigMap and Secret with
  `optional: true` on every app and server Service, and document the Kubernetes precedence
  (`envFrom` first, inline `env` second) as part of the contract.
  Rationale: lets a later plan change managed env without re-rendering or rebuilding;
  `optional: true` means an app whose store was never written still deploys; the precedence
  gives explicit inline declarations (and, later, generated variables) the final say. This
  is IP3 in the parent MasterPlan.
  Date: 2026-06-09

- Decision: Own the managed-resource name format here (`scopeToken`,
  `managedConfigMapName`, `managedSecretName`) and export it from the library, so EP-24,
  EP-25, and EP-27 call these helpers and never re-derive names by hand. The format is
  `nagare-env-<app>-<scope>` and `nagare-secret-<app>-<scope>` with the scope token
  lowercased (`runtime`/`build`/`preview`). This is IP2.
  Rationale: a single owner of the string format prevents drift between the names the
  Service references in `envFrom` and the names the store creates.
  Date: 2026-06-09

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-09): complete, all three milestones delivered.** The
`nagare-dsl` model now carries `EnvScope`/`ScopedEnvVar`, every existing config
compiles unchanged through the `runtimeScoped` default, the scope set survives
the JSON round-trip, and every rendered app and server Service scope-filters its
inline `env:` to Runtime entries and emits the `envFrom` block referencing the
managed store with `optional: true`. The three integration contracts (IP1 type +
env-map change, IP2 naming helpers, IP3 `envFrom` wiring + precedence) are in
place for the downstream plans to import.

**Against the purpose:** both new abilities exist — a `{Build}`-only variable is
excluded from the running container (proven by `build-only.service.yaml`), and
every Service reaches out to a per-app managed store it can be populated from
later without editing Haskell or rebuilding.

**Notes / lessons:**
- `Server/Render.hs` imports the naming helpers from `Nagare.Dsl.Render` rather
  than redefining them, keeping a single owner of the string format (IP2). There
  is no import cycle: `Render` depends only on `Build` and `Types`.
- `DuplicateRecordFields` is on, so the new `value`/`scopes` selectors of
  `ScopedEnvVar` coexist with other records; tests poke them via the
  constructor-qualified record pattern `Deployment{env = m}` and the unambiguous
  `scopes`/`value` selectors, avoiding a `generic-lens` test dependency.
- The workspace beyond the library (`nagarectl`) was rebuilt and its suite run to
  confirm the env-field type change is transparent to consumers that go through
  `loadDeployment`/`renderService`.

