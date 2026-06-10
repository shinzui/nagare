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


## Context and Orientation

This section assumes no prior knowledge of the repository. Every file is named by its full
path from the repo root (`/Users/shinzui/Keikaku/bokuno/nagare`). The two Haskell packages
involved are the typed DSL library `cli/nagare-dsl/` and the CLI `cli/nagarectl/`.

**Terms used throughout.**

- *Knative Service*: the single YAML resource Nagare deploys for an app or server site. Its
  container spec lives at `spec.template.spec.containers[0]` and lists `image`, `ports`,
  inline `env`, `envFrom`, and `resources`.
- *`envFrom`*: a Kubernetes container field meaning "import all keys from this ConfigMap or
  Secret as environment variables." With `optional: true` the container still starts if the
  referenced resource is absent. Kubernetes applies the `envFrom` list **in order**, then
  the inline `env:` list, so later `envFrom` entries override earlier ones, and inline
  `env:` overrides everything. This ordering is the whole mechanism behind the preview
  overlay.
- *build-arg*: a value passed to `docker build --build-arg NAME=VALUE`. Inside the
  `Dockerfile`, a matching `ARG NAME` line makes it available to subsequent `RUN`
  instructions during the build. It does **not** become a runtime environment variable
  unless the Dockerfile also writes `ENV NAME=$NAME`. **Caveat:** build-args are stored in
  image metadata and printed by `docker history`, so they are not a place for confidential
  secrets.
- *BuildKit secret*: Docker's confidential build-time mechanism —
  `docker build --secret id=foo,src=./foo` plus `RUN --mount=type=secret,id=foo ...` — where
  the secret is mounted into a single `RUN` and never written to a layer or to image
  metadata. This is the recommended path for *confidential* build secrets; see the
  MasterPlan-4 seam below for why full support is a follow-up.
- *scope*: from EP-23, each variable carries a non-empty `Set EnvScope` drawn from
  `Runtime` (in the running container), `Build` (present during the image build), and
  `Preview` (overlay for preview deploys). A bare variable defaults to `{Runtime}`.

**What EP-23 gives us (the contracts this plan consumes).** EP-23 lives in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs` and `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`. The
exact types and helpers, exported from the `nagare-dsl` library:

```haskell
-- Nagare.Dsl.Types
data EnvScope = Runtime | Build | Preview
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

data ScopedEnvVar = ScopedEnvVar
  { value  :: !EnvVar          -- existing sum type: EnvLiteral Text | EnvSecretRef SecretName
  , scopes :: !(Set EnvScope)  -- invariant: non-empty
  }
  deriving stock (Generic, Eq, Show)

-- Nagare.Dsl.Render
scopeToken           :: EnvScope -> Text          -- Runtime->"runtime", Build->"build", Preview->"preview"
managedConfigMapName :: Text -> EnvScope -> Text  -- "nagare-env-<app>-<scope>"
managedSecretName    :: Text -> EnvScope -> Text  -- "nagare-secret-<app>-<scope>"
```

After EP-23, the `env` field of both `Deployment` (`Nagare.Dsl.Types`) and `ServerSite`
(`Nagare.Dsl.Server.Types`) is `Map EnvName ScopedEnvVar` (it was `Map EnvName EnvVar`).
The `EnvVar` sum type is unchanged: `EnvLiteral Text` or `EnvSecretRef SecretName` (see
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`). EP-23 also made every rendered app/server Service
emit, in its container spec, this exact runtime `envFrom` (its IP3 contract):

```yaml
envFrom:
  - configMapRef:
      name: nagare-env-<app>-runtime
      optional: true
  - secretRef:
      name: nagare-secret-<app>-runtime
      optional: true
```

Static-site Services (`cli/nagare-dsl/src/Nagare/Dsl/Static/Render.hs`) carry **no** env
and **no** `envFrom` — static files have no environment. That fact drives a key design
choice in Milestone 2 (see its Decision Log entry): the preview overlay for a static site
must be added by the nagarectl preview path, because the DSL never emits any `envFrom` for
static sites to extend.

**What EP-24 gives us (the store reads this plan consumes).** EP-24 lives in the new module
`cli/nagarectl/src/Nagare/Env/Store.hs`. The two read functions this plan calls:

