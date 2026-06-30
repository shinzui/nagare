---
id: 83
slug: decouple-nagarectl-deploy-and-build-from-gcp-for-local-mode
title: "Decouple nagarectl deploy and build from GCP for local mode"
kind: exec-plan
created_at: 2026-06-30T00:56:38Z
intention: "intention_01kwb012h6ebgs5qjn5r12nyda"
master_plan: "docs/masterplans/16-local-development-and-testing-for-nagare.md"
---

# Decouple nagarectl deploy and build from GCP for local mode

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the Haskell command-line tool **`nagarectl`** (the program operators run to deploy
apps, snapshot volumes, take database backups, and check platform health) can only build,
push, and deploy against Google Cloud Platform (GCP). Before it builds an app image it
shells out to **`gcloud auth configure-docker <host>`** to teach Docker how to authenticate
to Google Artifact Registry, and it pushes to that registry. There is no way to make
`nagarectl deploy` work without a `gcloud` binary and a GCP account, so an operator cannot
exercise a real deploy on their laptop.

After this change, an operator who has stood up the local cluster from the prerequisite plan
EP-82 (a [k3d](https://k3d.io/) cluster — k3s packaged to run inside Docker — with a local
container registry and a Knative + Kourier ingress stack) and selected **local mode** by
exporting `NAGARE_MODE=local` can run the **same** `nagarectl deploy` end to end with **no
`gcloud` and no GCP account**. In local mode `nagarectl` resolves a *mode* from the
environment, **skips `gcloud auth configure-docker` entirely** (a local k3d registry needs no
Google credential helper), pushes the built image to the local registry named by
`NAGARE_REGISTRY_HOST`, builds for the host architecture named by `NAGARE_TARGET_PLATFORM`,
and serves the app on the loopback base domain named by `NAGARE_BASE_DOMAIN` (for example
`127-0-0-1.sslip.io`, a wildcard domain where every `*.127-0-0-1.sslip.io` name resolves to
`127.0.0.1` with no DNS setup).

The user-visible behavior you will be able to demonstrate at the end:

- With `NAGARE_MODE` unset (or `cloud`) and the cloud target profile in place, `nagarectl`
  behaves **exactly** as it does today: it runs `gcloud auth configure-docker`, pushes to
  Artifact Registry, and deploys to the cloud base domain — proving no regression.
- With `NAGARE_MODE=local` and the EP-82 local profile in place, `NAGARE_MODE=local nagarectl
  deploy` on the shipped example `cluster/examples/dockerfile-app` builds the image for the
  host platform, pushes it to the local registry, applies the Knative Service, waits for it to
  become Ready, and `curl http://dockerfile-app.<namespace>.127-0-0-1.sslip.io` returns
  **HTTP 200** — with **zero `gcloud` invocations** (provable by running with `gcloud` absent
  from `PATH`, and by a unit test asserting the `gcloud` argv is never constructed in local
  mode).
- The static `nagarectl site deploy` and the server-site deploy path honor the same mode: in
  local mode they skip `gcloud auth configure-docker`, push to the local registry, and serve
  on the loopback domain.

This plan touches only Haskell under `cli/nagarectl/` (plus tests). It hard-depends on EP-82
(`docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md`), which
defines the `NAGARE_MODE` switch, the `nagare.local.env` profile, the local registry host,
the loopback base domain, and the host build platform — and stands up the cluster this plan
deploys against. The variables this plan reads, and the cloud-preserving defaults, are
restated in full below so the plan is self-contained. This plan **owns** MasterPlan 16's
Integration Point 2 (the Haskell `Mode` type and the conditional Docker auth); EP-84 and
EP-85 import the `Mode` type from here and never re-derive the mode from the environment
themselves.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1.1 — Add `data Mode = Cloud | Local` (deriving `Eq`, `Show`) and `parseMode :: Maybe
      String -> Mode` to `cli/nagarectl/src/Nagare/Target.hs`; export both plus the new
      `tpMode` accessor. (Done 2026-06-29.)
- [x] M1.2 — Extend the `TargetProfile` record with `tpMode :: !Mode`; resolve it in
      `resolveTargetProfile` from `NAGARE_MODE` (default `Cloud`); update every literal
      `TargetProfile{..}` builder in the test suite to set `tpMode`. (Done 2026-06-29 — the only
      fresh literals are `initProfile`/`tnbProfile` in Spec.hs; `Init.hs` uses record-update on
      `resolveTargetProfile`, no change.)
- [x] M1.3 — Add `modeResolutionTests` to `cli/nagarectl/test/Spec.hs` (unset → `Cloud`;
      `local` → `Local`; `cloud`/`LOCAL`/garbage cases) and the `parseMode` pure-table test;
      `cabal test` green. (Done 2026-06-29.)
- [x] M2.1 — Add the pure `data DockerAuth = SkipDockerAuth | GcloudConfigureDocker [String]`
      and `dockerAuthPlan :: Mode -> Text -> DockerAuth` to `cli/nagarectl/src/Nagare/Image.hs`;
      export both. (Done 2026-06-29.)
- [x] M2.2 — Reimplement `configureDockerAuth :: IO ()` to resolve the profile, compute
      `dockerAuthPlan (tpMode tp) (tpRegistryHost tp)`, and run the `gcloud` argv only for
      `GcloudConfigureDocker`; `SkipDockerAuth` is a no-op. All six call sites unchanged.
      (Done 2026-06-29 — library + all six call sites recompiled clean.)
- [x] M2.3 — Add `dockerAuthPlanTests` to `cli/nagarectl/test/Spec.hs`: `Cloud` yields the
      `gcloud auth configure-docker <host> --quiet` argv; `Local` yields `SkipDockerAuth`
      (no `gcloud` argv built); `cabal test` green. (Done 2026-06-29 — all 328 tests pass,
      including both EP-83 groups.)
- [ ] M3.1 — Bring up the EP-82 local cluster (`just local-up` + `just local-bootstrap`) and
      export the local profile (`NAGARE_MODE=local`, `NAGARE_REGISTRY_HOST`,
      `NAGARE_BASE_DOMAIN`, `NAGARE_TARGET_PLATFORM`).
- [ ] M3.2 — Run `NAGARE_MODE=local nagarectl deploy` on `cluster/examples/dockerfile-app`;
      observe build for the host platform, push to the local registry, apply, wait Ready.
- [ ] M3.3 — `curl` the loopback URL and capture the HTTP-200 transcript; confirm zero
      `gcloud` calls (run with `gcloud` absent from `PATH`).
- [ ] M4.1 — Confirm `nagarectl site deploy` (static) honors mode: skips auth in local mode,
      pushes to the local registry, serves on the loopback domain.
- [ ] M4.2 — Confirm the server-site deploy path (`Nagare.Server.Deploy`) honors mode; decide
      whether `buildImage`/`prepareServerOutput` need the host `--platform` and adjust if so.
- [ ] M4.3 — Final regression: with `NAGARE_MODE` unset, both suites green and the cloud
      `dockerAuthPlan`/argv unchanged (record counts).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: model the mode as a closed sum type `data Mode = Cloud | Local` carried in
  `TargetProfile` as `tpMode`, not as a bare `Bool` (e.g. `tpLocal :: Bool`).
  Rationale: a named two-constructor type reads at every use site as the domain concept
  ("are we cloud or local?") rather than an opaque truth value whose polarity a reader must
  remember; it pattern-matches exhaustively so the compiler flags any future branch that
  forgets a case; and it is the public type EP-84 and EP-85 import across plan boundaries
  (MasterPlan 16, Integration Point 2) — a shared `Mode` is far clearer in their signatures
  than a shared `Bool`. It is also extensible: if a third target ever appears, adding a
  constructor surfaces every incomplete match. The cost (a few extra lines vs. a `Bool`) is
  negligible.
  Rationale-for-record: matches the house pattern of EP-62's `TargetProfile` (a typed record
  of resolved values, no raw `lookupEnv` downstream).
  Date: 2026-06-30

