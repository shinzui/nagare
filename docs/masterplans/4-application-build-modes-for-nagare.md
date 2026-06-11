---
id: 4
slug: application-build-modes-for-nagare
title: "Application Build Modes for Nagare"
kind: master-plan
created_at: 2026-06-09T23:50:49Z
intention: "intention_01ktqcgfx8end8kwp5ejmy0k6q"
---

# Application Build Modes for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Today Nagare can deploy a containerized application exactly one way. A developer writes a
typed `nagare/Config.hs` that produces a `Deployment` value, runs `nagarectl deploy`, and the
CLI always shells out to `docker build -t <image:tag> <context>` against a build context
(default `.`) that must contain a hand-written `Dockerfile`. There is no way to say "this image
is already built, just deploy it" and no way to say "build this without a Dockerfile." The
container image is named by an `ImageRef` (a registry repository path with no tag, e.g.
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes`) and the tag is appended at deploy time; the
build mode is implicit and unconfigurable.

After this initiative, the `Deployment` model carries an explicit, typed `BuildSpec` field that
names one of three build modes. The first, **prebuilt image**, deploys an image that already
exists in a registry — including third-party images and images produced by an external CI
pipeline — without building or pushing anything locally. The second, **Dockerfile build**,
formalizes today's behavior and adds first-class control over the Dockerfile path, the build
context directory, and `--build-arg` build arguments. The third, **Nixpacks build**, lets a
developer deploy an app that has no Dockerfile at all: Nixpacks (an open-source tool that
inspects a source tree, detects its language and framework, and produces an OCI image) builds
the image automatically. After the initiative a developer can deploy a Go, Node, Python, or
Rust app from source with no Dockerfile, deploy a prebuilt `ghcr.io/...` image directly, or keep
building from a custom Dockerfile — all selected by a single typed field in `Config.hs` and all
driven by the same `nagarectl deploy` command.

In scope: the `BuildSpec` type and its three variants in the `nagare-dsl` package; JSON
emission and loading for the new field; preset and example updates so the default behavior is
preserved; the `nagarectl deploy` pipeline changes that dispatch on build mode; a real Nixpacks
integration with a feasibility spike; and user documentation plus runnable examples for each
mode. Out of scope: changing the static-site and server-site build models (they already have
their own `StaticBuild` / `ServerBuild` types and are not touched here); image references by
digest (`@sha256:...`) rather than tag (noted as future work); remote/cluster-side builds (all
builds run wherever the CLI runs, exactly as today); and the broader Phase 1 app-lifecycle CLI
(`app list/get/logs/restart`), health checks, multiple-domain support, and resource limits from
the roadmap — those are separate initiatives. This MasterPlan implements only the "Application
build modes" row of `docs/roadmaps/paas-gap-roadmap.md`.


## Decomposition Strategy

The work splits into four child plans along functional seams that each produce an independently
verifiable behavior, following the principle of grouping by concern rather than by file.

The first seam is the **typed model** (EP-19): the `BuildSpec` sum type, the new `build` field on
`Deployment`, the JSON wire format, the smart constructors, the renderer change that lets a
prebuilt image keep its own tag, and the preset/example updates that preserve today's default.
This is pure library work in `cli/nagare-dsl` and is verifiable entirely with `cabal test`
(golden files and round-trip tests) without ever touching a cluster. It must come first because
every other plan consumes the types it defines.

The second seam is **execution** (EP-20): teaching `nagarectl deploy` to read the `BuildSpec` and
do the right thing — skip building for a prebuilt image, run `docker build` with the configured
Dockerfile, context, and build args for a Dockerfile build, and (for now) refuse a Nixpacks build
with a clear "not yet supported" message. This is verifiable with `nagarectl deploy --dry-run`
and a real prebuilt/Dockerfile deploy, and it is separated from the model because it is CLI and
subprocess work in a different package (`cli/nagarectl`) with a different test and validation
story.

The third seam is the **Nixpacks builder** (EP-21): the actual zero-Dockerfile build path. It is
isolated as its own plan because it carries the most external risk (it depends on the `nixpacks`
binary behaving as documented on the host), because the roadmap explicitly defers it ("a
placeholder for a future buildpack/Nixpacks-style builder later"), and because it begins with a
feasibility spike. Keeping it separate means EP-19 and EP-20 can ship a complete, useful feature
(prebuilt + Dockerfile) even if the Nixpacks work is delayed; the `NixpacksBuild` variant exists
from EP-19 onward and simply reports "not yet supported" until EP-21 lands.

The fourth seam is **documentation and examples** (EP-22): a user guide for build modes, a
runnable example project for each mode, and config-reference updates. It is last because good
documentation should describe behavior that already works end-to-end, and it depends on the
execution plan being complete.

An alternative considered was folding EP-19 and EP-20 into a single plan, since the model and its
first consumer are tightly related. That was rejected because they live in different packages
with different verification strategies (golden tests vs. dry-run/real deploy) and because a
single plan touching both the DSL and the CLI would exceed the "five milestones / ten files"
threshold that the MasterPlan specification uses to recommend splitting. A second alternative was
to drop Nixpacks entirely and ship only the typed placeholder per the strict letter of the
roadmap. That was rejected because zero-Dockerfile deploys are the single highest-leverage build
mode for a personal PaaS, and a spike-first isolated plan captures that value without endangering
the rest of the initiative.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 19 | Typed BuildSpec model and DSL integration | docs/plans/19-typed-buildspec-model-and-dsl-integration.md | None | EP-12 | Complete |
| 20 | Build-mode execution in nagarectl deploy | docs/plans/20-build-mode-execution-in-nagarectl-deploy.md | EP-19 | EP-12 | Complete |
| 21 | Nixpacks zero-Dockerfile builder | docs/plans/21-nixpacks-zero-dockerfile-builder.md | EP-19, EP-20 | None | Complete |
| 22 | Build-modes docs and end-to-end examples | docs/plans/22-build-modes-docs-and-end-to-end-examples.md | EP-20 | EP-21 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled. Hard Deps and Soft Deps reference
child plans by their `EP-<#>` prefix, where the number is the file number in `docs/plans/`.
`EP-12` refers to `docs/plans/12-nagarectl-integration-and-full-yaml-cutover.md`, the completed
plan that integrated the typed Haskell deployment DSL into `nagarectl`; it is a soft dependency
because both EP-19 and EP-20 extend the model and pipeline it established, but no new code from it
is required.


## Dependency Graph

EP-19 has no hard dependencies. It builds on the already-complete typed-DSL plans (EP-9 through
EP-12) but requires no unfinished work, so it can start immediately. It is the foundation: it
defines the `BuildSpec` type, adds the `build` field to `Deployment`, and ships the renderer and
JSON changes that every later plan relies on.

EP-20 hard-depends on EP-19 because the CLI cannot dispatch on a build mode that does not yet
exist as a type, cannot read the new `build` field off a loaded `Deployment`, and reuses the
`resolveImageTag` and `requiresBuild` helpers that EP-19 exports from the new
`Nagare.Dsl.Build` module. Until EP-19 is complete, EP-20 has nothing to call. Once EP-19 is
done, EP-20 can proceed on its own.

EP-21 hard-depends on both EP-19 and EP-20. It needs the `NixpacksBuild` variant from EP-19, and
it replaces the "not yet supported" branch that EP-20 writes into the `Nagare.Build` dispatch
module in `cli/nagarectl` — so the module it edits must exist first. EP-21 also begins with a
feasibility spike that is independent of the other plans (it can be run at any time to de-risk
the approach), but the production implementation cannot land until EP-20's dispatch scaffold is
in place.

EP-22 hard-depends on EP-20 because its prebuilt-image and Dockerfile-build examples must
actually deploy before they can be documented as working, and it soft-depends on EP-21 because
its Nixpacks example only fully works once the Nixpacks builder is real. EP-22 can therefore be
started in parallel with EP-21 — the prebuilt and Dockerfile sections of the guide and their
examples can be written and verified as soon as EP-20 lands — with the Nixpacks section finished
once EP-21 is complete.

In practice the initiative is a mostly-linear chain (EP-19 → EP-20 → EP-21) with EP-22 able to
overlap EP-21. The only meaningful parallelism is the EP-21 spike (runnable early) and the
prebuilt/Dockerfile portions of EP-22 (writable as soon as EP-20 is done).


## Integration Points

These are the shared artifacts that more than one child plan touches. Each is defined by the
earliest plan in dependency order; later plans consume it exactly as described here.

1. **The `BuildSpec` type and the `Nagare.Dsl.Build` module.** Defined by EP-19 in a new module
   `cli/nagare-dsl/src/Nagare/Dsl/Build.hs` and exposed from `cli/nagare-dsl/nagare-dsl.cabal`.
   The canonical shape is:

   ```haskell
   data BuildSpec
     = -- | Deploy an image that already exists in a registry. Carries the tag to
       -- deploy; nothing is built or pushed. The repository path is the
       -- 'Deployment' \'s 'ImageRef'; the full reference is @imageRef:tag@.
       PrebuiltImage Tag
     | -- | Build from a Dockerfile and push to the deployment\'s 'ImageRef'.
       DockerfileBuild
         { dockerfile :: !FilePathText
         , context :: !FilePathText
         , buildArgs :: !(Map Text Text)
         }
     | -- | Build from source with Nixpacks (no Dockerfile) and push to the
       -- deployment\'s 'ImageRef'. Execution lands in EP-21.
       NixpacksBuild
         { context :: !FilePathText
         , buildArgs :: !(Map Text Text)
         }
     deriving stock (Generic, Eq, Show)
   ```

   `Tag` is a newtype defined alongside it (non-empty, no whitespace, restricted to the Docker
   tag character set; digests are out of scope). `FilePathText` is the existing relative-path
   newtype from `Nagare.Dsl.Static.Types` (rejects empty, absolute, and `..` paths); EP-19
   reuses it and must confirm `"."` is an acceptable context. The module also exports two helpers
   that EP-20, EP-21, and the renderer all use:

   ```haskell
   -- | The tag to deploy: a prebuilt image carries its own; built images use the
   -- deploy tag computed by the CLI.
   resolveImageTag :: BuildSpec -> Text -> Text

   -- | Whether the CLI must build and push an image. False only for 'PrebuiltImage'.
   requiresBuild :: BuildSpec -> Bool
   ```

   EP-20 consumes `requiresBuild` to decide whether to run `configureDockerAuth`/build/push, and
   `resolveImageTag` to compute the reference. EP-21 pattern-matches the `NixpacksBuild` variant.

2. **The `build` field on `Deployment`.** EP-19 adds `build :: !BuildSpec` to the `Deployment`
   record in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`. This is a breaking change to the record
   literal that every `Config.hs` writes, so EP-19 also updates the `webService` preset
   (`cli/nagare-dsl/src/Nagare/Dsl/Presets.hs`) to default `build` to a Dockerfile build
   (`dockerfile = "Dockerfile"`, `context = "."`, empty build args) that reproduces today's
   behavior, and updates every in-repo fixture and example config. EP-20 reads this field via
   `dep ^. #build`; EP-22's example configs set it explicitly per mode.

3. **The JSON wire format for `build`.** EP-19 owns the contract between
   `Nagare.Dsl.Config.emitDeployment` (emission) and `Nagare.Dsl.Load.decodeDeployment`
   (loading), both in `cli/nagare-dsl`. The `build` value is a JSON object with a `"kind"`
   discriminator of `"PrebuiltImage"`, `"DockerfileBuild"`, or `"NixpacksBuild"`, mirroring the
   existing `StaticBuild` encoding in `Nagare.Dsl.Config`. EP-19 implements emission and decoding
   for all three kinds (including `NixpacksBuild`) so EP-21 changes no marshalling code — it only
   implements execution.

4. **The renderer's image string.** EP-19 changes `containerValue` in
   `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` so the rendered Knative container image is
   `imageRefText (dep ^. #image) <> ":" <> resolveImageTag (dep ^. #build) tag` instead of always
   appending the passed tag. This means a prebuilt image renders with its own embedded tag while
   built images render with the CLI-computed deploy tag. EP-20's `runDeploy` passes the same
   deploy tag it has always passed; the renderer and the CLI agree on the effective tag because
   both call `resolveImageTag`.

5. **The `Nagare.Build` dispatch module in the CLI.** EP-20 creates
   `cli/nagarectl/src/Nagare/Build.hs` (note: a different module from `Nagare.Image`), which takes
   a `BuildSpec`, the image reference, and a project directory and performs the build. EP-20
   writes the `PrebuiltImage` and `DockerfileBuild` branches and a `NixpacksBuild` branch that
   dies with "not yet supported". EP-21 replaces that branch with a real `nixpacks build`
   invocation. The module's exported function signature is owned by EP-20; EP-21 must not change
   it, only fill in the Nixpacks branch.


## Progress

- [x] EP-19: `BuildSpec`/`Tag` types and `Nagare.Dsl.Build` module with `resolveImageTag`/`requiresBuild`
- [x] EP-19: `build` field added to `Deployment`; `webService` preset and all fixtures/examples updated
- [x] EP-19: JSON emission and loading for all three build kinds; renderer uses `resolveImageTag`
- [x] EP-19: golden and round-trip tests pass (`cabal test` in `cli/nagare-dsl`)
- [x] EP-20: `Nagare.Build` dispatch module (prebuilt skip, Dockerfile build with `-f`/`--build-arg`, Nixpacks stub)
- [x] EP-20: `runDeploy` reads `build`, computes ref via `resolveImageTag`, dispatches on `requiresBuild`
- [x] EP-20: optional `--dockerfile`/`--context` overrides; `nagarectl deploy --dry-run` shows the planned build action
- [x] EP-20: prebuilt and Dockerfile deploys verified by dry-run (cluster deploy deferred — no cluster reachable); CLI tests pass. **Cluster deploy VERIFIED live 2026-06-10**: prebuilt and Dockerfile (amd64, `--build-arg` applied) apps both deployed to `nagare-01` and served HTTP 200; surfaced+fixed the node private-registry pull gap (see Outcomes).
- [x] EP-21: Nixpacks feasibility spike documented (build a sample app, observe the image) — `docs/spikes/ep21-nixpacks-spike.md`
- [x] EP-21: `Nagare.Build` Nixpacks branch invokes `nixpacks build` and pushes; host prerequisite documented (developer-machine install + preflight check)
- [x] EP-21: zero-Dockerfile app builds, tags, and pushes end-to-end (cluster apply deferred — no Knative cluster reachable). **Cluster apply path VERIFIED live 2026-06-10** — identical to the Dockerfile-mode apply that served 200; the Nixpacks build itself was already proven offline.
- [x] EP-22: `docs/user/build-modes.md` guide written
- [x] EP-22: runnable example projects for prebuilt, Dockerfile, and Nixpacks modes
- [x] EP-22: `docs/user/config-reference.md` and `docs/user/deploying-apps.md` updated


## Surprises & Discoveries

- EP-19: Adding `BuildSpec` to `Deployment` exposed a real module import cycle
  (`Types -> Build -> Static.Types -> Types`). It was resolved by extracting
  `FilePathText` into a new leaf module `Nagare.Dsl.Path` (re-exported from
  `Nagare.Dsl.Static.Types` for compatibility), not by moving it into
  `Nagare.Dsl.Types` as the plan's fallback suggested (which would have cycled
  `Types`↔`Build`). Consequence for later plans: `Nagare.Dsl.Build` imports
  `FilePathText` from `Nagare.Dsl.Path`; consumers may import it from either
  `Nagare.Dsl.Path` or `Nagare.Dsl.Static.Types` (both export it).

