---
type: Guide
title: "Deploying apps"
description: "Define, deploy, verify, and operate applications on Nagare with the typed configuration model and nagarectl."
docId: DOC-12
tags: [applications, deployment, nagarectl, knative]
generated:
  by: human:nadeem
  at: 2026-08-25T20:53:35Z
---

# Deploying apps

## Reviewed multi-workload deployment (supported subset)

`nagarectl app deploy` can save an inventory review for an application whose
image is already an accepted OCI publication. The current reviewed path supports
a web Service, workers, application databases with explicit recovery bindings,
accepted standalone brokers and topics, and protected routes through an accepted
platform auth owner. It records the release in the application's history
ConfigMap after its workloads. Pre-deploy hooks are reviewed when each declares
its affected resources, or explicitly asserts that it has no data effects.
Google CDN host DNS joins the review when each host has a DomainMapping and
`--cdn-backend-resource RESOURCE-ID` names the accepted platform Pulumi
BackendService. Cloudflare CDN joins when `CF_ZONE_ID` names exactly one
accepted platform zone grant and its `publicIp` stack output is an IPv4 origin;
set `CF_ACCOUNT_ID` and `CF_API_TOKEN` for provider observation and apply.
Each host contributes cache intent to the platform ruleset and owns its proxied
A record. Build inputs stay in the separate image publication step.
Its config still goes through
the typed `Application` loader. Use the exact resource ID of the accepted OCI
publication, and an explicit tag that resolves to that publication's destination:

The saved scope revision includes a canonical digest of the loaded typed config.
Apply and resume use the accepted scope and its private native evidence rather
than loading that source file again.

First, export the built image as a Docker archive and publish it through a
review. Use a distinct `--key` for each immutable image publication. Planning records
both the archive's file hash and OCI manifest digest. Keep the archive at the
same absolute path until apply or resume completes; the publisher rechecks its
bytes before copying to the selected context's registry.

```bash
docker save registry.example/app:v1 -o /absolute/path/app-v1.tar
nagarectl app image-plan --archive /absolute/path/app-v1.tar \
  --destination registry.example/app:v1 --key app-v1 \
  --save-plan image-review
nagarectl inventory apply image-review --yes
```

Omit `--save-plan` to print and apply the publication review in the same
invocation. A remote tag with different content refuses; the command never
overwrites it through this standard path. `image-plan` prints the resulting
image resource ID. Use that ID in the app
review below after the image review is accepted. The destination must match
the tag resolved from the application's typed config.

```bash
nagarectl app deploy --file nagare/Config.hs --tag v1 \
  --image-resource publication:app-image-app-v1/app-v1/oci-image \
  --save-plan app-review
nagarectl inventory apply app-review --yes
```

For a standard create or update, omit `--save-plan` to publish and apply the
same reviewed scope in one invocation:

```bash
nagarectl app deploy --file nagare/Config.hs --tag v1 \
  --image-resource publication:app-image-app-v1/app-v1/oci-image
```

The command prints the published review digest and public operation summaries
before execution. Apply reloads the immutable review from the context's
inventory store, so interrupted work can resume from that evidence. Adoption,
replacement, and resource retirement still require separate review decisions;
the one-invocation route refuses them. It also requires the selected context's
inventory store and accepted image publication.

The typed config may still describe a Dockerfile or Nixpacks build. Build the
image separately, export a Docker archive, and publish it with `app image-plan`.
`app deploy` deploys the accepted publication named by `--image-resource`; it
does not rebuild from the source tree. The published destination must match the
config's image reference and explicit tag. Every live `app deploy` requires the
accepted image resource and an initialized inventory store, including a newly
named app in a context with no prior application history. Build path overrides
are unavailable on this command; apply them while preparing the archive.

To preview the same supported scope without saving or publishing a review, use
`--dry-run` with the same accepted image and recovery inputs. It reads the
selected context's accepted inventory and prints resource identities and
addresses; `--json` prints the public scope document. Neither output includes
private native manifests or Secret values.

```bash
nagarectl app deploy --file nagare/Config.hs --tag v1 \
  --image-resource publication:app-image-app-v1/app-v1/oci-image \
  --dry-run
```

