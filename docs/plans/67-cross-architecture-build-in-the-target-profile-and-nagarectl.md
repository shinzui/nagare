---
id: 67
slug: cross-architecture-build-in-the-target-profile-and-nagarectl
title: "Cross-Architecture Build in the Target Profile and nagarectl"
kind: exec-plan
created_at: 2026-06-11T02:37:50Z
intention: "intention_01ktt8he4vepkb0gbp2k9z5fc3"
master_plan: "docs/masterplans/13-live-audit-hardening-control-plane-abstractions-and-declarative-cluster-configuration.md"
---

# Cross-Architecture Build in the Target Profile and nagarectl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, when an operator runs `nagarectl deploy` for an application that nagare
*builds* from source (a Dockerfile or a Dockerfile-free Nixpacks tree), the
resulting container image is built for whatever CPU architecture the operator's
local Docker daemon happens to be. On an Apple Silicon Mac running colima or
Docker Desktop, that daemon is `linux/arm64` (also spelled `aarch64`). The single
production node in this repository's cluster, `nagare-01`, is an `amd64`
(`x86_64`) virtual machine. An `arm64` image cannot run on an `amd64` node: the
pod crash-loops with an `exec format error`. During the 2026-06-10 live audit the
only way a build-mode deploy succeeded was that a human remembered to type
`export DOCKER_DEFAULT_PLATFORM=linux/amd64` into their shell before deploying.
That is a silent, easily forgotten foot-gun: forget it, and the deploy "succeeds"
(the build and push work) but the app never starts on the cluster.

After this change, the *target architecture is part of the target profile*, just
like the GCP project and region already are, and `nagarectl` passes it explicitly
to the image builder. A fresh checkout deploys node-runnable `linux/amd64` images
with no environment variable and no ceremony, because `linux/amd64` is the
built-in default. An operator whose cluster is some other architecture sets one
line in their profile and every build-mode deploy honors it.

Concretely, after this plan a developer on an Apple Silicon laptop can run, with
**no** `DOCKER_DEFAULT_PLATFORM` exported:

```bash
cd /path/to/an/app/with/a/Dockerfile
nagarectl deploy --file nagare/Config.hs
```

and the image that gets built, pushed, and deployed is `linux/amd64`. They can
prove it locally without deploying at all by inspecting the freshly built image:

```bash
docker image inspect <built-ref> --format '{{.Architecture}}'
# -> amd64
```

The "target profile" referred to throughout is the per-operator configuration
that already exists in this repo: a git-ignored file `nagare.target.env` at the
repository root (a sequence of `export VAR=value` lines), documented by the
tracked example `nagare.target.env.example`, mirrored for shell tooling by
`scripts/lib/target.sh`, and read in Haskell by the `Nagare.Target` module
(`cli/nagarectl/src/Nagare/Target.hs`). This plan adds exactly one new field to
that profile.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `tpTargetPlatform` to `TargetProfile` and resolve `NAGARE_TARGET_PLATFORM` (default `linux/amd64`) in `resolveTargetProfile` (`cli/nagarectl/src/Nagare/Target.hs`).
- [ ] M1: Add the `NAGARE_TARGET_PLATFORM` line to `nagare.target.env.example` (repo root) and the `TARGET_PLATFORM` mirror to `scripts/lib/target.sh`.
- [ ] M1: Extend `renderTargetEnv` and the `targetProfileTests` (and any record literals that no longer compile) so the field round-trips and the precedence is tested.
- [ ] M2: Thread the resolved platform into `performBuild` (`cli/nagarectl/src/Nagare/Build.hs`) and through `Nagare.Image.buildDockerfile`/`buildNixpacks`, passing `--platform <platform>` to both `docker build` and `nixpacks build`.
- [ ] M2: Update the `dockerBuildArgs`/`nixpacksBuildArgs` unit tests and add a render test asserting `--platform linux/amd64` appears.
- [ ] M3: Demonstrate (and record in this plan) that a Dockerfile build produces a `linux/amd64` image with no `DOCKER_DEFAULT_PLATFORM` set.

