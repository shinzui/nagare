---
id: 27
slug: build-time-and-preview-scoped-env-application
title: "Build-time and preview-scoped env application"
kind: exec-plan
created_at: 2026-06-09T23:52:37Z
intention: "intention_01ktqcj5aseb1rx94fh6npnydv"
master_plan: "docs/masterplans/5-environment-and-secret-management-for-nagare.md"
---

# Build-time and preview-scoped env application

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [27-build-time-and-preview-scoped-env-application.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/27-build-time-and-preview-scoped-env-application.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today every environment variable a Nagare deployment knows about is a *runtime* variable:
it ends up in the running container and nowhere else. Two real needs are unmet. First, some
secrets and settings are needed only while the image is **built** — an API token to pull a
private npm package, a `SENTRY_AUTH_TOKEN` to upload source maps during `npm run build` —
and you do not want them baked into the running container. Second, a **preview**
deployment (a throwaway copy of a site for a branch or pull request) usually needs to point
at *different* backing services than production — a staging database, a sandbox payment key
— without changing production's own variables.

This plan makes both work, building on two prior plans in the same initiative:

- **EP-23** (`docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md`) gave every
  variable a *scope set* drawn from `Runtime`, `Build`, and `Preview`, and made every
  rendered Knative Service pull extra variables from a per-app *managed store* via an
  `envFrom:` block. Today that block references only the **Runtime** store.
- **EP-24** (`docs/plans/24-per-app-secret-and-configmap-store-with-reconcile-modes.md`)
  created that managed store as per-app, per-scope Kubernetes ConfigMaps and Secrets and
  the functions to read them.

After this plan:

- A variable scoped `Build` (whether written inline in the typed `Config.hs`, or stored in
  the app's managed Build store via the CLI) is passed to `docker build` as a
  `--build-arg`, so a `Dockerfile` line `ARG SENTRY_AUTH_TOKEN` / `RUN npm run build` sees
  it. It is **not** placed in the runtime container.
- A variable scoped `Preview` overlays the runtime set *only for preview deployments*: the
  preview Service's container imports the app's Runtime store **and then** its Preview
  store, with Preview last so it wins on conflicts. Production deployments are untouched.

How to see it working (full transcripts appear in **Concrete Steps**):

```text
# A build that needs an API token at build time. With BUILD_TOKEN scoped {Build}
# (inline in Config.hs or in the managed Build store), the deploy runs:
$ docker build --build-arg BUILD_TOKEN=abc123 -t gcr.io/proj/notes:20260609-120000 <ctx>

# A preview that points at a staging backend. With API_BASE scoped {Preview} set to
# the staging URL in the Preview store, the preview Service carries (in order):
envFrom:
  - configMapRef: { name: nagare-env-notes-runtime, optional: true }
  - secretRef:    { name: nagare-secret-notes-runtime, optional: true }
  - configMapRef: { name: nagare-env-notes-preview, optional: true }
  - secretRef:    { name: nagare-secret-notes-preview, optional: true }
```

The work is two independently verifiable milestones: **Milestone 1** wires build-scoped env
into `docker build`; **Milestone 2** adds the preview env overlay. They share the same
prerequisites (the scope model and the store) but touch different code, so either can land
first; this plan implements them in order for a clean narrative.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0: Confirmed EP-23 and EP-24 are merged (both marked Complete; `nagare-dsl`
      exports the scope types/helpers and `Nagare.Env.Store` the read functions). (2026-06-09)
- [x] M1 (ADAPTED — see Surprises): the build path was reworked by EP-19–22 into
      `BuildSpec`/`performBuild`, so instead of widening `buildImage`, build-scoped env is
      injected into the `BuildSpec`'s `buildArgs` via a new pure `Nagare.Build.addBuildArgs`
      before `performBuild`. `buildImage` and the static/server paths are unchanged (static
      has no env; the server runtime-image build consumes no ARGs, its site build is out of
      scope). (2026-06-09)
- [x] M1: Added `Nagare.Env.BuildArgs` with `assembleBuildArgs` (pure), `gatherBuildArgs`
      (IO), `BuildArgWarning`, and `printBuildArgWarnings`; registered in cabal
      `exposed-modules`. (2026-06-09)
- [x] M1: Wired `gatherBuildArgs` + `addBuildArgs` into `runDeploy`'s build branch (only
      when actually building); prints the secret-ref warning. (2026-06-09)
- [x] M1: Unit tests (5): inline Build overrides managed and Runtime-only is excluded,
      name-sorted output; managed-only; managed secret + config value; build-scoped
      secret-ref warns; secret-ref resolves to its stored value. (2026-06-09)
- [x] M2: Added `Nagare.Env.PreviewOverlay.withPreviewEnvFrom` (decode Service YAML →
      inject the four-entry `envFrom` into container[0] → re-encode with a Knative key
      comparator) and wired it into `Nagare.Static.Deploy.previewManifests`, keyed by the
      **production** app name, runtime-then-preview order. (2026-06-09)
- [x] M2: Render tests (3): the preview Service carries the four `envFrom` entries in
      runtime-then-preview order with `optional: true` and the container preserved; the
      production (un-overlaid) Service carries none. (2026-06-09)
- [x] M2: Confirmed previews still do not record a production release
      (`deployStaticPreview` calls no `recordRelease`) and production manifests are
      untouched (production static `--dry-run` shows no `envFrom`). (2026-06-09)
- [x] Both new test groups wired into `nagarectl-test`; `cabal test` green (89 tests). No
      `nagare-dsl` source touched, so its suite is unaffected. (2026-06-09)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The build path was reworked by MasterPlan-4 (EP-19–22) before this plan ran**, exactly
  the seam this plan flagged. The app deploy no longer calls
  `buildImage :: Text -> FilePath -> IO ()`; it calls `Nagare.Build.performBuild spec ref`
  where `spec :: Nagare.Dsl.Build.BuildSpec` already carries `buildArgs :: Map Text Text`
  for `DockerfileBuild`/`NixpacksBuild` (`Nagare.Image.buildDockerfile`/`buildNixpacks`
  emit `--build-arg`/`--env`). So M1's "widen `buildImage` + update three call sites" no
  longer fits. **Adaptation:** the pure `assembleBuildArgs`/`gatherBuildArgs` (the real,
  tested deliverable) are implemented as written; the wiring injects the gathered
  build-scoped env into the `BuildSpec`'s `buildArgs` via a new pure
  `Nagare.Build.addBuildArgs :: [(Text,Text)] -> BuildSpec -> BuildSpec` (config-declared
  build args win on collision), called in `runDeploy`'s build branch. `buildImage` and the
  static/server `buildImage` call sites are left unchanged: static sites carry no env, and
  the server runtime-image build runs a generated Dockerfile with no `ARG` lines (its
  `npm run build` site-build, where build env would matter, is explicitly out of scope per
  Context). This delivers the user-facing behavior (a Dockerfile-built app's `{Build}` env
  reaches `docker build --build-arg`) without dead code. `assembleBuildArgs` stays
  builder-agnostic, so a future Nixpacks/other build mode reuses it unchanged.

- The build-args gather is placed **inside the `requiresBuild` branch** (not before the
  dry-run check), so `--dry-run` and prebuilt-image deploys make no `kubectl` read for the
  Build store — build-scoped env never affects the rendered Service (it is not runtime), so
  there is nothing to show in dry-run.

- `Data.Aeson.KeyMap` exports no `adjust`; the preview overlay's `modifyKey` uses
  `lookup`+`insert`. Re-encoding the overlaid Service needs `yaml` and `vector` — both were
  absent from `nagarectl.cabal` but are already in the nix flake (transitively via `aeson`
  and directly via `nagare-dsl`), so adding them resolved cleanly (cf. EP-24's lesson about
  preferring flake-present packages).

## Decision Log

Record every decision made while working on the plan.

- Decision: Change `Nagare.Image.buildImage`'s signature to
  `buildImage :: Text -> FilePath -> [(Text, Text)] -> IO ()` and update all call sites,
  rather than adding a second `buildImageWithArgs` alongside the old two-argument form.
  Rationale: there are only three call sites (app, static, server deploy), all in this
  repo; a single signature keeps one obvious way to build and avoids a dead/ambiguous
  overload. The empty list `[]` reproduces the old command exactly, so "no build args" is
  still trivially expressible.
  Date: 2026-06-09

- Decision: Build-time **secrets** passed via `--build-arg` are explicitly treated as
  **non-confidential**, and the implementation emits a `WARNING` on stderr whenever a
  `Build`-scoped secret-ref (or a value sourced from the managed Build *Secret* store) is
  about to be passed as a `--build-arg`. We do not silently drop it (that would surprise a
  user who deliberately scoped a non-sensitive token as a secret), and we do not block the
  build (that would make the feature unusable for the common "build needs a token" case).
  We document BuildKit `--secret` / `RUN --mount=type=secret` as the confidential path and
  mark full BuildKit-secret support as a noted follow-up (see the MasterPlan-4 seam below).
  Rationale: `--build-arg` values are recoverable from `docker history` and image metadata,
  so they are not a confidentiality boundary; a loud, non-fatal warning is the safe,
  honest default that still lets the common case work.
  Date: 2026-06-09

- Decision: Precedence for build args mirrors the runtime `envFrom`-then-`env` precedence
  from EP-23 IP3: **managed Build store first, inline DSL Build env overrides it.** So if
  `BUILD_TOKEN` exists both in `Config.hs` (scope `{Build}`) and in the managed Build
  ConfigMap/Secret, the inline value wins. Rationale: keeps one mental model across runtime
  and build — the value written closest to the code (the typed config) is the explicit,
  overriding declaration, while the managed store is the day-2-editable backstop.
  Date: 2026-06-09

- Decision: The preview env overlay is keyed by the **production app name**
  (`nagare-env-<app>-preview`, `nagare-secret-<app>-preview`), *not* by the derived preview
  Service name (`<app>-pr-<branch>`). Rationale: preview env (a staging backend URL, a
  sandbox key) is naturally shared across *all* previews of the same app; keying by the
  production name means an operator sets `API_BASE=staging` once and every branch preview
  inherits it, with no per-branch store to manage. The Service is still named with the
  derived preview name; only the `envFrom` store references use the production name.
  Date: 2026-06-09

- Decision: Produce the preview `envFrom` in the **nagarectl preview render path**
  (`Nagare.Static.Deploy.previewManifests`) by post-processing the rendered Service, rather
  than threading a "preview overlay" flag into EP-23's DSL renderer. Rationale: static
  sites carry *no* env in EP-23 (only `Deployment` and `ServerSite` gained the scope-aware
  env map and the runtime `envFrom`), so the static Service has no `envFrom` block at all;
  the preview overlay is fundamentally a deploy-time concern of the nagarectl preview path,
  which already owns preview naming and isolation. Keeping it there avoids growing the DSL
  renderer's surface and keeps the overlay's four-entry shape consistent with EP-23's
  `envFrom` contract (same key shape, same `optional: true`). For the server preview path
  (when EP-23 has given server sites a runtime `envFrom`), the overlay appends the two
  preview entries after the existing two runtime entries.
  Date: 2026-06-09

- Decision: Keep this plan implemented against the **current** `docker build` path
  (`buildImage`) and flag the seam to MasterPlan 4 (`docs/masterplans/4-application-build-modes-for-nagare.md`,
  EP-19–EP-22). Rationale: MasterPlan 4 reworks the build into a `BuildSpec` with
  `DockerfileBuild` / `PrebuiltImage` / `Nixpacks` modes; build-time env must compose with
  whichever builder runs (build-args for the Docker path, that builder's env mechanism for
  others). This plan must be self-contained today, so it targets `buildImage`; the assembler
  `assembleBuildArgs` is deliberately pure and builder-agnostic so a future build mode can
  reuse it.
  Date: 2026-06-09

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-09): complete, both milestones.**

