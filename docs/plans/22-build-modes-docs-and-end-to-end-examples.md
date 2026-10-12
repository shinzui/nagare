---
id: 22
slug: build-modes-docs-and-end-to-end-examples
title: "Build-modes docs and end-to-end examples"
kind: exec-plan
created_at: 2026-06-09T23:51:00Z
intention: "intention_01ktqcgfx8end8kwp5ejmy0k6q"
master_plan: "docs/masterplans/4-application-build-modes-for-nagare.md"
---

# Build-modes docs and end-to-end examples

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [22-build-modes-docs-and-end-to-end-examples.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/22-build-modes-docs-and-end-to-end-examples.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

This is the fourth and final plan under the MasterPlan
`docs/masterplans/4-application-build-modes-for-nagare.md` ("Application Build Modes for Nagare").
The build-mode behavior is implemented by
`docs/plans/19-typed-buildspec-model-and-dsl-integration.md` (the typed model),
`docs/plans/20-build-mode-execution-in-nagarectl-deploy.md` (the CLI execution), and
`docs/plans/21-nixpacks-zero-dockerfile-builder.md` (the Nixpacks builder). This plan makes that
behavior **discoverable and learnable**: it writes the user guide and the runnable example projects
so a developer who has never seen the feature can choose a build mode and deploy.

After this plan, a developer can open `docs/user/build-modes.md`, read what each of the three modes
(prebuilt image, Dockerfile build, Nixpacks build) is for, copy the matching example project from
`cluster/examples/`, change the name and image, and run `nagarectl deploy`. The existing
`docs/user/deploying-apps.md` gains a short section pointing at build modes, and
`docs/user/config-reference.md` gains the `BuildSpec` constructors so the typed surface is fully
documented. The proof this plan works is that each example deploys (or dry-runs) successfully by
following only the words in the guide.

Terms. A **build mode** is the value of the new `build` field on a `Deployment`: `PrebuiltImage`
(deploy an existing image), `DockerfileBuild` (build from a Dockerfile), or `NixpacksBuild` (build
from source with no Dockerfile). An **example project** under `cluster/examples/<name>/` is a small,
self-contained directory with a `nagare/Config.hs` (and any source/Dockerfile it needs) that a reader
can deploy as-is. The **config reference** (`docs/user/config-reference.md`) is the catalog of every
typed constructor a `Config.hs` author can use.

## Progress

- [x] Milestone 1: `cluster/examples/prebuilt-image-app/` — a deployable prebuilt-image example.
- [x] Milestone 2: `cluster/examples/dockerfile-app/` — a deployable Dockerfile-build example with a real Dockerfile and a build arg.
- [x] Milestone 3: `cluster/examples/nixpacks-app/` — a deployable zero-Dockerfile example (depends on EP-21).
- [x] Milestone 4: `docs/user/build-modes.md` written, covering all three modes with copyable configs and commands.
- [x] Milestone 5: `docs/user/deploying-apps.md` and `docs/user/config-reference.md` updated; cross-links added; every example dry-run/deploy verified against the docs.

## Surprises & Discoveries

- All three example configs use a **record update** on the `webService` result
  (`base {build = ...}`) rather than the `#build` lens, because the loader runs
  configs with `runghc -XGHC2024`, which does not enable `OverloadedLabels`
  (carried over from EP-20's discovery). The migration note in `build-modes.md`
  and the example comments call this out so readers don't reach for `#build`.

- The Dockerfile example serves on **8080** with `python -m http.server 8080`
  (the `python:3.12-alpine` base), so the built image matches the config's
  `port 8080` with no extra nginx/port wiring — kept the example minimal while
  still exercising a real `--build-arg` (verified by a local `docker build`).

## Decision Log

- Decision: One example project per build mode under `cluster/examples/`, alongside the existing
  `preset-app-a`, `static-site`, and `tanstack-start` examples.
  Rationale: The repo already teaches features through runnable `cluster/examples/*` projects; build
  modes should follow the same convention so readers learn by copying a working directory rather than
  assembling snippets.
  Date: 2026-06-09

- Decision: Keep build-mode documentation in a dedicated `docs/user/build-modes.md` rather than
  expanding `deploying-apps.md` in place.
  Rationale: `deploying-apps.md` is the general app-deploy walkthrough; build modes are a focused
  sub-topic that benefits from its own page with one section per mode. `deploying-apps.md` links to it.
  Date: 2026-06-09

## Outcomes & Retrospective

Delivered. Three runnable examples live under `cluster/examples/`:
`prebuilt-image-app` (a public image deployed by tag), `dockerfile-app` (a real
`Dockerfile` + a `SITE_MESSAGE` build arg), and `nixpacks-app` (a Dockerfile-free
Node app). Each has a `README.md` with the deploy command and expected output. The
user guide `docs/user/build-modes.md` documents all three modes with copyable
configs, the `--dockerfile`/`--context` overrides, the Nixpacks prerequisite, and
the migration note for the new `build` field. `docs/user/config-reference.md`
gained a "Build modes" section (`BuildSpec`, `Tag`/`mkTag`, `FilePathText`,
`defaultBuild`, the `build` field); `docs/user/deploying-apps.md` gained a "Build
modes" subsection, an updated flags table (`--dockerfile`; `--context` is now an
override), an updated deploy-steps description, and a corrected `hello` literal
that includes `build`; and `docs/user/README.md` indexes the new page.

Verification: all three examples dry-run with the exact `Build mode:` lines and
image strings the guide shows (prebuilt renders `:latest`, Dockerfile and Nixpacks
render the deploy timestamp). The Dockerfile example's build arg was confirmed by a
local `docker build` (the message is baked into the served page). Every internal
`build-modes.md` link resolves. Both test suites stay green (135 + 52).

