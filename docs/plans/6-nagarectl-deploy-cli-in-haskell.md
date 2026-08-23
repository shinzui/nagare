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


## Context and Orientation

This section is a historical snapshot of the abandoned YAML design. Do not use it as current
implementation guidance; use MP-2, EP-12, and the `nagare-dsl` source instead.

**Where this fits.** Nagare is built by seven coordinated ExecPlans tracked by the MasterPlan
at `docs/masterplans/1-bootstrap-nagare-personal-paas.md`. This is EP-6. It **hard-depends on
EP-4** (`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`): EP-4 installs
Knative Serving, the Kourier ingress (the component, backed by the Envoy proxy, that routes
external HTTP/HTTPS traffic into Knative services), and cert-manager (which obtains TLS
certificates from Let's Encrypt so the URLs are `https://`). Without EP-4 there is no cluster
to deploy into and no TLS, so Milestones M2 and M3 of this plan cannot be validated until EP-4
is `Complete`. EP-4 also ships the test artifact this plan depends on: an example application
under `cluster/examples/hello-knative-service/` containing a `Dockerfile` and a `nagare.yaml`.
This plan **soft-depends on EP-1** (`docs/plans/1-...`) only for the developer shell that
provides the Haskell toolchain (the GHC compiler and the `cabal` build tool); the prerequisites
are restated below so this plan stands alone.

**The fixed facts you must hard-code or read from the cluster** (these come from the MasterPlan
Integration Points; do not invent alternatives):

- Artifact Registry repository URL (IP-1): `us-west1-docker.pkg.dev/tan-nb-exp/nagare`. The
  Docker auth command (IP-1, IP-9) is `gcloud auth configure-docker us-west1-docker.pkg.dev`.
  All `gcloud` work targets GCP project `tan-nb-exp` (IP-9).
- The default application namespace (IP-5) is `personal`. (A Kubernetes "namespace" is a named
  partition of the cluster; apps live in `personal` unless `nagare.yaml` overrides it.)
- The apps wildcard base domain (IP-4) is referred to as `baseDomain`; the canonical placeholder
  across all plans is `apps.example.com`, supplied by EP-2 and surfaced as the Pulumi stack
  output `baseDomain`. The automatic service URL shape (IP-4) is
  `https://<name>.<namespace>.<baseDomain>` — e.g. a service `notes` in namespace `personal`
  is reachable at `https://notes.personal.apps.example.com`.
- Cluster access (IP-7): EP-3 writes the cluster's kubeconfig (the file that tells `kubectl`
  how to reach and authenticate to the cluster) at `/etc/rancher/k3s/k3s.yaml` on the VM. The
  operator copies it locally, rewrites its `server:` field to the VM's Tailscale name or public
  IP, and exports the `KUBECONFIG` environment variable to point at it. `nagarectl` does not
  manage kubeconfig; it relies on `kubectl` finding it via `KUBECONFIG` exactly as a human would.

**The `nagare.yaml` schema (IP-6 — this plan OWNS it; reproduce it exactly).** Every deployable
app repository provides this file. This is the canonical shape:

```yaml
name: notes
namespace: personal
image: us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes
domain: notes.example.com   # optional
port: 8080                  # optional, default 8080
env:
  DATABASE_URL:
    secretRef: notes-db-url
  LOG_LEVEL:
    value: info
resources:
  cpu: 250m
  memory: 512Mi
scale:
  min: 0
  max: 3
```

Field-by-field meaning:

- `name` (required): the Knative Service name; must be DNS-safe (lowercase letters, digits, and
  hyphens). It becomes `metadata.name` of the rendered Service.
- `namespace` (optional, default `personal`): the Kubernetes namespace; becomes
  `metadata.namespace`.
- `image` (required): the image *repository* path with **no tag**. `nagarectl` appends a tag
  (default a timestamp, or `--tag`). The container image becomes `<image>:<tag>`.
- `domain` (optional): a custom public hostname. If present, render a `DomainMapping`.
- `port` (optional, default `8080`): the container's HTTP port; becomes the container's
  `containerPort`.
- `env` (optional): a map from environment-variable name to a one-key object that is *either*
  `value: <literal>` *or* `secretRef: <secret-name>`. A `value` entry renders to an `env` item
  with a literal `value`. A `secretRef` entry renders to an `env` item with
  `valueFrom.secretKeyRef` whose `name` is the secret name and whose `key` is the environment
  variable's own name (the documented key convention — see Decision Log).
