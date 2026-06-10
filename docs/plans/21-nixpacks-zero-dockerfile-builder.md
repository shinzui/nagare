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

- [ ] Milestone 1 (spike): `nixpacks` is available on the build host; a sample app builds to an image that runs and serves on its port; findings recorded in Surprises & Discoveries.
- [ ] Milestone 2: `Nagare.Image` gains `nixpacksBuildArgs` (pure) and `buildNixpacks` (runner); `cabal build` passes.
- [ ] Milestone 3: the `NixpacksBuild` branch of `Nagare.Build.performBuild` invokes `buildNixpacks` instead of dying; `describeBuild` drops the "NOT YET SUPPORTED" note.
- [ ] Milestone 4: host prerequisite (installing `nixpacks`) documented and, where applicable, added to the NixOS host module or the nagared image.
- [ ] Milestone 5: tests for `nixpacksBuildArgs` pass; a zero-Dockerfile app deploys end-to-end (or builds locally where a cluster is unavailable).


## Surprises & Discoveries

(None yet — the Milestone 1 spike findings go here, e.g. the exact `nixpacks` version, how it
detects the port, and whether it needs Docker vs. BuildKit on the host.)


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


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/nagare`.

This plan hard-depends on `docs/plans/19-typed-buildspec-model-and-dsl-integration.md` and
`docs/plans/20-build-mode-execution-in-nagarectl-deploy.md`. By the time you start:

- `Nagare.Dsl.Build` (in `cli/nagare-dsl`) exports `BuildSpec` with the variant
  `NixpacksBuild { context :: !FilePathText, buildArgs :: !(Map Text Text) }`, plus `requiresBuild`
  (returns `True` for Nixpacks) and `resolveImageTag` (returns the deploy tag for Nixpacks, since it
  is a build mode). `filePathText :: FilePathText -> Text` is in `Nagare.Dsl.Static.Types`.

- `cli/nagarectl/src/Nagare/Build.hs` exists with:

  ```haskell
  performBuild :: BuildSpec -> Text -> IO ()
  performBuild spec ref = case spec of
    PrebuiltImage _ -> pure ()
    DockerfileBuild df ctx args -> buildDockerfile ref (T.unpack (filePathText df)) (T.unpack (filePathText ctx)) (Map.toList args)
    NixpacksBuild _ _ -> die "nagare: nixpacks build mode is not yet supported (see docs/plans/21-nixpacks-zero-dockerfile-builder.md)"

  describeBuild :: BuildSpec -> Text   -- the NixpacksBuild branch ends with "— NOT YET SUPPORTED"
  ```

  `runDeploy` in `cli/nagarectl/app/Main.hs` already calls `performBuild spec ref` whenever
  `requiresBuild spec` is `True`, then `pushImage ref`. So once `performBuild` builds an image tagged
  `ref`, the existing push/apply/wait flow deploys it with no further change.

- `cli/nagarectl/src/Nagare/Image.hs` holds the Docker/registry primitives and the `cradle` shell-out
  pattern (`run_ $ cmd "..." & addArgs [...]`). `configureDockerAuth` runs
  `gcloud auth configure-docker us-west1-docker.pkg.dev --quiet`; `pushImage ref` runs `docker push ref`.

- The NixOS host configuration lives under `nixos/` (`nixos/hosts`, `nixos/modules`). If Nagare's
  build host is the VM (e.g. when `nagared` runs builds), `nixpacks` must be installed there;
  if developers build on their own machines, the prerequisite is documented for them. Determine which
  applies during Milestone 4 and record it.

Non-obvious detail: `nixpacks build <dir> --name <image:tag>` produces and **locally tags** an image
but does not push it. That is exactly what the CLI needs: `performBuild` builds and tags `ref`, and
`runDeploy` then calls the existing `pushImage ref`. The image must be tagged with the *same* `ref`
the CLI computed (`imageRef dep effTag`) so the subsequent push and the rendered Knative manifest
agree.


## Plan of Work

### Milestone 1 — Feasibility spike (prototype, throwaway)

Prove `nixpacks` works on the build host before touching the CLI. Install `nixpacks` (see Concrete
Steps), create a minimal sample app with no Dockerfile (a tiny Go or Node HTTP server listening on
`$PORT`/8080), and build it by hand:

```bash
nixpacks build ./sample --name nixpacks-spike:local
docker run --rm -p 8080:8080 nixpacks-spike:local &
curl -fsS localhost:8080
```

Confirm the image builds, runs, and serves. Record in Surprises & Discoveries: the `nixpacks`
version, whether it needs a running Docker daemon, how it picks the start command and port, and any
provider it downloaded. This milestone writes a short spike note under `docs/spikes/` (matching the
existing `docs/spikes/` convention) summarizing the result and the recommended invocation. Acceptance:
`curl` returns the sample app's response from the Nixpacks-built image. If the spike reveals a blocker
(e.g. Nixpacks cannot reach its providers from the host, or port detection is unreliable), stop and
record the blocker in the MasterPlan's Surprises & Discoveries before proceeding — the typed
placeholder remains and EP-22 documents Nixpacks as unsupported.

### Milestone 2 — Nixpacks build primitives in `Nagare.Image`

In `cli/nagarectl/src/Nagare/Image.hs`, add a pure argument builder and a runner mirroring the
Dockerfile ones from `docs/plans/20-build-mode-execution-in-nagarectl-deploy.md`:

```haskell
-- | The argument vector for @nixpacks build@: build the context directory and
-- tag the result @ref@, passing each build arg as a Nixpacks build-time env var.
nixpacksBuildArgs :: Text -> FilePath -> [(Text, Text)] -> [String]
nixpacksBuildArgs ref context args =
  ["build", context, "--name", T.unpack ref]
    <> concatMap (\(k, v) -> ["--env", T.unpack (k <> "=" <> v)]) args

