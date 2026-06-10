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

- [ ] Milestone 1: `cluster/examples/prebuilt-image-app/` — a deployable prebuilt-image example.
- [ ] Milestone 2: `cluster/examples/dockerfile-app/` — a deployable Dockerfile-build example with a real Dockerfile and a build arg.
- [ ] Milestone 3: `cluster/examples/nixpacks-app/` — a deployable zero-Dockerfile example (depends on EP-21).
- [ ] Milestone 4: `docs/user/build-modes.md` written, covering all three modes with copyable configs and commands.
- [ ] Milestone 5: `docs/user/deploying-apps.md` and `docs/user/config-reference.md` updated; cross-links added; every example dry-run/deploy verified against the docs.


## Surprises & Discoveries

(None yet.)


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

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/nagare`.

This plan hard-depends on `docs/plans/20-build-mode-execution-in-nagarectl-deploy.md` (so the prebuilt
and Dockerfile examples actually deploy) and soft-depends on
`docs/plans/21-nixpacks-zero-dockerfile-builder.md` (the Nixpacks example only fully deploys once
Nixpacks is real; until then its section is marked experimental and points at EP-21). The
prebuilt/Dockerfile examples and their docs can be written and verified as soon as EP-20 lands.

Existing material to imitate and extend:

- `cluster/examples/` holds the runnable examples. `cluster/examples/preset-app-a/nagare/Config.hs`
  is the model for an app config using presets:

  ```haskell
  module Main (main) where

  import Nagare.Dsl.Config (emitDeployment)
  import Nagare.Dsl.Presets (production, webService)
  import Nagare.Dsl.Types (Deployment)

  deployment :: Either String Deployment
  deployment = do
    base <- mapLeft show (webService "notes" "gcr.io/myproject/notes")
    mapLeft show (production base)
    where
      mapLeft f = either (Left . f) Right

  main :: IO ()
  main = case deployment of
    Left err -> ioError (userError err)
    Right dep -> emitDeployment dep
  ```

  After EP-19, `webService` defaults `build` to a Dockerfile build, so this example is already a
  Dockerfile-mode app. The new examples set `build` explicitly per mode (using the `BuildSpec`
  constructors and any overlay helper EP-19 provides — e.g. a `prebuilt`/`nixpacksBuild` helper, or a
  record update on the `webService` result).

- `cluster/examples/static-site/` and `cluster/examples/tanstack-start/` show how source-bearing
  examples are laid out (a `nagare/Config.hs` plus the app source).

- `docs/user/deploying-apps.md` — the general app-deploy guide that the new page links from.
  `docs/user/config-reference.md` — the typed-constructor catalog to extend with `BuildSpec`,
  `PrebuiltImage`, `DockerfileBuild`, `NixpacksBuild`, and `mkTag`. `docs/user/static-hosting.md` is
  the closest precedent for a focused feature page; match its tone and structure.
  `docs/user/README.md` indexes the user guides; add `build-modes.md` to it.

Non-obvious detail: EP-19 makes `build` a required field on `Deployment` and updates `webService` to
default it. The "what changed" note in `build-modes.md` and `deploying-apps.md` must tell readers who
hand-assemble a `Deployment` record literal that they now need a `build` field, and show the one-line
fix (use `webService`, or add `build = ...`).


## Plan of Work

### Milestone 1 — Prebuilt-image example

Create `cluster/examples/prebuilt-image-app/nagare/Config.hs` that emits a `Deployment` whose `build`
is `PrebuiltImage <mkTag "...">` and whose `image` points at a public, pullable image (so a reader can
deploy it without building anything). Include a short `cluster/examples/prebuilt-image-app/README.md`
explaining what it demonstrates and the exact `nagarectl deploy` command. Acceptance:
`nagarectl deploy -f cluster/examples/prebuilt-image-app/nagare/Config.hs --dry-run` prints
`Build mode: prebuilt image ...` and a manifest whose image carries the prebuilt tag; a real deploy (if
a cluster is available) serves the upstream image with no local build.

### Milestone 2 — Dockerfile-build example

Create `cluster/examples/dockerfile-app/` with a tiny app source, a real `Dockerfile`, and
`nagare/Config.hs` whose `build` is a `DockerfileBuild` with a non-default detail to exercise the
feature — e.g. a `Dockerfile` at a named path and one `buildArgs` entry consumed by an `ARG` in the
Dockerfile. Add a `README.md`. Acceptance:
`nagarectl deploy -f cluster/examples/dockerfile-app/nagare/Config.hs --dry-run` prints
`Build mode: docker build -f Dockerfile ...`; a real deploy builds with the build arg, pushes, and
becomes Ready.

### Milestone 3 — Nixpacks example (depends on EP-21)

Create `cluster/examples/nixpacks-app/` with a tiny app that has **no Dockerfile** (e.g. a minimal Go
or Node HTTP server) and `nagare/Config.hs` whose `build` is `NixpacksBuild`. Add a `README.md` noting
the `nixpacks` host prerequisite (link to `docs/user/build-modes.md`). If EP-21 is not yet complete,
still add the example and mark it "experimental — requires EP-21" in its README and in the guide.
Acceptance (with EP-21 complete): `nagarectl deploy -f cluster/examples/nixpacks-app/nagare/Config.hs`
builds with `nixpacks`, pushes, and serves the app; without EP-21, `--dry-run` prints the Nixpacks
description and a real deploy reports the "not yet supported" message.

### Milestone 4 — The build-modes user guide

Write `docs/user/build-modes.md`. Structure: a short intro explaining the `build` field and when to
use each mode; one section per mode with (a) what it is for, (b) a complete copyable `Config.hs`
snippet, (c) the deploy command and expected output, and (d) gotchas (prebuilt: the tag lives in the
config, not computed; Dockerfile: the `--dockerfile`/`--context` overrides; Nixpacks: the `nixpacks`
prerequisite and how to install it). Include the "what changed" migration note (the new required
`build` field) and a one-line fix. Acceptance: a reader following only this page can deploy each
example; the commands and outputs in the page match what the examples actually produce.

### Milestone 5 — Reference updates and cross-links

Extend `docs/user/config-reference.md` with the `BuildSpec` constructors (`PrebuiltImage`,
`DockerfileBuild`, `NixpacksBuild`), the `Tag` type and `mkTag`, and the `build` field on
`Deployment`, in the same style as the existing entries. Add a "Build modes" subsection to
`docs/user/deploying-apps.md` that links to `docs/user/build-modes.md`. Add `build-modes.md` to
`docs/user/README.md`'s index. Re-verify every example's dry-run output against the guide's
transcripts and fix any drift. Acceptance: all cross-links resolve, the reference lists every new
constructor, and the guide transcripts match real output.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

After creating each example, verify it loads and renders without a cluster using `--dry-run` (the
`--ghc-env`/`NAGARE_GHC_ENVIRONMENT` mechanism from
`docs/plans/10-config-surface-and-loading-for-the-chosen-substrate.md` lets the loader's `runghc` find
`nagare-dsl`):

```bash
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cluster/examples/prebuilt-image-app/nagare/Config.hs --dry-run
```

Expected (abbreviated):

```text
--- Knative Service manifest ---
...
        image: <public-image>:<tag>