- `resources` (optional): `cpu` and `memory` strings (Kubernetes quantity syntax: `250m` means
  250 millicpu, i.e. a quarter of a CPU; `512Mi` means 512 mebibytes). These render under the
  container's `resources.requests`.
- `scale` (optional): `min` and `max` integers. They render as the Knative autoscaling
  annotations on the Revision template: `autoscaling.knative.dev/min-scale` = `min` and
  `autoscaling.knative.dev/max-scale` = `max`. `min: 0` means the service may scale to zero
  pods when idle.

**What the renderer must produce.** From the example above, with computed tag `20260602-120000`,
the rendered Knative Service (API group/version `serving.knative.dev/v1`, kind `Service`) is:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: notes
  namespace: personal
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: '0'
        autoscaling.knative.dev/max-scale: '3'
    spec:
      containers:
      - image: us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: notes-db-url
              key: DATABASE_URL
        - name: LOG_LEVEL
          value: info
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
```

And, because `domain: notes.example.com` is set, also a DomainMapping (API group/version
`serving.knative.dev/v1beta1`, kind `DomainMapping`). A DomainMapping lives in the same
namespace and maps a hostname onto a target Knative Service by name:

```yaml
apiVersion: serving.knative.dev/v1beta1
kind: DomainMapping
metadata:
  name: notes.example.com
  namespace: personal
spec:
  ref:
    apiVersion: serving.knative.dev/v1
    kind: Service
    name: notes
```

Notes on rendered YAML stability: env ordering must be deterministic (render `env` entries
sorted by variable name) so the golden test is stable. The autoscaling annotation *values* are
strings (Kubernetes annotations are always strings), hence the quotes around `'0'` and `'3'`.
When `scale` is omitted, omit the annotations block; when `env` is omitted, omit `env`; when
`resources` is omitted, omit `resources`.

**The directory you will create.** All new files live under `cli/nagarectl/`:

```text
cli/nagarectl/
  nagarectl.cabal          -- the Cabal package description (build config)
  app/
    Main.hs                -- entry point: optparse-applicative CLI, deploy subcommand
  src/
    Nagare/
      Config.hs            -- NagareConfig record + YAML parser + validation
      Render.hs            -- renderService / renderDomainMapping (NagareConfig -> YAML text)
      Image.hs             -- buildImage / configureDockerAuth / pushImage / computeTag
      Deploy.hs            -- applyManifests / waitForReady / serviceUrl
  test/
    Spec.hs                -- test entry point (golden + unit tests)
    golden/
      hello.nagare.yaml    -- a copy of the hello example's nagare.yaml (test input)
      hello.service.yaml   -- the expected rendered Service YAML (golden output)
```

**Toolchain prerequisites.** Run all `cabal` commands from inside the EP-1 developer shell,
entered from the repository root with `nix develop` (this provides the GHC compiler and
`cabal`). If EP-1 is not yet available, any environment with GHC 9.4+ and `cabal` 3.x works for
M1 (build and golden test). M2/M3 additionally need the `docker`, `gcloud`, and `kubectl`
binaries on `PATH` and a reachable cluster (`KUBECONFIG` exported per IP-7).


## Plan of Work

The work below is retired and must not be executed. It is preserved so the replacement can be
audited against the original intended behavior.

The work is three milestones, each independently verifiable. The order is deliberate: M1
produces a tool that builds, parses, and renders correct YAML (provable with a fast offline
golden test); M2 makes it actually deploy to a live cluster and return a working URL; M3 adds
secrets, custom domains, and error polish. Implement and validate M1 fully before M2.

**Milestone M1 — the project builds; parser + renderer are correct (offline).** At the end of
M1 there is a compiling Cabal project; `cabal run nagarectl -- --help` prints usage with a
`deploy` subcommand; and `cabal test` passes a golden test that parses the hello example's
`nagare.yaml` and renders byte-for-byte the expected Knative Service YAML. No cluster, Docker,
or network is required. This de-risks the trickiest correctness surface (the IP-6 schema) before
touching infrastructure.

Steps: create the Cabal skeleton and module stubs (M1.1); confirm it builds and `--help` works
(M1.2); implement `Nagare.Config` with the `NagareConfig` record, a `FromJSON` instance that
applies defaults (`namespace` → `personal`, `port` → `8080`) and validates required fields, and
a `readConfig :: FilePath -> IO (Either String NagareConfig)` (M1.3); implement `Nagare.Render`
with `renderService :: NagareConfig -> Text -> ByteString` (the `Text` is the resolved tag) and
`renderDomainMapping :: NagareConfig -> Maybe ByteString` (M1.4); add the golden test (M1.5).

Because EP-4 (which ships `cluster/examples/hello-knative-service/nagare.yaml`) may not be
checked in when you implement M1, create `cli/nagarectl/test/golden/hello.nagare.yaml` as a copy
of the canonical IP-6 example (the schema block in Context and Orientation, with `image:`
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello` and `name: hello`). When EP-4's example lands,
the golden input should be reconciled to match it exactly; record any difference in Surprises.