Scheduled tasks attached to the application's web Service join this review as
CronJobs. They must resolve to the same accepted image as the application; an
explicit task image pointing elsewhere refuses. For each task in the aggregate
application's `tasks` list, pass `--hook-affects TASK=database:NAME` for each
database declared in the application that its command can change, or
`--hook-affects TASK=RESOURCE-ID` for another managed resource. Use
`--hook-no-data-effects TASK` only when it changes no managed data resource.
Every hook needs one of these declarations; the review refuses missing and
duplicate effects. For example:

```bash
nagarectl app deploy --file nagare/Config.hs --tag v1 \
  --image-resource RESOURCE-ID \
  --hook-affects migrate=database:app-db \
  --save-plan app-review
```

The review includes an independent scope for each hook and tag. Each scope
declares a stable Job and a completion operation listing its affected resources.
Jobs run in declared order, after
their CronJob and affected resource updates; the Service, workers, and scheduled
tasks wait for completion. Retrying the same accepted tag verifies the completed
Job rather than rerunning it. A later tag leaves the old hook scope in accepted
history. Changing the hook or its effects under the same tag refuses; choose a
new tag. One-off `task run` is a separate operational action. With hooks,
`--dry-run --json` prints an object containing `application` and `hooks` scopes.

For a single Service config, the reviewed route uses an independent Service
scope:

```bash
nagarectl deploy --file nagare/Config.hs --tag v1 \
  --image-resource RESOURCE-ID --save-plan service-review
nagarectl inventory apply service-review --yes
```

For a standard create or update, omit `--save-plan` to publish and apply the
same reviewed Service scope in one invocation:

```bash
nagarectl deploy --file nagare/Config.hs --tag v1 \
  --image-resource RESOURCE-ID
```

Every live `deploy` requires this reviewed image route and an initialized
inventory store, including for a Service that has never been deployed.

The command prints the published review digest and public operations before
applying them. An existing direct release history still needs the separate
exact adoption review described below.
The same accepted image binding works when the Service config describes a
Dockerfile or Nixpacks build; the reviewed deploy uses the published image.

Use the same accepted image and inputs with `--dry-run` to print the public
canonical Service scope before saving a review:

```bash
nagarectl deploy --file nagare/Config.hs --tag v1 \
  --image-resource RESOURCE-ID --dry-run
```

This preview reads the selected context's accepted inventory and checks scope
claims, but does not save or apply a review. It requires the same accepted
image as live deployment. The two review options cannot be combined in one
invocation.

The reviewed Service scope also records a release-history ConfigMap after its
Service and scheduled tasks. It carries forward entries from accepted private
history. An existing direct ConfigMap needs the exact legacy import below before
ordinary reviewed deployment.

The Service requires the accepted namespace and image. Add
`--service-volume-recovery VOLUME=BACKUP:KEY:VERSION` for each retained PVC,
`--tls-secret-resource RESOURCE-ID` for supplied TLS, and
`--env-secret-resource RESOURCE-ID` for runtime Secret references. Scheduled
tasks join the same review when they resolve to its accepted image. Topic free
broker references bind to accepted standalone broker Services. Database
references bind to an accepted standalone database in the same cluster and
namespace. Planning checks its Service, StatefulSet, and saved credential
template in one scope, then records the StatefulSet dependency and Secret
references in the workload. Missing private evidence or an unknown engine
refuses before review. Accepted standalone broker topics can also supply the
workload's Kafka environment and become explicit dependencies. Protected access
requires an accepted platform auth owner with a grant for this scope; the review
includes its backend contribution and central route. CDN settings still refuse
this single-Service route.

For each declared application database, add
`--database-recovery NAME=BACKUP:KEY_VERSION` to the planning command. The
review keeps the database credential and PVC under retained data policy and
records the backup and key version as recovery intent. A missing, repeated, or
unknown database binding refuses the review.
Workloads that declare a database reference receive its host and port plus
credential fields through references to the database's owned Secret. The review
contains the references and no password value. Two referenced databases using
the same engine and environment variable names refuse instead of silently
selecting one.

An application-level broker binding uses the accepted standalone broker Service
in the same cluster and namespace. Planning requires its StatefulSet in the
same accepted scope, records the Service as a dependency for each workload, and
derives Kafka connection variables without live discovery. Topic references
require accepted logical topic resources and add dependencies on those exact
resources. Missing or unaccepted topics refuse before review.