```haskell
-- Nagare.Env.Store
readEnvStore    :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))  -- app ns scope
readSecretStore :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))  -- app ns scope
```

`readEnvStore app ns Build` runs `kubectl get configmap nagare-env-<app>-build -n <ns> -o json`
and returns the plaintext data map (or an empty map when the ConfigMap is absent — EP-24
treats not-found as "no managed env yet", returning `Right Map.empty`, not an error; verify
this in EP-24 before relying on it). `readSecretStore app ns Build` is the same against the
Secret, returning the **decoded** values.

**The current build path (what `buildImage` does today).** In
`cli/nagarectl/src/Nagare/Image.hs`, the build is:

```haskell
-- | Run @docker build -t <image:tag> <context>@.
buildImage :: Text -> FilePath -> IO ()
buildImage ref context =
  run_ $ cmd "docker" & addArgs ["build", "-t", T.unpack ref, context]
```

It shells out through the `cradle` process library (`Cradle`, imported in that module);
`run_` runs a command and discards output, `cmd "docker"` starts a command builder, and
`addArgs [...]` appends arguments. There are **no** build-args today. The three places that
call `buildImage`:

1. App deploy — `cli/nagarectl/app/Main.hs`, function `runDeploy` (around lines 324–357):
   `buildImage ref (dopts ^. #context)`.
2. Static-site deploy — `cli/nagarectl/src/Nagare/Static/Deploy.hs`, functions
   `deployStaticProduction` and `deployStaticPreview`:
   `withStaticImageContext s out (buildImage ref)` (so `buildImage ref` is applied to the
   temp context path produced by `withStaticImageContext`).
3. Server-site deploy — `cli/nagarectl/src/Nagare/Server/Deploy.hs` (read it during M1; it
   uses `withServerImageContext site prepared (buildImage ref)` mirroring the static path,
   via `cli/nagarectl/src/Nagare/Server/Image.hs`).

The static/server build *commands* (`npm run build` etc.) run earlier, in
`cli/nagarectl/src/Nagare/Static/Build.hs` (`prepareStaticOutput`) and
`cli/nagarectl/src/Nagare/Server/Build.hs` (`prepareServerOutput`), through `sh -c`. Those
are *site* build commands, distinct from `docker build`; this plan does **not** change them
(build-scoped env reaching the *site* build command is out of scope — the build-arg path
targets the `docker build` step, which is where the image is assembled). Note this
explicitly so the reader does not confuse the two builds.

**The preview path (what Milestone 2 extends).** In `cli/nagarectl/app/Main.hs`,
`runPreviewDeploy` (around lines 483–500) loads the site, resolves the image tag, builds
`DeployInputs`, calls `previewManifests inputs pname` (pure render) for `--dry-run`, and
otherwise calls `deployStaticPreview inputs pname`. Both live in
`cli/nagarectl/src/Nagare/Static/Deploy.hs`:

- `previewManifests :: DeployInputs -> Text -> Either Text StaticManifests` renders the
  preview artifacts. It derives the preview Service name with
  `previewServiceName prodName raw` (from `cli/nagarectl/src/Nagare/Static/Preview.hs`),
  swaps the site's domain for the derived preview domain, and renders with a
  `StaticDeployContext { imageTag, previewName = Just svcName }`. The `prodName` here is
  `siteNameText (s ^. #name)` — the **production** site name — which is exactly the key we
  want for the preview store.
- `deployStaticPreview :: DeployInputs -> Text -> IO (Either Text Text)` runs the
  build/push/apply for the preview and **does not** record a production release (the
  isolation this plan must preserve).

`Nagare.Static.Preview.previewServiceName :: Text -> Text -> Either Text Text` produces
`"<site>-pr-<branch>"` (DNS-clamped). The store names, per the Decision Log, use the
production name, not this derived one.


## Plan of Work

The work is two milestones. Milestone 1 makes build-scoped env reach `docker build`.
Milestone 2 makes preview-scoped env overlay the runtime set in preview deploys. Read
`cli/nagarectl/src/Nagare/Server/Deploy.hs` at the start of each milestone — its shape
mirrors `Nagare.Static.Deploy` and the same edits apply.


### Milestone 1 — Build-time env into `docker build`