**Milestone M2 — end-to-end deploy returns a live URL.** At the end of M2, running `nagarectl
deploy` in a directory with a `Dockerfile` and `nagare.yaml` builds and pushes the image to
Artifact Registry, applies the rendered Service, waits for `Ready`, and prints a `https://…`
URL that returns HTTP 200. This requires EP-4 complete and `KUBECONFIG` exported.

Steps: implement `Nagare.Image` (M2.1) with `computeTag :: IO Text` (UTC `YYYYMMDD-HHMMSS`),
`buildImage :: Text -> FilePath -> IO ()` (`docker build -t <image:tag> <context>`),
`configureDockerAuth :: IO ()` (`gcloud auth configure-docker us-west1-docker.pkg.dev --quiet`),
and `pushImage :: Text -> IO ()` (`docker push <image:tag>`). Implement `Nagare.Deploy` (M2.2)
with `applyManifests :: [ByteString] -> IO ()` (pipe each rendered manifest into
`kubectl apply -f -`), `waitForReady :: Text -> Text -> IO ()` (`kubectl wait
--for=condition=Ready --timeout=300s ksvc/<name> -n <namespace>`), and `serviceUrl ::
NagareConfig -> Text -> Text` (compute `https://<name>.<namespace>.<baseDomain>`, or the custom
`domain` if set; `baseDomain` is supplied via `--base-domain` or the `NAGARE_BASE_DOMAIN`
environment variable, defaulting to `apps.example.com`). Wire the subcommand end to end in
`Main.hs` (M2.3). Run a real deploy and curl the URL (M2.4).

**Milestone M3 — secrets, custom domain, and polished errors.** At the end of M3, an env entry
using `secretRef` correctly wires `valueFrom.secretKeyRef` against a pre-existing Kubernetes
Secret; a `domain` in `nagare.yaml` produces and applies a `DomainMapping` whose custom URL
serves over HTTPS; and all foreseeable failures (missing file, malformed YAML, missing `docker`/
`gcloud`/`kubectl`, build/push/apply failures, readiness timeout) produce a clear one-line error
and a non-zero exit code rather than a Haskell exception stack trace.

Steps: M3.1 verify `secretRef` (create a Secret with `kubectl create secret generic`, deploy,
confirm the running pod sees the value); M3.2 verify the DomainMapping path; M3.3 wrap each
external call in error handling that maps a non-zero `ExitCode` to a descriptive `Left`/`die`,
and add a `--dry-run` flag (already useful in M1) that prints the rendered manifests and the
computed URL without building, pushing, or applying.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless stated
otherwise. Enter the toolchain shell first:

```bash
nix develop
```

**M1.1 — create the Cabal skeleton.** Create `cli/nagarectl/nagarectl.cabal`:

```cabal
cabal-version:      3.0
name:               nagarectl
version:            0.1.0.0
synopsis:           Deploy a nagare.yaml app to Knative with one command.
build-type:         Simple

common warnings
    ghc-options: -Wall

library
    import:           warnings
    hs-source-dirs:   src
    exposed-modules:  Nagare.Config
                      Nagare.Render
                      Nagare.Image
                      Nagare.Deploy
    build-depends:    base >=4.17 && <5
                    , aeson
                    , yaml
                    , text
                    , bytestring
                    , containers
                    , unordered-containers
                    , cradle
                    , time
    default-language: Haskell2010

executable nagarectl
    import:           warnings
    main-is:          Main.hs
    hs-source-dirs:   app
    build-depends:    base
                    , nagarectl
                    , text
                    , bytestring
                    , optparse-applicative
    default-language: Haskell2010

test-suite nagarectl-test
    import:           warnings
    type:             exitcode-stdio-1.0
    main-is:          Spec.hs
    hs-source-dirs:   test
    build-depends:    base
                    , nagarectl
                    , text
                    , bytestring
    default-language: Haskell2010
```

