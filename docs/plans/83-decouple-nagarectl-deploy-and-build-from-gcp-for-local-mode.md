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

Full plan before trimming: [83-decouple-nagarectl-deploy-and-build-from-gcp-for-local-mode.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/83-decouple-nagarectl-deploy-and-build-from-gcp-for-local-mode.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] M3.1 — Bring up the EP-82 local cluster (`just local-up` + `just local-bootstrap`) and
      export the local profile (`NAGARE_MODE=local`, `NAGARE_REGISTRY_HOST`,
      `NAGARE_BASE_DOMAIN`, `NAGARE_TARGET_PLATFORM`). (Done 2026-06-29 — node `v1.34.6+k3s1`,
      control plane Ready. Required configuring Colima `insecure-registries` for the host push;
      see Surprises & Discoveries.)
- [x] M3.2 — Run `NAGARE_MODE=local nagarectl deploy` on `cluster/examples/dockerfile-app`;
      observe build for the host platform, push to the local registry, apply, wait Ready.
      (Done 2026-06-29 — built `python:3.12-alpine` for `linux/arm64`, pushed to
      `k3d-registry.localhost:5000/tan-nb-exp/nagare/dockerfile-app:<ts>`, ksvc condition met. No
      `gcloud auth configure-docker` line appeared. Uncovered + fixed a `mkImageRef` bug; see
      Surprises & Discoveries.)