**Scope and result.** At the end of this milestone, `Nagare.Image.buildImage` accepts a
list of build args and emits `--build-arg K=V` flags; a new module
`cli/nagarectl/src/Nagare/Env/BuildArgs.hs` gathers the app's Build-scoped variables (inline
DSL entries scoped `Build`, plus the managed Build ConfigMap and Secret stores) into that
list; and all three deploy paths pass it. A build-scoped secret-ref passed as a build-arg
prints a loud, non-fatal warning. You can prove it with a unit test on the pure assembler
and, end to end, by a `docker build` whose command line shows the expected `--build-arg`
flags.

**Step 1 — widen `buildImage`.** In `cli/nagarectl/src/Nagare/Image.hs`, change the
signature and body:

```haskell
-- | Run @docker build [--build-arg K=V ...] -t <image:tag> <context>@.
-- The third argument is the list of build args, name-then-value; an empty list
-- reproduces the original @docker build -t <ref> <context>@ exactly.
buildImage :: Text -> FilePath -> [(Text, Text)] -> IO ()
buildImage ref context buildArgs =
  run_ $ cmd "docker" & addArgs (["build"] <> argFlags <> ["-t", T.unpack ref, context])
  where
    argFlags = concatMap (\(k, v) -> ["--build-arg", T.unpack (k <> "=" <> v)]) buildArgs
```

Keep the existing export list (`buildImage` is already exported). The build-args appear
*before* `-t` so the command reads `docker build --build-arg K=V -t ref ctx`, which Docker
accepts.

**Step 2 — the pure assembler and IO gatherer.** Create
`cli/nagarectl/src/Nagare/Env/BuildArgs.hs`:

```haskell
module Nagare.Env.BuildArgs
  ( BuildArgWarning (..)
  , assembleBuildArgs
  , gatherBuildArgs
  ) where

import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Nagare.Dsl.Types
  ( EnvName, EnvScope (..), EnvVar (..), ScopedEnvVar (..)
  , envNameText, secretNameText )
import Nagare.Env.Store (readEnvStore, readSecretStore)

-- | A build-scoped secret-ref that will be passed as a (non-confidential)
-- --build-arg. Carried out so the caller can print the warning.
newtype BuildArgWarning = BuildArgSecretRef Text  -- the env var name
  deriving stock (Eq, Show)

-- | Pure: merge managed Build env (ConfigMap + decoded Secret) with the inline
-- DSL Build entries, returning the name-sorted build-arg list and the warnings.
--
-- Precedence (mirrors EP-23 runtime envFrom-then-env): managed first, inline
-- DSL Build env overrides it. Inline secret-refs are resolved against the
-- managed Build *Secret* store by key; if absent there, they are dropped with a
-- warning (a build secret-ref with no stored value has nothing to pass).
assembleBuildArgs ::
  Map Text Text ->            -- managed Build ConfigMap data
  Map Text Text ->            -- managed Build Secret data (decoded)
  Map EnvName ScopedEnvVar -> -- inline DSL env (full map; we filter to {Build})
  ([(Text, Text)], [BuildArgWarning])
assembleBuildArgs cfg sec inlineEnv = (Map.toAscList merged, warnings)
  where
    inlineBuild =
      [ (envNameText n, sev) | (n, sev) <- Map.toList inlineEnv
      , Set.member Build (scopes sev) ]
    -- resolve each inline Build entry to a literal value (or Nothing + warning)
    resolved = map resolve inlineBuild
    resolve (name, sev) = case value sev of
      EnvLiteral lit   -> (name, Just lit, [])
      EnvSecretRef sn  ->
        case Map.lookup name sec of               -- secret-ref keyed by the var name
          Just v  -> (name, Just v, [BuildArgSecretRef name])  -- warn: build secret as build-arg
          Nothing -> (name, Nothing, [BuildArgSecretRef name]) -- warn + drop
    inlineMap  = Map.fromList [ (n, v) | (n, Just v, _) <- resolved ]
    warnings   = concat [ w | (_, _, w) <- resolved ]
    managed    = Map.union sec cfg               -- managed: secret values + config values
    merged     = Map.union inlineMap managed     -- inline overrides managed

-- | IO: read the app's managed Build stores and assemble the build args for it.
gatherBuildArgs ::
  Text ->                     -- app name (the deploy/service name)
  Text ->                     -- namespace
  Map EnvName ScopedEnvVar -> -- inline DSL env
  IO ([(Text, Text)], [BuildArgWarning])
gatherBuildArgs app ns inlineEnv = do
  cfg <- either (const Map.empty) id <$> readEnvStore app ns Build
  sec <- either (const Map.empty) id <$> readSecretStore app ns Build
  pure (assembleBuildArgs cfg sec inlineEnv)
```