Create stub modules so the project compiles before logic is filled in. For each of
`cli/nagarectl/src/Nagare/Config.hs`, `Render.hs`, `Image.hs`, `Deploy.hs`, start with a
`module` header and a `{-# LANGUAGE OverloadedStrings #-}` pragma. Create
`cli/nagarectl/app/Main.hs` and `cli/nagarectl/test/Spec.hs` (a `main = putStrLn "ok"` stub is
fine for M1.1).

If `cabal` cannot find the corpus packages `cradle` and `optparse-applicative` on Hackage in
your environment, add a `cabal.project` at `cli/nagarectl/cabal.project` pointing at the corpus
source trees as `packages:` entries (the `mori` corpus paths are
`/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle` and
`/Users/shinzui/Keikaku/hub/haskell/optparse-applicative-project/optparse-applicative`); the
EP-1 dev shell is expected to provide these, so prefer the Hackage versions and record in
Surprises whichever path you used.

**M1.2 — build and check help.** From `/Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl`:

```bash
cabal build
cabal run nagarectl -- --help
```

Expected (shape, not exact wording):

```text
nagarectl - deploy a nagare.yaml app to Knative

Usage: nagarectl COMMAND

Available commands:
  deploy                   Build, push, and deploy the app in the current directory
```

**M1.3 — implement `Nagare.Config`.** The record and parser (illustrative; adjust imports as
the compiler directs):

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Nagare.Config
  ( NagareConfig (..)
  , EnvValue (..)
  , Resources (..)
  , Scale (..)
  , readConfig
  ) where

import           Data.Aeson
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Text (Text)
import qualified Data.Yaml as Yaml

data EnvValue
  = EnvLiteral Text          -- from { value: ... }
  | EnvSecretRef Text        -- from { secretRef: ... }
  deriving (Eq, Show)

data Resources = Resources { resCpu :: Maybe Text, resMemory :: Maybe Text }
  deriving (Eq, Show)

data Scale = Scale { scaleMin :: Int, scaleMax :: Int }
  deriving (Eq, Show)

data NagareConfig = NagareConfig
  { cfgName      :: Text
  , cfgNamespace :: Text            -- defaulted to "personal"
  , cfgImage     :: Text            -- repository, no tag
  , cfgDomain    :: Maybe Text
  , cfgPort      :: Int             -- defaulted to 8080
  , cfgEnv       :: Map Text EnvValue
  , cfgResources :: Maybe Resources
  , cfgScale     :: Maybe Scale
  } deriving (Eq, Show)

instance FromJSON EnvValue where
  parseJSON = withObject "env entry" $ \o -> do
    mv <- o .:? "value"
    ms <- o .:? "secretRef"
    case (mv, ms) of
      (Just v, Nothing) -> pure (EnvLiteral v)
      (Nothing, Just s) -> pure (EnvSecretRef s)
      _ -> fail "each env entry must have exactly one of 'value' or 'secretRef'"

instance FromJSON Resources where
  parseJSON = withObject "resources" $ \o ->
    Resources <$> o .:? "cpu" <*> o .:? "memory"

instance FromJSON Scale where
  parseJSON = withObject "scale" $ \o ->
    Scale <$> o .: "min" <*> o .: "max"

instance FromJSON NagareConfig where
  parseJSON = withObject "nagare.yaml" $ \o -> NagareConfig
    <$> o .:  "name"
    <*> (o .:? "namespace" .!= "personal")
    <*> o .:  "image"
    <*> o .:? "domain"
    <*> (o .:? "port" .!= 8080)
    <*> (o .:? "env" .!= Map.empty)
    <*> o .:? "resources"
    <*> o .:? "scale"

readConfig :: FilePath -> IO (Either String NagareConfig)
readConfig path = do
  res <- Yaml.decodeFileEither path
  pure $ case res of
    Left err  -> Left (Yaml.prettyPrintParseException err)
    Right cfg -> Right cfg