When the application references an already accepted Secret, supply its resource
ID with `--tls-secret-resource RESOURCE-ID` for a supplied-TLS domain or
`--env-secret-resource RESOURCE-ID` for runtime environment. Repeat either
option for distinct Secrets. Planning checks the exact cluster, namespace, and
Secret name and refuses missing, extra, or wrong-address bindings. An
application-owned database credential can satisfy its runtime environment
reference without a second Secret option.

Retained PVCs need explicit recovery inputs. Use
`--service-volume-recovery VOLUME=BACKUP:KEY:VERSION` for a Service volume and
`--worker-volume-recovery WORKER/VOLUME=BACKUP:KEY:VERSION` for a worker volume.
Repeat each option for all retained volumes. The worker name and volume name
select the typed declaration; the review binds the decision to its stable
resource ID. Missing, repeated, unknown, or throwaway-volume bindings refuse.

For a new namespace, add `--request-namespace` to the planning command. The
review sends a closed namespace request to the platform foundation. Planning
refuses unless that owner has granted the application scope permission; the
application cannot edit other Namespace fields or advance the platform scope
revision.

The resource ID above is illustrative; obtain the real ID from your accepted
inventory. Planning checks the accepted platform Namespace or granted namespace
request and the image's
tagged destination before saving the review. The review is bound to the current
inventory head; apply uses the native bytes saved in that review. Other
application inputs are refused until their inventory operation and recovery
contracts are available. The reviewed release-history member uses the web
Service name, matching the legacy ConfigMap. If a direct deploy already created
that ConfigMap, ordinary planning refuses its unowned live object. Save its
complete JSON under a private path and prepare a versioned adoption proposal
using `cli/nagarectl/test/fixtures/inventory/lifecycle/adopt.example.json` as the
shape. Set `candidate` to `"."`, bind the active context and project, and give
the exact release resource address and observed UID. Include any other live
unowned resources in the selected deploy scope that this review must adopt.
The command reports the release resource ID if the proposal omits it.

Run the import with the **currently recorded tag** and an accepted OCI image
matching that record. Use `nagarectl app deploy` for an aggregate application or
`nagarectl deploy` for a standalone Service:

```bash
kubectl --context KUBE_CONTEXT -n personal get configmap \
  nagare-app-deployments-SERVICE_NAME -o json > legacy-releases.json
nagarectl app deploy --file nagare/Config.hs --tag CURRENT_TAG \
  --image-resource RESOURCE-ID \
  --legacy-release-import legacy-releases.json \
  --release-adoption-input adoption.json \
  --save-plan import-review
nagarectl inventory apply import-review --yes
```

For a standalone Service, replace `nagarectl app deploy` with `nagarectl deploy`
and keep the same import flags. The import review preserves the old history and
requires exact content and physical identity for adoption. A changed or absent
live ConfigMap refuses. Inspect the whole review: other application resources
may also need adoption. After import, a normal reviewed deploy reads the accepted
private history, keeps earlier entries, and records the next release after its
workloads. Release history and accepted reviews live in the selected context's
inventory store.

> **Status:** 🟡 Built and tested through CLI/render coverage. The live deploy path
> supports both cloud mode and local mode: short image names are qualified through
> the active target, Docker auth is skipped for the local registry, and local
> apps serve on the loopback base domain.

This is the one page aimed at **app developers** rather than platform operators:
how a personal project becomes a running HTTPS service on Nagare. The promise is
a single command —

```bash
nagarectl deploy
```

— that hides Kubernetes entirely. What you write is **not YAML**: it is a small,
*typed* Haskell file that the compiler checks before anything touches the
cluster. A misspelled field, a name that is not DNS-safe, an environment
variable that is both a literal and a secret reference, or a `max` scale below
its `min` are no longer silently accepted — they fail to compile or are rejected
at load time with a precise message.

> **Why typed, not YAML?** The full rationale is in the
> [MasterPlan](../masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md).
> The short version: YAML has no types, so whole classes of misconfiguration
> only fail minutes later when the cluster rejects the manifest. The typed model
> makes those mistakes *impossible to write down*. For the complete field and
> constructor catalogue, see **[Config reference](config-reference.md)**.