Notes for the implementer: confirm the real `EnvVar`/`ScopedEnvVar` field accessors and the
`Set`/`Map` import names against the merged EP-23/EP-24 source — adjust the record-field
access to match (EP-23 may expose `value`/`scopes` as generic-lens labels `^. #value` /
`^. #scopes` rather than bare functions; use whichever the source provides). Keep the
*behavior* exactly as the comments state: name-sorted output, managed-then-inline
precedence, a warning per build-scoped secret-ref.

Add `Nagare.Env.BuildArgs` (and, if not already present from EP-24, `Nagare.Env.Store`) to
the `nagarectl` library's `exposed-modules`/`other-modules` in
`cli/nagarectl/nagarectl.cabal`.

**Step 3 — wire it into the deploy paths.** In each path, after the site/deployment is
loaded and before `buildImage` is called, gather the args, print warnings, and pass the
args:

- App deploy (`cli/nagarectl/app/Main.hs`, `runDeploy`): the app name is
  `serviceNameText (dep ^. #name)`, the namespace `namespaceText (dep ^. #namespace)`, the
  inline env `dep ^. #env`. Replace `buildImage ref (dopts ^. #context)` with:

  ```haskell
  (bargs, warns) <- gatherBuildArgs name ns (dep ^. #env)
  printBuildArgWarnings warns
  buildImage ref (dopts ^. #context) bargs
  ```

- Static deploy (`cli/nagarectl/src/Nagare/Static/Deploy.hs`): static sites have **no** env
  in EP-23, so there are no inline Build entries and (today) no Build store usage. Update
  the two call sites to `withStaticImageContext s out (\ctx -> buildImage ref ctx [])` so
  the new signature compiles. (If a future plan gives static sites env, the same
  `gatherBuildArgs` call slots in here.)

- Server deploy (`cli/nagarectl/src/Nagare/Server/Deploy.hs`): server sites *do* carry env;
  gather with the server site's name/namespace/env and pass the args to the `buildImage`
  continuation, mirroring the app path. Read the module first to find the exact accessor
  names.

Add a small helper in `app/Main.hs` (and reuse it in server deploy) to print warnings to
stderr:

```haskell
printBuildArgWarnings :: [BuildArgWarning] -> IO ()
printBuildArgWarnings =
  mapM_ $ \(BuildArgSecretRef name) ->
    TIO.hPutStrLn stderr
      ( "nagarectl: WARNING: build-scoped secret '" <> name
        <> "' is passed to docker build as a --build-arg; build-args are visible in "
        <> "`docker history` and image metadata and are NOT confidential. For a "
        <> "confidential build secret use BuildKit (RUN --mount=type=secret)." )
```

`stderr` and `TIO.hPutStrLn` are already imported in `app/Main.hs`.

**Commands and acceptance.** Build and test the package:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal build
cabal test
```

Acceptance: `cabal build` succeeds with the new `buildImage` arity; the new
`assembleBuildArgs` unit test (Step 4) passes, proving that given Build-scoped inline +
managed env the emitted flags are exactly the expected `--build-arg` pairs in name-sorted
order; and the build-scoped-secret-ref test shows a `BuildArgSecretRef` warning is produced.

**Step 4 — tests.** In `cli/nagarectl/test/Spec.hs`, add a `testGroup "build args"` with at
least three `testCase`s, importing `Nagare.Env.BuildArgs` and the DSL constructors. The
assembler is pure, so no cluster is needed:

```haskell
-- managed cfg {A:1}, managed sec {B:2}, inline DSL {A:{Build}=9, C:{Runtime}=x}
-- expected build args (name-sorted): [("A","9"),("B","2")]  (C is Runtime-only; A inline wins)
testCase "inline Build overrides managed; Runtime-only excluded" $
  let (args, _) = assembleBuildArgs
        (Map.fromList [("A","1")])
        (Map.fromList [("B","2")])
        (Map.fromList [ (envName "A", scoped (EnvLiteral "9") [Build])
                      , (envName "C", scoped (EnvLiteral "x") [Runtime]) ])
   in args @?= [("A","9"), ("B","2")]