```

**M1.4 — implement `Nagare.Render`.** Build `aeson` `Value`s and serialize with
`Data.Yaml.encode`. Sort env entries by name for determinism. Signatures:

```haskell
renderService      :: NagareConfig -> Text -> Data.ByteString.ByteString
renderDomainMapping :: NagareConfig -> Maybe Data.ByteString.ByteString
```

`renderService cfg tag` constructs the Service `Value` exactly as shown in Context and
Orientation: container image `cfgImage cfg <> ":" <> tag`; `containerPort` = `cfgPort cfg`;
`env` items from `cfgEnv` (literal → `value`, secretRef → `valueFrom.secretKeyRef` with `name`
= the secret and `key` = the env var name); `resources.requests` from `cfgResources` if present;
and the two autoscaling annotations (as **string** values) from `cfgScale` if present. Omit
empty sub-objects. `renderDomainMapping cfg` returns `Just` the DomainMapping bytes when
`cfgDomain cfg` is `Just`, else `Nothing`.

**M1.5 — golden test.** Place a copy of the hello example at
`cli/nagarectl/test/golden/hello.nagare.yaml` and the expected output at
`cli/nagarectl/test/golden/hello.service.yaml`. `test/Spec.hs` reads the input with
`Nagare.Config.readConfig`, renders with `renderService cfg "20260602-120000"`, and compares
the bytes to the golden file. Use a fixed tag so the output is deterministic. Example test body:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.ByteString as BS
import           Nagare.Config (readConfig)
import           Nagare.Render (renderService)
import           System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  Right cfg <- readConfig "test/golden/hello.nagare.yaml"
  let got = renderService cfg "20260602-120000"
  want <- BS.readFile "test/golden/hello.service.yaml"
  if got == want
    then putStrLn "golden: OK" >> exitSuccess
    else do
      putStrLn "golden: MISMATCH"
      BS.putStr got
      exitFailure
```

Run from `cli/nagarectl`:

```bash
cabal test
```

Expected:

```text
golden: OK
1 of 1 test suites (1 of 1 test cases) passed.
```

To regenerate the golden file after an intentional renderer change, run a small `cabal repl`
snippet that writes `renderService cfg "20260602-120000"` to the golden path, then re-run
`cabal test`. Document any regeneration in the Decision Log.

**M2.1 — implement `Nagare.Image`** using `cradle`. The confirmed `cradle` API is: `run` /
`run_` to execute, `cmd "exe"` to start a configuration, `addArgs ["a","b"]` to append
arguments, and output types like `StdoutTrimmed` and `(ExitCode, StderrRaw)` (from
`/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle/src/Cradle.hs` and `.../Helpers.hs`).

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Nagare.Image (computeTag, buildImage, configureDockerAuth, pushImage) where

import           Cradle
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time (getCurrentTime, defaultTimeLocale, formatTime)

registryHost :: String
registryHost = "us-west1-docker.pkg.dev"

computeTag :: IO Text
computeTag = do
  now <- getCurrentTime
  pure (T.pack (formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now))

-- ref is the full "<image>:<tag>"
buildImage :: Text -> FilePath -> IO ()
buildImage ref context =
  run_ $ cmd "docker" & addArgs ["build", "-t", T.unpack ref, context]

configureDockerAuth :: IO ()
configureDockerAuth =
  run_ $ cmd "gcloud"
       & addArgs ["auth", "configure-docker", registryHost, "--quiet"]

pushImage :: Text -> IO ()
pushImage ref =
  run_ $ cmd "docker" & addArgs ["push", T.unpack ref]
```

**M2.2 — implement `Nagare.Deploy`.** `applyManifests` pipes manifest bytes into
`kubectl apply -f -`. The simplest reliable way is to write each manifest to a temp file and
`kubectl apply -f <file>`, or pass stdin via a handle with `setStdinHandle`. Temp-file approach
keeps it simple:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Nagare.Deploy (applyManifests, waitForReady, serviceUrl) where

import           Cradle
import qualified Data.ByteString as BS
import           Data.Text (Text)
import qualified Data.Text as T
import           System.IO.Temp (withSystemTempFile)
import           System.IO (hClose)
import           Nagare.Config (NagareConfig (..))

applyManifests :: [BS.ByteString] -> IO ()
applyManifests manifests =
  mapM_ applyOne manifests
  where
    applyOne m = withSystemTempFile "nagare-manifest.yaml" $ \fp h -> do
      BS.hPut h m
      hClose h
      run_ $ cmd "kubectl" & addArgs ["apply", "-f", fp]

waitForReady :: Text -> Text -> IO ()
waitForReady name namespace =
  run_ $ cmd "kubectl"
       & addArgs [ "wait", "--for=condition=Ready", "--timeout=300s"
                 , "ksvc/" <> T.unpack name, "-n", T.unpack namespace ]

-- baseDomain is the resolved apps base (e.g. "apps.example.com")
serviceUrl :: NagareConfig -> Text -> Text
serviceUrl cfg baseDomain =
  case cfgDomain cfg of
    Just d  -> "https://" <> d
    Nothing -> "https://" <> cfgName cfg <> "." <> cfgNamespace cfg <> "." <> baseDomain
```