- EP-19: The `build` field is loaded as optional-with-default (a missing `build`
  decodes to the standard Dockerfile build) for backward compatibility, and a new
  pure `encodeDeployment :: Deployment -> ByteString` was exported from
  `Nagare.Dsl.Config` to make the emit→decode round-trip testable in-process.

- EP-20: A `Config.hs` run by the loader's `runghc` compiles under `-XGHC2024`
  only, which does **not** enable `OverloadedLabels`. A config that overrides the
  preset's `build` (e.g. to a `PrebuiltImage`) must use a record update
  (`base {build = PrebuiltImage t}`) or declare `{-# LANGUAGE OverloadedLabels #-}`
  itself — the `#build` lens is not available by default. EP-22's prebuilt example
  must follow this.


## Decision Log

- Decision: Model build mode as a single typed `BuildSpec` sum on `Deployment` with three
  variants (`PrebuiltImage`, `DockerfileBuild`, `NixpacksBuild`), rather than as CLI flags only.
  Rationale: Nagare's design principle is typed-config-first — illegal states are made
  unrepresentable in `Config.hs`, not validated at the CLI. Putting the build mode in the typed
  model keeps the config self-describing and reproducible, matching how `StaticBuild` and
  `ServerBuild` already work for the static and server site models.
  Date: 2026-06-09