testCase "build-scoped secret-ref warns" $
  let (_, warns) = assembleBuildArgs Map.empty (Map.fromList [("TOKEN","s3cr3t")])
        (Map.fromList [ (envName "TOKEN", scoped (EnvSecretRef (mkSecret "tok")) [Build]) ])
   in warns @?= [BuildArgSecretRef "TOKEN"]
```

(Use the real smart constructors — `mkEnvName`, `mkSecretName`, the EP-23 scoped-env helper
— wrapping `Either` with `either error id` in the test as the existing fixtures do. Adjust
`scoped`/`envName`/`mkSecret` to the actual helper names.)


### Milestone 2 — Preview-scoped env overlay

**Scope and result.** At the end of this milestone, a **preview** deployment's Service
imports the app's Runtime store and then its Preview store via `envFrom`, in that order, so
Preview overrides Runtime. The production Service is untouched (it keeps only the two
runtime `envFrom` entries from EP-23, and static production Services keep none). You can
prove it with a render test: the preview Service YAML contains the four entries in
runtime-then-preview order; the production Service does not contain the preview pair.

**The exact shape** the preview Service's container spec must carry:

```yaml
envFrom:
  - configMapRef:
      name: nagare-env-<app>-runtime
      optional: true
  - secretRef:
      name: nagare-secret-<app>-runtime
      optional: true
  - configMapRef:
      name: nagare-env-<app>-preview
      optional: true
  - secretRef:
      name: nagare-secret-<app>-preview
      optional: true
```

`<app>` is the **production** app name (Decision Log: preview env is shared across all
previews of one app). The order matters: Kubernetes applies `envFrom` top-to-bottom, so the
preview entries (last) override the runtime entries.

**Where to add it.** Per the Decision Log, add the overlay in the nagarectl preview render
path, not in EP-23's DSL renderer, because static Services carry no `envFrom` to extend.
Add a small module `cli/nagarectl/src/Nagare/Env/PreviewOverlay.hs` that, given a rendered
Service YAML `ByteString` and the production app name, inserts the four `envFrom` entries
into `spec.template.spec.containers[0].envFrom` (replacing any existing `envFrom` for the
two runtime entries, then appending the two preview entries). Because the rendered YAML is
deterministic and we control its shape, prefer the robust route: **decode the Service YAML
to a `Data.Aeson.Value`, rewrite the container's `envFrom` array, and re-encode** with the
same `Data.Yaml.Pretty` config and key comparator EP-23/the static renderer use, so the
output is byte-stable and key-ordered. Sketch:

```haskell
module Nagare.Env.PreviewOverlay (withPreviewEnvFrom) where

import Data.Aeson (Value (..), object, toJSON, (.=))
-- ... lens into spec.template.spec.containers[0], set "envFrom" to the 4-entry array ...
import Nagare.Dsl.Render (managedConfigMapName, managedSecretName)
import Nagare.Dsl.Types (EnvScope (..))

previewEnvFrom :: Text -> Value
previewEnvFrom app = toJSON
  [ object ["configMapRef" .= object ["name" .= managedConfigMapName app Runtime, "optional" .= True]]
  , object ["secretRef"    .= object ["name" .= managedSecretName    app Runtime, "optional" .= True]]
  , object ["configMapRef" .= object ["name" .= managedConfigMapName app Preview, "optional" .= True]]
  , object ["secretRef"    .= object ["name" .= managedSecretName    app Preview, "optional" .= True]]
  ]