---

## The model: one project = one Knative Service

Each app repo provides two files:

```text
Dockerfile          # how to build the app's container image
nagare/Config.hs    # how Nagare should run it — a typed deployment descriptor
```

### `nagare/Config.hs`

A config is an ordinary Haskell program. It binds a `deployment` value built
through the `nagare-dsl` smart constructors and emits it as the last line of
`main`. Here is the bundled `hello` example
(`cluster/examples/hello-knative-service/nagare/Config.hs`) verbatim:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types

deployment :: Either String Deployment
deployment = do
  name' <- first show (mkServiceName "hello")
  ns' <- first show (mkNamespace "personal")
  img' <- first show (mkImageRef "gcr.io/knative-samples/helloworld-go")
  doms <- first show (mkDomains [("hello.example.com", True)])
  port' <- first show (mkPort 8080)
  target <- first show (mkEnvName "TARGET")
  sc <- first show (mkScale 0 3)
  cpuQ <- first show (mkQuantity "250m")
  memQ <- first show (mkQuantity "128Mi")
  bld <- first show defaultBuild
  Right
    Deployment
      { name = name'
      , namespace = ns'
      , image = img'
      , build = bld
      , domains = doms
      , port = port'
      , env = Map.singleton target (runtimeScoped (EnvLiteral "Nagare"))
      , resources = Just Resources {cpu = Just cpuQ, memory = Just memQ, cpuLimit = Nothing, memoryLimit = Nothing}
      , scale = Just sc
      , healthCheck = Nothing
      }

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
```

The shape never changes:

- **The module is `Main`** and `main` ends in `emitDeployment dep`. That call
  hands the validated value to `nagarectl` over stdout as JSON; the tool decodes
  it and re-runs the same validators as defence in depth.
- **Every field goes through a smart constructor** (`mkServiceName`, `mkPort`,
  `mkScale`, …). Each returns `Either Text`, so the `do` block short-circuits
  with a clear message the moment a value is invalid. (`first show` adapts
  `Either Text` to the `Either String` that `ioError` wants.)
- **`env` is a `Map EnvName ScopedEnvVar`.** A value is *either* a literal
  (`EnvLiteral "Nagare"`) *or* a secret reference (`EnvSecretRef …`) — never
  both; that mutual exclusion is the headline guarantee, enforced by the type.
  Each value is wrapped with `runtimeScoped` (runtime-only); build- and
  preview-scoped variables are an [env-and-secrets](env-and-secrets.md) topic.
- **`domains` is a list with one canonical entry.** `mkDomains [(host, isCanon)]`
  builds it; the canonical hostname drives the printed URL and each entry becomes
  a `DomainMapping`. Use `[]` for no custom domain.
- **`healthCheck` is an optional HTTP probe**, and `resources` now carries
  optional `cpuLimit`/`memoryLimit` alongside the requests. Both default to
  "absent" here; see [Config reference](config-reference.md) and
  [App lifecycle](app-lifecycle.md) for an app that uses them.
- **`build` says how the image is produced.** Here it is `defaultBuild` — a
  Dockerfile build from `./Dockerfile`, reproducing Nagare's classic behavior. It
  can instead be a prebuilt image or a Dockerfile-free Nixpacks build; see
  **[Build modes](build-modes.md)**. A preset (`webService`) sets `build` for you.

> The registry path for a real app is
> `us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>` — the Artifact Registry that
> Pulumi created (see [Reference](reference.md)). The examples use
> `gcr.io/...` placeholders only because they are illustrative.

For the meaning and rules of every type and constructor, see
**[Config reference](config-reference.md)**.

### Apex landing page and three-domain routing

The exact context base domain is an ordinary custom hostname. A landing page
can therefore declare `apps.example.com` as its sole canonical domain:

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Lens ((&), (.~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Nagare.Dsl.Build (BuildSpec (PrebuiltImage), mkTag)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment, mkDomains)

landing :: Either String Deployment
landing = do
  base <- first show (webService "landing" "gcr.io/example/landing")
  tag <- first show (mkTag "2026-09-14")
  doms <- first show (mkDomains [("apps.example.com", True)])
  Right (base & #build .~ PrebuiltImage tag & #domains .~ doms)

main :: IO ()
main = either (ioError . userError) emitDeployment landing
```

