# Environment and secrets

> **Status:** 🟡 **Built and tested offline; live walkthrough pending `nagare-01`.**
>
> The scoped env model, the `nagarectl env`/`secret` CLI, the generated `NAGARE_*`
> variables, and build/preview application all exist and are tested. Every command on
> this page works in `--dry-run` today (no cluster). The *live* legs — deploy, set,
> curl, sync, preview — are the intended behaviour against the cluster on GCP project
> `tan-nb-exp`, region `us-west1`; they are pending `nagare-01` being powered on, the
> same caveat as [Deploying apps](deploying-apps.md).

## What this page is

This page is for a **developer** managing the environment variables and secrets of an
app deployed onto Nagare — adding, changing, and removing them as a *day-2 operation*,
**without editing Haskell or rebuilding the image**. The values live in per-app
Kubernetes ConfigMaps and Secrets that the running Service already reads through an
`envFrom` block, so a change takes effect by re-applying a tiny manifest.

This is **distinct** from the operator [Secrets](secrets.md) page, which is about
`sops-nix` for the *host* and `sops`+`age` for *cluster bootstrap* secrets. That page is
about standing up the platform; this page is about an app running on it.

A complete, deployable example accompanies this guide:
[`cluster/examples/env-and-secrets`](../../cluster/examples/env-and-secrets). Its tiny
Node app prints its own environment so you can `curl` the URL and *watch* env take
effect.

## The scope model

Every environment variable in a Nagare config carries a set of **scopes**, answering
*when* the variable applies. A **scope** (`EnvScope`) is one of:

- **`Runtime`** — present in the running container (the default if you write a plain
  variable).
- **`Build`** — present during the image build (`docker build`), **not** in the running
  container.
- **`Preview`** — overlays preview deployments only.

A variable can carry several scopes at once. In the typed model (`Nagare.Dsl.Types`), an
env entry is a `ScopedEnvVar { value :: EnvVar, scopes :: Set EnvScope }`, where `EnvVar`
is either `EnvLiteral Text` (a plain value) or `EnvSecretRef SecretName` (a reference to
a Kubernetes Secret). You write them in `nagare/Config.hs`:

```haskell
import Data.Set qualified as Set

-- a plain Runtime literal (the default):
(greeting, runtimeScoped (EnvLiteral "hello from Config.hs"))

-- an explicit Build-only literal (reaches docker build, not the runtime container):
buildScoped <- scopedEnv (Set.fromList [Build]) (EnvLiteral "dev-stamp")
(buildStamp, buildScoped)

-- a Runtime secret reference (resolved from a Kubernetes Secret):
(apiKey, runtimeScoped (EnvSecretRef apiKeySecret))
```

`runtimeScoped :: EnvVar -> ScopedEnvVar` is the total `{Runtime}` default;
`scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar` takes an explicit scope
set and rejects the empty set. (The `secretEnv` preset from `Nagare.Dsl.Presets` adds a
Runtime secret-ref for you.) The full excerpt is in the example's
[`nagare/Config.hs`](../../cluster/examples/env-and-secrets/nagare/Config.hs).

## Where managed env lives, and precedence

**Managed env** lives outside the config, in per-app, per-scope Kubernetes objects an
operator changes without touching Haskell or rebuilding the image:

- a **ConfigMap** named `nagare-env-<app>-<scope>` for plain values, and
- a **Secret** named `nagare-secret-<app>-<scope>` for sensitive values,

where `<scope>` is the lowercased token `runtime`/`build`/`preview`. Every rendered
Knative `Service` consumes the **Runtime** pair through an `envFrom:` block with
`optional: true` (so the app still deploys if the store was never written):

```yaml
envFrom:
- configMapRef:
    name: nagare-env-<app>-runtime
    optional: true
- secretRef:
    name: nagare-secret-<app>-runtime
    optional: true
```

**Precedence is the contract and the most common source of confusion.** Kubernetes
applies `envFrom` *first* and the inline `env:` list *second*, so an inline variable
overrides a managed one of the same name. Inline `env:` comes from two places: the
variables you wrote in `Config.hs` (scope-filtered to `{Runtime}` for the running
container) and the generated `NAGARE_*` variables (below), which are also inline. The
rule, top wins:

