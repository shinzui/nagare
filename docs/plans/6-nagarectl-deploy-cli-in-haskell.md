---
id: 6
slug: nagarectl-deploy-cli-in-haskell
title: "nagarectl deploy CLI in Haskell"
kind: exec-plan
created_at: 2026-06-02T15:39:48Z
intention: "intention_01kt4f3svnekz80g94f2k4tthq"
master_plan: "docs/masterplans/1-bootstrap-nagare-personal-paas.md"
---

# nagarectl deploy CLI in Haskell

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

**Retirement status (2026-08-23): Cancelled — superseded by
[MP-2](../masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md) and
[EP-12](12-nagarectl-integration-and-full-yaml-cutover.md).** The original YAML-specific
milestones below are retained as historical design context and must not be implemented. The
typed `nagare/Config.hs` deployment path delivered the intended user-visible capability without
creating the `Nagare.Config` or `Nagare.Render` modules specified here.

Full plan before trimming: [6-nagarectl-deploy-cli-in-haskell.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/6-nagarectl-deploy-cli-in-haskell.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare is a single-node personal Platform-as-a-Service (PaaS): one Google Cloud Platform
(GCP) virtual machine running a small Kubernetes distribution (k3s) with Knative Serving
installed. "Knative Serving" is a layer on top of Kubernetes that turns a single container
image into a web service that automatically scales up when traffic arrives and scales down
to zero when idle; the unit it manages is called a **Knative Service** (a Kubernetes object
of kind `Service` in the API group `serving.knative.dev/v1` — note this is a *different*
kind from a plain Kubernetes core `Service`). The whole point of Nagare is that the owner
should never have to hand-write Kubernetes YAML. Instead, each application repository carries
one short descriptor file named `nagare.yaml`, and a single command turns that descriptor
into a running, public, HTTPS web service.

This plan delivers that command: a Haskell command-line program called **`nagarectl`**, and
specifically its `deploy` subcommand. After this plan is complete, a developer who has an app
with a `Dockerfile` and a `nagare.yaml` in the current directory can run:

```bash
nagarectl deploy
```

and the tool will, in order: read and validate `nagare.yaml`; build the container image with
`docker build`; authenticate to Google Artifact Registry (Nagare's private container image
store) and `docker push` the image under a unique tag; render a Knative `Service` manifest
(and, if the descriptor asks for a custom public domain, a Knative `DomainMapping` manifest);
apply those manifests to the cluster with `kubectl apply`; wait until Knative reports the
service is `Ready`; and finally print the live `https://…` URL. Visiting that URL in a browser
(or with `curl`) returns the app's HTTP response. That is the user-visible outcome: one
command in, one working HTTPS URL out.

"Artifact Registry" is GCP's hosted Docker image registry; Nagare's repository lives at
`us-west1-docker.pkg.dev/tan-nb-exp/nagare` (the host is `us-west1-docker.pkg.dev`, the GCP
project is `tan-nb-exp`, the repository is `nagare`). "Render" means: take the parsed
`nagare.yaml` data and produce the exact Kubernetes YAML text that describes the desired
service. "DomainMapping" is a Knative object (`serving.knative.dev/v1beta1`, kind
`DomainMapping`) that maps a custom hostname like `notes.example.com` onto a Knative Service.

This plan owns the `nagare.yaml` schema and its parser and renderer — these are Integration
Point 6 (IP-6) of the MasterPlan at `docs/masterplans/1-bootstrap-nagare-personal-paas.md`.
The exact schema is reproduced verbatim in "Context and Orientation" below; do not deviate
from it, because EP-4 ships a sample app whose `nagare.yaml` must parse with this tool.

## Progress

This plan is closed as **Cancelled**, not Complete. The original M1–M3 checklist was abandoned
when MP-2/EP-12 made the typed deployment contract authoritative.

- [x] 2026-08-23: verified that the YAML parser/renderer and `nagare.yaml` contract were never
  implemented and remain absent.
- [x] 2026-08-23: verified that EP-12 delivered `nagarectl deploy` through
  `Nagare.Dsl.Load.loadDeployment` and the typed renderer, including image and deploy stages.
- [x] 2026-08-23: changed the MP-1 registry state to Cancelled, removed EP-6 as an active
  dependency, and recorded the successor lineage.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence (command output, error text).

- The successor did more than substitute a parser: commit `1e4459e` cut `nagarectl` over to the
  typed `nagare-dsl` package, and current `cli/nagarectl/app/Main.hs` defaults to
  `nagare/Config.hs`. The obsolete `Nagare.Config`/`Nagare.Render` modules and every repository
  `nagare.yaml` were deliberately absent after the cutover. (2026-08-23)

## Decision Log

Record every decision made while working on the plan, with rationale and date.

- Decision: cancel EP-6 rather than mark it Complete or implement its remaining checklist.
  Rationale: Complete would falsely claim that the YAML parser, YAML renderer, and associated
  golden test were delivered. Implementing them now would restore a contract deliberately
  removed by MP-2/EP-12. The typed successor already provides the intended one-command deploy
  outcome and is the only supported deployment path.
  Date: 2026-08-23

- Decision: For v1, talk to Kubernetes by shelling out to the `kubectl` binary (via the
  `cradle` process library) rather than using the `codedownio/kubernetes-api` Haskell client.
  Rationale: `kubectl apply` is declarative and idempotent, handles the kubeconfig/credential
  plumbing (Integration Point 7) for free, understands Knative custom resources without us
  needing generated types for `serving.knative.dev/v1`, and `kubectl wait --for=condition=Ready`
  gives us readiness polling in one call. The `kubernetes-api` packages are auto-generated per
  Kubernetes minor version (1.25–1.32 are registered in the local `mori` corpus at
  `/Users/shinzui/Keikaku/hub/haskell/kubernetes-api-project`) and do not include Knative's CRD
  types, so we would still hand-build the Knative request bodies — strictly more work for no
  v1 benefit. Shelling out is the simplest reliable path. `kubernetes-api` is noted as a later
  option if we want typed status reads instead of parsing `kubectl` output.
  Date: 2026-06-02

- Decision: For v1, build and push images by shelling out to `docker` and `gcloud` (via
  `cradle`) rather than using the `brendanhay/gogol` GCP SDK.
  Rationale: Building an image fundamentally requires the Docker daemon (or `nerdctl`), which is
  a local process regardless; `docker build` + `docker push` is the canonical path. Artifact
  Registry authentication is a single idempotent command, `gcloud auth configure-docker
  us-west1-docker.pkg.dev`, which writes a Docker credential helper entry; after that `docker
  push` just works. `gogol` (registered at `/Users/shinzui/Keikaku/hub/haskell/gogol-project`,
  packages `gogol` and `gogol-core`) would let us call the Artifact Registry REST API directly,
  but it cannot build or push image layers — that still needs Docker — so for v1 it buys nothing.
  `gogol` is noted as a later option (e.g. to list existing tags or garbage-collect old images).
  Date: 2026-06-02

- Decision: Use `garnix-io/cradle` (corpus at `/Users/shinzui/Keikaku/hub/haskell/cradle-project`)
  as the single process-running library for all `docker`, `gcloud`, and `kubectl` calls.
  Rationale: It wraps the standard `process` library with a typed, composable "run and collect
  output" API (`run`, `run_`, `cmd`, `addArgs`, `silenceStderr`, `setWorkingDir`), never invokes
  a shell (so no quoting/injection pitfalls), and its polymorphic output (`StdoutTrimmed`,
  `(ExitCode, StderrRaw)`) makes capturing exit codes and stdout trivial. It depends only on
  `base`, `bytestring`, `process`, `string-conversions`, and `text`.
  Date: 2026-06-02

- Decision: Use `pcapriotti/optparse-applicative` for command-line parsing.
  Rationale: It is the standard Haskell library for declarative subcommand CLIs and is in the
  local corpus at `/Users/shinzui/Keikaku/hub/haskell/optparse-applicative-project`. It gives a
  `deploy` subcommand, `--file`, `--tag`, `--namespace`, `--dry-run` flags, and `--help` for free.
  Date: 2026-06-02

- Decision: Parse `nagare.yaml` with the Hackage `yaml` package layered on `aeson`'s
  `FromJSON`. Render Knative YAML by building `aeson` `Value`s and serializing with
  `Data.Yaml.encode`.
  Rationale: `yaml` decodes YAML into `aeson` `Value`s, so a single `FromJSON NagareConfig`
  instance both parses and validates. Rendering through `aeson` `Value` + `Data.Yaml.encode`
  produces deterministic, well-formed YAML and keeps a golden test stable.
  Date: 2026-06-02

- Decision: The default per-deploy image tag is a UTC timestamp `YYYYMMDD-HHMMSS` unless the
  user passes `--tag`. Re-deploying with a fresh tag forces Knative to roll a new Revision.
  Rationale: Knative only creates a new Revision (and thus actually rolls out new code) when the
  pod template changes; reusing a fixed tag like `latest` can leave the old Revision running.
  A unique tag per deploy makes every deploy observably take effect. See "Idempotence".
  Date: 2026-06-02

- Decision: For an env var sourced from a Kubernetes Secret, `secretRef: <name>` renders
  `valueFrom.secretKeyRef` with `name: <name>` and **key equal to the environment variable's
  own name** (e.g. env `DATABASE_URL` with `secretRef: notes-db-url` reads key `DATABASE_URL`
  from Secret `notes-db-url`).
  Rationale: The IP-6 schema gives only a Secret *name*, not a key, so a deterministic key
  convention is required. Using the env var name as the key is the least surprising default and
  is documented in Context and Orientation. (A future `secretKey:` field could override it.)
  Date: 2026-06-02

## Outcomes & Retrospective

EP-6 was not implemented as written and is now Cancelled. Its configuration mechanism
(`nagare.yaml` plus `Nagare.Config`/`Nagare.Render`) was superseded before implementation by the
typed Haskell configuration initiative in MP-2. EP-12 delivered the intended product outcome:
`nagarectl deploy` loads an app's `nagare/Config.hs`, obtains a validated
`Nagare.Dsl.Types.Deployment`, builds or resolves the image, renders Knative resources, applies
them, waits for readiness, and reports the service URL.

No runtime feature is lost by retiring this document. The historical YAML milestones, types,
commands, and acceptance criteria below remain useful for explaining the supersession, but they
are not an implementation backlog. Environment-gated wildcard TLS validation remains an EP-4
operational deferral; it is not unfinished EP-6 work.