-- | Run @nixpacks build@ to produce and locally tag the image @ref@.
buildNixpacks :: Text -> FilePath -> [(Text, Text)] -> IO ()
buildNixpacks ref context args =
  run_ $ cmd "nixpacks" & addArgs (nixpacksBuildArgs ref context args)
```

Export both. Use the exact flag form the Milestone 1 spike validated (adjust `--name`/`--env` if the
spike found different flags, and record the change in the Decision Log). Acceptance: `cabal build`
passes and `nixpacksBuildArgs "r" "." [("A","1")]` equals
`["build",".","--name","r","--env","A=1"]`.

### Milestone 3 — Replace the stub in `Nagare.Build`

In `cli/nagarectl/src/Nagare/Build.hs`, change the `NixpacksBuild` branch of `performBuild` from the
`die` stub to a real build:

```haskell
  NixpacksBuild ctx args ->
    buildNixpacks ref (T.unpack (filePathText ctx)) (Map.toList args)
```

Update `describeBuild`'s `NixpacksBuild` branch to drop "— NOT YET SUPPORTED" and read
`"nixpacks build " <> filePathText ctx`. Import `buildNixpacks` from `Nagare.Image`. No signature
changes — `performBuild :: BuildSpec -> Text -> IO ()` is unchanged, so `runDeploy` already drives it.
Acceptance: `nagarectl deploy --dry-run` against a `NixpacksBuild` config prints
`Build mode: nixpacks build .` with no "NOT YET SUPPORTED"; a non-dry-run deploy invokes `nixpacks`.

### Milestone 4 — Host prerequisite

Make `nixpacks` reliably available wherever Nagare builds. Decide, based on Milestone 1, whether
builds run on the developer's machine (document the install in the user docs handed to
`docs/plans/22-build-modes-docs-and-end-to-end-examples.md`) or on the VM via `nagared` (add
`nixpacks` to the relevant NixOS module under `nixos/modules` or to the `nagared` image's tooling).
Add a preflight check: if `performBuild` is about to run Nixpacks and `nixpacks` is not on `PATH`,
fail with a clear message ("nagare: nixpacks not found on PATH; see docs/user/build-modes.md") rather
than a raw "command not found". Acceptance: on a host without `nixpacks`, a Nixpacks deploy prints the
actionable message and exits non-zero; on a host with it, the build proceeds.

### Milestone 5 — Tests and end-to-end verification

Add `nixpacksBuildArgs` cases to the `Nagare.Build` test group in `cli/nagarectl/test/Spec.hs`
(argument ordering with and without env args). Run `cabal test`. Then deploy a zero-Dockerfile app
end-to-end: build the sample from Milestone 1 (or an EP-22 example) via `nagarectl deploy`, confirm
the image is pushed to Artifact Registry and the Knative Service becomes Ready, and `curl` the URL.
Where a cluster is unavailable, stop after confirming `nagarectl deploy` (without `--dry-run`)
produces a locally tagged image via `nixpacks` and would push it.


## Concrete Steps

Per the repository policy (`CLAUDE.md`), all GCP operations target project `tan-nb-exp`, region
`us-west1`. Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Install Nixpacks for the spike (choose one; record what you used):

```bash
# Official installer
curl -sSL https://nixpacks.com/install.sh | bash
# or, if packaged in nixpkgs on this host
nix-shell -p nixpacks
nixpacks --version
```

Run the spike against a throwaway sample (create `sample/` with a tiny HTTP server first):

```bash
nixpacks build ./sample --name nixpacks-spike:local
docker run --rm -d -p 8080:8080 --name nixpacks-spike nixpacks-spike:local
curl -fsS localhost:8080
docker rm -f nixpacks-spike
```

Expected:

```text
Hello from a Dockerfile-free app
```

Build and test the CLI after Milestones 2–3:

```bash
cd cli/nagarectl
cabal build
cabal test
```

Dry-run a Nixpacks config to confirm the description (Milestone 3):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
cabal --project-dir=cli/nagarectl run nagarectl -- deploy -f /tmp/nixapp/nagare/Config.hs --dry-run
```

