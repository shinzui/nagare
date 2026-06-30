# Deploying apps

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
`--dockerfile`/`--context` override the Dockerfile build's paths. See the full
guide: **[Build modes](build-modes.md)**.

### Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `-f, --file FILE` | `nagare/Config.hs` | Path to the typed config file. |
| `-t, --tag TAG` | UTC `YYYYMMDD-HHMMSS` | Image tag override. |
| `--base-domain DOMAIN` | `$NAGARE_BASE_DOMAIN`, else `apps.example.com` | Apps base domain for the printed URL. |
| `-c, --context DIR` | from the config | Override the build-context directory (build modes only). |
| `--dockerfile FILE` | from the config | Override the Dockerfile path (Dockerfile build only). |
| `--ghc-env FILE` | `$NAGARE_GHC_ENVIRONMENT` | GHC package-environment file for the loader (see below). |
| `--dry-run` | off | Render and print only; no build/push/apply. |

### One operational wrinkle: the config is compiled

Because the chosen substrate is "configuration as a program", `nagarectl` loads
your config by running it with `runghc`. That child process must be able to
resolve the `nagare-dsl` package. Two ways to satisfy this:

- **In this repo's dev shell**, a `.ghc.environment.*` file is generated next to
  the package, and `runghc` discovers it automatically when you run from
  `cli/nagarectl/`. No flag needed.
- **From an arbitrary app directory**, point the loader at a package-environment
  file with `--ghc-env <file>` or `export NAGARE_GHC_ENVIRONMENT=<file>`.
  Hardening this into the standalone binary's package DB is the remaining
  follow-up tied to the deferred live deploy.

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
[README](../../cluster/examples/multi-workload-app/README.md)). It is deployed
with **one** command, `nagarectl app deploy`, which builds and pushes the shared
image once, then rolls the app out in dependency order:

```bash
# Dry-run (no cluster): print every rendered object, each with nagare.dev/app=<name>.
nagarectl app deploy --dry-run -f nagare/Config.hs

# Live: build/push once, then roll out in order.
nagarectl app deploy -f nagare/Config.hs
```

The rollout order is fixed and enforced: **pre-deploy hooks first** (the migration
Task runs to completion as a one-off Job — a non-zero exit aborts the release
**before any Service or Worker is applied**), **then** the managed databases are
ensured (idempotent), **then** the Knative Service and every Worker are applied
and waited on. So "run migrations before the new code boots" is a platform
guarantee, not a runbook step. Because the migration is re-run on every deploy,
it must be idempotent at the SQL level (the standard "migrations tracked in a
table" discipline) — an already-applied migration must be a no-op.

For tooling, `--dry-run --json` emits the whole rollout as a single machine-
readable document — `{ app, image, objects: [ { kind, name, phase, labels, … } ] }`,
ordered hook → database → service → worker, every object carrying the shared
`nagare.dev/app` label — so an external system of record can track the release as
one unit without scraping prose:

```bash
nagarectl app deploy --dry-run --json -f nagare/Config.hs | jq '[.objects[].kind]'
```

## Verify (against a running cluster)

```bash
just status                                  # ksvc Ready with a URL
curl https://notes.personal.<baseDomain>     # the app answers over HTTPS
```

In local mode, the bootstrap is HTTP-first:

```bash
curl http://notes.personal.127-0-0-1.sslip.io
```

## Next

Your app is deployed — now operate it. **[App lifecycle →](app-lifecycle.md)**
covers listing, inspecting, logging, restarting, stopping, and deleting apps,
plus deployment history (`nagarectl app` / `deployments`). Or manage the secrets
your apps and the host depend on: **[Secrets →](secrets.md)** — or browse the
full **[Config reference →](config-reference.md)**.