-- | Decode the Service YAML, set the first container's "envFrom" to the 4-entry
-- preview overlay, re-encode with the Knative key comparator. Returns the input
-- unchanged on a decode failure (defensive; the input is always our own render).
withPreviewEnvFrom :: Text -> ByteString -> ByteString
```

Use the same `knativeConfig`/`keyCompare` pretty-print config the static renderer uses;
either re-export it from `Nagare.Dsl.Static.Render` or duplicate the tiny comparator with
`envFrom`/`configMapRef`/`secretRef`/`optional` ranks so the four entries serialize
deterministically (configMapRef before secretRef within each entry; runtime pair before
preview pair as written in the array, since array order is preserved by encoding).

Then, in `cli/nagarectl/src/Nagare/Static/Deploy.hs`, wrap the preview Service in
`previewManifests` with the overlay, keyed by the production name:

```haskell
previewManifests inputs raw = do
  let s = site inputs
      prodName = siteNameText (s ^. #name)
  svcName <- previewServiceName prodName raw
  -- ... unchanged domain/site setup ...
  let renderedSvc = renderStaticService previewSite ctx
  Right StaticManifests
    { service = withPreviewEnvFrom prodName renderedSvc   -- <-- overlay applied here
    , ...
    }
```

`deployStaticPreview` already calls `previewManifests` and applies `service m`, so threading
the overlay through `previewManifests` covers both `--dry-run` and the real apply with one
change. For the **server** preview path (if `Nagare.Server.Deploy` has one), apply the same
`withPreviewEnvFrom prodName` to its preview Service render; server production Services
already have the two runtime entries from EP-23, and the overlay's first two entries match
them, so the result is still exactly the four entries in order.

**Isolation to preserve.** Do not touch `deployStaticProduction` or `productionManifests` —
production keeps only its EP-23 runtime `envFrom` (or none, for static). Confirm
`deployStaticPreview` still does not call `recordRelease` (it doesn't today), so previews
still leave the production release log alone.

**Commands and acceptance.** From `cli/nagarectl`:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal test
```

Plus a `--dry-run` preview against the example site (see Concrete Steps) to eyeball the four
`envFrom` entries. Acceptance: the render test asserts the preview Service contains, in
order, `nagare-env-<app>-runtime`, `nagare-secret-<app>-runtime`, `nagare-env-<app>-preview`,
`nagare-secret-<app>-preview`; and a production-render assertion shows the preview pair is
absent from production.


## Concrete Steps

All commands assume the repo root `/Users/shinzui/Keikaku/bokuno/nagare` and the nix
dev shell (Cabal/GHC 9.12 via the flake). Enter it once with `direnv allow` (per the repo's
`.envrc`) or `nix develop`.

**M0 — verify the dependencies are present.**

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
grep -rn "data EnvScope = Runtime | Build | Preview" cli/nagare-dsl/src
grep -rn "managedConfigMapName\|managedSecretName\|scopeToken" cli/nagare-dsl/src/Nagare/Dsl/Render.hs
grep -rn "readEnvStore\|readSecretStore" cli/nagarectl/src/Nagare/Env/Store.hs
```

Expected: the first prints the `EnvScope` definition in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`; the second prints the three naming/token helpers;
the third prints the two read functions. If any is missing, EP-23 or EP-24 is not yet
merged — stop and land them first (this plan hard-depends on both).

**M1 — build-time env.** Make the edits in the Plan of Work, then:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal build
cabal test
```

Expected test transcript (the new group appears alongside the existing ones):

```text
build args
  inline Build overrides managed; Runtime-only excluded: OK
  managed-only when no inline:                           OK
  build-scoped secret-ref warns:                         OK
All N tests passed
```

End-to-end build transcript (illustrative): with `BUILD_TOKEN` scoped `{Build}` in the app
and a populated managed Build store, `nagarectl deploy` runs a `docker build` whose command
line includes the flags. To observe the exact command without a registry, run with the
docker CLI traced, or assert it in the unit test; a representative line:

```text
$ docker build --build-arg BUILD_TOKEN=abc123 --build-arg NPM_REGISTRY=https://r.example.com \
    -t gcr.io/proj/notes:20260609-120000 .
```

If `BUILD_TOKEN` is a secret-ref, the deploy first prints to stderr:

```text
nagarectl: WARNING: build-scoped secret 'BUILD_TOKEN' is passed to docker build as a --build-arg;
build-args are visible in `docker history` and image metadata and are NOT confidential.
For a confidential build secret use BuildKit (RUN --mount=type=secret).
```

**M2 — preview overlay.** Make the edits, then run the render test and a dry-run preview
against the bundled example site (no cluster needed for `--dry-run`):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal test
cabal run nagarectl -- site preview deploy \
  -f ../../cluster/examples/static-site/nagare/Config.hs \
  -C ../../cluster/examples/static-site \
  --name pr-42 --dry-run --skip-build
```

Expected `--dry-run` transcript excerpt — the rendered preview Service shows the four
`envFrom` entries in runtime-then-preview order (with `<app>` = the example site's name,
e.g. `static-demo`):

```yaml
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: static-demo-pr-42
  namespace: personal
spec:
  template:
    spec:
      containers:
      - image: gcr.io/proj/static-demo:20260609-120000
        ports:
        - containerPort: 8080
        envFrom:
        - configMapRef:
            name: nagare-env-static-demo-runtime
            optional: true
        - secretRef:
            name: nagare-secret-static-demo-runtime
            optional: true
        - configMapRef:
            name: nagare-env-static-demo-preview
            optional: true
        - secretRef:
            name: nagare-secret-static-demo-preview
            optional: true
Preview service: static-demo-pr-42
```

(The exact site name and image come from the example config; what matters is the four
`envFrom` entries and their order. If EP-25 is merged, populate the Preview store first with
`nagarectl env set static-demo API_BASE=https://staging... --preview` so the overlay points
at something real; without EP-25, the entries are still emitted with `optional: true` and a
hand-written ConfigMap/Secret can stand in.)


## Validation and Acceptance

Acceptance is behavior a human can verify, not internal structure.

**Build-time env (M1).**

1. The pure assembler test in `cli/nagarectl/test/Spec.hs` proves the build-arg list is
   exactly the expected name-sorted `--build-arg` pairs given Build-scoped inline + managed
   env, with inline overriding managed and Runtime-only entries excluded. Run
   `cabal test` in `cli/nagarectl`; the `build args` group must be `OK`.
2. The security caveat is verified: the secret-ref test asserts a `BuildArgSecretRef`
   warning is produced for a `{Build}` secret-ref, and a manual `nagarectl deploy` with such
   a config prints the stderr `WARNING:` line shown above. Success = the warning text
   appears; failure = no warning, or the build aborts (it must not abort).
3. End to end, the `docker build` command carries the `--build-arg` flags (observable in the
   unit test or by tracing the docker CLI). The variable does **not** appear in the runtime
   container's inline `env:` (it is Build-scoped, excluded by EP-23's runtime filter).

