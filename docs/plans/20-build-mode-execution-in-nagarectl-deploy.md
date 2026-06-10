---
id: 20
slug: build-mode-execution-in-nagarectl-deploy
title: "Build-mode execution in nagarectl deploy"
kind: exec-plan
created_at: 2026-06-09T23:51:00Z
intention: "intention_01ktqcgfx8end8kwp5ejmy0k6q"
master_plan: "docs/masterplans/4-application-build-modes-for-nagare.md"
---

# Build-mode execution in nagarectl deploy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This is the second plan under the MasterPlan
`docs/masterplans/4-application-build-modes-for-nagare.md` ("Application Build Modes for Nagare").
It makes the build modes from `docs/plans/19-typed-buildspec-model-and-dsl-integration.md` actually
do something when a developer runs `nagarectl deploy`.

Before this plan, `nagarectl deploy` always builds an image with `docker build -t <image:tag> .`
regardless of what the config says — the build step is hardcoded. After this plan, the CLI reads
the new `build` field off the loaded `Deployment` and dispatches: a **prebuilt image** is deployed
with no local build or push at all (the image already lives in a registry); a **Dockerfile build**
runs `docker build` with the Dockerfile path, build context, and `--build-arg` build arguments named
in the config; and a **Nixpacks build** stops with a clear "not yet supported" message that points
to the plan that will implement it (`docs/plans/21-nixpacks-zero-dockerfile-builder.md`).