Expected line:

```text
Build mode: nixpacks build .
```

End-to-end deploy (Milestone 5, cluster required):

```bash
cabal --project-dir=cli/nagarectl run nagarectl -- deploy -f /tmp/nixapp/nagare/Config.hs
# ... nixpacks build output ...
# ... docker push us-west1-docker.pkg.dev/tan-nb-exp/nagare/nixapp:<tag> ...
# Deployed: https://nixapp.apps.<base-domain>
curl -fsS https://nixapp.apps.<base-domain>
```


## Validation and Acceptance

Acceptance beyond compilation: the Milestone 1 spike `curl` returns the sample app's body from a
Nixpacks-built image, proving the tool works on the host. `cabal test` in `cli/nagarectl` passes with
the `nixpacksBuildArgs` cases. A `--dry-run` of a `NixpacksBuild` config prints `Build mode: nixpacks
build <ctx>` with no "NOT YET SUPPORTED". The headline proof is a real deploy of an app with no
Dockerfile: `nagarectl deploy` runs `nixpacks build`, pushes the image to `tan-nb-exp`'s Artifact
Registry, the Knative Service reaches Ready, and `curl`-ing the printed URL returns the app's
response. On a host missing `nixpacks`, the preflight message appears instead of a raw shell error.
The Dockerfile and prebuilt modes from EP-20 must continue to work unchanged, proving the Nixpacks
branch was added without disturbing the dispatch.


## Idempotence and Recovery

Source edits are additive and `cabal build`/`cabal test` are safe to repeat. `nixpacks build` is
re-runnable: a fresh invocation rebuilds and re-tags the image; a deploy uses a fresh timestamp tag
each time, so re-deploying never clobbers a prior image. The spike artifacts (`sample/`, the local
`nixpacks-spike:local` image, the spike note) are throwaway — remove the container with
`docker rm -f` and the image with `docker rmi` once done. If Nixpacks downloads providers into a
cache, that cache is harmless to delete and will be repopulated. If a Nixpacks deploy fails midway
(e.g. push denied), no Knative change has been applied yet (build and push precede `applyManifests`),
so there is nothing to roll back beyond the local image; fix the cause and re-run.


## Interfaces and Dependencies

External dependency: the `nixpacks` CLI must be on `PATH` wherever the build runs. No new Haskell
package dependencies — `cradle`, `text`, `containers`, and `nagare-dsl` already cover the shell-out
and the types.

Signatures that must exist at the end of this plan, in `Nagare.Image`
(`cli/nagarectl/src/Nagare/Image.hs`):

```haskell
nixpacksBuildArgs :: Text -> FilePath -> [(Text, Text)] -> [String]
buildNixpacks :: Text -> FilePath -> [(Text, Text)] -> IO ()
```

`Nagare.Build.performBuild` and `describeBuild` keep the signatures established in
`docs/plans/20-build-mode-execution-in-nagarectl-deploy.md`; only their `NixpacksBuild` branches
change. The `BuildSpec` type from `Nagare.Dsl.Build` is consumed unchanged.
