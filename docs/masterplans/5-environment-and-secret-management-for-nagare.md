---
id: 5
slug: environment-and-secret-management-for-nagare
title: "Environment and Secret Management for Nagare"
kind: master-plan
created_at: 2026-06-09T23:52:26Z
intention: "intention_01ktqcj5aseb1rx94fh6npnydv"
---

# Environment and Secret Management for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This initiative implements **Phase 2 (Environment and Secret Management)** of the PaaS
capability roadmap at `docs/roadmaps/paas-gap-roadmap.md`. It is the third initiative in
the roadmap's recommended order, following static hosting (`docs/masterplans/3-static-hosting-for-nagare.md`)
and application build modes (`docs/masterplans/4-application-build-modes-for-nagare.md`).

Full plan before trimming: [5-environment-and-secret-management-for-nagare.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/masterplans/5-environment-and-secret-management-for-nagare.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Vision & Scope

Today a Nagare app or site carries its environment variables inline in a typed Haskell
config (`Config.hs`): each entry is either a literal value or a reference to a Kubernetes
Secret that must already exist in the cluster. There is no way to add, change, or remove an
environment variable, or to create a secret, without editing Haskell and redeploying. There
is no notion of *when* a variable applies — every variable is a runtime variable, baked into
the running container; nothing is available only at build time or only in preview
deployments. And there is no way to inject values that Nagare itself knows (the service URL,
the release id, the source branch) without hard-coding them.

After this initiative, a Nagare operator can manage environment and secrets as a first-class
day-2 operation, entirely from the CLI, without editing Haskell:

- **Scopes.** Every environment variable has one or more scopes — `Runtime` (present in the
  running container), `Build` (present during the image build), and `Preview` (an overlay
  that applies only to preview deployments). A variable can carry several scopes at once. The
  existing simple configs keep working unchanged: an undecorated variable defaults to
  `Runtime`.
- **CLI management.** New commands `nagarectl env list|set|delete|sync` and
  `nagarectl secret set|list|delete` let an operator add, change, remove, and bulk-sync
  variables and secrets for an app without touching its `Config.hs` or rebuilding its image.
  Managed values are stored in per-app Kubernetes ConfigMaps and Secrets and consumed by the
  running Service through `envFrom`, so a change takes effect by re-applying a tiny manifest
  rather than rebuilding.
- **`.env` sync with reconcile modes.** `nagarectl env sync APP --file .env.production`
  imports a dotenv file in bulk, with a documented choice between *merge* (keep keys not in
  the file) and *reconcile-exact* (delete keys not in the file).
- **Generated variables.** Nagare injects a documented set of predefined variables —
  `NAGARE_SERVICE_URL`, `NAGARE_SERVICE_NAME`, `NAGARE_NAMESPACE`, `NAGARE_BASE_DOMAIN`,
  `NAGARE_RELEASE_ID`, and `NAGARE_SOURCE` — so apps can discover their own identity without
  hard-coding it.
- **Build-time and preview env.** Build-scoped variables flow into `docker build`; preview-scoped
  variables overlay the runtime set when a preview is deployed.

What is **in scope**: the typed scope model, the per-app ConfigMap/Secret store with reconcile
modes, the `env`/`secret` CLI surface, generated variables, build-time env wiring into the
existing Docker build, preview env overlays, and user documentation with a working example.

What is **out of scope** (deferred to later roadmap phases): managed databases and their
generated connection env (Phase 4 — though the generated-variable mechanism here is the
foundation it will reuse); persistent storage (Phase 3); secret rotation and external secret
managers (e.g. Vault, Sealed Secrets); encryption of secrets at rest beyond what the cluster
already provides; and a web UI for env management (Phase 10). Build-time *builder* integration
beyond the current `docker build` (e.g. Nixpacks from `docs/plans/21-nixpacks-zero-dockerfile-builder.md`)
is acknowledged as an integration point but its env wiring is left to that builder's own plan.

## Decomposition Strategy

The initiative was decomposed into six child ExecPlans grouped into four phases. The guiding
principle was to separate the *model* (what an environment variable is) from the *store* (where
managed values live) from the *surfaces* (CLI, generated values, build/preview application)
that depend on both, so that each plan produces an independently verifiable behavior.

The natural seam in the existing code drove the split. The typed DSL
(`cli/nagare-dsl/`) owns the env *model* and the *renderer* that turns it into Knative YAML;
that is the foundation everything else references, so it is its own plan (EP-23) with no
dependencies. The `nagarectl` library (`cli/nagarectl/`) already has a clean precedent for
reading and writing per-app Kubernetes state through `kubectl`: `Nagare.Static.Release`
stores a per-site release log in a ConfigMap with a pure schema layer and a thin IO layer.
The env/secret *store* (EP-24) follows that exact pattern, so it is a distinct plan that the
CLI then sits on. The CLI surface (EP-25), generated variables (EP-26), and build/preview
application (EP-27) are three independent *consumers* of the model and store; each touches a
different part of the codebase (command parser, deploy-time render call sites, and the build
and preview paths respectively), so each is independently verifiable and they can largely
proceed in parallel once the foundations exist. Documentation and a real end-to-end example
(EP-28) is its own plan, mirroring how static hosting was finished by
`docs/plans/17-static-hosting-docs-and-end-to-end-examples.md`.

Alternatives considered and rejected. **A single ExecPlan**: rejected because the roadmap
explicitly notes that once build-time env integration and preview overlays are included the
work warrants a MasterPlan, and because the model, store, and three consumers each produce
distinct, separately demonstrable behavior. **Splitting by file/module** (e.g. one plan for
`Types.hs`, one for `Config.hs`): rejected per the decomposition principle that work streams
are grouped by functional concern, not by file — the model plan deliberately touches
`Types.hs`, `Config.hs`, `Load.hs`, and `Render.hs` together because they form one coherent
round-trip. **Splitting build-time env and preview overlays into two plans**: considered, but
they share the same precondition (the scope model and the store) and are both "apply a scope
at a non-runtime phase," so they are combined into EP-27 with two milestones to keep the plan
count at six and the scopes coherent; the plan notes they could be split if either milestone
grows.

## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 23 | Scoped env model and scoped Knative renderer | docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md | None | None | Complete |
| 24 | Per-app Secret and ConfigMap store with reconcile modes | docs/plans/24-per-app-secret-and-configmap-store-with-reconcile-modes.md | EP-23 | None | Complete |
| 25 | nagarectl env and secret CLI commands | docs/plans/25-nagarectl-env-and-secret-cli-commands.md | EP-24 | EP-23 | Complete |
| 26 | Generated and predefined environment variables | docs/plans/26-generated-and-predefined-environment-variables.md | EP-23 | None | Complete |
| 27 | Build-time and preview-scoped env application | docs/plans/27-build-time-and-preview-scoped-env-application.md | EP-23, EP-24 | EP-25 | Complete |
| 28 | Env and secret management docs and end-to-end example | docs/plans/28-env-and-secret-management-docs-and-end-to-end-example.md | EP-25, EP-27 | EP-26 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-23).