You can see it working three ways without finishing the Nixpacks plan. First, `nagarectl deploy
--dry-run` prints, in addition to the rendered manifests, a one-line description of the build action
it *would* take ("Build mode: prebuilt image (no local build)", "Build mode: docker build -f
Dockerfile <ctx>", or "Build mode: nixpacks — not yet supported"). Second, a real deploy of a
config whose `build` is `PrebuiltImage` applies the Knative Service and skips Docker entirely, and
the running service serves the prebuilt image. Third, a real deploy of a `DockerfileBuild` config
with a non-default Dockerfile path or a build argument shows those reflected in the `docker build`
command line.

Terms used here. **`nagarectl`** is the deploy CLI in `cli/nagarectl`; its entry point is
`cli/nagarectl/app/Main.hs`. A **build context** is the directory `docker build` reads as its
working set (the final argument to `docker build`). A **build argument** (`--build-arg KEY=VALUE`)
is a value passed into a Dockerfile's `ARG` declarations at build time. **`cradle`** is the Haskell
library this CLI uses to shell out to external programs; calls look like
`run_ $ cmd "docker" & addArgs [...]`. **`optparse-applicative`** is the command-line parser
library; subcommands and flags are declared as `Parser` values in `Main.hs`.


## Progress

- [ ] Milestone 1: `Nagare.Image` gains a pure `dockerBuildArgs` builder and a `buildDockerfile` runner; `cabal build` passes.
- [ ] Milestone 2: new `Nagare.Build` dispatch module (prebuilt no-op, Dockerfile build, Nixpacks stub) exposed from the cabal file.
- [ ] Milestone 3: `runDeploy` reads `dep ^. #build`, computes the ref via `resolveImageTag`, and dispatches on `requiresBuild`; dry-run prints the planned build action.
- [ ] Milestone 4: `--dockerfile` and `--context` become optional overrides validated against the build mode.
- [ ] Milestone 5: CLI tests for `dockerBuildArgs` and override resolution pass; a prebuilt and a Dockerfile deploy are verified end-to-end (or by dry-run where a cluster is unavailable).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Put build dispatch in a new module `Nagare.Build` (`cli/nagarectl/src/Nagare/Build.hs`),
  separate from `Nagare.Image`.
  Rationale: `Nagare.Image` holds Docker/registry primitives (tag, build, auth, push). Dispatch over
  the typed `BuildSpec` is a higher-level concern that also has to refuse Nixpacks for now and will
  grow the Nixpacks branch in EP-21. Keeping it separate gives EP-21 one obvious place to edit and
  keeps `Nagare.Image` free of `nagare-dsl` build-mode types.
  Date: 2026-06-09

- Decision: The config's `build` field is authoritative; `--context`/`-c` and a new `--dockerfile`
  flag are optional *overrides*, valid only for build modes.
  Rationale: Typed-config-first means the build is described in `Config.hs`, not reconstructed from
  flags on every invocation. Overrides remain for ad-hoc cases (e.g. building from a subdirectory)
  and preserve the existing `-c DIR` behavior for anyone who used it. Passing an override with a
  `PrebuiltImage` config is a user error and is rejected with a clear message rather than silently
  ignored.
  Date: 2026-06-09

- Decision: Make the Docker argument construction a pure function (`dockerBuildArgs`) so it can be
  unit-tested without invoking Docker.
  Rationale: The CLI test suite (`cli/nagarectl/test/Spec.hs`) does not mock subprocesses; it tests
  pure logic. Exposing the arg list as data lets us assert that `-f`, `-t`, `--build-arg`, and the
  context appear in the right order without running `docker`.
  Date: 2026-06-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/nagare`.

This plan depends on `docs/plans/19-typed-buildspec-model-and-dsl-integration.md` being complete. By
then the `nagare-dsl` package exports, from `Nagare.Dsl.Build`:

```haskell
data BuildSpec
  = PrebuiltImage Tag
  | DockerfileBuild { dockerfile :: !FilePathText, context :: !FilePathText, buildArgs :: !(Map Text Text) }
  | NixpacksBuild   { context :: !FilePathText, buildArgs :: !(Map Text Text) }

resolveImageTag :: BuildSpec -> Text -> Text   -- prebuilt -> its own tag; else the deploy tag
requiresBuild   :: BuildSpec -> Bool           -- False only for PrebuiltImage
tagText :: Tag -> Text
```

and `Nagare.Dsl.Types.Deployment` has a `build :: !BuildSpec` field, read with `dep ^. #build`.
`FilePathText`/`mkFilePathText`/`filePathText` come from `Nagare.Dsl.Static.Types`.

The CLI package is `cli/nagarectl`. Key files:

- `cli/nagarectl/app/Main.hs` — the entry point. The `deploy` path is `runDeploy :: DeployOpts -> IO ()`,
  which today reads:

  ```haskell
  runDeploy dopts = do
    bd <- resolveBaseDomain (dopts ^. #baseDomain)
    provisionGhcEnv (dopts ^. #ghcEnv)
    edep <- Load.loadDeployment (dopts ^. #file)
    dep <- case edep of
      Left err -> dieT (Load.renderLoadError err)
      Right d -> pure d
    imageTag <- resolveTag (dopts ^. #tag)
    let ref = imageRef dep imageTag
        svcBytes = renderService dep imageTag
        dmBytes = maybeToList (renderDomainMapping dep)
        url = serviceUrl dep bd
        name = serviceNameText (dep ^. #name)
        ns = namespaceText (dep ^. #namespace)
    if dopts ^. #dryRun
      then do ... print manifests + URL ...
      else do
        configureDockerAuth
        buildImage ref (dopts ^. #context)
        pushImage ref
        applyManifests (svcBytes : dmBytes)
        waitForReady name ns
        TIO.putStrLn ("Deployed: " <> url)
  ```

  The `DeployOpts` record (also in `Main.hs`) is:

  ```haskell
  data DeployOpts = DeployOpts
    { file :: !FilePath
    , tag :: !(Maybe String)
    , baseDomain :: !(Maybe String)
    , context :: !FilePath
    , ghcEnv :: !(Maybe FilePath)
    , dryRun :: !Bool
    }
  ```

  and its parser `deployOptsParser` defines `--context`/`-c` with `value "."`. `dieT :: Text -> IO a`
  prints to stderr and exits non-zero.

- `cli/nagarectl/src/Nagare/Image.hs` — Docker primitives. Today:

  ```haskell
  imageRef :: Deployment -> Text -> Text                 -- dep.image <> ":" <> tag
  taggedImageRef :: ImageRef -> Text -> Text
  buildImage :: Text -> FilePath -> IO ()                -- docker build -t <ref> <context>
  configureDockerAuth :: IO ()                           -- gcloud auth configure-docker ...
  pushImage :: Text -> IO ()                             -- docker push <ref>
  computeTag :: IO Text                                  -- UTC YYYYMMDD-HHMMSS
  ```

  `buildImage` runs `run_ $ cmd "docker" & addArgs ["build", "-t", T.unpack ref, context]`.

- `cli/nagarectl/nagarectl.cabal` — declares the library `exposed-modules` (add `Nagare.Build`
  here), the `nagarectl` executable, and the `nagarectl-test` test suite (tasty/HUnit). It already
  depends on `nagare-dsl`, `cradle`, `optparse-applicative`, and `text`.

- `cli/nagarectl/test/Spec.hs` — tasty test groups. Tests are pure or use temp directories; there is
  no subprocess mocking. You will add a `Nagare.Build` group.

Non-obvious detail: the renderer change from EP-19 means `renderService dep imageTag` already
produces the correct image string for a prebuilt deployment (it internally calls `resolveImageTag`).
So `runDeploy` keeps passing the raw deploy `imageTag` to `renderService`, and only the *build/push*
path needs the resolved tag.


## Plan of Work

### Milestone 1 — Docker argument builder and Dockerfile-aware build

In `cli/nagarectl/src/Nagare/Image.hs`, add a pure function that constructs the `docker build`
argument vector, and a runner that uses it. Keep the existing `buildImage` for now (other call
sites — static/server deploy — still use it) and add:

```haskell
-- | The argument vector for @docker build@ with an explicit Dockerfile, build
-- args, tag, and context. Pure so it can be unit-tested without Docker.
dockerBuildArgs :: Text -> FilePath -> FilePath -> [(Text, Text)] -> [String]
dockerBuildArgs ref dockerfile context args =
  ["build", "-f", dockerfile, "-t", T.unpack ref]
    <> concatMap (\(k, v) -> ["--build-arg", T.unpack (k <> "=" <> v)]) args
    <> [context]

-- | Run @docker build@ with an explicit Dockerfile path, build args, and context.
buildDockerfile :: Text -> FilePath -> FilePath -> [(Text, Text)] -> IO ()
buildDockerfile ref dockerfile context args =
  run_ $ cmd "docker" & addArgs (dockerBuildArgs ref dockerfile context args)
```

Export both from the module's export list. Acceptance: `cabal build` passes and
`dockerBuildArgs "r" "Dockerfile" "." [("A","1")]` equals
`["build","-f","Dockerfile","-t","r","--build-arg","A=1","."]`.

### Milestone 2 — The `Nagare.Build` dispatch module

Create `cli/nagarectl/src/Nagare/Build.hs` and add `Nagare.Build` to `exposed-modules` in
`cli/nagarectl/nagarectl.cabal`. It dispatches over a `BuildSpec`:

```haskell
module Nagare.Build (performBuild, describeBuild, applyBuildOverrides) where

import Nagare.Dsl.Build (BuildSpec (..), tagText)
import Nagare.Dsl.Static.Types (filePathText, mkFilePathText)
import Nagare.Image (buildDockerfile)
import qualified Data.Map as Map
import qualified Data.Text as T
-- plus Text + a local die :: Text -> IO a

-- | Build the image for a build mode that requires building (Dockerfile or
-- Nixpacks). Precondition: 'requiresBuild' is True — 'PrebuiltImage' is handled
-- by the caller (no build). 'NixpacksBuild' is not yet supported and exits with a
-- clear message (implemented in docs/plans/21-...).
performBuild :: BuildSpec -> Text -> IO ()
performBuild spec ref = case spec of
  PrebuiltImage _ -> pure ()   -- defensive; caller skips via requiresBuild
  DockerfileBuild df ctx args ->
    buildDockerfile ref (T.unpack (filePathText df)) (T.unpack (filePathText ctx)) (Map.toList args)
  NixpacksBuild _ _ ->
    die "nagare: nixpacks build mode is not yet supported (see docs/plans/21-nixpacks-zero-dockerfile-builder.md)"

-- | A one-line, human-readable description of the build action, for --dry-run.
describeBuild :: BuildSpec -> Text
describeBuild = \case
  PrebuiltImage t   -> "prebuilt image (no local build), tag " <> tagText t
  DockerfileBuild df ctx _ -> "docker build -f " <> filePathText df <> " " <> filePathText ctx
  NixpacksBuild ctx _ -> "nixpacks build " <> filePathText ctx <> " — NOT YET SUPPORTED"
```

`applyBuildOverrides` is the pure core of the override logic (Milestone 4). Use a local `die`
(writes to stderr, calls `exitFailure`) or the CLI's existing `dieT` if it is moved to a shared
module; record the choice in the Decision Log. Acceptance: `cabal build` passes; `describeBuild`
returns the expected strings for each variant.

### Milestone 3 — Wire dispatch into `runDeploy`

Edit `runDeploy` in `cli/nagarectl/app/Main.hs`. Import `requiresBuild`, `resolveImageTag` from
`Nagare.Dsl.Build` and `performBuild`, `describeBuild` from `Nagare.Build`. Replace the build block:

```haskell
  imageTag <- resolveTag (dopts ^. #tag)
  spec <- resolveBuildSpec dopts (dep ^. #build)   -- applies overrides; Milestone 4
  let effTag = resolveImageTag spec imageTag
      ref = imageRef dep effTag
      svcBytes = renderService dep imageTag         -- renderer resolves the tag itself
      dmBytes = maybeToList (renderDomainMapping dep)
      ...
  if dopts ^. #dryRun
    then do
      ... existing manifest prints ...
      TIO.putStrLn ("Build mode: " <> describeBuild spec)
      TIO.putStrLn ("URL: " <> url)
    else do
      if requiresBuild spec
        then do
          configureDockerAuth
          performBuild spec ref
          pushImage ref
        else TIO.putStrLn "Skipping build/push: deploying prebuilt image."
      applyManifests (svcBytes : dmBytes)
      waitForReady name ns
      TIO.putStrLn ("Deployed: " <> url)
```

For Milestone 3 you may stub `resolveBuildSpec dopts spec = pure spec` (ignore overrides) so the core
dispatch is testable first; Milestone 4 fills it in. Acceptance: `nagarectl deploy --dry-run` against
a prebuilt-image fixture prints `Build mode: prebuilt image ...` and a Knative manifest whose image
ends with the prebuilt tag; against a Dockerfile fixture it prints `Build mode: docker build -f ...`.

### Milestone 4 — Optional `--dockerfile` / `--context` overrides

Change `DeployOpts` so the override flags are optional and add a Dockerfile override:

```haskell
data DeployOpts = DeployOpts
  { file :: !FilePath
  , tag :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  , contextOverride :: !(Maybe FilePath)
  , dockerfileOverride :: !(Maybe FilePath)
  , ghcEnv :: !(Maybe FilePath)
  , dryRun :: !Bool
  }
```

Update `deployOptsParser`: make `--context`/`-c` an `optional (strOption ...)` (drop the `value "."`),
and add `--dockerfile` as `optional (strOption (long "dockerfile" <> metavar "FILE" <> help "Override the Dockerfile path from the config"))`.
Implement the pure core and an IO wrapper:

```haskell
-- Apply CLI overrides to the config's build spec. Overrides are valid only for
-- build modes; supplying one with a prebuilt image is a user error.
applyBuildOverrides :: Maybe FilePath -> Maybe FilePath -> BuildSpec -> Either Text BuildSpec

resolveBuildSpec :: DeployOpts -> BuildSpec -> IO BuildSpec   -- in Main.hs; wraps applyBuildOverrides + dieT
```

`applyBuildOverrides ctxOverride dfOverride spec` returns the spec unchanged when both overrides are
`Nothing`. For `DockerfileBuild`/`NixpacksBuild` it re-validates any override path with
`mkFilePathText` and substitutes the field (`NixpacksBuild` has no `dockerfile`, so a `--dockerfile`
override against it is an error). For `PrebuiltImage`, any `Just` override yields
`Left "nagare: --context/--dockerfile cannot be used with a prebuilt-image config"`. Wire
`resolveBuildSpec dopts (dep ^. #build)` into `runDeploy`. Acceptance: `-c sub/dir` with a Dockerfile
config changes the build context in the `--dry-run` description; `-c x` with a prebuilt config exits 1
with the override error.

### Milestone 5 — Tests and end-to-end verification

Add a `Nagare.Build` test group to `cli/nagarectl/test/Spec.hs` covering: `dockerBuildArgs` ordering
with and without build args; `describeBuild` strings per variant; and `applyBuildOverrides` —
overrides applied to a Dockerfile spec, the prebuilt-with-override error, and a `--dockerfile`
override against a Nixpacks spec erroring. Run `cabal test`. Then exercise the CLI against fixtures
(see Concrete Steps): a prebuilt and a Dockerfile config under `--dry-run`, and, if a cluster is
reachable, a real prebuilt deploy that skips Docker.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Build and test the CLI after each milestone:

```bash
cd cli/nagarectl
cabal build
cabal test
```

Create two throwaway config fixtures to exercise dry-run (a prebuilt image and a Dockerfile build).
For example, a prebuilt config emits a `Deployment` whose `build = PrebuiltImage <mkTag "v1">` and
whose `image` is a public repo; a Dockerfile config uses `webService` (which now defaults to a
Dockerfile build) and overrides nothing. Then:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
# Prebuilt: no Docker, image keeps its own tag
cabal --project-dir=cli/nagarectl run nagarectl -- deploy -f /tmp/prebuilt/nagare/Config.hs --dry-run
```

Expected (illustrative — the manifest is abbreviated):

```text
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
...
        image: ghcr.io/acme/web:v1
Build mode: prebuilt image (no local build), tag v1
URL: https://web.apps.<base-domain>
```

```bash
# Dockerfile build with an override
cabal --project-dir=cli/nagarectl run nagarectl -- deploy -f /tmp/app/nagare/Config.hs -c services/web --dry-run
```

Expected line:

```text
Build mode: docker build -f Dockerfile services/web
```

```bash
# Override misuse on a prebuilt config exits 1
cabal --project-dir=cli/nagarectl run nagarectl -- deploy -f /tmp/prebuilt/nagare/Config.hs -c x --dry-run; echo "exit=$?"
```

Expected:

```text
nagare: --context/--dockerfile cannot be used with a prebuilt-image config
exit=1
```

The exact `cabal run` invocation may differ in this repo; if a wrapper or `just`/`make` target builds
`nagarectl`, use it. The `NAGARE_GHC_ENVIRONMENT` / `--ghc-env` mechanism documented in
`docs/plans/10-config-surface-and-loading-for-the-chosen-substrate.md` is required for the loader's
`runghc` to find `nagare-dsl` when running a fixture config.


## Validation and Acceptance

Beyond compilation, acceptance is behavioral: `cabal test` in `cli/nagarectl` passes with the new
`Nagare.Build` group, proving `dockerBuildArgs` emits `-f`, `-t`, `--build-arg`, and the context in
the correct order, that `describeBuild` produces the expected per-mode strings, and that
`applyBuildOverrides` applies to build modes and rejects prebuilt-with-override. The `--dry-run`
transcripts above prove the dispatch is wired: a prebuilt config reports "no local build" and renders
the prebuilt tag; a Dockerfile config reports a `docker build -f` command reflecting any `-c`
override; a Nixpacks config reports "NOT YET SUPPORTED". If a cluster is reachable, a real prebuilt
deploy completes without invoking `docker` (observable because no image is pushed and the Knative
Service references the upstream image), and a real Dockerfile deploy builds, pushes, and becomes
Ready. The existing static-site and server-site deploy paths must continue to pass their tests,
proving the shared `Nagare.Image.buildImage` they use was not broken.


## Idempotence and Recovery

All source edits are additive and re-runnable; `cabal build`/`cabal test` are safe to repeat.
`--dry-run` has no side effects, so it can be run freely while iterating. A real deploy is idempotent
the same way the existing deploy is: re-running re-applies the Knative Service (kubectl apply is
declarative) and, for build modes, rebuilds and re-pushes under a fresh tag. A prebuilt deploy that
references a missing image fails at the Knative readiness wait (`waitForReady`) with an image-pull
error, not at the CLI; the recovery is to fix the `image`/`tag` in the config and redeploy. Because
`Nagare.Image.buildImage` is retained unchanged, the static/server paths are unaffected and need no
rollback.


## Interfaces and Dependencies

No new package dependencies; `cradle`, `optparse-applicative`, `text`, `containers`, and `nagare-dsl`
are already in `cli/nagarectl/nagarectl.cabal`.

Signatures that must exist at the end of this plan:

In `Nagare.Image` (`cli/nagarectl/src/Nagare/Image.hs`):

```haskell
dockerBuildArgs :: Text -> FilePath -> FilePath -> [(Text, Text)] -> [String]
buildDockerfile :: Text -> FilePath -> FilePath -> [(Text, Text)] -> IO ()
```

In `Nagare.Build` (`cli/nagarectl/src/Nagare/Build.hs`):

```haskell
performBuild :: BuildSpec -> Text -> IO ()
describeBuild :: BuildSpec -> Text
applyBuildOverrides :: Maybe FilePath -> Maybe FilePath -> BuildSpec -> Either Text BuildSpec
```

The `performBuild` signature is consumed by `docs/plans/21-nixpacks-zero-dockerfile-builder.md`,
which replaces the `NixpacksBuild` branch with a real `nixpacks build` invocation. Do not change this
signature without updating that plan. `runDeploy` in `cli/nagarectl/app/Main.hs` is the sole caller of
`performBuild`/`describeBuild`/`resolveBuildSpec` and is updated in place; its type stays
`runDeploy :: DeployOpts -> IO ()`.