- Decision: factor the Docker-auth decision into a **pure** function `dockerAuthPlan :: Mode
  -> Text -> DockerAuth` (returning `SkipDockerAuth` or `GcloudConfigureDocker [String]`),
  and keep the `IO` shell `configureDockerAuth` a thin interpreter over it.
  Rationale: the acceptance criterion is "zero `gcloud` calls in local mode," which is a
  statement about which argv is constructed. A pure planner lets a unit test assert
  `dockerAuthPlan Local host == SkipDockerAuth` and `dockerAuthPlan Cloud host ==
  GcloudConfigureDocker ["auth","configure-docker", T.unpack host, "--quiet"]` deterministically,
  with **no Docker and no gcloud installed** — exactly the EP-62 precedent of pure,
  unit-testable arg vectors (`dockerBuildArgs`, `nixpacksBuildArgs`, the CDN argv builders).
  Compilation alone could not prove the gcloud call is gone; this test can.
  Date: 2026-06-30

- Decision: `configureDockerAuth` keeps its current signature `configureDockerAuth :: IO ()`
  and **resolves the `TargetProfile` internally**, rather than being changed to take a
  `Mode`/`TargetProfile` parameter threaded from each caller.
  Rationale: `configureDockerAuth` is called from six sites
  (`Nagare/App/Deploy.hs`, `app/Main.hs`, `Nagare/Static/Deploy.hs` ×2, `Nagare/Server/
  Deploy.hs`, `Nagare/Worker/Deploy.hs`); two of them (`deployStaticProduction`,
  `deployServerProduction`) have no `TargetProfile` in scope. EP-62 already established
  internal resolution for exactly this helper to avoid cascading signature changes through
  deploy modules that have no other need for the profile (see EP-62 Surprises & Decision Log).
  Keeping internal resolution means **no call site changes**, the local-vs-cloud branch lives
  in one place, and the negligible extra `lookupEnv` per deploy is the same cost EP-62 already
  accepted. The pure `dockerAuthPlan` carries the actual decision, so testability does not
  depend on threading the profile.
  Date: 2026-06-30

- Decision: in local mode `configureDockerAuth` is a **no-op** (`SkipDockerAuth`), not a
  `docker login` to the local registry.
  Rationale: EP-82's local registry (a k3d-managed registry such as
  `k3d-registry.localhost:5000`) is unauthenticated by design — both the host `docker push`
  and the in-cluster containerd pull reach it without credentials. A `docker login` would add
  a step that can fail (no credential store on a fresh machine) for no benefit. If a future
  local registry needs auth, the no-op becomes a `DockerLogin [String]` constructor on
  `DockerAuth` without disturbing the cloud path. The local registry prefix still comes from
  `NAGARE_REGISTRY_HOST`, so `qualifyImage` continues to prefix a name-only `Config.hs`
  correctly (a local registry accepts arbitrary nested repository paths like
  `<host>/<project>/nagare/<app>`).
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### What the pieces are (terms of art)

- **`nagarectl`** — the Haskell command-line program operators run to deploy apps, take
  backups, snapshot volumes, and check platform health. Its library lives under
  `cli/nagarectl/src/`, its `main` entry point in `cli/nagarectl/app/Main.hs`, and its tests
  in `cli/nagarectl/test/Spec.hs`. The test suite uses `tasty`/`tasty-hunit` (`testGroup`,
  `testCase`, `@?=`, `assertBool`).