## Progress

- [x] EP-23: `EnvScope`/`ScopedEnvVar` types added; existing configs compile with default Runtime scope. (2026-06-09)
- [x] EP-23: JSON round-trip (Config.hs emit / Load.hs decode) carries scopes; golden tests pass. (2026-06-09)
- [x] EP-23: Scope-filtered inline render + `envFrom` wiring + naming helpers; golden tests pass. (2026-06-09)
- [x] EP-24: Pure `reconcile` + ConfigMap/Secret rendering with unit tests. (2026-06-09)
- [x] EP-24: kubectl read/write IO for the per-app stores. (2026-06-09)
- [x] EP-25: `nagarectl env list|set|delete|sync` commands working against the cluster (or `--dry-run`). (2026-06-09)
- [x] EP-25: `nagarectl secret set|list|delete` commands; `.env` parsing with reconcile modes. (2026-06-09)
- [x] EP-26: Generated `NAGARE_*` variables injected at deploy; golden/render test shows them. (2026-06-09)
- [x] EP-27: Build-scoped env flows into `docker build`; demonstrated end to end. (2026-06-09)
- [x] EP-27: Preview-scoped env overlays runtime in preview deploys; render test shows the overlay. (2026-06-09)
- [x] EP-28: User guide written; end-to-end example deploys with managed env and a secret. (2026-06-09)

## Surprises & Discoveries