**Preview overlay (M2).**

1. The render test asserts the preview Service YAML contains the four `envFrom` entries in
   the order runtime-config, runtime-secret, preview-config, preview-secret, with names
   `nagare-env-<app>-runtime`, `nagare-secret-<app>-runtime`, `nagare-env-<app>-preview`,
   `nagare-secret-<app>-preview`, all `optional: true`. A complementary assertion on the
   *production* render shows the preview pair is absent.
2. The `--dry-run` preview transcript above shows the four entries to a human.
3. Isolation: deploying a preview does not change the production Service and does not write
   the production release log — assert `deployStaticPreview` does not call `recordRelease`
   (code inspection plus the existing release-log test remaining green).

Both milestones: `cabal test` is green in `cli/nagarectl` (and `cli/nagare-dsl` if any DSL
test was touched). The existing golden tests for production Services must remain
byte-for-byte unchanged, proving production behavior did not regress.


## Idempotence and Recovery

Every step here is additive and repeatable. Re-running `cabal build` / `cabal test` is
idempotent. The `buildImage` signature change and the new modules are pure additions plus
call-site updates; if a call site is missed, the build fails loudly (arity mismatch) rather
than silently misbehaving — fix the flagged site and rebuild.

Re-running a **preview deploy** reproduces the same four `envFrom` entries: `previewManifests`
is a pure function of the inputs and the production app name, so the rendered Service (and
thus the applied manifest) is identical on every run. `kubectl apply` of an unchanged Service
is a no-op, so repeated preview deploys do not drift. The preview store references use
`optional: true`, so a preview deploys whether or not the Preview ConfigMap/Secret exists;
creating them later and re-applying simply makes the values take effect.

The **build** is deterministic given the same store: `gatherBuildArgs` reads the managed
Build ConfigMap/Secret and merges with the inline config; for a fixed store and config the
build-arg list is identical (name-sorted), so two builds from the same inputs pass the same
`--build-arg` flags. EP-24's reads treat a missing store as empty, so a never-populated
Build store yields no build args — the build still runs, exactly as before this plan.

