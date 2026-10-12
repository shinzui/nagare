---
id: 21
slug: nixpacks-zero-dockerfile-builder
title: "Nixpacks zero-Dockerfile builder"
kind: exec-plan
created_at: 2026-06-09T23:51:00Z
intention: "intention_01ktqcgfx8end8kwp5ejmy0k6q"
master_plan: "docs/masterplans/4-application-build-modes-for-nagare.md"
---

# Nixpacks zero-Dockerfile builder

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [21-nixpacks-zero-dockerfile-builder.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/21-nixpacks-zero-dockerfile-builder.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

This is the third plan under the MasterPlan
`docs/masterplans/4-application-build-modes-for-nagare.md` ("Application Build Modes for Nagare").
It turns the `NixpacksBuild` variant — which exists as a type after
`docs/plans/19-typed-buildspec-model-and-dsl-integration.md` and is rejected with a "not yet
supported" message after `docs/plans/20-build-mode-execution-in-nagarectl-deploy.md` — into a real,
working build mode.

The user-visible outcome: a developer can deploy an application that has **no Dockerfile at all**.
They point `nagarectl deploy` at a directory containing, say, a Go module, a `package.json`, a
`requirements.txt`, or a `Cargo.toml`, set `build = NixpacksBuild { context = ".", buildArgs = ... }`
in their `nagare/Config.hs`, and the CLI runs **Nixpacks** — an open-source tool that inspects the
source tree, detects the language and framework, and produces a runnable OCI container image — then
pushes that image to Artifact Registry and deploys it as a Knative Service exactly like the
Dockerfile path. The developer never writes a `FROM`, `RUN`, or `CMD` line.

Because Nixpacks is an external tool whose behavior must be validated on the host before we rely on
it, this plan begins with a **feasibility spike**: a small, throwaway experiment that builds a sample
app with `nixpacks` by hand and confirms the produced image runs and serves traffic on the expected
port. Only after the spike succeeds do we wire `nixpacks` into the CLI. You can see the finished work
by deploying one of the example apps (added in
`docs/plans/22-build-modes-docs-and-end-to-end-examples.md`, or a throwaway here) with no Dockerfile
and watching the Knative URL serve the app.

Terms. **Nixpacks** is a CLI (`nixpacks`) from the Railway project; `nixpacks build <dir> --name
<image:tag>` builds an image locally via the Docker daemon (or BuildKit) and tags it. **OCI image**
is the standard container image format Docker and Knative both understand. **Artifact Registry** is
the Google-hosted container registry Nagare pushes to (`us-west1-docker.pkg.dev`). A **build
argument** here maps to a Nixpacks build-time environment variable (`--env KEY=VALUE`), the closest
analogue to a Dockerfile `--build-arg`.

## Progress

- [x] Milestone 1 (spike): `nixpacks` is available on the build host; a sample app builds to an image that runs and serves on its port; findings recorded in Surprises & Discoveries.
- [x] Milestone 2: `Nagare.Image` gains `nixpacksBuildArgs` (pure) and `buildNixpacks` (runner); `cabal build` passes.
- [x] Milestone 3: the `NixpacksBuild` branch of `Nagare.Build.performBuild` invokes `buildNixpacks` instead of dying; `describeBuild` drops the "NOT YET SUPPORTED" note.
- [x] Milestone 4: host prerequisite (installing `nixpacks`) documented (developer-machine install) and guarded by a `nixpacks`-on-PATH preflight check.
- [x] Milestone 5: tests for `nixpacksBuildArgs` pass; a zero-Dockerfile app builds, tags, and pushes end-to-end (cluster apply deferred — local kube-context is not a Knative cluster).

## Surprises & Discoveries

Spike findings (full note: `docs/spikes/ep21-nixpacks-spike.md`):

- `nixpacks` **1.41.0**, obtained via `nix-shell -p nixpacks` (it was not on the bare `PATH`).
- It **requires the Docker daemon** — `nixpacks build` drives BuildKit through Docker (the build
  log exports to `docker.io/library/...`). No standalone BuildKit needed.
- **Port:** Nixpacks does not hard-code a port. For Node it runs the `package.json` `start` script
  and the app binds `$PORT` (default 8080). This composes cleanly with Knative, which injects `PORT`
  = the container port, so a Nixpacks image listens correctly with no extra config (as long as the
  app honors `$PORT`).
- **`--name image:tag` builds and locally tags but does not push** — exactly the contract
  `performBuild` needs (build/tag `ref`, then `runDeploy` calls the existing `pushImage ref`).
- **`--env KEY=VALUE`** is the build-time-env analogue of `--build-arg`; `buildArgs` maps to it.
- A harmless BuildKit warning (`UndefinedVar: $NIXPACKS_PATH`) appears but the build succeeds.

End-to-end (Milestone 5): a real `nagarectl deploy` of a Dockerfile-free Node app ran
`nixpacks build`, locally tagged the image, **and pushed all layers to Artifact Registry in
`tan-nb-exp`** successfully. The run stopped only at `kubectl apply` ("no matches for kind Service
in serving.knative.dev/v1") because the local kube-context is not a Knative cluster — the cluster
step, not the build/push, which both succeeded. All throwaway artifacts (local image, the pushed
`:e2e-local` registry image, the sample) were removed afterward.

The `nixpacks`-on-PATH preflight (`ensureNixpacks` in `Nagare.Build`) was verified: a real deploy
on a host without `nixpacks` prints `nagare: nixpacks not found on PATH; see
docs/user/build-modes.md` rather than a raw "command not found".

## Decision Log

- Decision: Begin with a feasibility spike (Milestone 1) before writing any CLI code.
  Rationale: Nixpacks is an external dependency whose port detection, image entrypoint, and host
  requirements (Docker daemon access, network for downloading providers) are not yet proven on the
  Nagare host. The ExecPlan specification encourages prototyping milestones that de-risk a larger
  change; proving `nixpacks build` works by hand first means the CLI wiring is mechanical.
  Date: 2026-06-09

- Decision: Map a `NixpacksBuild` `buildArgs` entry to `nixpacks build --env KEY=VALUE`.
  Rationale: Nixpacks has no `--build-arg`; build-time configuration is passed as environment
  variables, which is the natural analogue. This keeps the typed `buildArgs :: Map Text Text` field
  meaningful for both Dockerfile and Nixpacks modes.
  Date: 2026-06-09

- Decision: The `nixpacks` host prerequisite is a **developer-machine install**, documented in the
  user guide (EP-22), not added to the NixOS host module.
  Rationale: App image builds run wherever `nagarectl deploy` is invoked. The NixOS host
  (`nagare-01`) runs k3s and serves the cluster; it does not run `nagarectl deploy` for app images,
  and `nagared` (the static-site webhook runner) shells to `nagarectl site deploy`, which uses the
  static Docker build, not Nixpacks. Adding `nixpacks` to the host module would imply the VM builds
  app images, which it does not. Instead, a preflight check (`ensureNixpacks`) gives an actionable
  message pointing at `docs/user/build-modes.md` when `nixpacks` is missing.
  Date: 2026-06-09

## Outcomes & Retrospective

Delivered. The `NixpacksBuild` variant is now a real, working build mode. The feasibility spike
(`docs/spikes/ep21-nixpacks-spike.md`) confirmed `nixpacks` 1.41.0 builds a Dockerfile-free app to a
runnable image on the host. `Nagare.Image` gained the pure `nixpacksBuildArgs` and the
`buildNixpacks` runner (`nixpacks build <ctx> --name <ref> [--env K=V ...]`); the `NixpacksBuild`
branch of `Nagare.Build.performBuild` now builds via `buildNixpacks` after a `nixpacks`-on-PATH
preflight, and `describeBuild` no longer says "NOT YET SUPPORTED".

`cabal test` passes (52 tests; new `nixpacksBuildArgs` cases). The headline proof: a real
`nagarectl deploy` of a Dockerfile-free Node app ran `nixpacks build`, locally tagged the image, and
pushed every layer to Artifact Registry in `tan-nb-exp` — the deploy stopped only at the Knative
apply because the local kube-context is not a Knative cluster. The Dockerfile and prebuilt modes are
untouched.

Host prerequisite: a developer-machine `nixpacks` install (not a NixOS host change), guarded by the
`ensureNixpacks` preflight and to be documented in EP-22's user guide.