If you use `withSystemTempFile`, add the `temp` package to the `library` `build-depends`. If you
prefer stdin piping instead, use `setStdinHandle` from `cradle` against a pipe and pass
`["apply", "-f", "-"]`.

**M2.3 — wire `deploy` in `app/Main.hs`** using `optparse-applicative`. The `deploy` flow:
resolve options (`--file` default `nagare.yaml`, `--tag`, `--base-domain`/`NAGARE_BASE_DOMAIN`
default `apps.example.com`, `--dry-run`, `--context` build-context dir default `.`); read config
(die with a clear message on `Left`); compute the tag; if `--dry-run`, print the rendered
manifests and `serviceUrl` and exit 0; otherwise `configureDockerAuth`, `buildImage`,
`pushImage`, `applyManifests` (Service plus DomainMapping if present), `waitForReady`, then
print `serviceUrl`.

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import           Options.Applicative
-- ... import Nagare.Config, Render, Image, Deploy; Data.Maybe (maybeToList)

data DeployOpts = DeployOpts
  { optFile       :: FilePath
  , optTag        :: Maybe String
  , optBaseDomain :: Maybe String
  , optContext    :: FilePath
  , optDryRun     :: Bool
  }

main :: IO ()
main = do
  cmd' <- execParser opts
  runDeploy cmd'
  where
    opts = info (deployParser <**> helper)
      ( fullDesc <> progDesc "Deploy a nagare.yaml app to Knative" )
```

(Flesh out `deployParser` with `subparser`/`command "deploy"`, `strOption`, `switch`, etc.)

**M2.4 — real deploy.** From the app directory (for the hello example,
`/Users/shinzui/Keikaku/bokuno/nagare/cluster/examples/hello-knative-service`), with
`KUBECONFIG` exported per IP-7 and `gcloud` authenticated to `tan-nb-exp`:

```bash
nagarectl deploy
```

Expected transcript (abridged):

```text
Reading nagare.yaml ...
Building image us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello:20260602-120000 ...
Configuring Docker auth for us-west1-docker.pkg.dev ...
Pushing image ...
Applying Knative Service hello to namespace personal ...
Waiting for Ready (up to 300s) ...
service.serving.knative.dev/hello condition met
Deployed: https://hello.personal.apps.example.com
```

Then confirm it serves:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://hello.personal.apps.example.com
```

Expected: `200`.

**M3.1–M3.3** as described in Plan of Work. To verify a secret end to end:

```bash
kubectl -n personal create secret generic notes-db-url --from-literal=DATABASE_URL='postgres://example'
nagarectl deploy   # in an app whose nagare.yaml references secretRef: notes-db-url
kubectl -n personal exec deploy/<revision> -- printenv DATABASE_URL
```


## Validation and Acceptance

These were the abandoned YAML plan's acceptance gates. They are not current release gates; the
successor's validation and evidence live in EP-12 and later `nagarectl` plans.

Acceptance is behavioral, not "code exists". The three observable gates:

1. **M1 (offline correctness).** From `/Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl`:
   `cabal build` completes with no errors, `cabal run nagarectl -- --help` shows a `deploy`
   subcommand, and `cabal test` prints `golden: OK` and reports the suite passed. The golden
   test proves the renderer emits exactly the IP-6 Knative Service for the hello input — this is
   the contract EP-4's example depends on. Re-run after any renderer change.

2. **M2 (live deploy).** `nagarectl deploy` run in the hello example directory ends by printing
   a `https://…` URL, and `curl -sS -o /dev/null -w '%{http_code}' <url>` returns `200`. Capture
   the full transcript and the curl result as evidence in this plan's Surprises/Outcomes when
   first achieved. Also confirm scale-to-zero: after a few minutes idle, `kubectl get pods -n
   personal` shows the app's pod terminated, and a fresh `curl` brings it back (cold start) and
   still returns `200`.