Build mode: prebuilt image (no local build), tag <tag>
URL: https://prebuilt-image-app.apps.<base-domain>
```

```bash
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cluster/examples/dockerfile-app/nagare/Config.hs --dry-run
# expect: Build mode: docker build -f Dockerfile .

cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cluster/examples/nixpacks-app/nagare/Config.hs --dry-run
# expect (EP-21 done): Build mode: nixpacks build .
```

Check that the docs render and links resolve (if a Markdown linter or link checker exists in the repo,
run it; otherwise grep for the new filenames):

```bash
grep -rn "build-modes.md" docs/user/
```


## Validation and Acceptance

Acceptance is documentation-by-demonstration: each of the three example projects under
`cluster/examples/` deploys (or, where no cluster is available, dry-runs) successfully by following
only the instructions in `docs/user/build-modes.md`, and the command output in the guide matches what
the examples actually produce. Concretely: the prebuilt example dry-run reports "prebuilt image (no
local build)" and renders the prebuilt tag; the Dockerfile example dry-run reports `docker build -f`
and a real deploy honors its build arg; the Nixpacks example (with EP-21 complete) deploys an app that
has no Dockerfile and serves it. `docs/user/config-reference.md` lists `PrebuiltImage`,
`DockerfileBuild`, `NixpacksBuild`, `Tag`/`mkTag`, and the `build` field; `docs/user/deploying-apps.md`
links to the new page; and all internal links resolve. The migration note correctly tells a reader
with a hand-written `Deployment` literal how to add the `build` field.


## Idempotence and Recovery

All work here is additive files (new examples, a new doc page) and edits to existing docs; everything
is safe to re-run and re-render. `--dry-run` has no side effects, so example verification can be
repeated freely. The only externally visible action is an optional real deploy of an example to the
cluster; those deploys are idempotent the same way any `nagarectl deploy` is (declarative
`kubectl apply`, fresh image tag per build), and an example deployed for verification can be removed
afterward with the standard delete path. No data migration or destructive operation is involved.


## Interfaces and Dependencies

No code dependencies beyond what EP-19, EP-20, and EP-21 already provide; this plan writes Markdown and
example `Config.hs`/`Dockerfile`/source files. The example configs consume the public DSL surface:
`Nagare.Dsl.Config.emitDeployment`, `Nagare.Dsl.Presets.webService`, and the `BuildSpec` constructors
and `mkTag` from `Nagare.Dsl.Build` (all defined in
`docs/plans/19-typed-buildspec-model-and-dsl-integration.md`). The Nixpacks example additionally
requires the `nixpacks` host prerequisite from
`docs/plans/21-nixpacks-zero-dockerfile-builder.md`. The deploy commands use the `nagarectl deploy`
flags established in `docs/plans/20-build-mode-execution-in-nagarectl-deploy.md`, including the
`--dockerfile`/`--context` overrides.