(Replace `[ ]` with `[x]` as each item lands. Add sub-items / split items at every stopping point.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Pre-recorded from research, 2026-06-11.) `nixpacks build` accepts a
  `--platform <os/arch>` flag for a **single** platform, e.g.
  `nixpacks build . --platform linux/amd64`. It is only *multi*-platform
  (comma-separated) builds that fail with "Multiple platforms feature is currently
  not supported for docker driver" and require a `docker buildx` driver. Since this
  plan only ever passes one platform, the plain `nixpacks build --platform` path is
  sufficient and no buildx driver setup is needed. (Source: railwayapp/nixpacks
  issue #1015; corroborated by the Nixpacks configuration docs.)
- (Pre-recorded.) `docker build` (the legacy builder and BuildKit) both honor the
  `DOCKER_DEFAULT_PLATFORM` environment variable as the implicit `--platform`. An
  explicit `--platform` flag on the command line *overrides* that env var. So after
  this change the explicit flag we pass wins, and an operator who still exports
  `DOCKER_DEFAULT_PLATFORM` does not break anything — but they also no longer *need*
  to, which is the whole point.

(Add further entries with evidence as work proceeds.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Name the new profile variable `NAGARE_TARGET_PLATFORM` (Haskell field
  `tpTargetPlatform`), with default value `linux/amd64`.
  Rationale: The value is passed verbatim to `docker build --platform` and
  `nixpacks build --platform`, both of which expect the Docker platform string
  `os/arch` (e.g. `linux/amd64`, `linux/arm64`), not a bare arch like `amd64`. The
  `NAGARE_` prefix matches every other nagare-specific profile variable
  (`NAGARE_REGISTRY_HOST`, `NAGARE_IMAGE_BUCKET`, …); the canonical `CLOUDSDK_*`
  names are reserved for the variables the Google Cloud SDK and the Pulumi GCP
  provider read directly, which this is not. `linux/amd64` is the default because
  the cluster node is `amd64`; with no profile the historic-correct value is
  reproduced, matching the EP-60 precedence philosophy "do nothing → original
  behavior".
  Date: 2026-06-11

- Decision: Pass `--platform` *explicitly* on the build command line rather than
  relying on (or setting) the `DOCKER_DEFAULT_PLATFORM` environment variable from
  within `nagarectl`.
  Rationale: An explicit flag is self-documenting, appears in `--dry-run` output,
  is unit-testable as a pure argument vector, and overrides any stale
  `DOCKER_DEFAULT_PLATFORM` an operator may have exported. Setting an env var from
  inside the process would be invisible and fragile by comparison. The env var
  still works as a manual override for ad-hoc `docker` use outside nagare; we just
  no longer depend on it.
  Date: 2026-06-11

- Decision: Resolve the platform once, in `runDeploy`, from the already-resolved
  `TargetProfile`, and thread it as an explicit argument down to `performBuild`
  and the `Nagare.Image` builders — rather than having the low-level builders call
  `resolveTargetProfile` themselves.
  Rationale: `runDeploy` already binds `tp <- resolveTargetProfile`
  (`cli/nagarectl/app/Main.hs`, ~line 1732) and uses it for image qualification, so
  the value is in scope at the build call site (~line 1817). Threading keeps the
  pure builder functions (`dockerBuildArgs`, `nixpacksBuildArgs`) pure and
  unit-testable, consistent with the existing module shape.
  Date: 2026-06-11

- Decision: Leave the `TargetProfile` record and the `nagare.target.env.example`
  ordering deliberately extensible so EP-6 (docs/plans/70) can append its
  `NAGARE_SSH_USER` field without restructuring. EP-3 does **not** add the SSH-user
  field. See Interfaces and Dependencies → Integration Contract.
  Rationale: MasterPlan 13 Integration Point #2 designates EP-3 as the *first
  writer* of this shared schema and EP-6 as the second; the two must agree on the
  record shape, env-file schema, and the env > profile > default precedence rule.
  Date: 2026-06-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before
editing anything.

**What nagare is, minimally.** `nagare` deploys applications to a single
Knative-on-k3s cluster (one VM named `nagare-01`) in one configurable Google Cloud
Platform (GCP) project. The operator-facing tool is a Haskell command-line program
called `nagarectl`, whose source lives under `cli/nagarectl/`. Its executable
entry point is `cli/nagarectl/app/Main.hs`; its library modules are under
`cli/nagarectl/src/Nagare/`; its test suite is the single file
`cli/nagarectl/test/Spec.hs`.

**What "build mode" means.** Some apps ship a prebuilt public image and nagare
just deploys it. Others nagare *builds* from the app's source tree before pushing
to the project's private Artifact Registry. There are two build modes, both
modeled by the `BuildSpec` type in `Nagare.Dsl.Build`:

- `DockerfileBuild` — the app has a `Dockerfile`; nagare runs `docker build`.
- `NixpacksBuild` — the app has *no* Dockerfile; nagare runs `nixpacks build`,
  which auto-detects the language and produces an OCI image. ("OCI image" = the
  standard container-image format Docker produces and runs.)

A third constructor, `PrebuiltImage`, means "do not build at all".

**Where the build actually happens.** Two modules collaborate:

- `cli/nagarectl/src/Nagare/Build.hs` — the *dispatch* layer. Its `performBuild ::
  BuildSpec -> Text -> IO ()` pattern-matches on the `BuildSpec` and calls the
  right primitive. For `DockerfileBuild` it calls `Nagare.Image.buildDockerfile`;
  for `NixpacksBuild` it first checks `nixpacks` is on `PATH`, then calls
  `Nagare.Image.buildNixpacks`. `describeBuild :: BuildSpec -> Text` produces the
  one-line human description used by `--dry-run`.
- `cli/nagarectl/src/Nagare/Image.hs` — the *primitive* layer that actually shells
  out via the `cradle` process library. The argument vectors are computed by two
  **pure** functions so they can be unit-tested without Docker or Nixpacks:
  - `dockerBuildArgs :: Text -> FilePath -> FilePath -> [(Text, Text)] -> [String]`
    currently returns `["build", "-f", dockerfile, "-t", ref] <> <--build-arg
    flags> <> [context]`.
  - `nixpacksBuildArgs :: Text -> FilePath -> [(Text, Text)] -> [String]` currently
    returns `["build", context, "--name", ref] <> <--env flags>`.
  Their `IO` siblings `buildDockerfile` and `buildNixpacks` simply run `docker`
  resp. `nixpacks` with those argument vectors.

The critical fact for this plan: **neither `dockerBuildArgs` nor
`nixpacksBuildArgs` currently emits any `--platform`.** With no `--platform` and no
`DOCKER_DEFAULT_PLATFORM`, the build uses the daemon's native architecture. That is
the bug.

**The target profile, in three mirrored places.** The configurable GCP target
(project, region, zone, and derived names) is read from a per-operator profile.
There are three artifacts you will touch, and they must stay consistent:

1. `cli/nagarectl/src/Nagare/Target.hs` — the Haskell source of truth. It defines
   the record `TargetProfile` (one strict `!Text` field per profile value) and
   `resolveTargetProfile :: IO TargetProfile`, which reads each value from the
   process environment via the helper `envOr :: String -> Text -> IO Text`. `envOr`
   returns the env var's value if set and non-empty, otherwise a default — this is
   precisely the rule "environment variable > built-in default". (The *profile
   file* sits between them because `.envrc`/`target.sh` export the file's values
   into the environment before `nagarectl` runs; from Haskell's point of view a
   profile value simply arrives as an env var. So the full precedence chain
   "environment > profile file > default" is honored without `Target.hs` doing
   anything file-specific.)

2. `nagare.target.env.example` (repository root) — the tracked, documented schema
   and worked example. Each profile variable has a commented `export NAME=value`
   line carrying the original `tan-nb-exp` example value.

3. `scripts/lib/target.sh` — the shell mirror sourced by bash tooling. It sources
   `nagare.target.env` (if present) and then derives `TARGET_*` variables with the
   historic fallback defaults.

A fourth, generated artifact is the renderer `renderTargetEnv` in
`cli/nagarectl/src/Nagare/Init.hs`: `nagarectl init` writes a fresh
`nagare.target.env` by emitting one `export` line per profile field. Because this
plan adds a field, `renderTargetEnv` must emit it too, or `nagarectl init` would
write an incomplete profile.

**How a `TargetProfile` reaches the build today.** In `cli/nagarectl/app/Main.hs`,
`runDeploy :: DeployOpts -> IO ()` (around line 1726) already binds:

```haskell
tp <- resolveTargetProfile      -- ~line 1732
```

and uses `tp` immediately to qualify the image reference. Further down, inside the
non-dry-run branch (~line 1817), it calls:

```haskell
performBuild (addBuildArgs bargs spec) ref
```

`tp` is in scope here. So threading the platform requires no new resolution call —
only passing one more argument through `performBuild` into the `Nagare.Image`
builders.

**The test suite.** `cli/nagarectl/test/Spec.hs` is a `tasty` suite (run with
`cabal test nagarectl-test`; 258 tests pass today). The relevant existing groups:

- `targetProfileTests` (around line 346) is a *single* sequential `testCase` named
  `"resolveTargetProfile honors env vars and falls back to defaults"`. It mutates
  the process environment, asserts the resolved fields, and restores the original
  environment in a `finally`. Its `where`-bound `allTargetVars` list enumerates the
  nine profile env vars so they can all be cleared between sub-cases. This is the
  pattern your new precedence assertions must follow.
- `tnbProfile` (around line 332) is a fixed `TargetProfile` literal carrying the
  `tan-nb-exp` worked-example values, used by tests that need a profile value.
  Adding a record field will make this literal (and the `initProfile` literal near
  line 244, and any others) fail to compile until you add the new field — that is
  expected and is the cheapest possible reminder that you've touched the record.
- Build-argument render tests exist for `dockerBuildArgs`/`nixpacksBuildArgs`
  (search `Spec.hs` for `dockerBuildArgs` and `nixpacksBuildArgs`); your new
  `--platform` assertions extend those.

**Definitions of terms used below.**
- *Platform string* — Docker's `os/arch[/variant]` identifier, e.g. `linux/amd64`,
  `linux/arm64`. This is the exact string `docker build --platform` and
  `nixpacks build --platform` expect.
- *Architecture* — the `arch` part alone, e.g. `amd64`. `docker image inspect
  --format '{{.Architecture}}'` reports this (so a `linux/amd64` platform yields
  architecture `amd64`).
- *Build daemon* — the Docker engine doing the build. On Apple Silicon with colima
  or Docker Desktop it is natively `arm64`.


## Plan of Work

The work is three milestones. M1 adds the field to the profile (all three mirrors
plus the generated renderer) with precedence tests, and is independently
verifiable by the test suite alone. M2 threads the field into the build and passes
`--platform`, verifiable by pure render tests. M3 is an end-to-end demonstration
that the built image is `linux/amd64` without the env var.

The guiding constraint across all three: **do not weaken or bypass the existing
precedence rule** (environment variable > profile file > built-in default), and
**do not touch the frontmatter of this file or any unrelated code**. In
particular, do **not** edit `cli/nagarectl/src/Nagare/Ops/Doctor.hs` or
`Probe.hs` — EP-4 (docs/plans/68) owns the build/node arch-mismatch `doctor`
check and will *read* the field you add here; adding the doctor check is out of
scope for EP-3.


### Milestone 1 — Add the target-platform field to the profile

**Scope.** Introduce `NAGARE_TARGET_PLATFORM` (default `linux/amd64`) as a
first-class profile value in all three mirrors and in the `nagarectl init`
renderer, with tests proving env > profile > default precedence. At the end of
this milestone the field exists and round-trips, but nothing consumes it yet, so
build behavior is unchanged. That is fine — M1 is verifiable purely by the test
suite.

**Edits.**

1. `cli/nagarectl/src/Nagare/Target.hs`. Add one strict field to the
   `TargetProfile` record. Place it **last** in the record so the existing field
   order is undisturbed and EP-6's future SSH field can append after it cleanly:

   ```haskell
   , tpInstanceName :: !Text
   -- ^ NAGARE_INSTANCE_NAME, default @"nagare-01"@
   , tpTargetPlatform :: !Text
   -- ^ NAGARE_TARGET_PLATFORM, the Docker platform string the cluster node runs,
   -- default @"linux/amd64"@. Passed verbatim to @docker build --platform@ and
   -- @nixpacks build --platform@ (EP-3). The node is amd64; an operator whose
   -- node differs overrides this in @nagare.target.env@.
   ```

   In `resolveTargetProfile`, add the resolution line alongside the others, using
   the same `envOr` helper so the precedence is identical to every other field:

   ```haskell
   instanceName <- envOr "NAGARE_INSTANCE_NAME" "nagare-01"
   targetPlatform <- envOr "NAGARE_TARGET_PLATFORM" "linux/amd64"
   ```

   and add `tpTargetPlatform = targetPlatform` to the returned record literal. Do
   **not** export anything new from the module header beyond what is already there
   — `TargetProfile (..)` already re-exports all fields, and the field accessor
   `tpTargetPlatform` comes along automatically. (Note: `Nagare.Target`'s explicit
   export list is `TargetProfile (..)`? Verify: it currently lists `TargetProfile
   (..)`, `resolveTargetProfile`, `registryPrefix`. The `(..)` exports every field
   accessor, so no header change is needed.)

2. `nagare.target.env.example` (repo root). Append a new commented section after
   the `NAGARE_INSTANCE_NAME` line (keep it last so EP-6 appends after it):

   ```bash
   # --- Build target architecture ---

   # Docker platform string for images nagarectl BUILDS (Dockerfile or Nixpacks).
   # It must match the cluster node's architecture, because an image built for the
   # wrong architecture cannot run on the node (the pod fails with "exec format
   # error"). The node is amd64, hence the default. nagarectl passes this verbatim
   # to `docker build --platform` and `nixpacks build --platform`, so you no longer
   # need to export DOCKER_DEFAULT_PLATFORM by hand. Override only if your node is a
   # different architecture (e.g. linux/arm64).
   export NAGARE_TARGET_PLATFORM=linux/amd64
   ```

3. `scripts/lib/target.sh`. Add the shell-side mirror after the existing
   `TARGET_ZONE` derivation, following the identical `${VAR:-default}` pattern:

   ```bash
   TARGET_PLATFORM="${NAGARE_TARGET_PLATFORM:-linux/amd64}"
   ```

   No bash tooling consumes `TARGET_PLATFORM` today (the builder is the Haskell
   path), but adding it keeps the shell mirror complete and ready, exactly as
   `TARGET_REGION`/`TARGET_ZONE` are present though only some scripts use them. A
   one-line comment above it should say so: `# Build platform for nagarectl image
   builds (EP-3); mirrored here for completeness.`

4. `cli/nagarectl/src/Nagare/Init.hs`. In `renderTargetEnv`, append the new export
   line after the `NAGARE_INSTANCE_NAME` line so `nagarectl init` writes a complete
   profile:

   ```haskell
   , "export NAGARE_INSTANCE_NAME=" <> tpInstanceName tp
   , "export NAGARE_TARGET_PLATFORM=" <> tpTargetPlatform tp
   ```

   `seedKeys` (the Pulumi-config projection in the same file) does **not** need a
   new entry: the platform is a *build-time client* concern, not GCP
   infrastructure, so Pulumi has no use for it. Note that explicitly in a code
   comment near `seedKeys` to forestall a future contributor adding it
   unnecessarily.

**Tests (M1).**

- In `cli/nagarectl/test/Spec.hs`, the literals `tnbProfile` (~line 332) and
  `initProfile` (~line 244), plus any other `TargetProfile {...}` literal, will
  stop compiling until you add `tpTargetPlatform = "linux/amd64"` (for `tnbProfile`
  and any tan-nb-exp literal) or an apt value for `initProfile`. Add the field to
  each.
- Extend `targetProfileTests`: add `"NAGARE_TARGET_PLATFORM"` to the
  `allTargetVars` `where`-list (so it is cleared between sub-cases), and add
  assertions in each numbered sub-case:
  - sub-case (1) "nothing set": `tpTargetPlatform tp0 @?= "linux/amd64"`.
  - a new sub-case (or extend (2)): after `setEnv "NAGARE_TARGET_PLATFORM"
    "linux/arm64"`, assert `tpTargetPlatform <$> resolveTargetProfile` is
    `"linux/arm64"` — proving the environment value (which is also how a profile
    value arrives) overrides the default.
  - assert the empty-string-is-unset rule the helper guarantees: after `setEnv
    "NAGARE_TARGET_PLATFORM" ""`, the resolved value falls back to `"linux/amd64"`.
- Add a test for `renderTargetEnv` (mirror the existing
  `"renderTargetEnv emits the export lines with the right values"` test near line
  262): assert `T.isInfixOf "export NAGARE_TARGET_PLATFORM=linux/amd64" out` for a
  profile with the default platform, and that a profile with `tpTargetPlatform =
  "linux/arm64"` renders `linux/arm64`.

**Acceptance (M1).** `cd cli/nagarectl && cabal build` compiles, and `cabal test
nagarectl-test` passes with the new assertions. The default resolves to
`linux/amd64`; a set `NAGARE_TARGET_PLATFORM` overrides it; `nagarectl init`'s
rendered profile includes the line.


### Milestone 2 — Pass `--platform` to docker build and nixpacks build

**Scope.** Make the builders emit `--platform <platform>`, threading the resolved
platform from `runDeploy`'s `tp` down through `performBuild`. At the end, a
build-mode deploy builds for the configured platform with no env var. Verifiable by
pure render tests (no Docker needed) and by `--dry-run` output.

**Edits.**

1. `cli/nagarectl/src/Nagare/Image.hs`. Thread the platform as a new argument into
   both pure arg-vector functions and their `IO` runners. The platform goes
   **immediately after `build`** in the vector, which is the conventional position
   and the position `docker`/`nixpacks` accept:

   ```haskell
   dockerBuildArgs :: Text -> Text -> FilePath -> FilePath -> [(Text, Text)] -> [String]
   dockerBuildArgs platform ref dockerfile context args =
     ["build", "--platform", T.unpack platform, "-f", dockerfile, "-t", T.unpack ref]
       <> concatMap (\(k, v) -> ["--build-arg", T.unpack (k <> "=" <> v)]) args
       <> [context]

   buildDockerfile :: Text -> Text -> FilePath -> FilePath -> [(Text, Text)] -> IO ()
   buildDockerfile platform ref dockerfile context args =
     run_ $ cmd "docker" & addArgs (dockerBuildArgs platform ref dockerfile context args)

   nixpacksBuildArgs :: Text -> Text -> FilePath -> [(Text, Text)] -> [String]
   nixpacksBuildArgs platform ref context args =
     ["build", context, "--platform", T.unpack platform, "--name", T.unpack ref]
       <> concatMap (\(k, v) -> ["--env", T.unpack (k <> "=" <> v)]) args

   buildNixpacks :: Text -> Text -> FilePath -> [(Text, Text)] -> IO ()
   buildNixpacks platform ref context args =
     run_ $ cmd "nixpacks" & addArgs (nixpacksBuildArgs platform ref context args)
   ```

   (Choose the *first* positional argument for `platform` consistently across all
   four signatures so call sites read uniformly. The exact position is a style
   choice; what matters is that the emitted vector places `--platform <value>`
   where the tool accepts it. For `nixpacks build` the validated form is `nixpacks
   build <context> --platform <os/arch> --name <ref> [--env K=V ...]`, with a single
   platform; see Surprises & Discoveries for why single-platform needs no buildx
   driver.)

2. `cli/nagarectl/src/Nagare/Build.hs`. Give `performBuild` the platform. The
   cleanest signature is to add it as a leading `Text` argument:

   ```haskell
   performBuild :: Text -> BuildSpec -> Text -> IO ()
   performBuild platform spec ref = case spec of
     PrebuiltImage _ -> pure ()
     DockerfileBuild df ctx args ->
       buildDockerfile platform ref (T.unpack (filePathText df)) (T.unpack (filePathText ctx)) (Map.toList args)
     NixpacksBuild ctx args -> do
       ensureNixpacks
       buildNixpacks platform ref (T.unpack (filePathText ctx)) (Map.toList args)
   ```

   Also enrich `describeBuild` so `--dry-run` reveals the platform (it currently
   shows neither). Either give `describeBuild` the platform too, e.g.:

   ```haskell
   describeBuild :: Text -> BuildSpec -> Text
   describeBuild platform = \case
     PrebuiltImage t -> "prebuilt image (no local build), tag " <> tagText t
     DockerfileBuild df ctx _ ->
       "docker build --platform " <> platform <> " -f " <> filePathText df <> " " <> filePathText ctx
     NixpacksBuild ctx _ ->
       "nixpacks build --platform " <> platform <> " " <> filePathText ctx
   ```

   (Threading the platform into `describeBuild` is recommended because the dry-run
   line is the operator's confirmation that the right platform will be used. If you
   prefer to keep `describeBuild`'s arity, document why in the Decision Log; the
   default recommendation is to thread it.)

3. `cli/nagarectl/app/Main.hs`. At the two call sites in `runDeploy`, pass
   `tpTargetPlatform tp`:
   - the `--dry-run` branch (~line 1805): `TIO.putStrLn ("Build mode: " <>
     describeBuild (tpTargetPlatform tp) spec)`.
   - the build branch (~line 1817): `performBuild (tpTargetPlatform tp)
     (addBuildArgs bargs spec) ref`.

   `tp` is already bound at ~line 1732 (`tp <- resolveTargetProfile`), so no new
   resolution is needed. Confirm by searching `Main.hs` for `describeBuild` and
   `performBuild` that these are the only call sites in the deploy path. If
   `describeBuild`/`performBuild` are also called from the static-site or
   server-site deploy paths (search the whole file), update those call sites too,
   resolving/`tp`-threading the platform there as well; if those paths use a
   different builder (`Nagare.Server.Build`, `Nagare.Static.Build`) that does not
   route through `Nagare.Build.performBuild`, they are out of scope for this plan
   and you should note that in the Decision Log. (Research note: the app deploy
   path is the one the audit exercised and is the required target of this plan; the
   static/server paths use `Nagare.Image.buildImage` directly — `docker build -t
   <ref> <context>` with no `-f` — and if you want full coverage you may add the
   `--platform` there analogously, but the *required* deliverable is the app build
   path via `performBuild`.)

**Tests (M2).**

- Update the existing `dockerBuildArgs`/`nixpacksBuildArgs` render tests to pass a
  platform argument and assert the vector now contains `"--platform"` immediately
  followed by the platform string. Add a focused assertion such as:

  ```haskell
  testCase "dockerBuildArgs includes --platform" $
    dockerBuildArgs "linux/amd64" "reg/app:tag" "Dockerfile" "." []
      @?= ["build", "--platform", "linux/amd64", "-f", "Dockerfile", "-t", "reg/app:tag", "."]
  ```

  and the analogous one for `nixpacksBuildArgs`:

  ```haskell
  testCase "nixpacksBuildArgs includes --platform" $
    nixpacksBuildArgs "linux/amd64" "reg/app:tag" "." []
      @?= ["build", ".", "--platform", "linux/amd64", "--name", "reg/app:tag"]
  ```

- Add a `describeBuild` test asserting the dry-run string contains `--platform
  linux/amd64` for both a Dockerfile and a Nixpacks spec.

**Acceptance (M2).** `cabal test nagarectl-test` passes, including the new
`--platform` assertions. A `nagarectl deploy --dry-run` on a build-mode app prints
a `Build mode:` line that contains `--platform linux/amd64`.


### Milestone 3 — Demonstrate a node-runnable image with no env var

**Scope.** Prove the user-visible outcome: with **no** `DOCKER_DEFAULT_PLATFORM`
exported, a Dockerfile build through `nagarectl` produces a `linux/amd64` image.
This milestone is a demonstration plus recorded evidence in this plan; it adds no
new production code.

**How to demonstrate.** On a machine whose Docker daemon is *not* natively amd64
(an Apple Silicon Mac with colima/Docker Desktop is the canonical case), with a
clean environment:

```bash
# Make sure the foot-gun env var is NOT set, to prove we no longer depend on it.
unset DOCKER_DEFAULT_PLATFORM

# Use any app that builds from a Dockerfile. The repo's example configs under
# docs/ or examples/ that declare a Dockerfile build work; or create a throwaway
# Dockerfile that does `FROM alpine` so the build is fast.
cd /path/to/a/dockerfile-app
nagarectl deploy --file nagare/Config.hs --dry-run
# Observe: the "Build mode:" line contains "--platform linux/amd64".
```

Then perform a real (non-dry-run) build and inspect the produced image's
architecture. The image reference printed/used by the deploy is the one to
inspect; capture it (it is `imageRef dep' effTag` in `runDeploy`). Two equivalent
checks:

```bash
# Direct architecture read (simplest):
docker image inspect <built-ref> --format '{{.Architecture}}'
# Expected output:
# amd64

# Or, via buildx imagetools (works against the registry after push):
docker buildx imagetools inspect <built-ref>
# Expected: the manifest lists Platform: linux/amd64
```

To make the contrast unmistakable, you can run the same build with the *old*
behavior simulated — temporarily revert the `--platform` flag (or check out the
pre-change commit) on the same arm64 daemon — and confirm the architecture comes
back `arm64`. Record both outputs (pass: `amd64`; the without-flag baseline:
`arm64`) in the Surprises & Discoveries section as the evidence that the flag is
load-bearing.

**Acceptance (M3).** The built image's architecture is `amd64` on an arm64 build
daemon with `DOCKER_DEFAULT_PLATFORM` unset, and the recorded transcript in this
plan shows it. This is the concrete fix for the 2026-06-10 audit foot-gun.


## Concrete Steps

All commands assume the repository root `/Users/shinzui/Keikaku/bokuno/nagare` as
the starting directory unless a `cd` is shown. The Haskell project lives in
`cli/nagarectl/`.

Build and test the CLI:

```bash
cd cli/nagarectl
cabal build
cabal test nagarectl-test
```

Expected tail of a passing run (numbers will grow as you add tests; 258 pass
today):

```text
All NNN tests passed (… s)
Test suite nagarectl-test: PASS
```

Inspect the edited profile mirrors after M1 (sanity check that the field appears
in all three places):

```bash
grep -n NAGARE_TARGET_PLATFORM nagare.target.env.example scripts/lib/target.sh cli/nagarectl/src/Nagare/Target.hs cli/nagarectl/src/Nagare/Init.hs
```

Expected: a hit in each of the four files.

Dry-run a build-mode deploy (after M2) to see the platform in the description:

```bash
cd /path/to/a/dockerfile-app
nagarectl deploy --file nagare/Config.hs --dry-run | grep "Build mode:"
# -> Build mode: docker build --platform linux/amd64 -f Dockerfile .
```

Override demonstration (precedence):

```bash
NAGARE_TARGET_PLATFORM=linux/arm64 nagarectl deploy --file nagare/Config.hs --dry-run | grep "Build mode:"
# -> Build mode: docker build --platform linux/arm64 -f Dockerfile .
```

Architecture proof (after a real build, M3):

```bash
docker image inspect <built-ref> --format '{{.Architecture}}'
# -> amd64
```


## Validation and Acceptance

The plan is complete when all of the following hold:

1. `cd cli/nagarectl && cabal test nagarectl-test` passes, including: the extended
   `targetProfileTests` proving `NAGARE_TARGET_PLATFORM` resolves to `linux/amd64`
   by default and to an overriding value when set (env > profile > default); the
   `renderTargetEnv` test proving the line is emitted; and the
   `dockerBuildArgs`/`nixpacksBuildArgs`/`describeBuild` tests proving `--platform`
   is rendered.
2. A build-mode `nagarectl deploy --dry-run` shows `--platform linux/amd64` in the
   `Build mode:` line; with `NAGARE_TARGET_PLATFORM=linux/arm64` it shows
   `linux/arm64`. This proves the value flows from the profile to the command.
3. On an arm64 build daemon with `DOCKER_DEFAULT_PLATFORM` unset, a real Dockerfile
   build through `nagarectl` yields an image whose `docker image inspect … --format
   '{{.Architecture}}'` is `amd64`. This is the user-visible behavior the plan
   exists to deliver, and it must be demonstrated, not merely compiled.

Acceptance is phrased as behavior: an operator who has never heard of
`DOCKER_DEFAULT_PLATFORM` can deploy a build-mode app from an Apple Silicon laptop
and get an image the amd64 node can run.


## Idempotence and Recovery

Every edit in this plan is additive and re-runnable. Adding a record field, an
`envOr` line, an example-file line, a `target.sh` line, a render line, and a
build-argument element are all deterministic source edits; re-applying them (or
re-running `cabal build`/`cabal test`) causes no drift. There is no migration and
nothing destructive: no files are deleted, no cluster state changes, no GCP calls
are made by these edits. `nagarectl init` writing the new line into a fresh
`nagare.target.env` is idempotent in the same way `init` already is (it is gated by
`--force` for overwrite).

If the build breaks after adding the record field, the cause is almost always a
`TargetProfile {…}` record literal somewhere (in `Spec.hs`, `Init.hs`, or a fixture)
that does not yet mention `tpTargetPlatform`; the compiler names the file and line.
Add the field there. To back the whole change out, revert the edits to the six
files this plan touches (`Target.hs`, `Init.hs`, `Build.hs`, `Image.hs`, `Main.hs`,
`Spec.hs`) plus `nagare.target.env.example` and `scripts/lib/target.sh`; nothing
outside those is affected.


## Interfaces and Dependencies

**Modules and functions that must exist at the end of each milestone.**

End of M1:

- `Nagare.Target.TargetProfile` gains the field `tpTargetPlatform :: !Text`
  (placed last in the record).
- `Nagare.Target.resolveTargetProfile :: IO TargetProfile` resolves it from
  `NAGARE_TARGET_PLATFORM` via the existing `envOr :: String -> Text -> IO Text`
  helper, default `"linux/amd64"`.
- `Nagare.Init.renderTargetEnv :: TargetProfile -> Text` emits `export
  NAGARE_TARGET_PLATFORM=<value>` as its last line.
- `nagare.target.env.example` and `scripts/lib/target.sh` carry the mirrored line
  (`export NAGARE_TARGET_PLATFORM=linux/amd64` and `TARGET_PLATFORM="${…:-linux/amd64}"`
  respectively).

End of M2:

- `Nagare.Image.dockerBuildArgs :: Text -> Text -> FilePath -> FilePath ->
  [(Text, Text)] -> [String]` and `nixpacksBuildArgs :: Text -> Text -> FilePath ->
  [(Text, Text)] -> [String]` take the platform as their leading `Text` argument
  and emit `--platform <platform>`. Their `IO` runners `buildDockerfile` /
  `buildNixpacks` take the platform correspondingly.
- `Nagare.Build.performBuild :: Text -> BuildSpec -> Text -> IO ()` and
  `Nagare.Build.describeBuild :: Text -> BuildSpec -> Text` take the platform.
- `cli/nagarectl/app/Main.hs`'s `runDeploy` passes `tpTargetPlatform tp` at both
  call sites.

**External tools relied upon.**

- `docker build` (legacy builder or BuildKit) accepts `--platform <os/arch>` and an
  explicit flag overrides the `DOCKER_DEFAULT_PLATFORM` env var. No buildx driver
  is required for a single platform on a daemon that supports the requested
  architecture via emulation (Docker Desktop / colima ship QEMU emulation, so an
  arm64 daemon can build linux/amd64).
- `nixpacks build` accepts `--platform <os/arch>` for a *single* platform; only
  comma-separated multi-platform requires a `docker buildx` driver. This plan only
  ever passes one platform, so the plain path suffices (Surprises & Discoveries).

**Integration Contract — MasterPlan 13 Integration Point #2 (READ THIS).**

EP-3 (this plan) is the **first writer** of the shared target-profile schema that
two plans extend: the record `Nagare.Target.TargetProfile`, the env-file schema
`nagare.target.env(.example)`, and the shell mirror `scripts/lib/target.sh`. EP-6
(docs/plans/70, "CLI and Operator-Harness Ergonomics") is the **second writer**: it
will later add a *separate* field, the SSH user `NAGARE_SSH_USER` (default
`deploy`), to the **same** record and schema, and read it from `scripts/lib/target.sh`
for `scripts/iap-ssh.sh`.

To let EP-6 append cleanly, this plan deliberately:

- Adds `tpTargetPlatform` as the **last** field of the record, so EP-6's
  `tpSshUser` appends after it without reordering existing fields.
- Adds `export NAGARE_TARGET_PLATFORM=…` as the **last** line of
  `nagare.target.env.example` and of `renderTargetEnv`, so EP-6's
  `export NAGARE_SSH_USER=deploy` appends after it in the same style.
- Adds `TARGET_PLATFORM="${NAGARE_TARGET_PLATFORM:-linux/amd64}"` as the last
  derivation in `scripts/lib/target.sh`, so EP-6's
  `TARGET_SSH_USER="${NAGARE_SSH_USER:-deploy}"` appends after it.
- Follows the precedence rule documented in `CLAUDE.md` and EP-60 verbatim —
  environment variable > profile file > built-in default — implemented for free by
  reusing `envOr` (Haskell) and `${VAR:-default}` (shell). EP-6 must use the same
  two mechanisms.

**EP-3 does NOT add the SSH-user field.** That is EP-6's deliverable. This plan
only guarantees the schema is extensible and documents the conventions above so
EP-6 can follow them.

EP-4 (docs/plans/68, "Doctor Diagnostics Correctness") will later *read*
`tpTargetPlatform` to implement a build/node architecture-mismatch `doctor` check.
EP-3 must **not** edit `cli/nagarectl/src/Nagare/Ops/Doctor.hs` or `Probe.hs`; it
only provides the field EP-4 consumes.