3. **M3 (secrets + domain + errors).** A `secretRef` env var is visible inside the running
   container (`printenv` shows the secret value), a `domain:` in `nagare.yaml` yields a working
   `DomainMapping` (`kubectl get domainmapping -n personal` shows the mapping `Ready`, and
   `curl https://<domain>` returns 200), and each failure path prints a single clear error line
   with a non-zero exit. Demonstrate the error path deliberately: run `nagarectl deploy` in a
   directory with no `nagare.yaml` and observe a message like `error: nagare.yaml not found in
   current directory` and exit code 1 (`echo $?`).

A reviewer can reproduce gate 1 with no cloud access at all; gates 2 and 3 require EP-4 complete
and cluster access (IP-7).


## Idempotence and Recovery

`kubectl apply` is **declarative**: applying the same Service manifest twice converges the
cluster to the desired state without error, so re-running `nagarectl deploy` is safe and simply
updates the Service. Because each deploy computes a fresh image tag (UTC timestamp, or `--tag`),
the pod template changes on every deploy and Knative therefore creates a new Revision and rolls
traffic to it; this guarantees a deploy actually takes effect rather than silently reusing a
stale `latest` image. `gcloud auth configure-docker` is idempotent (it rewrites the same Docker
credential-helper entry). Creating a Kubernetes Secret is *not* idempotent with `create`; use
`kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -` (or `kubectl create
... --save-config` followed by `apply`) if you script secret creation, but note `nagarectl` only
*references* secrets — creating them is the operator's responsibility.

Recovery from a failed deploy: failures are isolated by stage. If `buildImage` fails, nothing was
pushed or applied — fix the Dockerfile and re-run. If `pushImage` fails (e.g. auth expired), run
`gcloud auth login` / re-run; the build is cached so the rebuild is fast. If `applyManifests`
fails, the cluster is unchanged for the failed manifest; fix the YAML/permissions and re-run —
`apply` is safe to repeat. If `waitForReady` times out, the Service object exists but the
Revision is unhealthy; inspect with `kubectl describe ksvc/<name> -n <namespace>` and `kubectl
get revisions -n <namespace>`, fix the app, and re-deploy (the new tag rolls a new Revision; the
broken one is retired automatically as traffic shifts). No deploy step is destructive, so
re-running `nagarectl deploy` at any point is the standard recovery action. To roll back, deploy
a previous tag with `nagarectl deploy --tag <previous-timestamp>` (the prior image still exists
in Artifact Registry).


## Interfaces and Dependencies

The interfaces in this section are historical and non-authoritative. Current code uses
`Nagare.Dsl.Types.Deployment`, `Nagare.Dsl.Load.loadDeployment`, and the renderers in
`Nagare.Dsl.Render`; it does not depend on the `yaml` parser or the proposed `Nagare.Config` and
`Nagare.Render` modules.

**Libraries (exact package names and why).** From the local `mori` corpus, confirmed by reading
the sources:

- `pcapriotti/optparse-applicative` (package `optparse-applicative`, source at
  `/Users/shinzui/Keikaku/hub/haskell/optparse-applicative-project`) — declarative CLI with the
  `deploy` subcommand, flags, and `--help`.
- `garnix-io/cradle` (package `cradle`, source at
  `/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle`) — run `docker`/`gcloud`/`kubectl`
  and capture output. Confirmed API: `run`, `run_`, `cmd`, `addArgs`, `setWorkingDir`,
  `setStdinHandle`, `silenceStdout`, `silenceStderr`, output types `StdoutTrimmed`, `StderrRaw`,
  `ExitCode` (see `cradle/src/Cradle.hs`). Depends only on `base`, `bytestring`, `process`,
  `string-conversions`, `text`.
- `yaml` + `aeson` (Hackage) — decode `nagare.yaml` into a `FromJSON NagareConfig`
  (`Data.Yaml.decodeFileEither`, `Data.Yaml.prettyPrintParseException`) and encode rendered
  manifests (`Data.Yaml.encode`).
- `text`, `bytestring`, `containers` (for `Data.Map.Strict`), `time` (tag timestamp), and
  optionally `temp` (`System.IO.Temp.withSystemTempFile` for the apply-via-tempfile path).