- **target profile** — the typed record `Nagare.Target.TargetProfile` and the action
  `resolveTargetProfile :: IO TargetProfile` in
  `cli/nagarectl/src/Nagare/Target.hs`. It is the **single resolution point** for the deploy
  target: every value that used to be a compile-time literal (the GCP project, region, zone,
  registry host/id, image/backup buckets, base domain, VM instance name, and — since EP-3 —
  the Docker build platform `tpTargetPlatform`) is read once from the process environment with
  documented fallback defaults. Nothing downstream reads raw environment variables. EP-62
  (`docs/plans/62-parameterize-nagarectl-and-the-dsl-image-refs-to-the-target-profile.md`,
  checked in) created this layer; this plan adds one field (`tpMode`) to it.

- **local mode** — a second, parallel deploy target selected by the environment variable
  `NAGARE_MODE=local`, defined by EP-82
  (`docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md`). It swaps
  each GCP-backed primitive for a local equivalent: Artifact Registry → a local k3d registry;
  Cloud DNS → a wildcard loopback domain; the GCE VM → a k3d cluster. With `NAGARE_MODE` unset
  or set to `cloud`, nagare behaves exactly as today. This plan is what teaches the Haskell CLI
  to read that switch and branch its build/push/auth behavior on it.

- **k3d** — k3s (a lightweight Kubernetes) packaged to run inside Docker. EP-82 creates a k3d
  cluster with a paired local image registry and installs Knative Serving + the Kourier
  ingress on it. This plan does not create the cluster; it deploys against the one EP-82
  stands up.

- **Knative Service** — the single Kubernetes object a deploy produces: a request-driven
  workload (`serving.knative.dev/v1` kind `Service`, abbreviated `ksvc`). `nagarectl` renders
  it as pure YAML and applies it with `kubectl apply -f`. The rendered YAML has no GCP
  coupling (verified: `grep -i 'gcloud\|gcr.io\|pkg.dev\|cloudsdk\|googleapis'
  cli/nagare-dsl/src/Nagare/Dsl/Render.hs` returns nothing).

- **`gcloud auth configure-docker <host>`** — a Google Cloud SDK command that writes a Docker
  credential-helper entry so a subsequent `docker push` to Artifact Registry authenticates
  automatically. It is the **one** GCP shell-out on the build/push path, and the only thing
  this plan must make conditional. It is the entire reason `nagarectl deploy` cannot run
  without `gcloud` today.

- **sslip.io** — a public DNS service where a hostname embedding an IP resolves to that IP.
  `anything.127-0-0-1.sslip.io` resolves to `127.0.0.1`, so the loopback base domain
  `127-0-0-1.sslip.io` gives every `<app>.<namespace>.127-0-0-1.sslip.io` a working DNS name
  pointing at the local machine, with no `/etc/hosts` editing.

### The current build/push/auth path (what is GCP-coupled today)

The single GCP coupling on the deploy path is `configureDockerAuth` in
`cli/nagarectl/src/Nagare/Image.hs` (lines 96–106). Today it reads:

```haskell
-- | Run @gcloud auth configure-docker <host> --quiet@ for the resolved Artifact
-- Registry host (EP-62; the host comes from 'Nagare.Target.tpRegistryHost', ...).
configureDockerAuth :: IO ()
configureDockerAuth = do
  tp <- resolveTargetProfile
  run_ $
    cmd "gcloud"
      & addArgs ["auth", "configure-docker", T.unpack (tpRegistryHost tp), "--quiet"]
```