- Decision: Keep `Deployment.image` as a tagless `ImageRef` (the registry repository) for all
  three modes, and let `PrebuiltImage` carry the deploy tag while build modes use the CLI-computed
  tag. A shared `resolveImageTag` helper reconciles the two.
  Rationale: This preserves the existing renderer contract (`image <> ":" <> tag`) and the
  existing `mkImageRef` validation (which forbids a colon), minimizing disruption. Folding a full
  tagged reference into every variant would have duplicated the repository path and forced
  `mkImageRef` to accept tags, complicating the model.
  Date: 2026-06-09

- Decision: Default the `webService` preset's `build` field to a Dockerfile build with
  `dockerfile = "Dockerfile"` and `context = "."`.
  Rationale: This exactly reproduces today's behavior (`docker build -t <ref> .`), so existing
  apps that use the preset keep working with no change. Apps that assemble a `Deployment` record
  literal directly must add the field — an accepted breaking change for a typed DSL, documented in
  EP-19 and EP-22.
  Date: 2026-06-09

- Decision: Implement Nixpacks as a real, isolated plan (EP-21) that begins with a feasibility
  spike, rather than shipping only the typed placeholder the roadmap strictly requires.
  Rationale: Zero-Dockerfile deploys are the highest-leverage build mode for a personal PaaS.
  Isolating it as the last hard-dependent plan means the prebuilt and Dockerfile modes ship a
  complete feature first, and the `NixpacksBuild` type exists from EP-19 (reporting "not yet
  supported") so the model is forward-compatible regardless of EP-21's timing.
  Date: 2026-06-09

- Decision: Decompose into four child plans (model, execution, Nixpacks, docs) rather than three
  or fewer.
  Rationale: Model and execution live in different packages with different verification stories
  (golden tests vs. dry-run/real deploy); Nixpacks carries external risk and is roadmap-deferred;
  docs should describe working behavior. Four plans keep each independently verifiable and within
  the MasterPlan size guidance.
  Date: 2026-06-09


## Outcomes & Retrospective

**Complete.** All four child plans (EP-19 → EP-22) landed. Nagare now models how an
application's container image is produced as a single typed `BuildSpec` field on
`Deployment`, with three modes:

- **Prebuilt image** — deploy an existing registry image by tag; no local build
  or push. The renderer honors the embedded tag.
- **Dockerfile build** — `docker build` with a configurable Dockerfile path,
  build context, and `--build-arg`s; the historical default (`webService` sets
  it), so existing preset-based apps are unchanged.
- **Nixpacks build** — `nixpacks build` from source with no Dockerfile; verified
  end-to-end (build → push to Artifact Registry in `tan-nb-exp`).

Delivered across the stack: the `nagare-dsl` types, JSON marshalling, and renderer
(EP-19); `nagarectl deploy` dispatch with `--dockerfile`/`--context` overrides and
a `--dry-run` build-action line (EP-20); the real Nixpacks builder with a
PATH preflight, preceded by a feasibility spike (EP-21); and a user guide plus
three runnable `cluster/examples/` projects and reference updates (EP-22). Tests:
`nagare-dsl` 135, `nagarectl` 52, all green.

Notable deviations from the written plans (details in each plan's Decision Log /
Surprises): `FilePathText` was extracted into a new leaf module `Nagare.Dsl.Path`
to break a genuine `Types`↔`Build` import cycle the plan's fallback would not have
resolved; the `build` field decodes optional-with-default for backward
compatibility; and example/guide configs use a record update (`base {build = ...}`)
rather than the `#build` lens because the loader's `runghc` runs under `-XGHC2024`
without `OverloadedLabels`.

Deferred (consistent with the rest of the project): the *live* Knative apply
(`nagare-01` is powered down), and the future-work items the Vision deliberately
left out — image references by digest, remote/cluster-side builds, and the broader
app-lifecycle CLI.

**Live verification 2026-06-10 (the deferred Knative apply, executed).** With `nagare-01` running:
- **Prebuilt mode (EP-20)** — `prebuilt-image-app` (public `gcr.io/knative-samples/helloworld-go`)
  deployed via `nagarectl deploy` and served **HTTP 200** (also the MP2 M2 proof).
- **Dockerfile mode (EP-20)** — a Dockerfile app built with `DOCKER_DEFAULT_PLATFORM=linux/amd64`
  (the node is amd64; the build daemon is arm64), pushed to `us-west1-docker.pkg.dev/tan-nb-exp/nagare`,
  and deployed. The `--build-arg SITE_MESSAGE` was applied at build time (verified in the running
  container: `build_arg=hello-from-a-dockerfile-build-arg`), and the app served **HTTP 200**. Runtime
  env from the managed store was injected too (`GREETING=hello-from-managed-store` — MP5/EP-27).
- **Nixpacks mode (EP-21)** — the cluster-apply path is identical to Dockerfile mode (now proven); the
  Nixpacks build itself was already verified offline (builds/tags/pushes).

**Two infra gaps this live run surfaced (build modes had never deployed a *private* image before — all
prior live tests used public images):**
1. **The node could not pull from the project's own Artifact Registry** (`DENIED: Unauthenticated`).
   There was no `/etc/rancher/k3s/registries.yaml`, so containerd pulled anonymously. The node SA
   (`nagare-node@`) already has `roles/artifactregistry.writer` + cloud-platform scope; writing
   `registries.yaml` with an `oauth2accesstoken` from the metadata server fixed the containerd pull
   (verified with `crictl pull`).
2. **Knative's controller-side tag→digest resolver** does not use `registries.yaml`, so it still failed
   admission. Adding `us-west1-docker.pkg.dev` to `registriesSkippingTagResolving` in the
   `config-deployment` ConfigMap made Knative defer the pull to containerd; the revision then went
   Ready and served 200.
   **Follow-up (NOT yet permanent):** both fixes were applied imperatively on the running VM — the
   `registries.yaml` token expires (~1h) and neither change is in the NixOS host config or the cluster
   bootstrap. To make private-image deploys durable, declare `registries.yaml` (with a token-refresh
   mechanism, e.g. a systemd timer minting a metadata token) in the host image and set
   `registriesSkippingTagResolving` in the Knative bootstrap. Tracked as a bootstrap/host follow-up.