**Not used in v1 (recorded for future work):** `codedownio/kubernetes-api` (typed Kubernetes
client; would need hand-built Knative CRD bodies — see Decision Log) and `brendanhay/gogol`
(GCP SDK; cannot build/push image layers). `iand675/hs-opentelemetry` is optional tracing and
out of scope for v1.

**Types and function signatures that must exist** (full module paths):

- `Nagare.Config.NagareConfig` (record with `cfgName, cfgNamespace, cfgImage :: Text`,
  `cfgDomain :: Maybe Text`, `cfgPort :: Int`, `cfgEnv :: Map Text EnvValue`,
  `cfgResources :: Maybe Resources`, `cfgScale :: Maybe Scale`); `Nagare.Config.EnvValue`
  (`EnvLiteral Text | EnvSecretRef Text`); `Nagare.Config.Resources`; `Nagare.Config.Scale`;
  and `Nagare.Config.readConfig :: FilePath -> IO (Either String NagareConfig)`.
- `Nagare.Render.renderService :: NagareConfig -> Text -> ByteString` (second arg is the
  resolved tag) and `Nagare.Render.renderDomainMapping :: NagareConfig -> Maybe ByteString`.
- `Nagare.Image.computeTag :: IO Text`, `Nagare.Image.buildImage :: Text -> FilePath -> IO ()`,
  `Nagare.Image.configureDockerAuth :: IO ()`, `Nagare.Image.pushImage :: Text -> IO ()`.
- `Nagare.Deploy.applyManifests :: [ByteString] -> IO ()`,
  `Nagare.Deploy.waitForReady :: Text -> Text -> IO ()` (name, namespace),
  `Nagare.Deploy.serviceUrl :: NagareConfig -> Text -> Text` (config, baseDomain).

**Services and endpoints consumed.** Artifact Registry `us-west1-docker.pkg.dev/tan-nb-exp/nagare`
(IP-1); Docker auth via `gcloud auth configure-docker us-west1-docker.pkg.dev` against project
`tan-nb-exp` (IP-1, IP-9); the k3s cluster via `kubectl` using `KUBECONFIG` (IP-7); the Knative
Serving API groups `serving.knative.dev/v1` (Service) and `serving.knative.dev/v1beta1`
(DomainMapping) installed by EP-4; the default namespace `personal` (IP-5); and the URL shape
`https://<name>.<namespace>.<baseDomain>` with `baseDomain` defaulting to `apps.example.com`
(IP-4). The test artifact is `cluster/examples/hello-knative-service/` from EP-4
(`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`).

## Revision note (EP-12, 2026-06-03)

EP-12 (`docs/plans/12-nagarectl-integration-and-full-yaml-cutover.md`) performed the hard cutover
described in MasterPlan 2 (`docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md`)
Integration Point 4. The modules `Nagare.Config` (YAML parser, `NagareConfig` record) and
`Nagare.Render` (YAML renderer from `NagareConfig`) were never implemented and are now explicitly
retired — they must not be created. The `cli/nagarectl/` package instead depends on `nagare-dsl` and
calls `Nagare.Dsl.Load.loadDeployment` (EP-10) and `Nagare.Dsl.Render.renderService` /
`renderDomainMapping` (EP-9). `Nagare.Image` and `Nagare.Deploy` were implemented to accept
`Nagare.Dsl.Types.Deployment` rather than `NagareConfig`. The golden test in this plan's M1.5 (which
tested `Nagare.Config`/`Nagare.Render`) was not created; the authoritative renderer golden tests live
in `nagare-dsl-test` (EP-9). The example app's `nagare.yaml` was replaced by a typed
`nagare/Config.hs`. All other EP-6 milestones (M2 live deploy, M3 secrets/custom-domain) are unchanged
in intent — only the config-loading path differs: `nagarectl` compiles-and-runs the app's
`nagare/Config.hs` to obtain a validated `Deployment` instead of parsing YAML.

## Revision note (retirement, 2026-08-23)

EP-6 is now formally **Cancelled — superseded by MP-2/EP-12**. The Progress checklist was
replaced with retirement evidence so corpus scans no longer report the abandoned YAML work as
unimplemented. Purpose, Outcomes, Context, Plan of Work, Validation, and Interfaces now distinguish
historical material from the supported typed path. MP-1's registry, dependency graph, progress,
decision log, and retrospective were updated in the same change. No ADR was added because this
records plan lineage for the already-decided typed cutover; it introduces no new architecture.