A multi-domain workload marks one advertised URL explicitly; list order does
not decide it:

```haskell
doms <- first show (mkDomains
  [ ("apps.example.com", True)
  , ("www.apps.example.com", False)
  , ("alternate.apps.example.com", False)
  ])
```

All three names route to the same Service. `nagarectl` reports
`https://apps.example.com`, but it does not redirect the other two names.
Production deploys preflight ownership and TLS before apply, then wait for each
DomainMapping and its covering origin certificate.

## Less boilerplate: presets

Hand-writing every field is fine for one app, but most services share a shape.
`Nagare.Dsl.Presets` factors that out. `preset-app-a`
(`cluster/examples/preset-app-a/nagare/Config.hs`) is a complete production web
service in four lines:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (production, webService)
import Nagare.Dsl.Types (Deployment)

deployment :: Either String Deployment
deployment = do
  base <- first show (webService "notes" "gcr.io/myproject/notes")
  first show (production base)

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
```

`webService "notes" "gcr.io/myproject/notes"` gives you namespace `personal`,
port `8080`, scale-to-zero `0..3`, and standard `250m`/`128Mi` resources. The
`production` overlay then bumps it to scale `1..5` with `500m`/`256Mi`. A second
app (`preset-app-b`) reuses the *same* preset and overlay, adding only a name,
image, and one `secretEnv`, proving one definition is shared with no copy-paste.
The composition is type-checked end to end: an overlay that would produce an
invalid value is rejected at the point it is applied. See the
[Presets section](config-reference.md#reusable-presets) of the reference for the
full API.

## Deploying: `nagarectl deploy`

```bash
# From the app directory (the one containing nagare/Config.hs and Dockerfile):
nagarectl deploy                 # build, push, apply, wait, print URL
nagarectl deploy --dry-run       # validate + render manifests, touch nothing
```

What it does, in order:

```text
1. Resolve the apps base domain (--base-domain > NAGARE_BASE_DOMAIN > apps.example.com).
2. Load nagare/Config.hs: compile-and-run it, decode the emitted JSON, re-validate.
   A load failure prints one line to stderr and exits 1 — before anything else.
3. Compute the image tag (a UTC timestamp YYYYMMDD-HHMMSS unless --tag is given).
4. Render the Knative Service (and one DomainMapping per entry in `domains`).
5. --dry-run? Print the manifests, the planned build action, and URL, then stop.
   Otherwise, dispatch on the config's build mode: a prebuilt image skips Docker
   entirely; a Dockerfile or Nixpacks build configures Docker auth, builds the
   image, and pushes it. In cloud mode Docker auth targets Artifact Registry; in
   local mode it is skipped and the image goes to the k3d registry. Then apply
   the manifests, wait for the Knative Ready condition, and print the live URL.
```

### Build modes

The `build` field in `nagare/Config.hs` selects how the image is produced, and
`nagarectl deploy` dispatches on it: **prebuilt** (deploy an existing image, no
build), **Dockerfile** (`docker build`), or **Nixpacks** (build from source with
no Dockerfile). `--dry-run` prints the planned action as a `Build mode:` line, and
`--dockerfile`/`--build-context` override the Dockerfile build's paths. See the full
guide: **[Build modes](build-modes.md)**.

### Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `-f, --file FILE` | `nagare/Config.hs` | Path to the typed config file. |
| `-t, --tag TAG` | UTC `YYYYMMDD-HHMMSS` | Image tag override. |
| `--base-domain DOMAIN` | `$NAGARE_BASE_DOMAIN`, else `apps.example.com` | Apps base domain for the printed URL. |
| `-c, --build-context DIR` | from the config | Override the build-context directory (build modes only). |
| `--dockerfile FILE` | from the config | Override the Dockerfile path (Dockerfile build only). |
| `--ghc-env FILE` | `$NAGARE_GHC_ENVIRONMENT` | GHC package-environment file for the loader (see below). |
| `--dry-run` | off | Render and print only; no build/push/apply. |

### One operational wrinkle: the config is compiled

Because the chosen substrate is "configuration as a program", `nagarectl` loads
your config by running it with `runghc`. That child process must be able to
resolve the `nagare-dsl` package. The Nix application packages both together:

```bash
# Run a reviewed release from any app directory, or install it once.
export NAGARE_VERSION=0.1.0
nix run "github:shinzui/nagare/v${NAGARE_VERSION}#nagarectl" -- version
nix profile install "github:shinzui/nagare/v${NAGARE_VERSION}#nagarectl"

