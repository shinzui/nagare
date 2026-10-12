---
id: 19
slug: typed-buildspec-model-and-dsl-integration
title: "Typed BuildSpec model and DSL integration"
kind: exec-plan
created_at: 2026-06-09T23:51:00Z
intention: "intention_01ktqcgfx8end8kwp5ejmy0k6q"
master_plan: "docs/masterplans/4-application-build-modes-for-nagare.md"
---

# Typed BuildSpec model and DSL integration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [19-typed-buildspec-model-and-dsl-integration.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/19-typed-buildspec-model-and-dsl-integration.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

This plan is the first of four under the MasterPlan
`docs/masterplans/4-application-build-modes-for-nagare.md` ("Application Build Modes for
Nagare"). It adds a typed way to say *how* a Nagare application's container image is produced.

Today an application deployment is described by a `Deployment` value in a user's `nagare/Config.hs`,
and the image is always built from a hand-written `Dockerfile` by `nagarectl deploy`. There is no
typed way to express "this image already exists, just deploy it" or "build this with a tool other
than a raw Dockerfile". After this plan, the `Deployment` model carries a new `build` field of a
new type `BuildSpec` with three variants: `PrebuiltImage` (deploy an existing image by tag, build
nothing), `DockerfileBuild` (build from a named Dockerfile and context with build arguments), and
`NixpacksBuild` (build from source with no Dockerfile — execution arrives in a later plan,
`docs/plans/21-nixpacks-zero-dockerfile-builder.md`).

This plan is **library-only**: it changes the `nagare-dsl` Haskell package and nothing in the CLI.
You can see it working by running the package's test suite (`cabal test` in `cli/nagare-dsl`): new
golden files show a `Deployment` with each build mode emitting and round-tripping correctly, and a
prebuilt-image deployment renders a Knative Service whose container image carries the prebuilt
tag rather than a freshly computed one. The CLI work that actually performs the builds lives in
`docs/plans/20-build-mode-execution-in-nagarectl-deploy.md` and is out of scope here.

A note on terms used throughout. A **smart constructor** is a function named `mkX` that validates
its inputs and returns `Either Text X`, where the data constructor of `X` is hidden so the only
way to build a value is through `mkX`. An **`ImageRef`** is a container image repository path
*without* a tag, e.g. `us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes`; the tag is appended
separately. A **golden test** compares generated output (here, emitted JSON or rendered YAML)
against a checked-in expected file; if they differ the test fails and prints a diff. **Nixpacks**
is an open-source command-line tool that inspects a source directory, auto-detects its language
and framework, and builds an OCI container image without a Dockerfile; this plan only adds the
*type* for it, not the build itself.

## Progress

- [x] Milestone 1: `Tag`, `BuildSpec`, and the `Nagare.Dsl.Build` module exist and are exposed from the cabal file; `resolveImageTag` and `requiresBuild` compile.
- [x] Milestone 2: `Deployment` has a `build` field; `webService` preset defaults it to a Dockerfile build; all in-repo fixtures and example configs updated and the package builds.
- [x] Milestone 3: JSON emission (`Nagare.Dsl.Config`) and loading (`Nagare.Dsl.Load`) handle all three build kinds with a `"kind"` discriminator and precise `MarshalError`s.
- [x] Milestone 4: the renderer (`Nagare.Dsl.Render`) uses `resolveImageTag` so a prebuilt image renders with its own tag.
- [x] Milestone 5: golden files and round-trip/unit tests added; `cabal test` passes for all three modes plus failure cases.

## Surprises & Discoveries

- The import-cycle the plan anticipated is real: `Deployment` (in `Nagare.Dsl.Types`)
  needs `BuildSpec` (in `Nagare.Dsl.Build`), which needs `FilePathText` — and
  `FilePathText` lived in `Nagare.Dsl.Static.Types`, which imports
  `Nagare.Dsl.Types` for `Domain`/`ImageRef`/`Namespace`. That closes the loop
  `Types -> Build -> Static.Types -> Types`. The plan's suggested fix (move
  `FilePathText` into `Nagare.Dsl.Types`) does **not** resolve it — it would make
  `Build` import `Types` and `Types` import `Build`, a direct two-module cycle.
  Resolution taken: extract `FilePathText`/`mkFilePathText`/`filePathText` into a
  new leaf module `Nagare.Dsl.Path` that depends only on `text`. `Build` imports
  `Path`; `Static.Types` re-exports `FilePathText` from `Path` so every existing
  importer is unaffected. See Decision Log.