- [x] M3.3 — `curl` the loopback URL and capture the HTTP-200 transcript; confirm zero
      `gcloud` calls (run with `gcloud` absent from `PATH`). (Done 2026-06-29 — `HTTP/1.1 200 OK`,
      `server: envoy`, body `hello from a Dockerfile build with a build arg` (via a Kourier
      port-forward since this host's port 80 is taken — EP-82 discovery). Zero-gcloud proven by
      redeploying with a *failing* `gcloud` shim first in `PATH`: the deploy still succeeded and
      the shim's sentinel never fired.)
- [x] M4.1 — Confirm `nagarectl site deploy` (static) honors mode: skips auth in local mode,
      pushes to the local registry, serves on the loopback domain. (Done 2026-06-29 —
      `cluster/examples/static-site` deployed under the failing-gcloud shim with no sentinel;
      pushed to the local registry; `curl` returns `HTTP/1.1 200 OK` with the HTML body.)
- [x] M4.2 — Confirm the server-site deploy path (`Nagare.Server.Deploy`) honors mode; decide
      whether `buildImage`/`prepareServerOutput` need the host `--platform` and adjust if so.
      (Done 2026-06-29 — verified by construction: the server path shares `runSiteDeploy`'s
      `resolveBaseDomain`→`tpBaseDomain` (loopback) and `qualifyImage tp` (local registry), and
      `deployServerProduction` calls the now-mode-aware `configureDockerAuth` + host-arch
      `buildImage` — identical to the static path proven live. Decision: NO `--platform` change;
      see Decision Log.)
- [x] M4.3 — Final regression: with `NAGARE_MODE` unset, both suites green and the cloud
      `dockerAuthPlan`/argv unchanged (record counts). (Done 2026-06-29 — `cli/nagarectl` 328
      tests pass; `cli/nagare-dsl` 356 pass; the `dockerAuthPlan Cloud` argv test pins the
      unchanged cloud argv.)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`mkImageRef` rejected the ported local-registry host — a real blocker requiring a
  `cli/nagare-dsl` change the plan said it would not make.** `Nagare.Dsl.Types.mkImageRef` forbade
  *any* `:` to prevent a baked-in tag, but the local registry host `k3d-registry.localhost:5000`
  carries a port whose `:` is not a tag. The first `NAGARE_MODE=local nagarectl deploy` aborted with
  `image ref must not include a tag (found ':' in: k3d-registry.localhost:5000/tan-nb-exp/nagare/
  dockerfile-app)`. In cloud mode the Artifact Registry host (`us-west1-docker.pkg.dev`) has no port,
  so this never surfaced. Fix: detect a tag by a `:` only in the final path segment
  (`Text.takeWhileEnd (/= '/')`), which admits `host:port/...` while still rejecting
  `gcr.io/foo/bar:latest`. Added two `mkImageRef` tests. The plan's scope note ("`cli/nagare-dsl` is
  untouched") was wrong: MasterPlan 16 IP-1 fixes a *ported* registry, so the DSL's ref validation
  had to learn about ports. Committed separately as `fix(dsl): allow a ported registry host in
  mkImageRef`. Date: 2026-06-29.

- **Zero-gcloud was proven with a *failing* `gcloud` shim, not by removing gcloud from `PATH`.** Two
  `gcloud` binaries are installed here (the devshell `google-cloud-sdk` and `~/.nix-profile/bin`), so
  the plan's `grep -v google-cloud-sdk` PATH filter left one reachable. The robust live proof is to
  prepend a `gcloud` shim that prints a sentinel and `exit 42`: the local-mode deploy completed
  (`condition met`, `Deployed:`) and the sentinel never fired, so `nagarectl` never invoked `gcloud`.
  This complements the `dockerAuthPlan Local _ == SkipDockerAuth` unit test. Date: 2026-06-29.

- **Two EP-82 host prerequisites gate the live deploy (inherited, not new to EP-83).** (1) The host
  `docker push` to `k3d-registry.localhost:5000` needs the registry in Docker's `insecure-registries`
  — configured here via `~/.colima/default/colima.yaml` + `colima restart`, after which the push
  succeeds. (2) This host's port 80 is held by a Caddy, so the loopback `curl` went through a
  `kubectl -n kourier-system port-forward svc/kourier` + `Host:` header. Both are documented in
  EP-82; EP-86's runbook/smoke must surface them. Date: 2026-06-29.

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

- Decision (M4.2): do **not** thread `tpTargetPlatform` into the static/server
  `Nagare.Image.buildImage` path; leave `docker build` defaulting to the host architecture.
  Rationale: `buildImage` runs `docker build -t <ref> <context>` with no `--platform`, so it builds
  for the host arch. On a single-arch developer machine the host arch *is* the local k3d node's arch
  (here `linux/arm64` on Apple Silicon), so the image runs — demonstrated live: the `static-site`
  deploy built via `buildImage` and the pod served `HTTP 200` on the arm64 node. Threading
  `tpTargetPlatform` would only matter on a host whose Docker default platform differs from the node
  (e.g. forcing `linux/amd64` on an arm64 host), which is not the local-mode scenario. The app deploy
  path already honors `--platform` (via `buildDockerfile`/`dockerBuildArgs`); the static/server path
  does not need it for local mode. If a cross-arch need ever appears the one-line change is
  `buildImage :: Text -> Text -> FilePath -> IO ()` (platform, ref, context) fed `tpTargetPlatform tp`
  — recorded here, not made.
  Date: 2026-06-29

- Decision: fix `Nagare.Dsl.Types.mkImageRef` to tolerate a registry-host port, expanding EP-83's
  scope into `cli/nagare-dsl` (which the plan had declared untouched).
  Rationale: MasterPlan 16 Integration Point 1 fixes a *ported* local registry
  (`k3d-registry.localhost:5000`), and the DSL's image-ref validator rejected every `:`, so a local
  deploy could not even construct its image ref. The minimal correct fix checks for a tag-colon only
  in the final path segment. The cloud path is unaffected (no port in the AR host). See Surprises &
  Discoveries for evidence.
  Date: 2026-06-29

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-29).** EP-83 is complete: all four milestones implemented, committed, and verified
both at the unit level and with a real laptop deploy. Against the original purpose — "the *same*
`nagarectl deploy` runs end to end in local mode with no `gcloud` and no GCP account" — the delivered
state is:

- **M1 — `Mode` on the profile.** `Nagare.Target` exposes `data Mode = Cloud | Local`, `parseMode`,
  and `tpMode`, resolved from `NAGARE_MODE` (default `Cloud`). This is MasterPlan 16 Integration
  Point 2's public type; EP-84/EP-85 import it.
- **M2 — conditional Docker auth.** A pure `dockerAuthPlan :: Mode -> Text -> DockerAuth` returns the
  `gcloud auth configure-docker` argv in cloud mode and `SkipDockerAuth` in local mode;
  `configureDockerAuth` interprets it with its `IO ()` signature unchanged, so all six call sites
  compile untouched. The cloud argv is pinned by a test.
- **M3 — live app deploy.** `NAGARE_MODE=local nagarectl deploy` of `cluster/examples/dockerfile-app`
  built `python:3.12-alpine` for `linux/arm64`, pushed to `k3d-registry.localhost:5000`, applied the
  ksvc, reached Ready, and `curl` returned `HTTP 200` with the build-arg body. Zero gcloud was proven
  by a failing-`gcloud`-shim redeploy whose sentinel never fired.
- **M4 — static + server paths.** The static `site deploy` deployed and served `HTTP 200` in local
  mode with no gcloud; the server path honors mode by the same `runSiteDeploy` construction. No
  `--platform` change was needed (host-arch default matches the single-arch node).

Regression: `cli/nagarectl` 328 tests and `cli/nagare-dsl` 356 tests pass; the cloud `dockerAuthPlan`
argv is byte-identical.

**Gaps / discoveries (full evidence in Surprises & Discoveries):**

1. **A `cli/nagare-dsl` change was required after all.** `mkImageRef` rejected the ported local
   registry host; fixed to detect a tag only in the final path segment. The plan's "nagare-dsl
   untouched" scope statement was incorrect for a ported registry.
2. **Two EP-82 host prerequisites gate the live deploy** — Docker `insecure-registries` for the host
   push (configured via Colima here) and a Kourier port-forward for the curl (host port 80 occupied).
   Both are EP-82 discoveries; EP-86 must surface them in the runbook/smoke.

**Lessons.** (a) A registry *host* and an image *tag* both use `:`; any ref validation must
distinguish "before the first `/`" (port) from "after the last `/`" (tag). (b) "No gcloud" is best
proven by a *failing shim* that turns any accidental invocation into a hard failure, not by trying to
remove a multiply-installed binary from `PATH`. (c) The pure-planner pattern (`dockerAuthPlan`) made
the core guarantee machine-checkable without Docker or gcloud — the right altitude for the test.