# Then use the installed command from any app repository.
nagarectl deploy --dry-run --file nagare/Config.hs
```

The wrapper supplies a GHC package database containing `nagare-dsl`, so it does
not need a `.ghc.environment.*` file or a Nagare source ancestor. Contributor
builds retain two explicit alternatives for development and debugging:

- **In this repo's dev shell**, a `.ghc.environment.*` file is generated next to
  the package, and `runghc` discovers it automatically when you run from
  `cli/nagarectl/`. No flag needed.
- **With a custom package set**, point the loader at a package-environment
  file with `--ghc-env <file>` or `export NAGARE_GHC_ENVIRONMENT=<file>`.
  These explicit overrides take precedence over automatic discovery.

### The rendered Knative Service

`--dry-run` for the `hello` example prints exactly this Service (byte-for-byte
the golden contract the tests assert):

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: '0'
        autoscaling.knative.dev/max-scale: '3'
    spec:
      containers:
      - image: gcr.io/knative-samples/helloworld-go:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: TARGET
          value: Nagare
        envFrom:
        - configMapRef:
            name: nagare-env-hello-runtime
            optional: true
        - secretRef:
            name: nagare-secret-hello-runtime
            optional: true
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
```

Two rendering details worth knowing: every app Service carries the
`nagare.dev/managed-by: nagarectl` label (it's how [`app
list`](app-lifecycle.md) finds Nagare apps), and an `envFrom` block always
references the app's managed env/secret stores as `optional` — so
[`nagarectl env`/`secret`](env-and-secrets.md) edits take effect without
re-rendering. A `healthCheck` would add `readinessProbe`/`livenessProbe`/
`startupProbe` blocks, and `cpuLimit`/`memoryLimit` would add a
`resources.limits` block (see [App lifecycle](app-lifecycle.md) for an example
showing both).

And, because `domains` is non-empty, one `DomainMapping` per entry:

```yaml
apiVersion: serving.knative.dev/v1beta1
kind: DomainMapping
metadata:
  name: hello.example.com
  namespace: personal
spec:
  ref:
    apiVersion: serving.knative.dev/v1
    kind: Service
    name: hello
```

Rendering rules worth knowing: env entries are sorted by variable name for
determinism; the autoscaling annotation values are quoted strings; and any
sub-object (`env`, `resources`, the annotations block) is omitted entirely when
its source field is absent.

## When a config is wrong

Load failures are reported as a single clear line and a non-zero exit, never an
opaque cluster rejection. The failure modes:

| You did | What you see |
| --- | --- |
| Pointed at a missing file | `nagare: config file not found: <path>` |
| Wrote code that doesn't compile / crashes | `nagare: compile error in <path>:` + the GHC diagnostic |
| Forgot `emitDeployment` (printed nothing) | `nagare: <path> compiled but did not produce a 'deployment' value` |
| Slipped an invalid value past a constructor | `nagare: field '<field>' failed validation: <message>` |

The first two catch *programming* mistakes; the last catches *configuration*
mistakes. Most invalid values can't even reach the loader — they're a `Left`
from a smart constructor inside `Config.hs`, surfaced when you build or run it.

## URLs your app gets

- **Automatic internal URL:** `notes.personal.<baseDomain>` (via the wildcard
  DNS + TLS set up in [Cluster bootstrap](cluster-bootstrap.md)). Works with no
  per-app DNS configuration.
- **Optional public URL(s):** whatever you set with `mkDomains` (e.g.
  `notes.example.com`), each wired via a Knative `DomainMapping`. The canonical
  entry is the one reported as the app's URL. You point each hostname's DNS at
  the static IP yourself.

## Choosing a data tier

Pick the lightest tier that fits the app (full detail in the
[spec](../initial-spec.md#data-strategy)):

| Tier | Use when | How |
| --- | --- | --- |
| **1 — Stateless** | APIs, web apps, tools with no durable local state. | Knative Service only; scales to zero. |
| **2 — Small stateful** | Personal apps, low write volume. | SQLite on a PVC-backed app volume, optionally with Litestream for hot database replication. |
| **3 — Important shared state** | Data you really don't want to lose, higher write volume. | Managed in-cluster Postgres/Redis/ClickHouse for single-node use, or Cloud SQL / Neon / Supabase for managed HA. |

For tier 2 you no longer need a hand-mounted host path: declare a durable
**volume** in your typed config and Nagare provisions a PVC, mounts it, and can
snapshot it to the active object store — GCS in cloud mode, MinIO in local mode;
see **[Persistent storage](persistent-storage.md)**. The SQLite-on-PVC example
pairs a durable volume with Litestream.

For tier 3, you can now run a **managed database** in-cluster: a typed `Database`
(Postgres, Redis, or ClickHouse) provisioned and operated with `nagarectl db`,
connected to your app by name (the app receives `DATABASE_URL`/`REDIS_URL`/
`CLICKHOUSE_URL` injected from a Secret), and backed up to GCS or local MinIO on
a schedule with a tested restore path — see
**[Managed databases](managed-databases.md)**. Each database is a single replica
on the single node (no HA); for managed HA, Cloud SQL / Neon / Supabase remain
options. Runtime app secrets are managed with `nagarectl secret`; see
[Environment and secrets](env-and-secrets.md).

Need to run work **on a schedule** (a nightly cleanup) or **once on demand** (a
one-off migration)? Declare a typed `Task` in your app's `tasks` list and operate
it with `nagarectl task` — it can inherit the app's image and runtime env/secrets.
See **[Scheduled tasks](scheduled-tasks.md)**.

## Multi-workload applications

When an app is **several workloads at once** — a web Service plus background
Workers plus a managed Database plus a migration Task — you no longer write a
separate `Config.hs` per workload. Describe the whole app as **one typed
`Application`** in a single `nagare/Config.hs`: the **image**, **env/secret set**,
and **database bindings** are declared once on the `Application` and validated to
agree with every workload it bundles (a worker pointing at an undeclared database,
or disagreeing on the shared image, is rejected at config-load time). Every object
it renders carries one shared identity label, `nagare.dev/app: <name>`, so the app
can be listed and torn down as a unit.

A worked example — one Service, two Workers binding a managed Postgres, and a
migration Task, all on one shared image — is
`cluster/examples/multi-workload-app/nagare/Config.hs` (see its
[README](../../cluster/examples/multi-workload-app/README.md)). Publish its
shared image with `app image-plan`, then use the reviewed
`app deploy --image-resource` command shown above.

Each declared pre-deploy Task becomes a separate reviewed Job scope with its
stated data effects and completion proof. The application workload waits for
that proof. Database, Service, and worker members follow their declared
inventory dependencies.

The inventory-backed `--dry-run --json` path requires an accepted image, an explicit
tag, any required recovery bindings, and a declared effect set for each aggregate
hook. For a supported application, it emits the canonical public scope document, including its
config digest, explicit overrides, and typed resource declarations:

```bash
nagarectl app deploy --dry-run --json --tag v1 \
  --hook-affects kizashi-migrate=database:kizashi-db \
  --image-resource RESOURCE-ID -f nagare/Config.hs \
  | jq '{application: (.application | {scope, configDigest, overrides}), hooks: [.hooks[].scope]}'
```

## Verify (against a running cluster)

```bash
nagare status                                # ksvc Ready with a URL
curl https://notes.personal.<baseDomain>     # the app answers over HTTPS
```

In local mode, bootstrap installs the local CA; use its public certificate when
checking HTTPS from the host:

```bash
kubectl -n cert-manager get secret nagare-local-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/nagare-local-ca.pem
curl --cacert /tmp/nagare-local-ca.pem \
  https://notes.personal.127-0-0-1.sslip.io
```

## Next

Your app is deployed — now operate it. **[App lifecycle →](app-lifecycle.md)**
covers listing, inspecting, logging, restarting, stopping, and deleting apps,
plus deployment history (`nagarectl app` / `deployments`). Or manage the secrets
your apps and the host depend on: **[Secrets →](secrets.md)** — or browse the
full **[Config reference →](config-reference.md)**.
