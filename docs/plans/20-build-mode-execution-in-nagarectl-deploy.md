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

Full plan before trimming: [20-build-mode-execution-in-nagarectl-deploy.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/20-build-mode-execution-in-nagarectl-deploy.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] Milestone 1: `Nagare.Image` gains a pure `dockerBuildArgs` builder and a `buildDockerfile` runner; `cabal build` passes.
- [x] Milestone 2: new `Nagare.Build` dispatch module (prebuilt no-op, Dockerfile build, Nixpacks stub) exposed from the cabal file.
- [x] Milestone 3: `runDeploy` reads `dep ^. #build`, computes the ref via `resolveImageTag`, and dispatches on `requiresBuild`; dry-run prints the planned build action.
- [x] Milestone 4: `--dockerfile` and `--context` become optional overrides validated against the build mode.
- [x] Milestone 5: CLI tests for `dockerBuildArgs` and override resolution pass; a prebuilt and a Dockerfile deploy are verified end-to-end (or by dry-run where a cluster is unavailable).

## Surprises & Discoveries

- The override-misuse error reaches the user prefixed `nagarectl:` (via the CLI's
  existing `dieT`/`orDie`), not `nagare:` as the plan's Concrete-Steps transcript
  sketched. `resolveBuildSpec` calls `orDie (applyBuildOverrides ...)`, and `orDie`
  goes through `dieT`, which is the established CLI convention. The `nagare:`
  prefix is reserved for the in-`Nagare.Build` `die` used by the Nixpacks
  not-yet-supported message (which is raised from inside `performBuild`, outside
  the CLI's `dieT` path). Both are clear; no change made.

- The CLI library did not previously depend on `containers`; `Nagare.Build` uses
  `Data.Map.toList`, so `containers` was added to the library `build-depends`.

- Relevant for EP-22's prebuilt example: a config run by the loader's `runghc`
  compiles under `-XGHC2024` only (see `Nagare.Dsl.Load.runConfig`), which does
  **not** enable `OverloadedLabels`. A prebuilt config that overrides the preset's
  `build` field must therefore use a record update (`base {build = PrebuiltImage
  t}`) or declare `{-# LANGUAGE OverloadedLabels #-}` itself — the `#build` lens is
  not available by default. Verified by dry-run against a throwaway fixture.

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

Delivered. `nagarectl deploy` now reads the typed `build` field and dispatches:
`Nagare.Image` gained the pure `dockerBuildArgs` and the `buildDockerfile` runner;
a new `Nagare.Build` module provides `performBuild` (prebuilt no-op, Dockerfile
build with `-f`/`--build-arg`, Nixpacks stub that exits with a pointer to EP-21),
`describeBuild` (the `--dry-run` line), and the pure `applyBuildOverrides`. The
`deploy` parser's `--context`/`-c` is now an optional override and a new
`--dockerfile` override was added; `resolveBuildSpec` applies them and rejects
misuse. `runDeploy` skips build/push for a prebuilt image and computes the push
reference via `resolveImageTag`.

`cabal test` passes (49 tests, new `Nagare.Build` group: `dockerBuildArgs`
ordering, `describeBuild` strings, and `applyBuildOverrides` including the
prebuilt-with-override and Nixpacks-`--dockerfile` errors). End-to-end dry-run
verified for all four cases (prebuilt renders its own tag and reports "no local
build"; Dockerfile reports the `docker build -f` line and honors `-c`; prebuilt +
`-c` exits 1). The static/server deploy paths still pass — they keep using the
retained `Nagare.Image.buildImage`. A real cluster deploy was not exercised in
this session (no cluster reachable); the dry-run transcripts stand in per the
plan's acceptance allowance.