It already resolves the `TargetProfile` internally (EP-62's decision), so it has the profile in
hand — it just always runs `gcloud`. It is called **unconditionally before build + push** at
six sites, all in `IO`:

- `cli/nagarectl/src/Nagare/App/Deploy.hs:440` — `buildAndPushShared` (the `app deploy` path).
- `cli/nagarectl/app/Main.hs:2186` — `runDeploy` (the single-Service `deploy` command).
- `cli/nagarectl/src/Nagare/Static/Deploy.hs:116` and `:135` — static `site deploy`
  (production and preview).
- `cli/nagarectl/src/Nagare/Server/Deploy.hs:86` — `deployServerProduction`.
- `cli/nagarectl/src/Nagare/Worker/Deploy.hs:128` — `buildAndPush` (worker images).

Everything else on the path is **already portable**:

- **Build.** `cli/nagarectl/src/Nagare/Build.hs` `performBuild :: Text -> BuildSpec -> Text ->
  IO ()` runs `docker build --platform <platform> ...` or `nixpacks build --platform
  <platform> ...`. The platform string is `tpTargetPlatform tp` (env `NAGARE_TARGET_PLATFORM`,
  default `linux/amd64`). On Apple Silicon the developer sets `NAGARE_TARGET_PLATFORM=linux/arm64`
  so locally built images run on the local node. No GCP. (Note: the **static/server** site
  build uses `Nagare.Image.buildImage :: Text -> FilePath -> IO ()` at
  `cli/nagarectl/src/Nagare/Image.hs:55-57`, which runs `docker build -t <ref> <context>` with
  **no** `--platform` — see M4 for whether this needs the host platform.)
- **Push.** `Nagare.Image.pushImage :: Text -> IO ()` runs `docker push <ref>` against whatever
  registry the ref names. The registry comes from `qualifyImage`'s prefix, which is
  `registryPrefix tp = tpRegistryHost tp <> "/" <> tpProject tp <> "/" <>
  tpArtifactRegistryId tp`. In local mode `tpRegistryHost` is the local registry, so a
  name-only `Config.hs` image (e.g. `dockerfile-app`) qualifies to
  `<local-registry>/<project>/nagare/dockerfile-app`, which the local registry accepts. No GCP.
- **Apply.** `Nagare.Deploy.applyManifests :: [ByteString] -> IO ()`
  (`cli/nagarectl/src/Nagare/Deploy.hs:38-44`) writes each manifest to a temp file and runs
  `kubectl apply -f <file>` against whatever `KUBECONFIG` points at. In local mode that is the
  k3d kubeconfig EP-82 produces. No GCP, no change needed.
- **Wait.** `Nagare.Deploy.waitForReady` runs `kubectl wait --for=condition=Ready ksvc/...`. No
  GCP.
- **Render.** `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` produces pure Knative Service +
  DomainMapping YAML with no GCP coupling (grep confirmed above).

### The base-domain resolution (already mode-friendly)

The app deploy resolves the base domain at `cli/nagarectl/src/Nagare/App/Deploy.hs:389`:

```haskell
reBaseDomain = maybe (tpBaseDomain tp) id (adpBaseDomain p)
```

— the `--base-domain` CLI flag overrides; otherwise the profile's `tpBaseDomain` is used. The
site deploy resolves it via `app/Main.hs` `resolveBaseDomain` (which falls back to
`NAGARE_BASE_DOMAIN`/the profile). In local mode `tpBaseDomain` is the loopback domain
(`127-0-0-1.sslip.io`) the EP-82 profile sets, so **no code change is needed** for the base
domain — it already flows from the profile. This plan only has to make sure local mode resolves
that profile, which it does because `NAGARE_MODE` is just another profile field.

### The `tpTargetPlatform` field already exists

EP-3 already added `tpTargetPlatform :: !Text` to `TargetProfile` (env `NAGARE_TARGET_PLATFORM`,
default `linux/amd64`) and threaded it into `performBuild`. So the *build platform* half of
local mode is already in place; this plan does not re-add it. The only new field this plan adds
is `tpMode`.

### The environment-variable contract this plan reads (restated)

EP-82 (Integration Point 1) fixes these names; this plan reads them from the **process
environment** (EP-82's local profile, sourced into the shell, exports them). Precedence
everywhere: environment value if set and non-empty, else the built-in default.

```text
NAGARE_MODE              (the switch; "local" → Local; unset/"cloud"/anything-else → Cloud)
NAGARE_REGISTRY_HOST     (the registry to push to; e.g. k3d-registry.localhost:5000 in local mode)
NAGARE_BASE_DOMAIN       (the apps domain; e.g. 127-0-0-1.sslip.io in local mode)
NAGARE_TARGET_PLATFORM   (the docker build --platform; e.g. linux/arm64 on Apple Silicon)
```

`NAGARE_REGISTRY_HOST`, `NAGARE_BASE_DOMAIN`, and `NAGARE_TARGET_PLATFORM` are already resolved
by `TargetProfile`; only `NAGARE_MODE` is new in this plan. The exact local registry string and
loopback domain are EP-82's to fix; this plan's tests use representative values and the
end-to-end steps read whatever the active local profile sets.

### Files this plan edits

- `cli/nagarectl/src/Nagare/Target.hs` — add `Mode`, `parseMode`, `tpMode`, resolve from
  `NAGARE_MODE`.
- `cli/nagarectl/src/Nagare/Image.hs` — add `DockerAuth`, `dockerAuthPlan`; route
  `configureDockerAuth` through it.
- `cli/nagarectl/test/Spec.hs` — add `modeResolutionTests` and `dockerAuthPlanTests`; update
  every literal `TargetProfile{..}` to set `tpMode`.

### Scope boundary — what this plan does NOT do

It does not create the k3d cluster, the local registry, the `nagare.local.env` profile, or the
`NAGARE_MODE` switch's *definition* (all EP-82). It does not change `Nagare.Cluster.GcsJob` or
the backup/snapshot backend (EP-84). It does not touch the auth plane or local TLS (EP-85). It
does not write the smoke test or the runbook (EP-86). It writes no Haskell that makes a GCP
call, and it leaves the cloud path byte-for-byte unchanged.


## Plan of Work

The work is four milestones. **M1** adds a resolved `Mode` to the `TargetProfile` — verifiable
purely with `cabal test` and an env toggle, no cluster. **M2** makes Docker auth conditional via
a pure planner — verifiable by a unit test that asserts the `gcloud` argv is built in cloud mode
and absent in local mode, no Docker/gcloud needed. **M3** demonstrates a real end-to-end app
deploy in local mode against the EP-82 cluster returning HTTP 200 with zero `gcloud` calls.
**M4** confirms the static `site` and server-site deploy paths honor mode the same way. Each
milestone ends in observable behavior, not a mere added field.


### Milestone 1 — resolve a `Mode` from `NAGARE_MODE`

Scope: at the end of M1, `cli/nagarectl/src/Nagare/Target.hs` exposes `data Mode = Cloud |
Local` and `parseMode :: Maybe String -> Mode`, the `TargetProfile` record carries `tpMode ::
!Mode`, and `resolveTargetProfile` sets it from `NAGARE_MODE` (default `Cloud` when unset or set
to anything other than `local`, case-insensitively). No consumer branches on it yet, but a unit
test proves resolution. This is **Integration Point 2's public type**: give it a clean
signature because EP-84 and EP-85 import it.

What will exist that did not before: a typed mode field on the single target record, so any
consumer can ask `tpMode tp` instead of re-reading `NAGARE_MODE`.

Commands: `cd cli/nagarectl && cabal build && cabal test`. Acceptance: the new
`modeResolutionTests` group passes — `NAGARE_MODE` unset resolves `Cloud`; `NAGARE_MODE=local`
resolves `Local`; `NAGARE_MODE=cloud` and `NAGARE_MODE=LOCAL` and `NAGARE_MODE=nonsense` all
resolve per the documented rule (case-insensitive `local` → `Local`, else `Cloud`); and
`parseMode` returns the right constructor for each string without touching the environment.


### Milestone 2 — conditional Docker auth via a pure planner

Scope: at the end of M2, `cli/nagarectl/src/Nagare/Image.hs` exposes `data DockerAuth =
SkipDockerAuth | GcloudConfigureDocker [String]` and `dockerAuthPlan :: Mode -> Text ->
DockerAuth`, and `configureDockerAuth :: IO ()` runs the `gcloud` argv only when the plan is
`GcloudConfigureDocker` — a no-op in local mode. All six call sites are unchanged (the helper
still resolves the profile internally). The cloud path is byte-for-byte identical.

What will exist that did not before: the build/push path no longer shells out to `gcloud` in
local mode, and the decision is a pure value a test can inspect.

Commands: `cd cli/nagarectl && cabal test`. Acceptance: `dockerAuthPlanTests` asserts
`dockerAuthPlan Cloud "us-west1-docker.pkg.dev" == GcloudConfigureDocker ["auth",
"configure-docker", "us-west1-docker.pkg.dev", "--quiet"]` and `dockerAuthPlan Local
"k3d-registry.localhost:5000" == SkipDockerAuth` — the latter proves no `gcloud` argv is ever
constructed in local mode. This is the fail-before/pass-after evidence: before M2 there was no
branch and `gcloud` always ran.


### Milestone 3 — end-to-end app deploy in local mode (HTTP 200, zero gcloud)

Scope: at the end of M3, a real `NAGARE_MODE=local nagarectl deploy` of the shipped example
`cluster/examples/dockerfile-app` against the EP-82 cluster has been demonstrated: it builds the
image for `NAGARE_TARGET_PLATFORM` (the host arch), pushes it to the local registry named by
`NAGARE_REGISTRY_HOST`, applies the Knative Service, waits for Ready, and a `curl` to
`http://dockerfile-app.<namespace>.<NAGARE_BASE_DOMAIN>` returns HTTP 200 — with no `gcloud`
invocation. `cluster/examples/dockerfile-app` is chosen because it is the simplest build-mode
app shipped: a `Dockerfile` building `python:3.12-alpine` to serve a one-line page on port 8080,
with a name-only image (`dockerfile-app`) so `qualifyImage` exercises the local registry prefix.

What will exist that did not before: a recorded transcript proving the whole decoupled path runs
on a laptop with no GCP. The `hello-knative-service` example is **not** used here because it
points at a public `gcr.io` image and builds nothing — it would not exercise the local
build/push path.

Commands (from the repo root, inside `nix develop`, after EP-82's `just local-up` +
`just local-bootstrap`): export the local profile, then `cabal run nagarectl -- deploy
--config cluster/examples/dockerfile-app/nagare/Config.hs` (exact invocation in Concrete Steps),
then `curl`. Acceptance: the curl returns `HTTP/1.1 200 OK` and the page body is the
build-arg-baked message; running the same deploy with `gcloud` removed from `PATH` still
succeeds (proving zero gcloud dependence).


### Milestone 4 — static `site` and server deploy paths honor mode

Scope: at the end of M4, the static `nagarectl site deploy` and the server-site deploy
(`cli/nagarectl/src/Nagare/Server/Deploy.hs`) are confirmed to honor mode: they skip
`gcloud auth configure-docker` in local mode (automatic, since they call the same
`configureDockerAuth`), push to the local registry (automatic, since `qualifyImage` is applied
at `runSiteDeploy`, `app/Main.hs:2241/2244`, against the resolved profile), and serve on the
loopback domain (automatic, since `resolveBaseDomain` falls back to `tpBaseDomain`). The one
open question this milestone resolves: the static/server build uses `Nagare.Image.buildImage`,
which runs `docker build -t <ref> <context>` **without** `--platform`. On the developer's
machine `docker build` defaults to the host architecture, which is exactly the local node's
architecture, so the image runs — but it does not honor an explicit `NAGARE_TARGET_PLATFORM`. M4
decides whether to thread `tpTargetPlatform` into the static/server build for parity with the
app path; if the default-host-arch behavior is sufficient for local mode (it is, on a
single-arch laptop), it is left as a documented note rather than a code change.

What will exist that did not before: a confirmation (and, if needed, a one-line adjustment) that
the two static/server deploy commands work in local mode with the same zero-gcloud, local-
registry, loopback-domain behavior as the app deploy.

Commands: `cd cli/nagarectl && cabal test` (regression) plus, against the cluster,
`NAGARE_MODE=local cabal run nagarectl -- site deploy --file
cluster/examples/static-site/nagare/Config.hs` and a `curl` of the resulting URL. Acceptance:
the static site returns HTTP 200 over the loopback domain with no gcloud call; the suite stays
green.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless a working
directory is stated. The Haskell toolchain (`cabal`, `ghc`) comes from the repo's Nix dev shell;
if a command is not found, prefix it with `nix develop -c` or enter the shell with `nix develop`
first.


### Step M1.1 / M1.2 — add `Mode` and `tpMode` to `Nagare.Target`

Edit `cli/nagarectl/src/Nagare/Target.hs`. Extend the export list, add the `Mode` type and
`parseMode`, add the `tpMode` field, and resolve it. The full set of edits:

```haskell
module Nagare.Target
  ( TargetProfile (..)
  , Mode (..)
  , parseMode
  , resolveTargetProfile
  , registryPrefix
  ) where

import Data.Char (toLower)
```

Add the `Mode` type (place it above `TargetProfile`):

```haskell
-- | The deploy target's mode (MasterPlan 16, EP-83; this is Integration Point 2's
-- public type — EP-84 and EP-85 import it and must not re-derive the mode from the
-- environment themselves). 'Cloud' is the original GCP target; 'Local' selects the
-- local k3d cluster + local registry from EP-82. Resolved from @NAGARE_MODE@ in
-- 'resolveTargetProfile'; with the variable unset the mode is 'Cloud', so existing
-- behavior is unchanged.
data Mode = Cloud | Local
  deriving stock (Eq, Show)

-- | Parse the @NAGARE_MODE@ value. The string @"local"@ (case-insensitive) selects
-- 'Local'; anything else — including 'Nothing' (unset), @"cloud"@, and any
-- unrecognized value — is 'Cloud'. Defaulting unknown values to 'Cloud' keeps the
-- fail-safe direction: a typo never silently points a cloud operator at a
-- nonexistent local cluster.
parseMode :: Maybe String -> Mode
parseMode m = case fmap (map toLower) m of
  Just "local" -> Local
  _ -> Cloud
```

Add the field to the record (after `tpTargetPlatform`):

```haskell
  , tpMode :: !Mode
  -- ^ NAGARE_MODE; 'Local' selects the EP-82 local cluster, default 'Cloud'
  -- (unset or any non-@local@ value). Drives conditional Docker auth in
  -- 'Nagare.Image.configureDockerAuth' (EP-83).
```

Resolve it in `resolveTargetProfile` (add a line and set the field):

```haskell
  mode <- parseMode <$> lookupEnv "NAGARE_MODE"
  -- ... in the TargetProfile{..} record:
      , tpMode = mode
```

Note: `parseMode` takes the raw `Maybe String` from `lookupEnv` (it does not use `envOr`,
because an empty `NAGARE_MODE=""` is "not local," which `parseMode` already yields). Build:

```bash
cd cli/nagarectl && cabal build lib:nagarectl
```

Because `TargetProfile` gains a strict field, **every** literal `TargetProfile{..}` constructor
must set `tpMode` or the build fails with a missing-field warning/error. The known literal
builders are in `cli/nagarectl/test/Spec.hs` (`initProfile` ~line 287, `tnbProfile` ~line 386).
Set both to `tpMode = Cloud` (they assert the historic cloud defaults). Search for any others:

```bash
grep -rn 'TargetProfile$\|TargetProfile {' cli/nagarectl
```


### Step M1.3 — add `modeResolutionTests` to `cli/nagarectl/test/Spec.hs`

Import `Mode (..)` and `parseMode` alongside the existing `Nagare.Target` import. Add a pure
table test plus an env-driven test (the env test mutates the process environment, so save/restore
`NAGARE_MODE` with `finally`, matching the existing `targetProfileTests` pattern at Spec.hs
~line 401). Append `modeResolutionTests` to the top-level `testGroup` list.

```haskell
modeResolutionTests :: TestTree
modeResolutionTests =
  testGroup
    "Nagare.Target mode (EP-83)"
    [ testCase "parseMode: local (any case) is Local, else Cloud" $ do
        parseMode (Just "local") @?= Local
        parseMode (Just "LOCAL") @?= Local
        parseMode (Just "Local") @?= Local
        parseMode (Just "cloud") @?= Cloud
        parseMode (Just "") @?= Cloud
        parseMode (Just "prod") @?= Cloud
        parseMode Nothing @?= Cloud
    , testCase "resolveTargetProfile reads NAGARE_MODE" $ do
        saved <- lookupEnv "NAGARE_MODE"
        let restore = maybe (unsetEnv "NAGARE_MODE") (setEnv "NAGARE_MODE") saved
        flip finally restore $ do
          unsetEnv "NAGARE_MODE"
          tpC <- resolveTargetProfile
          tpMode tpC @?= Cloud
          setEnv "NAGARE_MODE" "local"
          tpL <- resolveTargetProfile
          tpMode tpL @?= Local
    ]
```

Run:

```bash
cd cli/nagarectl && cabal test
```

Expected (abridged): the `Nagare.Target mode (EP-83)` group reports `OK` for both cases.


### Step M2.1 / M2.2 — pure `dockerAuthPlan` + conditional `configureDockerAuth`

Edit `cli/nagarectl/src/Nagare/Image.hs`. Add `DockerAuth` and `dockerAuthPlan` to the export
list, import `Mode (..)` from `Nagare.Target`, and replace the body of `configureDockerAuth`.

```haskell
module Nagare.Image
  ( -- ... existing exports ...
  , configureDockerAuth
  , dockerAuthPlan
  , DockerAuth (..)
  -- ...
  ) where

import Nagare.Target (Mode (..), TargetProfile, registryPrefix, resolveTargetProfile, tpMode, tpRegistryHost)
```

Add the pure planner (place near `configureDockerAuth`):

```haskell
-- | The Docker-credential action for a given mode and registry host (EP-83,
-- MasterPlan 16 Integration Point 2). In 'Cloud' mode it is the
-- @gcloud auth configure-docker <host> --quiet@ argv that teaches Docker to
-- authenticate to Google Artifact Registry. In 'Local' mode it is 'SkipDockerAuth':
-- the EP-82 local registry is unauthenticated, so no credential helper — and in
-- particular no @gcloud@ — is invoked. Pure so a test can assert the argv is built
-- in cloud mode and never built in local mode, with neither Docker nor gcloud
-- installed.
data DockerAuth
  = SkipDockerAuth
  | GcloudConfigureDocker [String]
  deriving stock (Eq, Show)

dockerAuthPlan :: Mode -> Text -> DockerAuth
dockerAuthPlan Local _ = SkipDockerAuth
dockerAuthPlan Cloud host =
  GcloudConfigureDocker ["auth", "configure-docker", T.unpack host, "--quiet"]
```

Reimplement the interpreter (keeping the `IO ()` signature and internal resolution):

```haskell
-- | Configure Docker auth for the resolved target (EP-62, EP-83). In cloud mode this
-- runs @gcloud auth configure-docker <host> --quiet@ so a subsequent @docker push@
-- authenticates to Artifact Registry. In local mode (@NAGARE_MODE=local@, EP-82) it
-- is a no-op: the local k3d registry needs no credential helper and no @gcloud@ is
-- invoked. Resolves the profile internally so all call sites are unchanged.
configureDockerAuth :: IO ()
configureDockerAuth = do
  tp <- resolveTargetProfile
  case dockerAuthPlan (tpMode tp) (tpRegistryHost tp) of
    SkipDockerAuth -> pure ()
    GcloudConfigureDocker args -> run_ $ cmd "gcloud" & addArgs args
```

Build and confirm the six call sites still typecheck unchanged:

```bash
cd cli/nagarectl && cabal build
```


### Step M2.3 — add `dockerAuthPlanTests`

In `cli/nagarectl/test/Spec.hs`, import `dockerAuthPlan`, `DockerAuth (..)` from `Nagare.Image`
and add:

```haskell
dockerAuthPlanTests :: TestTree
dockerAuthPlanTests =
  testGroup
    "Nagare.Image.dockerAuthPlan (EP-83)"
    [ testCase "cloud mode builds the gcloud configure-docker argv" $
        dockerAuthPlan Cloud "us-west1-docker.pkg.dev"
          @?= GcloudConfigureDocker
            ["auth", "configure-docker", "us-west1-docker.pkg.dev", "--quiet"]
    , testCase "local mode skips auth — no gcloud argv is constructed" $
        dockerAuthPlan Local "k3d-registry.localhost:5000" @?= SkipDockerAuth
    ]
```

Append `dockerAuthPlanTests` to the top-level `testGroup` list and run:

```bash
cd cli/nagarectl && cabal test
```

Expected (abridged): both new cases `OK`. The local case is the machine-checkable proof that no
`gcloud` invocation is reachable in local mode.


### Step M3.1 — bring up the EP-82 local cluster and profile

From the repo root, with EP-82 merged:

```bash
just local-up           # create the k3d cluster + local registry (EP-82)
just local-bootstrap    # install Knative + Kourier HTTP-first (EP-82)
```

Source the local profile (EP-82's `nagare.local.env`, or export directly for this shell). The
exact registry host and domain are EP-82's to fix; representative values:

```bash
export NAGARE_MODE=local
export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000
export NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io
export NAGARE_TARGET_PLATFORM=linux/arm64   # linux/amd64 on an Intel/AMD host
export KUBECONFIG=$(k3d kubeconfig write nagare-local)   # or as EP-82 documents
```

Confirm the cluster is reachable and the mode resolves:

```bash
kubectl get ksvc -A                       # expect: no resources yet (clean cluster)
cabal run nagarectl -- doctor || true     # mode-aware checks; local mode tolerated
```


### Step M3.2 — deploy `dockerfile-app` in local mode

```bash
cd cli/nagarectl
NAGARE_MODE=local cabal run nagarectl -- deploy \
  --config ../../cluster/examples/dockerfile-app/nagare/Config.hs
```

Expected transcript (abridged — exact tag/host vary):

```text
Build mode: docker build --platform linux/arm64 -f Dockerfile .
#1 [internal] load build definition from Dockerfile
...
=> => naming to k3d-registry.localhost:5000/<project>/nagare/dockerfile-app:20260630-120000
The push refers to repository [k3d-registry.localhost:5000/<project>/nagare/dockerfile-app]
20260630-120000: digest: sha256:... size: ...
service.serving.knative.dev/dockerfile-app created
ksvc/dockerfile-app condition met
Deployed: https://dockerfile-app.default.127-0-0-1.sslip.io
```

Note the **absence** of any `gcloud auth configure-docker` line — in cloud mode that is the
first thing printed. (The printed URL scheme is `https://`; non-login apps on the HTTP-first
local cluster are reached over `http://` — local TLS is EP-85's concern. The scheme in the
banner is cosmetic for this milestone.)


### Step M3.3 — curl the app and prove zero gcloud

```bash
curl -i http://dockerfile-app.default.127-0-0-1.sslip.io
```

Expected:

```text
HTTP/1.1 200 OK
content-type: text/html
...

hello from a Dockerfile build with a build arg
```

Prove no gcloud dependence by re-running the deploy with `gcloud` removed from `PATH` (delete the
Service first so the build/push/apply path runs again):

```bash
kubectl delete ksvc dockerfile-app -n default
env PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'google-cloud-sdk' | paste -sd: -)" \
  NAGARE_MODE=local cabal run nagarectl -- deploy \
    --config ../../cluster/examples/dockerfile-app/nagare/Config.hs
# expect: same successful deploy; no "command not found: gcloud"
curl -s -o /dev/null -w '%{http_code}\n' http://dockerfile-app.default.127-0-0-1.sslip.io
# expect: 200
```


### Step M4 — static and server site deploy in local mode

Static site (no build platform concern beyond host-arch default):

```bash
cd cli/nagarectl
NAGARE_MODE=local cabal run nagarectl -- site deploy \
  --file ../../cluster/examples/static-site/nagare/Config.hs
curl -s -o /dev/null -w '%{http_code}\n' http://static-site.default.127-0-0-1.sslip.io
# expect: 200, and no gcloud auth line in the deploy output
```

If M4.2 decides the server/static build must honor `NAGARE_TARGET_PLATFORM` explicitly (for a
machine whose Docker default platform differs from the node), the one-line change is to give
`Nagare.Image.buildImage` a platform parameter (mirroring `dockerBuildArgs`) and pass
`tpTargetPlatform tp` from the static/server deploy inputs. On a single-arch laptop the default
host-arch build already matches the local node, so this is recorded as a note unless a real
mismatch is observed. Document the decision in the Decision Log when M4 is executed.


## Validation and Acceptance

Unit level (no cluster, no Docker, no gcloud):

```bash
cd cli/nagarectl && cabal test
```

The new groups must pass: `Nagare.Target mode (EP-83)` (mode resolution + `parseMode` table) and
`Nagare.Image.dockerAuthPlan (EP-83)` (cloud builds the argv, local skips). The pre-existing
suites stay green; record the new totals (the baseline before this plan is ~253 in
`cli/nagarectl` and ~264 in `cli/nagare-dsl`; `cli/nagare-dsl` is untouched by this plan, so its
264 is unchanged). The `dockerAuthPlan Local _ == SkipDockerAuth` assertion is the
machine-checkable form of "zero gcloud calls in local mode."

End-to-end level (against the EP-82 cluster): the acceptance is observable behavior, not
compilation. `NAGARE_MODE=local nagarectl deploy` of `cluster/examples/dockerfile-app` builds for
the host platform, pushes to the local registry, applies the Knative Service, waits Ready, and
`curl http://dockerfile-app.default.127-0-0-1.sslip.io` returns HTTP 200 with the build-arg page
body. The same deploy succeeds with `gcloud` absent from `PATH`, proving the path makes no GCP
call. The static `site deploy` returns HTTP 200 over the loopback domain the same way.

Regression: with `NAGARE_MODE` unset and the cloud profile, the deploy output again begins with
`gcloud auth configure-docker <host> --quiet` and pushes to Artifact Registry — proving the cloud
path is unchanged.


## Idempotence and Recovery

The Haskell edits (M1, M2) are pure source changes; re-running `cabal build`/`cabal test` is
always safe. The mode resolution and `dockerAuthPlan` are deterministic functions of the
environment and arguments, so resolving twice yields the same value.

The end-to-end deploy (M3, M4) is idempotent: `kubectl apply -f` upserts the Knative Service, so
re-running `nagarectl deploy` re-applies the same object (a new image tag each run, since the tag
is a UTC timestamp). To start clean, `kubectl delete ksvc <name> -n <namespace>` and redeploy. If
a build fails midway, nothing is applied to the cluster (build/push precede apply), so a retry is
safe. If the local registry push fails (registry not reachable), confirm EP-82's `just local-up`
created the registry and that `NAGARE_REGISTRY_HOST` matches the name k3d advertises; the deploy
made no cluster change, so simply re-run. Tearing down the whole cluster is EP-82's `just
local-down`; this plan adds no new persistent state.


## Interfaces and Dependencies

Libraries/modules used and why: `Nagare.Target` (the single target-resolution layer — the right
home for the mode because it already owns every other resolved target value); `Nagare.Image` (the
Docker/registry primitives — the only place that shells out to `gcloud`); `cradle` (the process
library all shell-outs go through); `tasty`/`tasty-hunit` (the test framework). No new
third-party dependency is introduced; `Data.Char.toLower` is in `base`.

Signatures that must exist at the end of each milestone (full module paths):

End of M1 — in `cli/nagarectl/src/Nagare/Target.hs`:

```haskell
data Mode = Cloud | Local
  deriving stock (Eq, Show)

parseMode :: Maybe String -> Mode

data TargetProfile = TargetProfile
  { -- ... existing fields (tpProject ... tpTargetPlatform) ...
  , tpMode :: !Mode
  }
  deriving stock (Eq, Show)

resolveTargetProfile :: IO TargetProfile   -- now also sets tpMode from NAGARE_MODE
```

`Mode`, `parseMode`, and `tpMode` are exported. This is MasterPlan 16 Integration Point 2's
public surface: EP-84 and EP-85 `import Nagare.Target (Mode (..), tpMode)` and branch on
`tpMode tp`; they must not re-read `NAGARE_MODE`.

End of M2 — in `cli/nagarectl/src/Nagare/Image.hs`:

```haskell
data DockerAuth
  = SkipDockerAuth
  | GcloudConfigureDocker [String]
  deriving stock (Eq, Show)

dockerAuthPlan :: Mode -> Text -> DockerAuth   -- pure; Local -> SkipDockerAuth

configureDockerAuth :: IO ()                   -- unchanged signature; interprets dockerAuthPlan
```

`dockerAuthPlan` and `DockerAuth (..)` are exported (for the unit test and for any later consumer
that wants the local-registry login variant). `configureDockerAuth` keeps `:: IO ()` so all six
existing call sites (`Nagare/App/Deploy.hs:440`, `app/Main.hs:2186`, `Nagare/Static/Deploy.hs:116`
and `:135`, `Nagare/Server/Deploy.hs:86`, `Nagare/Worker/Deploy.hs:128`) compile unchanged.

End of M3/M4 — no new signatures required (the deploy/site/server paths reuse the above). If M4.2
adopts an explicit platform for the static/server build, the change is
`Nagare.Image.buildImage :: Text -> Text -> FilePath -> IO ()` (platform, ref, context) with the
platform supplied from `tpTargetPlatform tp`; record this in the Decision Log only if actually
made.

Services: the EP-82 k3d cluster + local registry (M3/M4 only). No GCP service is contacted by this
plan in local mode.


## Commit Conventions

Commits follow Conventional Commits (per `CLAUDE.md`). Suggested subjects per milestone:

```text
feat(target): resolve NAGARE_MODE into a Mode on the target profile
feat(image): make docker auth conditional on mode via a pure dockerAuthPlan
test(nagarectl): cover mode resolution and the local/cloud docker-auth plan
docs(plans): record EP-83 local-mode deploy decoupling outcomes
```

Every commit carries the trailers tying it to this plan and its MasterPlan:

```text
MasterPlan: docs/masterplans/16-local-development-and-testing-for-nagare.md
ExecPlan: docs/plans/83-decouple-nagarectl-deploy-and-build-from-gcp-for-local-mode.md
Intention: intention_01kwb012h6ebgs5qjn5r12nyda
```
