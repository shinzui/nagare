# Deploying apps

> **Status:** 🟡 **Built, not yet exercised against the live cluster.**
>
> The deploy tool (`nagarectl`) and the typed config library (`nagare-dsl`)
> exist and are tested: `nagarectl deploy --dry-run` loads a typed config,
> validates it, and renders the exact Knative manifests offline today. The
> *live* leg — build → push → apply → wait → URL — is implemented but has not
> been run end-to-end because `nagare-01` is currently powered down. Treat the
> "Verify against the cluster" steps as the intended behaviour until the box is
> back up.

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

import Data.Map.Strict qualified as Map
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types

deployment :: Either String Deployment
deployment = do
  name' <- mapLeft show (mkServiceName "hello")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "gcr.io/knative-samples/helloworld-go")
  dom' <- mapLeft show (mkDomain "hello.example.com")
  port' <- mapLeft show (mkPort 8080)
  target <- mapLeft show (mkEnvName "TARGET")
  sc <- mapLeft show (mkScale 0 3)
  cpuQ <- mapLeft show (mkQuantity "250m")
  memQ <- mapLeft show (mkQuantity "128Mi")
  Right
    Deployment
      { name = name'
      , namespace = ns'
      , image = img'
      , domain = Just dom'
      , port = port'
      , env = Map.singleton target (EnvLiteral "Nagare")
      , resources = Just Resources {cpu = Just cpuQ, memory = Just memQ}
      , scale = Just sc
      }
  where
    mapLeft f = either (Left . f) Right

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
  with a clear message the moment a value is invalid. (`mapLeft show` adapts
  `Either Text` to the `Either String` that `ioError` wants.)
- **`env` is a `Map EnvName EnvVar`.** A value is *either* a literal
  (`EnvLiteral "Nagare"`) *or* a secret reference (`EnvSecretRef …`) — never
  both. That mutual exclusion is the headline guarantee, enforced by the type,
  not a runtime check.

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

import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (production, webService)
import Nagare.Dsl.Types (Deployment)

deployment :: Either String Deployment
deployment = do
  base <- mapLeft show (webService "notes" "gcr.io/myproject/notes")
  mapLeft show (production base)
  where
    mapLeft f = either (Left . f) Right

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
4. Render the Knative Service (and a DomainMapping if `domain:` is set).
5. --dry-run? Print the manifests + URL and stop.
   Otherwise: configure Docker auth, build the image, push it, apply the
   manifests, wait for the Knative Ready condition, and print the live URL.
```

### Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `-f, --file FILE` | `nagare/Config.hs` | Path to the typed config file. |
| `-t, --tag TAG` | UTC `YYYYMMDD-HHMMSS` | Image tag override. |
| `--base-domain DOMAIN` | `$NAGARE_BASE_DOMAIN`, else `apps.example.com` | Apps base domain for the printed URL. |
| `-c, --context DIR` | `.` | Docker build-context directory. |
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
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
```

And, because `domain` is set, a `DomainMapping`:

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
- **Optional public URL:** whatever you set with `mkDomain` (e.g.
  `notes.example.com`), wired via a Knative `DomainMapping`. You point that
  hostname's DNS at the static IP yourself.

## Choosing a data tier

Pick the lightest tier that fits the app (full detail in the
[spec](../initial-spec.md#data-strategy)):

| Tier | Use when | How |
| --- | --- | --- |
| **1 — Stateless** | APIs, web apps, tools with no durable local state. | Knative Service only; scales to zero. |
| **2 — Small stateful** | Personal apps, low write volume. | SQLite on a host-mounted path under `/var/lib/nagare/sqlite`, with **Litestream** streaming to GCS. |
| **3 — Important shared state** | Data you really don't want to lose, higher write volume. | Host Postgres (`/var/lib/nagare/postgres`) with backups, or managed Cloud SQL / Neon / Supabase. |

Avoid running a serious database inside Kubernetes until backup/restore is
solved. Secrets an app needs (`EnvSecretRef` / `secretEnv`) are managed with
sops+age — see [Secrets](secrets.md).

## Verify (against a running cluster)

> Deferred until `nagare-01` is back up; these are the intended steps.

```bash
just status                                  # ksvc Ready with a URL
curl https://notes.personal.<baseDomain>     # the app answers over HTTPS
```

## Next

Manage the secrets your apps and the host depend on:
**[Secrets →](secrets.md)** — or browse the full
**[Config reference →](config-reference.md)**.