- EP-24 base64 codec (2026-06-09): the store base64-encodes Secret values, but rather
  than adding the `base64`/`base64-bytestring` package (only present in the local
  Hackage cache, not confirmed in the nix flake's Haskell package set), EP-24 reused
  `Data.ByteArray.Encoding` from `memory`, already a `nagarectl` dependency. The public
  `Nagare.Env.Store` signatures (IP4) are unchanged, so EP-25 and EP-27 are unaffected.
  Lesson for the remaining plans: prefer an already-present dependency over adding one
  under the flake; if a new package is unavoidable, verify it resolves in the flake
  set, not just the Hackage cache.

- EP-24 module visibility (2026-06-09): `Nagare.Env.Store` had to be `exposed-modules`
  (not `other-modules`) because the `nagarectl-test` suite consumes the library as an
  external package and Cabal hides `other-modules` from external consumers. Any future
  library module the test suite imports must be `exposed-modules`. (EP-25's `Nagare.Env.Dotenv`
  and EP-26's `Nagare.Env.Generated` followed this.)

- EP-27 build-path seam realized (2026-06-09): the MasterPlan-4 build-modes rework
  (EP-19–22) had already landed, so the app deploy flows through `performBuild`/`BuildSpec`
  rather than the `buildImage` EP-27 was written against. EP-27 adapted: build-scoped env is
  injected into the `BuildSpec`'s `buildArgs` via a new `Nagare.Build.addBuildArgs` before
  `performBuild`, leaving `buildImage`/static/server build calls untouched (static has no
  env; the server runtime-image build consumes no `ARG`s). The pure `assembleBuildArgs`
  stays builder-agnostic. **For EP-28:** document build-time env against the `BuildSpec`
  flow (a Dockerfile-built app's `{Build}` env becomes `docker build --build-arg`), not a
  `buildImage` signature, and note build-time env does not apply to prebuilt images.

- EP-26 record-field ambiguities (2026-06-09): `GeneratedContext`'s field names
  (`namespace`/`releaseId`/`source`/`serviceUrl`/`baseDomain`) collide under
  `DuplicateRecordFields` with existing bare selectors and `Nagare.Deploy.serviceUrl`, and
  a record *update* on `env` is ambiguous between `Deployment` and `ServerSite`. The fix —
  construct `GeneratedContext` through a qualified alias (`import Nagare.Env.Generated
  qualified as Gen`; `Gen.GeneratedContext { Gen.serviceUrl = ... }`) and update env via
  the generic-lens form `x & #env %~ f` — is the pattern **EP-28** should reuse when it
  exercises generated vars in code/examples.

## Decision Log

- Decision: Model scope as `data EnvScope = Runtime | Build | Preview` with a `Set EnvScope` on
  each env entry (`ScopedEnvVar`), rather than three separate env maps or a boolean-per-scope record.
  Rationale: a set most directly expresses "a variable can apply to several phases," keeps the
  existing literal-vs-secret `EnvVar` sum type intact (preserving the headline safety invariant),
  and defaults cleanly to `{Runtime}` so every existing config keeps compiling.
  Date: 2026-06-09

- Decision: Store CLI-managed env in **scope-suffixed per-app** Kubernetes ConfigMaps and Secrets
  (`nagare-env-<app>-<scope>`, `nagare-secret-<app>-<scope>`) and consume them via `envFrom` with
  `optional: true`, rather than baking managed values into the rendered Service's inline `env:`.
  Rationale: lets an operator change env without rebuilding or re-rendering the typed config (the
  roadmap's core goal), keeps each scope independently reconcilable, and `optional: true` means an
  app with no managed env still deploys. Inline DSL env and generated vars override managed env via
  Kubernetes' `envFrom`-then-`env` precedence, giving explicit declarations the final say.
  Date: 2026-06-09

- Decision: Build the store as a pure schema/reconcile layer plus a thin kubectl IO layer, directly
  mirroring the existing `Nagare.Static.Release` module (ConfigMap-as-JSON, `kubectl get -o json`
  read, `kubectl apply` write). Rationale: there is a proven, tested precedent in the codebase for
  exactly this shape, so reuse its structure for consistency and unit-testability without a cluster.
  Date: 2026-06-09

- Decision: Inject generated `NAGARE_*` variables as inline Runtime env at deploy time (a pure
  function merged into the env map at the call site) rather than changing the renderer's signature.
  Rationale: keeps EP-23's renderer stable, makes EP-26 purely additive, and gives generated values
  the correct (overriding) precedence over managed env for free.
  Date: 2026-06-09

- Decision: Combine build-time env and preview env overlays into one child plan (EP-27) with two
  milestones, rather than two separate plans. Rationale: both consume the same prerequisites (the
  scope model and the store) and are both "apply a non-runtime scope at the right phase"; combining
  keeps the plan count at six per the decomposition principles. The plan notes the milestones can be
  split if either grows.
  Date: 2026-06-09

- Decision: Number the initiative MasterPlan as 5 and its children as EP-23 through EP-28 (the next
  sequential numbers; the init scripts assign them, accounting for the build-modes plans EP-19–EP-22).
  Rationale: follows the repository's sequential numbering with no manual renumbering.
  Date: 2026-06-09

## Outcomes & Retrospective

**Status (2026-06-09): COMPLETE.** All six child ExecPlans (EP-23–28) are implemented,
tested, and committed. The initiative delivers, end to end:

- **Scoped env model (EP-23).** `EnvScope = Runtime | Build | Preview` and
  `ScopedEnvVar` in `nagare-dsl`; the env map of `Deployment`/`ServerSite` is
  `Map EnvName ScopedEnvVar`; scopes survive the JSON round-trip; the renderer
  scope-filters inline `env:` to `{Runtime}` and emits the `envFrom` block to the managed
  store with `optional: true`; naming helpers (`managedConfigMapName`/`managedSecretName`/
  `scopeToken`) are the single owner of the resource-name format.
- **Per-app store (EP-24).** `Nagare.Env.Store` — pure `reconcile` (Merge/ReconcileExact),
  ConfigMap/Secret rendering (base64 for secrets), strict extraction, and a thin kubectl
  IO layer.
- **CLI (EP-25).** `nagarectl env list|set|delete|sync` and `secret set|list|delete`, with
  config-derived app identity, scope flags, `.env` import, stdin-only `secret set`, and
  `--dry-run` on every mutation.
- **Generated variables (EP-26).** Inline `{Runtime}` `NAGARE_*` identity vars injected at
  deploy on the app and server paths, authoritative over the managed store.
- **Build/preview application (EP-27).** Build-scoped env into `docker build --build-arg`
  (via the `BuildSpec`/`performBuild` path) with a secret-as-build-arg warning; a
  four-entry preview `envFrom` overlay (runtime then preview) keyed by the production name.
- **Docs + example (EP-28).** `docs/user/env-and-secrets.md` and
  `cluster/examples/env-and-secrets/`, with real `--dry-run` transcripts. The live
  walkthrough was once deferred behind the shared 🟡 `nagare-01` caveat; **the managed-store
  half is now VERIFIED live (2026-06-10)** against the running cluster: `env set --runtime`/
  `--build` and `secret set` created the real scope-suffixed resources
  (`nagare-env-envdemo-runtime`, `nagare-env-envdemo-build`, `nagare-secret-envdemo-runtime`);
  `env list --all` grouped values by scope; `secret list` returned key names only (values never
  printed). _(Fixing the stale `env-and-secrets/Config.hs` to the current `Deployment` schema —
  it was missing the `tasks` field added by MP10 — was a prerequisite found by this live audit; see
  Decision Log.)_ The runtime-injection-into-the-container leg was folded into MP4's build-mode live
  test and is now **VERIFIED live (2026-06-10)**: a Dockerfile app built for the cluster's
  `linux/amd64` node was deployed with `GREETING` set only via the managed store (`env set --runtime`),
  and `printenv GREETING` inside the running container returned `hello-from-managed-store` — proving the
  managed ConfigMap reaches the container at runtime via the rendered `envFrom`. With the store-half
  verification above, the EP-28 live walkthrough is complete.

**Tests:** `nagare-dsl` 143 tests green; `nagarectl` 89 tests green; both executables
build.

**Key lessons / deviations (all recorded in the child plans' Surprises and above):**
- Prefer dependencies already in the nix flake over adding new ones: EP-24 used `memory`
  for base64 (not `base64`); EP-27 added `yaml`/`vector` only after confirming they are
  flake-present.
- `DuplicateRecordFields` requires care: construct records like `GeneratedContext` through
  a qualified alias, and update the `env` field via the generic-lens `& #env %~` form, to
  avoid field-name/selector ambiguities (EP-26).
- The build-modes rework (MasterPlan 4, EP-19–22) had already landed, so EP-27 injected
  build-scoped env into the `BuildSpec`'s `buildArgs` before `performBuild` rather than
  widening `buildImage` — the seam the plan anticipated.
- Library modules consumed by the external test suite must be `exposed-modules`, not
  `other-modules` (EP-24).
- A docs-and-example capstone (EP-28) is where the written contract meets shipped
  behaviour: it caught the compact-JSON store output and the required `build` field, both
  corrected against real output.

**Integration points held:** IP1 (scope type + env-map change), IP2 (naming helpers), IP3
(`envFrom` wiring + precedence), IP4 (reconcile/store schema), and IP5 (generated vars)
were delivered as specified and consumed unchanged by downstream plans.
</content>
</invoke>