1. Inline DSL `env:` (from `Config.hs`) and generated `NAGARE_*` — **highest**.
2. Managed store (`nagare-env-<app>-runtime` / `nagare-secret-<app>-runtime`) via
   `envFrom`.

So "my managed variable isn't taking effect" almost always means a `Config.hs` variable
of the same name is shadowing it — see [Troubleshooting](#troubleshooting).

## The CLI

The operator surface reads and writes the managed store. Its identity — the
`(name, namespace)` that names the managed store — comes from *loading the typed config*,
not from the literal `APP` word, so a typo cannot silently write a store the Service never
reads. The grammar:

```text
nagarectl env list   APP [-f|--config CONFIG] [--all]
nagarectl env set    APP KEY VALUE [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]
nagarectl env delete APP KEY       [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]
nagarectl env sync   APP --file FILE [-f|--config CONFIG] [--runtime] [--build] [--preview] [--merge | --reconcile-exact] [--dry-run]
nagarectl secret set    APP KEY    [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]   # value from stdin
nagarectl secret list   APP        [-f|--config CONFIG] [--all]
nagarectl secret delete APP KEY    [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]
```

Defaults and rules:

- **Scope defaults to `runtime`.** If none of `--runtime`/`--build`/`--preview` is given,
  the command targets the runtime scope. The flags may be combined to write several
  scopes at once.
- **`-f/--config CONFIG`** points at the typed config (default `nagare/Config.hs`); it is
  what identifies the app. **`--file FILE`** on `env sync` is a *separate* flag — the
  dotenv path.
- **`env sync` defaults to `--merge`** (keep existing keys not in the file; the file's
  keys win on collision). `--reconcile-exact` makes the store *exactly* the file,
  dropping any key not present. The two are mutually exclusive.
- **`secret set` reads the value from stdin, never argv** (so it never appears in `ps`,
  `/proc`, or shell history). **`secret list` prints key names only**, never values.
- **`--dry-run`** on any mutating command prints the exact ConfigMap/Secret manifest that
  *would* be applied and touches no cluster. (The store manifest is emitted as compact
  JSON — valid YAML, which `kubectl apply -f` accepts.) A Secret dry-run shows
  base64-encoded values (the wire format, not encryption).

### `env set` — set one managed variable

```console
$ nagarectl env set envdemo REGION us-west1 \
    --config cluster/examples/env-and-secrets/nagare/Config.hs --dry-run
--- ConfigMap (runtime) ---
{"apiVersion":"v1","data":{"REGION":"us-west1"},"kind":"ConfigMap","metadata":{"name":"nagare-env-envdemo-runtime","namespace":"personal"}}
```

Without `--dry-run` it applies that ConfigMap and prints `Set REGION in env for envdemo.`.

### `env list` — show managed variables

```console
$ nagarectl env list envdemo --config .../Config.hs
  SCOPE    KEY        VALUE
  runtime  LOG_LEVEL  info
  runtime  REGION     us-west1
```

`--all` lists all three scopes (runtime, build, preview).

### `env delete` — remove one variable

```console
$ nagarectl env delete envdemo REGION --config .../Config.hs
Deleted REGION from env for envdemo.
```

### `secret set` — set a secret from stdin

The value is read from standard input, so it never appears in the process arguments or
shell history:

```console
$ printf 'topsecret' | nagarectl secret set envdemo API_KEY \
    --config cluster/examples/env-and-secrets/nagare/Config.hs --dry-run
--- Secret (runtime) ---
{"apiVersion":"v1","data":{"API_KEY":"dG9wc2VjcmV0"},"kind":"Secret","metadata":{"name":"nagare-secret-envdemo-runtime","namespace":"personal"},"type":"Opaque"}
```

`dG9wc2VjcmV0` is base64 of `topsecret` (confirm with `printf 'dG9wc2VjcmV0' | base64 -d`),
proving the value came from stdin. If stdin is a TTY, `secret set` prompts with echo off.

### `secret list` / `secret delete`

```console
$ nagarectl secret list envdemo --config .../Config.hs
API_KEY
```

`secret list` prints key **names only**, never values. `secret delete envdemo API_KEY`
removes one key.

## Bulk import with `.env`

A dotenv (`.env`) file lists `KEY=VALUE` one per line; blank lines and `#` comments are
ignored; an `export ` prefix is stripped; single/double-quoted values are taken literally
(an inner `#` is part of the value); a non-blank line with no `=` is an error. Shell
interpolation (`${X}`) is **not** supported.

`env sync` imports the file in bulk, in one of two modes:

- **`--merge`** (the default): keep existing keys not in the file; the file's keys win on
  collision.
- **`--reconcile-exact`**: make the store *exactly* the file's contents, dropping any key
  not present.

```console
$ nagarectl env sync envdemo \
    --file cluster/examples/env-and-secrets/.env.production --reconcile-exact \
    --config cluster/examples/env-and-secrets/nagare/Config.hs --dry-run
--- ConfigMap (runtime) ---
{"apiVersion":"v1","data":{"FEATURE_FLAGS":"beta,fast","LOG_LEVEL":"info","REGION":"us-west1"},"kind":"ConfigMap","metadata":{"name":"nagare-env-envdemo-runtime","namespace":"personal"}}
```

With `--reconcile-exact`, the store becomes exactly `FEATURE_FLAGS`, `LOG_LEVEL`,
`REGION` — any previously-set key not in the file is dropped. With the default `--merge`,
such keys would be kept. The `--preview` flag writes the same import into the *preview*
store (`nagare-env-<app>-preview`) for the preview overlay below.

## Generated `NAGARE_*` variables

Every app and server site Nagare deploys automatically receives a reserved set of inline
`{Runtime}` variables describing the deployment's own identity. They are inline, so by the
precedence above they win over the managed store and over any user variable of the same
name — the `NAGARE_` prefix is **reserved**.

| Variable | Meaning | Example value |
| --- | --- | --- |
| `NAGARE_SERVICE_URL` | The deployment's resolved public https URL (custom domain if set, else the Knative wildcard) | `https://envdemo.personal.apps.example.com` |
| `NAGARE_SERVICE_NAME` | The Knative Service / app name | `envdemo` |
| `NAGARE_NAMESPACE` | The Kubernetes namespace the Service runs in | `personal` |
| `NAGARE_BASE_DOMAIN` | The apps base domain used to derive the wildcard URL | `apps.example.com` |
| `NAGARE_RELEASE_ID` | The image tag deployed (the release id) | `20260602-120000` |
| `NAGARE_SOURCE` | Source provenance from `--source` (branch/commit); present only when `--source` was given, and only on the `site deploy` path | `main` |

The first five are always present on the `deploy` and `site deploy` paths; `NAGARE_SOURCE`
is emitted only when a `--source` was given (today only `site deploy` has that flag). A
running app reads them through the normal environment, e.g.
`process.env.NAGARE_SERVICE_URL`. Here is the example app's rendered Service, showing the
inline `env:` (the user's `API_KEY`/`GREETING` plus the `NAGARE_*` block) and the runtime
`envFrom`:

```yaml
        env:
        - name: API_KEY
          valueFrom:
            secretKeyRef:
              name: envdemo-api-key
              key: API_KEY
        - name: GREETING
          value: hello from Config.hs
        - name: NAGARE_BASE_DOMAIN
          value: apps.example.com
        - name: NAGARE_NAMESPACE
          value: personal
        - name: NAGARE_RELEASE_ID
          value: 20260602-120000
        - name: NAGARE_SERVICE_NAME
          value: envdemo
        - name: NAGARE_SERVICE_URL
          value: https://envdemo.personal.apps.example.com
        envFrom:
        - configMapRef:
            name: nagare-env-envdemo-runtime
            optional: true
        - secretRef:
            name: nagare-secret-envdemo-runtime
            optional: true
```

Note the Build-scoped `BUILD_STAMP` is **absent** from this runtime `env:` — scope
filtering keeps it out of the running container (see the next section).

## Build-time env

A **`Build`-scoped** variable is passed to the image build as a `--build-arg`, so a
`Dockerfile` can read it via `ARG NAME` / `ENV NAME=$NAME`. It is **not** in the running
container's inline `env:` — it is filtered out by scope at render time. The example's
`BUILD_STAMP` is declared `{Build}` and consumed in its
[`Dockerfile`](../../cluster/examples/env-and-secrets/Dockerfile):

```dockerfile
ARG BUILD_STAMP=unset
ENV BUILD_STAMP=${BUILD_STAMP}
```

At deploy time, Nagare gathers the app's Build-scoped variables (the inline `{Build}`
entries plus the managed `nagare-env-<app>-build` / `nagare-secret-<app>-build` stores)
and passes them to `docker build` as `--build-arg`s. Managed Build env can be set with the
CLI's `--build` scope flag, e.g. `nagarectl env set envdemo NPM_REGISTRY https://r.example.com --build`.

> **Security caveat (read this).** A `--build-arg` value is recorded in the image's build
> history and is readable by anyone who can pull the image (`docker history`). Build-arg
> values are therefore **not a secret mechanism**. If you scope a *secret-ref* to `Build`,
> Nagare still passes it as a `--build-arg` but prints a loud warning to stderr — for a
> genuinely confidential build secret, use a BuildKit secret
> (`RUN --mount=type=secret`), not a build-arg.

## Preview env overlays

A **preview** deployment (a throwaway copy for a branch or PR) consumes the runtime
managed store *and then* the preview managed store: the preview Service's `envFrom` lists
the runtime pair first and the preview pair second, so a `Preview`-scoped value overlays
(overrides) the runtime value of the same key **in previews only**. Production is
unaffected. The four entries, in order:

```yaml
envFrom:
- configMapRef:
    name: nagare-env-<app>-runtime
    optional: true
- secretRef:
    name: nagare-secret-<app>-runtime
    optional: true
- configMapRef:
    name: nagare-env-<app>-preview
    optional: true
- secretRef:
    name: nagare-secret-<app>-preview
    optional: true
```

The store names use the **production** app name, not the derived preview Service name, so
preview env is shared across all previews of one app: set
`nagarectl env sync envdemo --file .env.preview --preview` once and every branch preview
inherits it.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| "My managed variable isn't taking effect." | It is shadowed by an inline DSL variable of the same name in `Config.hs` (inline `env:` wins over `envFrom`). Rename/remove the inline one, or set the value in `Config.hs` instead. (The example's `GREETING` is inline, so a managed `GREETING` is shadowed — use a different key like `REGION`.) |
| "My `NAGARE_*` value is ignored / I set it and it changed back." | `NAGARE_*` is **reserved**; the generated value always wins. Use a non-`NAGARE_` name. |
| "`env set` succeeded but the app didn't change." | Managed env is read by the Service via `envFrom`; a running revision must be replaced to pick it up. **Redeploy** (or otherwise trigger a new revision) so the pod re-reads the store. |
| "`secret list` shows the key but the app sees an empty value." | The value was written to a different **scope**, or to a different app name than the config resolves to. Check `-f/--config` and the scope flags. |
| "`env sync` deleted keys I wanted to keep." | You used `--reconcile-exact`. Use the default `--merge` to keep keys not in the file. |
| "A build-time variable shows up in `docker history`." | Expected — build-args are **not** secret. Use a BuildKit secret for private build values. |
| "Config fails to load: `Could not find module 'Nagare.Dsl...'`." | The loader's `runghc` needs the `nagare-dsl` package environment. Build once from `cli/nagarectl` (`cabal build`) or point `--ghc-env`/`NAGARE_GHC_ENVIRONMENT` at a built env file. |

## See also

- [Deploying apps](deploying-apps.md) — `nagarectl deploy` and the typed `nagare/Config.hs`.
- [Config reference](config-reference.md) — the typed config field/constructor catalogue.
- [Build modes](build-modes.md) — how an app's image is produced.
- [Secrets](secrets.md) — the *operator* host/cluster secret story (a different concern).
- The example: [`cluster/examples/env-and-secrets`](../../cluster/examples/env-and-secrets).