- The `build` field is decoded as **optional with a default** (`o .:? "build"`,
  defaulting to the standard Dockerfile build) rather than the strictly-required
  `o .: "build"` the plan sketched. Reason: pre-`BuildSpec` deployment JSON (and
  the hand-written JSON fixtures in `test/LoadSpec.hs`, which omit `build`) must
  still decode — they are designed to fail at the `name`/`scale` smart
  constructors, which a required `build` would pre-empt with a JSON parse error.
  Optional-with-default is also strictly backward-compatible and matches the
  MasterPlan decision to make the default mode reproduce today's behavior.

- Added one exported helper not in the plan's signature list: `encodeDeployment ::
  Deployment -> ByteString` in `Nagare.Dsl.Config` (the pure bytes `emitDeployment`
  writes). It makes the emit→decode round-trip testable in-process without
  capturing stdout or spawning `runghc`. `emitDeployment` is now `LBS.putStr .
  encodeDeployment`; its `IO ()` signature is unchanged.

## Decision Log

- Decision: Put `BuildSpec`, `Tag`, and the `resolveImageTag`/`requiresBuild` helpers in a new
  module `Nagare.Dsl.Build` rather than in `Nagare.Dsl.Types`.
  Rationale: `Nagare.Dsl.Types` is already large and holds only leaf newtypes; a dedicated module
  keeps the build concept cohesive and gives the CLI a single import. The helpers are pure and
  shared by both the renderer (this plan) and the CLI (EP-20), so they belong with the type.
  Date: 2026-06-09

- Decision: Reuse `FilePathText` from `Nagare.Dsl.Static.Types` for the `context` and `dockerfile`
  path fields instead of inventing a new path newtype.
  Rationale: `FilePathText` already rejects empty, absolute, and `..`-escaping paths, exactly the
  validation we want for a build context and Dockerfile path. Reusing it avoids duplicate
  validation logic. Milestone 1 verifies that `mkFilePathText "."` succeeds (the default context);
  if it does not, the fallback is to relax `mkFilePathText` to accept a lone `.` and re-run the
  static golden tests, which must stay green.
  Date: 2026-06-09

- Decision: `PrebuiltImage` carries a `Tag`; `Deployment.image` stays a tagless `ImageRef` for all
  modes.
  Rationale: Preserves the existing renderer contract and `mkImageRef` validation; see the
  MasterPlan Decision Log for the full rationale.
  Date: 2026-06-09

- Decision: Break the `Types -> Build -> Static.Types -> Types` import cycle by extracting
  `FilePathText`/`mkFilePathText`/`filePathText` into a new leaf module `Nagare.Dsl.Path` (depending
  only on `text`), rather than moving them into `Nagare.Dsl.Types` as the plan's fallback suggested.
  Rationale: Moving `FilePathText` into `Types` would not help — `Build` would then import `Types`
  for `FilePathText` while `Types` imports `Build` for `BuildSpec`, a direct two-module cycle. A
  dedicated leaf module that imports neither `Types` nor `Build` is the only acyclic option that
  keeps `Build` separate. `Static.Types` re-exports `FilePathText` from `Path`, so every existing
  importer (`Server.Types`, `Config`, `Load`, `Static.Render`, the CLI) is unchanged.
  Date: 2026-06-09

- Decision: Decode the `Deployment.build` field as optional-with-default (`o .:? "build"` defaulting
  to the Dockerfile build) rather than strictly required.
  Rationale: Backward compatibility with pre-`BuildSpec` JSON and with the existing `LoadSpec` JSON
  fixtures (which omit `build` and are designed to fail at the `name`/`scale` constructors). A
  required field would turn those into JSON parse errors. Matches the MasterPlan default-preserving
  decision.
  Date: 2026-06-09

## Outcomes & Retrospective

Delivered. `cli/nagare-dsl` now carries a typed `BuildSpec` (`PrebuiltImage`,
`DockerfileBuild`, `NixpacksBuild`) on `Deployment`, with a `Tag` newtype,
`resolveImageTag`/`requiresBuild`/`defaultBuild` helpers, `"kind"`-tagged JSON
emission and loading for all three modes, and a renderer that honors a prebuilt
image's embedded tag. `cabal test` passes (135 tests, including a new
`Nagare.Dsl.Build` group covering all three modes, the two helpers, the renderer,
emit→decode round-trips, and the failure cases: empty/invalid tag, absolute
context, unknown `build.kind`). The `nagarectl` package still builds against the
new required field (it only reads `Deployment` via lenses; no literal to update).

Key deviation from the written plan: `FilePathText` was extracted into a new leaf
module `Nagare.Dsl.Path` to break the import cycle, rather than moved into
`Nagare.Dsl.Types` (which would have cycled `Types`↔`Build`). See Decision Log
and Surprises.