To recover from a bad preview overlay, delete the preview with
`nagarectl site preview delete <name>` (existing command, tolerant of absence) and redeploy.
No production state is involved at any point.


## Interfaces and Dependencies

**New / changed in this plan (`cli/nagarectl`).**

```haskell
-- Nagare.Image (changed signature)
buildImage :: Text -> FilePath -> [(Text, Text)] -> IO ()

-- Nagare.Env.BuildArgs (new)
data BuildArgWarning = BuildArgSecretRef Text
assembleBuildArgs ::
  Map Text Text -> Map Text Text -> Map EnvName ScopedEnvVar
  -> ([(Text, Text)], [BuildArgWarning])
gatherBuildArgs :: Text -> Text -> Map EnvName ScopedEnvVar
  -> IO ([(Text, Text)], [BuildArgWarning])

-- Nagare.Env.PreviewOverlay (new)
withPreviewEnvFrom :: Text -> ByteString -> ByteString   -- app -> rendered Service -> Service+overlay

-- Nagare.Static.Deploy (changed): previewManifests applies withPreviewEnvFrom
previewManifests :: DeployInputs -> Text -> Either Text StaticManifests   -- signature unchanged
```

**Consumed from EP-23** (`nagare-dsl` library), already merged:

```haskell
import Nagare.Dsl.Types  (EnvScope (..), ScopedEnvVar (..), EnvVar (..), EnvName, envNameText, secretNameText)
import Nagare.Dsl.Render (managedConfigMapName, managedSecretName, scopeToken)
```

`EnvScope = Runtime | Build | Preview`; `ScopedEnvVar { value :: EnvVar, scopes :: Set EnvScope }`;
`managedConfigMapName app scope == "nagare-env-<app>-<scope>"`;
`managedSecretName app scope == "nagare-secret-<app>-<scope>"`. Every rendered app/server
Service already carries the runtime `envFrom` pair (EP-23 IP3); inline `env:` and generated
vars override `envFrom` of the same key.

**Consumed from EP-24** (`Nagare.Env.Store`), already merged:

```haskell
import Nagare.Env.Store (readEnvStore, readSecretStore)
-- readEnvStore    app ns Build :: IO (Either Text (Map Text Text))
-- readSecretStore app ns Build :: IO (Either Text (Map Text Text))  -- decoded values
```

A missing store is treated as empty (verify EP-24 returns `Right Map.empty` for not-found
before relying on the `either (const Map.empty) id` fallback above).

**Soft dependency — EP-25** (`docs/plans/25-nagarectl-env-and-secret-cli-commands.md`):
provides `nagarectl env set --build`/`--preview` to populate the Build and Preview stores
for a live demo. This plan can be implemented and unit-tested without EP-25 by writing the
ConfigMap/Secret by hand or by exercising the pure `assembleBuildArgs` directly.

**MasterPlan-4 seam** (`docs/masterplans/4-application-build-modes-for-nagare.md`, EP-19–22):
those plans rework the build into a `BuildSpec` with `DockerfileBuild`, `PrebuiltImage`, and
`Nixpacks` modes. Build-time env must compose with whichever build mode runs: for the current
`docker build` path it is `--build-arg` (this plan); for a future builder it is that builder's
env-passing mechanism (e.g. Nixpacks env vars), and for `PrebuiltImage` there is no build, so
Build-scoped env simply does not apply. The pure `assembleBuildArgs` is deliberately
builder-agnostic so the future build-mode plan can reuse it. Full BuildKit `--secret` /
`RUN --mount=type=secret` support for *confidential* build secrets is a **noted follow-up**:
this plan passes build secrets as `--build-arg` with a loud warning (see Decision Log), which
is honest but not confidential; the confidential path belongs with the build-mode rework.

**Build/test toolchain.** Cabal/GHC 9.12 via the nix flake. Tests use `tasty` + `tasty-hunit`
(`cli/nagarectl/test/Spec.hs`). Add `Nagare.Env.BuildArgs`, `Nagare.Env.PreviewOverlay`, and
(if not already from EP-24) `Nagare.Env.Store` to `cli/nagarectl/nagarectl.cabal`'s module
lists. Run `cabal build` and `cabal test` in `cli/nagarectl`; run `cabal test` in
`cli/nagare-dsl` only if a DSL file was touched (this plan touches no DSL source).