M1 — build-time env: `Nagare.Env.BuildArgs.assembleBuildArgs` (pure, name-sorted,
managed-then-inline precedence, secret-ref warnings) and `gatherBuildArgs` (reads the
managed Build ConfigMap/Secret) feed `Nagare.Build.addBuildArgs` into the `BuildSpec`'s
`buildArgs`, so a Dockerfile-built app's `{Build}`-scoped env reaches
`docker build --build-arg` and never the runtime container. A build-scoped secret-ref
prints a loud, non-fatal "NOT confidential" warning. 5 unit tests.

M2 — preview overlay: `Nagare.Env.PreviewOverlay.withPreviewEnvFrom` injects the four
`envFrom` entries (`nagare-env/secret-<app>-runtime` then `-preview`, `optional: true`)
into a preview Service, keyed by the production app name, applied in
`previewManifests`. Verified end-to-end: a `site preview deploy --dry-run` of the
example static site renders all four entries in order on `static-site-pr-pr-42` (keyed
`static-site`); the production deploy renders none. 3 render tests. Previews still record
no production release and leave the production Service untouched.

**Against the purpose:** both unmet needs are met — build-only secrets reach the build
without being baked into the runtime image, and a preview can point at staging backends
via the Preview store without touching production.

**Notes / lessons:** the single material deviation is the build-path adaptation (see
Surprises) forced by MasterPlan-4 having already landed; the plan anticipated this seam,
and the pure assembler design made the pivot small. The preview overlay was kept in the
nagarectl render path (not the DSL renderer) exactly as the Decision Log chose, which is
what made adding `envFrom` to an otherwise env-less static Service possible.

