---
id: 28
slug: env-and-secret-management-docs-and-end-to-end-example
title: "Env and secret management docs and end-to-end example"
kind: exec-plan
created_at: 2026-06-09T23:52:38Z
intention: "intention_01ktqcj5aseb1rx94fh6npnydv"
master_plan: "docs/masterplans/5-environment-and-secret-management-for-nagare.md"
---

# Env and secret management docs and end-to-end example

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, a newcomer who has never seen Nagare can — from one user-guide page and one
example project alone — manage environment variables and secrets for a real app and *see the
result change* through the app's own URL. Today the env and secret machinery exists across four
sibling implementation plans (the scoped model, the CLI, the generated `NAGARE_*` variables, and
build/preview application), but there is no single place that explains it to a user and no
worked example that proves it end to end. This plan delivers exactly that: a developer guide and
a deployable example, plus a reproducible walkthrough that exercises every surface.

Concretely, after this plan someone can:

- Read one page, `docs/user/env-and-secrets.md`, and understand the **scope model** (a variable
  applies at `Runtime`, `Build`, and/or `Preview`), the **precedence rule** (managed `envFrom`
  store first, then inline DSL `env` and the generated `NAGARE_*` variables, which win), the full
  **`nagarectl env`/`nagarectl secret` CLI**, **`.env` bulk import** with merge vs.
  reconcile-exact semantics, the **generated `NAGARE_*` variable table**, **build-time env** with
  its security caveat, **preview env overlays**, and a **troubleshooting** section.

- Deploy the bundled example at `cluster/examples/env-and-secrets/`, whose tiny app prints its
  `NAGARE_*` variables and any managed variable it can see, then:
  1. `nagarectl env set` a managed variable and `curl` the URL to watch it appear;
  2. `printf … | nagarectl secret set` a secret from stdin and confirm the app reads it;
  3. `nagarectl env sync --reconcile-exact` a `.env` file and watch a previously-set key
     **disappear** from the app's output;
  4. deploy a preview with a `Preview`-scoped overlay and watch the preview URL serve the
     overlaid value while production keeps the original.

The proof is not prose. Every surface is demonstrable with `--dry-run` on a laptop (no cluster),
and the live walkthrough is reproducible against the cluster on GCP project `tan-nb-exp`, region
`us-west1` (the only project this repository may target — see `CLAUDE.md`). This plan **documents
and demonstrates**; it implements no features. It consumes the surfaces the four sibling plans
deliver, using their exact command grammar and variable names.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Wrote the user guide `docs/user/env-and-secrets.md` covering the scope model and
      precedence, the full `env`/`secret` CLI with copy-pasteable examples, `.env` sync
      (merge vs. reconcile-exact), the generated `NAGARE_*` table, build-time env + its
      security caveat, preview env overlays, and a troubleshooting section. (2026-06-09)
- [x] M1: Linked the guide from `docs/user/README.md` (status-table row + read-in-order
      sub-bullet under "Deploying apps") and added a `nagarectl env`/`secret` command table
      to `docs/user/reference.md`. (2026-06-09)
- [x] M1: Fence-parity verified — both new docs have even fence counts and zero bare
      opening fences (Python check in place of `rg`). (2026-06-09)
- [x] M2: Created `cluster/examples/env-and-secrets/` — `nagare/Config.hs` (Runtime literal
      `GREETING`, Build-scoped `BUILD_STAMP`, Runtime secret-ref `API_KEY`; with the now-
      required `build = defaultBuild`), `app.js`, `Dockerfile`, `.env.production`,
      `.env.preview`, and `README.md`. (2026-06-09)
- [x] M2: Captured the **real** `deploy --dry-run` transcript into the guide and README
      (inline `env:` with `GREETING`+`API_KEY`+`NAGARE_*`, the runtime `envFrom`; `BUILD_STAMP`
      absent — `grep -c BUILD_STAMP` == 0). (2026-06-09)
- [x] M2: Captured the **real** `env set`/`secret set` (stdin)/`env sync --reconcile-exact`
      `--dry-run` transcripts (compact JSON, see Surprises) into the guide and README. (2026-06-09)
- [x] M2: Live walkthrough **deferred** (🟡 badge), matching `deploying-apps.md`/
      `static-hosting.md`: `nagare-01` is powered down. Every `--dry-run` leg is exercised;
      the live legs are written as intended behaviour against `tan-nb-exp`/`us-west1` with
      cleanup commands. (2026-06-09)
- [x] Filled in Outcomes & Retrospective. (2026-06-09)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The `env`/`secret` `--dry-run` prints compact JSON, not pretty YAML.** EP-24's
  `renderEnvConfigMap`/`renderEnvSecret` serialize with `Data.Aeson.encode` (compact,
  single-line JSON), and the CLI prints those bytes verbatim. The plan's idealized
  transcripts showed multi-line YAML; the real output is e.g.
  `{"apiVersion":"v1","data":{"REGION":"us-west1"},"kind":"ConfigMap","metadata":{...}}`.
  This is valid YAML (JSON ⊂ YAML) and `kubectl apply -f` accepts it, so it is correct —
  the guide and README use the **real** compact-JSON form and note it once. (The Knative
  *Service* dry-run, by contrast, is pretty YAML because the DSL renderer uses
  `Data.Yaml.Pretty`.)

- **The example `Config.hs` needed a `build` field.** The plan's `Config.hs` sketch
  predated the EP-19–22 build-modes rework, which added `build :: BuildSpec` to
  `Deployment`. The example uses `bld <- mapLeft show defaultBuild` (a `docker build -f
  Dockerfile .`), which suits the example's bundled `Dockerfile` and `ARG BUILD_STAMP`.

- **`NAGARE_RELEASE_ID` renders unquoted** (`value: 20260602-120000`), not quoted as the
  plan sketched — the tag contains a hyphen so YAML treats it as a plain scalar string;
  no quoting is needed. The guide uses the real output.

- The config loader's `runghc` resolves `nagare-dsl` from the `.ghc.environment.*` in
  `cli/nagarectl`, so the `--dry-run` commands must run from that directory (or set
  `--ghc-env`/`NAGARE_GHC_ENVIRONMENT`). Running from the repo root with
  `--project-dir=cli/nagarectl` fails the config load. Documented in the guide's
  troubleshooting table and the README.


## Decision Log

Record every decision made while working on the plan.

- Decision: Put the user guide at `docs/user/env-and-secrets.md` (a new sibling of
  `docs/user/deploying-apps.md` and `docs/user/static-hosting.md`), not inside the existing
  `docs/user/secrets.md`.
  Rationale: `docs/user/secrets.md` already exists and is about a *different* concern — `sops-nix`
  for the **host** and `sops`+`age` for **cluster** bootstrap secrets, an operator topic. This
  plan documents **application** env and secrets managed through `nagarectl env`/`nagarectl
  secret` (per-app managed ConfigMaps/Secrets the running Service reads via `envFrom`). Mixing the
  two would confuse a reader. The new page is a developer page, mirroring how
  `static-hosting.md` sits beside `deploying-apps.md`. The new page cross-links `secrets.md` for
  the operator distinction.
  Date: 2026-06-09

- Decision: The example project is a tiny **Node app** at `cluster/examples/env-and-secrets/`,
  not a copy of the Go `hello-knative-service`.
  Rationale: the headline observable behaviour is "the app prints its `NAGARE_*` vars and a
  managed var, so you can `curl` the URL and *see* env take effect." A few lines of Node
  (`process.env`) make that trivially readable and require no compiler in the image, matching the
  framework-free spirit of the `static-site` example (EP-17 Decision Log) while still being a real
  runtime app (a `Deployment`, so `nagarectl deploy` and the generated `NAGARE_*` vars both
  apply). The example also ships a `Dockerfile` because `nagarectl deploy` builds an image from
  the project directory.
  Date: 2026-06-09

- Decision: Document, but **mark live as pending**, matching the sibling guides.
  Rationale: `deploying-apps.md` and `static-hosting.md` both carry a 🟡 "built; live deploy
  pending `nagare-01`" badge because the box is powered down. This guide inherits the same status
  for its live walkthrough; every `--dry-run` leg is exercised today, and the live legs are
  written as the intended behaviour with the `tan-nb-exp`/`us-west1` target stated. If the box is
  up when this plan runs, run the live legs and capture real transcripts.
  Date: 2026-06-09

- Decision: The example declares its **Build**-scoped variable with the raw `scopedEnv`
  constructor (from `Nagare.Dsl.Types`, EP-23) and its **secret** with the `secretEnv` preset
  (Runtime-scoped), because there is no preset helper for a build-scoped secret and the Build var
  is a literal.
  Rationale: keeps the example honest to the surfaces the sibling plans actually deliver
  (EP-23 exports `scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar` and
  `runtimeScoped`; `secretEnv` is wrapped to Runtime in EP-23). It also makes the example a useful
  reference for *how to write a scoped var in `Config.hs`*.
  Date: 2026-06-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-09): complete, both milestones.** A newcomer now has one guide
(`docs/user/env-and-secrets.md`) and one deployable example
(`cluster/examples/env-and-secrets/`) that together explain and demonstrate the whole
env/secret surface: the scope model and the precedence ladder, the full `env`/`secret`
CLI with real copy-pasteable transcripts, `.env` sync (merge vs reconcile-exact), the
generated `NAGARE_*` table, build-time env with its `docker history` security caveat,
preview overlays, and a troubleshooting table. The guide is linked from both
`docs/user/README.md` (status row + read-in-order bullet) and `docs/user/reference.md`
(CLI table). Fence parity verified.

**Against the purpose:** every surface is demonstrable on a laptop with `--dry-run`, and
all embedded transcripts are the **real** output of the bundled example (not idealized) —
the deploy render shows the `NAGARE_*` block and runtime `envFrom` while excluding the
Build-scoped `BUILD_STAMP`; the `env set`/`secret set`/`env sync --reconcile-exact`
dry-runs show the exact ConfigMap/Secret manifests. The live walkthrough is written and
deferred behind the shared 🟡 `nagare-01` caveat.

**Notes / lessons:** the only deviations from the plan were forced by the codebase having
moved on (compact-JSON store output, the required `build` field) — recorded in Surprises
and corrected against real output, which is exactly what a docs-and-example capstone is
for: catching where the written contract and the shipped behaviour diverge.


## Context and Orientation

Read this section fully before editing; it assumes no prior knowledge of this repository and
restates everything the later sections rely on.

### Where Nagare's user docs live (the convention to match)

Nagare's user-facing documentation lives under `docs/user/`. Each page is a Markdown file with a
**status badge** quote-block at the top (`✅ Working`, `🟡 In progress`, `🔭 Planned`), as defined
in `docs/user/README.md`. The relevant existing developer pages are:

- `docs/user/deploying-apps.md` — how a project becomes a running HTTPS service via
  `nagarectl deploy` and a typed `nagare/Config.hs`. Carries 🟡 "built; live deploy pending."
- `docs/user/static-hosting.md` — static and full-stack site hosting via `nagarectl site deploy`
  (EP-17, the precedent for *this* docs+example plan). Also 🟡.
- `docs/user/config-reference.md` — the typed config field/constructor catalogue.
- `docs/user/secrets.md` — **operator** secrets: `sops-nix` for the host, `sops`+`age` for the
  cluster. This is a *different* concern from app env/secrets; this plan adds a separate page and
  cross-links it (see Decision Log).
- `docs/user/README.md` — the docs index: a status table mapping areas to plans, and a
  "Read in this order" list. New pages are linked here.
- `docs/user/reference.md` — operational reference values and CLI command tables.

The page this plan adds is **`docs/user/env-and-secrets.md`**, a new developer page beside
`deploying-apps.md` and `static-hosting.md`.

### Where example projects live (the convention to match)

Deployable examples live under `cluster/examples/<name>/`. Each carries a typed
`nagare/Config.hs` that imports the `nagare-dsl` library and emits a `Deployment` (an app),
a `StaticSite`, or a `ServerSite`, plus a `README.md` and (for some) reference manifests. The
templates this plan mirrors:

- `cluster/examples/hello-knative-service/` — a `Deployment` example: `nagare/Config.hs`,
  `README.md`, and reference `service.yaml`/`domainmapping.yaml`. Its `Config.hs` binds a
  `Deployment` through smart constructors and ends `main = emitDeployment dep`.
- `cluster/examples/static-site/` and `cluster/examples/tanstack-start/` — the site examples
  (framework-free static, and a Node full-stack app with a `Dockerfile`).

The example this plan adds is **`cluster/examples/env-and-secrets/`**, a `Deployment` example
(so `nagarectl deploy` and the generated `NAGARE_*` variables both apply) with a tiny Node app
and a `Dockerfile`.

### The four sibling plans this guide documents

This plan is the documentation+demonstration capstone of the parent MasterPlan
`docs/masterplans/5-environment-and-secret-management-for-nagare.md`. It documents the
user-facing surfaces these four checked-in plans deliver. You do not need to read them — the
contract you need is restated below — but they are the source of truth:

- `docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md` (EP-23) — the scope model,
  the managed `envFrom` store, and the naming helpers.
- `docs/plans/25-nagarectl-env-and-secret-cli-commands.md` (EP-25) — the `env`/`secret` CLI.
- `docs/plans/26-generated-and-predefined-environment-variables.md` (EP-26) — the `NAGARE_*`
  generated variable table.
- `docs/plans/27-build-time-and-preview-scoped-env-application.md` (EP-27) — build-time env
  reaching `docker build`, and preview env overlays.

This plan **hard-depends** on EP-25 (the CLI must exist to run the walkthrough) and EP-27
(build/preview application must exist to demonstrate those legs). It **soft-depends** on EP-26
(the `NAGARE_*` table can be documented even before injection is wired; the example simply will
not show those vars until EP-26 lands). It builds on EP-23, whose model the example's `Config.hs`
uses.

### The scope model and precedence (from EP-23 — restated so you need no other file)

Every environment variable in a Nagare config carries a set of **scopes**, answering *when* the
variable applies. A **scope** (`EnvScope`) is one of:

- **`Runtime`** — present in the running container (the default if you write a plain variable).
- **`Build`** — present during the image build (`docker build`), not in the running container.
- **`Preview`** — overlays preview deployments.

A variable can carry several scopes at once. In the typed model (`Nagare.Dsl.Types`), an env
entry is a `ScopedEnvVar { value :: EnvVar, scopes :: Set EnvScope }`, where `EnvVar` is either
`EnvLiteral Text` (a plain value) or `EnvSecretRef SecretName` (a reference to a Kubernetes
Secret). A plain variable defaults to `{Runtime}` (the helper `runtimeScoped`); an explicit scope
set uses `scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar` (which rejects an empty
set).

**Managed env** lives outside the config, in per-app, per-scope Kubernetes objects an operator can
change without editing Haskell or rebuilding the image:

- a **ConfigMap** named `nagare-env-<app>-<scope>` for plain values, and
- a **Secret** named `nagare-secret-<app>-<scope>` for sensitive values,

where `<scope>` is the lowercased token `runtime`/`build`/`preview`. Every rendered Knative
`Service` consumes the **Runtime**-scoped pair through an `envFrom:` block with `optional: true`
(so the app still deploys if the store was never written):

```yaml
envFrom:
- configMapRef:
    name: nagare-env-<app>-runtime
    optional: true
- secretRef:
    name: nagare-secret-<app>-runtime
    optional: true
```

**Precedence is the contract you must document and the most common source of confusion.**
Kubernetes applies `envFrom` *first* and the inline `env:` list *second*. So an inline variable
overrides a managed one of the same name. Inline `env:` comes from two places: the variables you
wrote in `Config.hs` (scope-filtered to `{Runtime}` for the running container) and the generated
`NAGARE_*` variables (EP-26), which are also inline. The rule, top wins:

1. Inline DSL `env:` (from `Config.hs`) and generated `NAGARE_*` — **highest**.
2. Managed store (`nagare-env-<app>-runtime` / `nagare-secret-<app>-runtime`) via `envFrom`.

This is why "my managed variable isn't taking effect" almost always means a `Config.hs` variable
of the same name is shadowing it — a key entry in the troubleshooting section.

### The CLI grammar (from EP-25 — use verbatim)

The operator surface (`nagarectl env` and `nagarectl secret`) reads/writes the managed store
without touching Haskell or rebuilding the image, because the running Service already references
those names via `envFrom`. The exact grammar, which the guide must reproduce verbatim:

```text
nagarectl env list   APP [-f|--config CONFIG] [--all]
nagarectl env set    APP KEY VALUE [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]
nagarectl env delete APP KEY       [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]
nagarectl env sync   APP --file FILE [-f|--config CONFIG] [--runtime] [--build] [--preview] [--merge | --reconcile-exact] [--dry-run]
nagarectl secret set    APP KEY    [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]   # value from stdin
nagarectl secret list   APP        [-f|--config CONFIG] [--all]
nagarectl secret delete APP KEY    [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]
```

Defaults and rules to document:

- **Scope defaults to `runtime`.** If none of `--runtime`/`--build`/`--preview` is given, the
  command targets the runtime scope. The scope flags may be combined to write several scopes at
  once.
- **`-f/--config CONFIG`** points at the typed config (default `nagare/Config.hs`). `APP`'s real
  identity — the `(name, namespace)` that determines the managed-store names — comes from *loading
  that config*, not from the literal `APP` word. If `APP` disagrees with the config's name it is a
  hard error, so a typo cannot silently write a store the Service never reads.
- **`--file FILE`** on `env sync` is the **dotenv path** (a separate flag from `-f/--config`).
- **`env sync` default mode is `--merge`** (keep existing keys not in the file; the file's keys
  win on collision). `--reconcile-exact` makes the store *exactly* the file's contents, dropping
  any key not present. `--merge` and `--reconcile-exact` are mutually exclusive.
- **`secret set` reads the value from stdin, never argv** (so the value never appears in `ps`,
  `/proc`, or shell history). `secret list` prints **key names only**, never values.
- **`--dry-run`** on any mutating command prints the exact ConfigMap/Secret manifest that *would*
  be applied and touches no cluster, so the whole surface is demonstrable on a laptop. A Secret
  dry-run shows base64-encoded values (the wire format, not encryption).

A dotenv (`.env`) file lists `KEY=VALUE` one per line; blank lines and `#` comments are ignored;
`export ` prefixes are stripped; single/double-quoted values are taken literally; a non-blank
line with no `=` is an error.

### The generated variables (from EP-26 — soft dependency)

Every app and server site Nagare deploys automatically receives a reserved set of inline
`{Runtime}` variables describing the deployment's own identity. They are inline, so by the
precedence above they win over the managed store and over any user variable of the same name —
the `NAGARE_` prefix is **reserved**. The canonical table the guide reproduces:

| Variable | Meaning | Example value |
| --- | --- | --- |
| `NAGARE_SERVICE_URL` | The deployment's resolved public https URL (custom domain if set, else the Knative wildcard) | `https://envdemo.personal.apps.example.com` |
| `NAGARE_SERVICE_NAME` | The Knative Service / app name | `envdemo` |
| `NAGARE_NAMESPACE` | The Kubernetes namespace the Service runs in | `personal` |
| `NAGARE_BASE_DOMAIN` | The apps base domain used to derive the wildcard URL | `apps.example.com` |
| `NAGARE_RELEASE_ID` | The image tag deployed (the release id) | `20260602-120000` |
| `NAGARE_SOURCE` | Source provenance from `--source` (branch/commit); present only when `--source` was given, and only on the `site deploy` path | `main` |

The first five are always present on the `deploy` and `site deploy` paths; `NAGARE_SOURCE` is
emitted only when a `--source` was given, which today is only the `site deploy` path (the
prebuilt-image `deploy` path has no `--source` flag). A running app reads these through the normal
environment, e.g. `process.env.NAGARE_SERVICE_URL`.

### Build-time and preview env (from EP-27 — hard dependency)

- **Build-scoped env reaches `docker build`.** A `Build`-scoped variable is passed to the image
  build as a `--build-arg`, so a `Dockerfile` can read it via `ARG NAME` / `ENV NAME=$NAME`. It is
  **not** in the running container's inline `env:` (it is filtered out by scope at render time).
  **Security caveat to document loudly:** a `--build-arg` value is recorded in the image's build
  history and is readable by anyone who can pull the image (`docker history`). Build-arg values are
  therefore **not a secret mechanism**; for true build secrets use the documented build-secret
  path, and never put a credential you must keep private into a plain build-arg.
- **Preview env overlays runtime in previews.** A preview deployment consumes the runtime managed
  store *and then* the preview managed store: the Service's `envFrom` lists the runtime pair first
  and the preview pair second, so a `Preview`-scoped value overlays (overrides) the runtime value
  of the same key in previews only. Production is unaffected.


## Plan of Work

The work is two milestones. **M1** writes the user guide and wires it into the docs index — this
is the page a newcomer reads. **M2** builds the deployable example and the end-to-end walkthrough
that proves every surface, capturing transcripts back into the guide and the example README. Each
milestone is independently verifiable: M1 by the guide existing, being linked, and passing the
fence-parity check; M2 by the `--dry-run` transcripts being reproducible and (when the box is up)
the live walkthrough showing the observable effects.


### Milestone M1 — Write the user guide and link it

**Scope.** Create `docs/user/env-and-secrets.md`; link it from `docs/user/README.md` and add a
CLI command table to `docs/user/reference.md`. No example or live run yet (those are M2), but the
guide includes placeholders for the M2 transcripts that M2 fills with real output.

**What will exist that did not before.** A single developer page that explains the scope model and
precedence, the full `env`/`secret` CLI with copy-pasteable examples, `.env` sync with merge vs.
reconcile-exact, the generated `NAGARE_*` table, build-time env and its security caveat, preview
env overlays, and a troubleshooting section.

**The guide's structure** (write these sections in `docs/user/env-and-secrets.md`, in order):

1. A status badge quote-block at the top, matching the sibling pages:

   ```text
   > **Status:** 🟡 **Built and tested offline; live walkthrough pending `nagare-01`.**
   >
   > The scoped env model, the `nagarectl env`/`secret` CLI, the generated `NAGARE_*`
   > variables, and build/preview application all exist and are tested. Every command on
   > this page works in `--dry-run` today (no cluster). The *live* legs — deploy, set,
   > curl, sync, preview — are the intended behaviour against the cluster on GCP project
   > `tan-nb-exp`, region `us-west1`; they are pending `nagare-01` being powered on, the
   > same caveat as [Deploying apps](deploying-apps.md).
   ```

2. **What this page is** — a short intro: app env/secrets managed without editing Haskell or
   rebuilding the image, distinct from the operator [Secrets](secrets.md) page (host/cluster
   sops). One link to the example: [`cluster/examples/env-and-secrets`](../../cluster/examples/env-and-secrets).

3. **The scope model** — define `Runtime`/`Build`/`Preview`, the default `{Runtime}`, and how you
   write a scoped variable in `Config.hs` (a `runtimeScoped (EnvLiteral …)`, a
   `scopedEnv (Set.fromList [Build]) (EnvLiteral …)`, and a `secretEnv` for a secret-ref). Show a
   minimal `Config.hs` excerpt taken from the M2 example.

4. **Where managed env lives, and precedence** — the `nagare-env-<app>-<scope>` /
   `nagare-secret-<app>-<scope>` names, the `envFrom optional:true` block, and the precedence
   ladder (inline DSL `env` + `NAGARE_*` win over the managed store). Reproduce the precedence list
   from Context. This is the conceptual heart of the page.

5. **The CLI** — reproduce the EP-25 grammar block verbatim, then a copy-pasteable worked block
   for each command (`env list/set/delete/sync`, `secret set/list/delete`), each with an example
   invocation and expected one-line output, drawn from the M2 transcripts. Call out: scope default
   `runtime`; `-f/--config` is the typed config while `--file` is the dotenv path; `secret set`
   reads stdin; `secret list` shows names only; `--dry-run` prints the manifest.

6. **Bulk import with `.env`** — explain dotenv format, then `env sync … --merge` (default, keeps
   other keys) vs. `env sync … --reconcile-exact` (store becomes exactly the file; other keys
   dropped). Show both with a before/after `env list`.

7. **Generated `NAGARE_*` variables** — reproduce the EP-26 table and the reserved-prefix rule;
   note `NAGARE_SOURCE` is only on the `site deploy` path with `--source`.

8. **Build-time env** — how a `Build`-scoped variable reaches `docker build` (`--build-arg`,
   read in the `Dockerfile` via `ARG`/`ENV`), that it is absent from the running container, and the
   **security caveat** (build-args are visible in `docker history`; not a secret mechanism; use the
   build-secret path for real build secrets).

9. **Preview env overlays** — how a `Preview`-scoped value overlays runtime in previews only
   (runtime `envFrom` first, then preview `envFrom`), with production unaffected.

10. **Troubleshooting** — a table of symptoms and fixes. At minimum:
    - *"My managed variable isn't taking effect."* — It is shadowed by an inline DSL variable of
      the same name in `Config.hs` (inline wins over `envFrom`). Rename or remove the inline one,
      or set the managed value through `Config.hs` instead.
    - *"My `NAGARE_*` value is ignored / I set it myself and it changed."* — `NAGARE_*` is reserved;
      the generated value always wins.
    - *"`env set` succeeded but the app didn't change."* — managed env is read by the Service via
      `envFrom`; a running revision may need a new revision to pick it up — redeploy (or trigger a
      new revision) so the pod re-reads the store.
    - *"`secret list` shows the key but the app sees an empty value."* — the value was written to a
      different scope, or to a different app name than the config resolves to (check
      `-f/--config`).
    - *"`env sync` deleted keys I wanted to keep."* — you used `--reconcile-exact`; use the default
      `--merge` to keep keys not in the file.
    - *"A build-time variable shows up in `docker history`."* — expected; build-args are not
      secret. Use the build-secret path for private values.

**Wire it in.** In `docs/user/README.md`: add a status-table row (Area "App env & secrets
(`nagarectl env`/`secret`)", Plan "MP-5 (EP-23–28)", Status 🟡) and a read-in-order sub-bullet
under item 8 ("Deploying apps"), mirroring how `static-hosting.md` is linked there. In
`docs/user/reference.md`: add a `nagarectl env`/`nagarectl secret` command table (the grammar
above, condensed to one row per subcommand).

**Commands and acceptance.** From the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
test -f docs/user/env-and-secrets.md && echo "guide present"
rg -n "env-and-secrets" docs/user/README.md docs/user/reference.md
```

Acceptance: the guide exists, is linked from both index files, and the fence-parity check in
Concrete Steps reports no untagged opening fence.


### Milestone M2 — The example project and the end-to-end walkthrough

**Scope.** Create `cluster/examples/env-and-secrets/`: a typed `nagare/Config.hs` declaring a
Runtime literal, a Build-scoped var, and a secret-ref; a tiny Node app and `Dockerfile` that
prints its `NAGARE_*` vars and a managed var; two dotenv files; and a `README.md`. Then run the
walkthrough (dry-run always; live when the box is up) and capture transcripts into the guide and
README.

**What will exist that did not before.** A deployable example whose URL *shows* env taking effect,
and a reproducible walkthrough proving: managed env set → curl shows it; secret set via stdin →
curl shows it; reconcile-exact sync → a key disappears; preview overlay → preview URL shows the
overlaid value while production keeps the original.

**The exact files to create:**

`cluster/examples/env-and-secrets/nagare/Config.hs` — a `Deployment` whose env map carries one
Runtime literal (`GREETING`), one Build-scoped literal (`BUILD_STAMP`), and one secret-ref
(`API_KEY`, Runtime via `secretEnv`). It binds the env map with the EP-23 scoped constructors:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Example: scoped env + managed env/secret stores, proven end to end (EP-28).
--
-- The app prints its NAGARE_* generated variables and any managed variable it
-- can see, so `curl`-ing the deployed URL shows env changes taking effect.
--
-- This config declares three variables across scopes:
--   * GREETING      — a Runtime literal (visible in the running container)
--   * BUILD_STAMP   — a Build-scoped literal (reaches `docker build`, NOT runtime)
--   * API_KEY       — a Runtime secret reference (resolved from a Kubernetes Secret)
module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types

deployment :: Either String Deployment
deployment = do
  name' <- mapLeft show (mkServiceName "envdemo")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/envdemo")
  port' <- mapLeft show (mkPort 8080)
  sc <- mapLeft show (mkScale 0 2)

  greeting <- mapLeft show (mkEnvName "GREETING")
  buildStamp <- mapLeft show (mkEnvName "BUILD_STAMP")
  apiKey <- mapLeft show (mkEnvName "API_KEY")
  apiKeySecret <- mapLeft show (mkSecretName "envdemo-api-key")

  buildScoped <- mapLeft show (scopedEnv (Set.fromList [Build]) (EnvLiteral "dev-stamp"))

  let env' =
        Map.fromList
          [ (greeting, runtimeScoped (EnvLiteral "hello from Config.hs"))
          , (buildStamp, buildScoped)
          , (apiKey, runtimeScoped (EnvSecretRef apiKeySecret))
          ]
  Right
    Deployment
      { name = name'
      , namespace = ns'
      , image = img'
      , domain = Nothing
      , port = port'
      , env = env'
      , resources = Nothing
      , scale = Just sc
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
```

(Note: `GREETING` is declared inline in `Config.hs`, so it demonstrates the precedence caveat — a
managed `GREETING` set with `nagarectl env set` is *shadowed* by this inline value. The walkthrough
uses a *different* key, `REGION`, for the "managed var appears" leg so the effect is visible, and
uses `GREETING` only in the troubleshooting demonstration. `BUILD_STAMP` is Build-scoped, so it is
absent from the running container's inline `env:`; `API_KEY` is a Runtime secret-ref resolved from
the Kubernetes Secret `envdemo-api-key`.)

`cluster/examples/env-and-secrets/app.js` — a tiny dependency-free HTTP server that prints the
`NAGARE_*` variables and a couple of managed/inline variables so a `curl` reveals the env:

```javascript
// Minimal HTTP server: echoes selected environment variables as plain text so a
// `curl` of the deployed URL shows env changes taking effect. No dependencies.
const http = require("http");

const SHOW = [
  "NAGARE_SERVICE_URL",
  "NAGARE_SERVICE_NAME",
  "NAGARE_NAMESPACE",
  "NAGARE_RELEASE_ID",
  "GREETING",   // inline DSL var (shadows a managed GREETING — see the guide)
  "REGION",     // managed var set via `nagarectl env set`
  "API_KEY",    // managed secret set via `nagarectl secret set` (shown masked)
];

const server = http.createServer((_req, res) => {
  const lines = SHOW.map((k) => {
    const v = process.env[k];
    if (v === undefined) return `${k}=(unset)`;
    if (k === "API_KEY") return `${k}=${"*".repeat(Math.min(v.length, 8))} (set)`;
    return `${k}=${v}`;
  });
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(lines.join("\n") + "\n");
});

server.listen(8080, () => console.log("envdemo listening on :8080"));
```

`cluster/examples/env-and-secrets/Dockerfile` — builds the Node image and demonstrates a
Build-scoped variable reaching the build via `--build-arg`:

```dockerfile
FROM node:22-slim

# BUILD_STAMP is a Build-scoped variable (EP-23/EP-27): Nagare passes it to
# `docker build` as --build-arg BUILD_STAMP=<value>. Read it here; it is baked
# into the image at build time and is NOT present in the running container's
# inline env. SECURITY: --build-arg values are visible via `docker history`;
# do not use them for secrets (see docs/user/env-and-secrets.md).
ARG BUILD_STAMP=unset
ENV BUILD_STAMP=${BUILD_STAMP}

WORKDIR /app
COPY app.js ./
EXPOSE 8080
CMD ["node", "app.js"]
```

`cluster/examples/env-and-secrets/.env.production` — a dotenv for the `env sync` leg:

```text
# Managed runtime env for the envdemo example. Imported with:
#   nagarectl env sync envdemo --file .env.production --reconcile-exact
REGION=us-west1
LOG_LEVEL=info
FEATURE_FLAGS=beta,fast
```

`cluster/examples/env-and-secrets/.env.preview` — a preview overlay:

```text
# Preview overlay: applied with --preview, overrides runtime values in previews only.
REGION=us-west1-preview
LOG_LEVEL=debug
```

`cluster/examples/env-and-secrets/README.md` — mirrors the `hello-knative-service` README: a
"Files" list, a "Preview the rendered manifest (no cluster)" `--dry-run` section, a "Deploy and
manage env/secrets" section pointing at the guide, and a "Cleanup" section (the `kubectl delete`
commands from Idempotence below). It links the guide as the authoritative walkthrough.

**Build the example image is not required for `--dry-run`.** `nagarectl deploy --dry-run` only
compiles-and-runs `nagare/Config.hs` and prints manifests; it does not build the Docker image. The
`Dockerfile` and `app.js` are needed only for the live deploy.

**Commands and acceptance.** See Concrete Steps and Validation. Acceptance at M2: the `--dry-run`
transcripts in the guide and README are reproducible byte-shape (the inline `env:` shows
`GREETING` and the `NAGARE_*` block but **not** `BUILD_STAMP`; the `envFrom` references
`nagare-env-envdemo-runtime`/`nagare-secret-envdemo-runtime`); the `env set`/`secret set`/`env sync
--reconcile-exact` `--dry-run` manifests match; and, when the box is up, the live walkthrough shows
each observable effect.


## Concrete Steps

Run everything from the repository root unless a step says otherwise. The repository root is the
directory containing `cli/`, `docs/`, `cluster/`, and `CLAUDE.md`:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Enter the flake dev shell first if not already inside it (the repo uses direnv: `direnv allow`
once, or `nix develop`). Build `nagarectl` once so the config loader's `runghc` can resolve the
`nagare-dsl` library (this materialises a `.ghc.environment.*`):

```bash
cabal --project-dir=cli/nagarectl build
```

### Read the docs to align with

```bash
sed -n '1,80p' docs/user/deploying-apps.md
sed -n '1,80p' docs/user/static-hosting.md
sed -n '1,120p' docs/user/README.md
```

### Create the example, then dry-run it

Create the files listed in M2 under `cluster/examples/env-and-secrets/`. Then render the manifest
with no cluster:

```bash
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- deploy --dry-run \
  --file cluster/examples/env-and-secrets/nagare/Config.hs \
  --base-domain apps.example.com \
  --tag 20260602-120000
```

Expected (abbreviated) — the inline `env:` shows the user's `GREETING` and the generated
`NAGARE_*` block, **omits** the Build-scoped `BUILD_STAMP`, shows the `API_KEY` secret-ref, and the
`envFrom` references the managed runtime store:

```text
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: envdemo
  namespace: personal
spec:
  template:
    spec:
      containers:
      - image: us-west1-docker.pkg.dev/tan-nb-exp/nagare/envdemo:20260602-120000
        ports:
        - containerPort: 8080
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
          value: "20260602-120000"
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
URL: https://envdemo.personal.apps.example.com
```

Confirm `BUILD_STAMP` is absent from the rendered runtime manifest:

```bash
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- deploy --dry-run \
  --file cluster/examples/env-and-secrets/nagare/Config.hs \
  --base-domain apps.example.com --tag 20260602-120000 \
  | grep -c BUILD_STAMP
# Expect: 0
```

### Dry-run the CLI surfaces (no cluster)

Set a managed env var — prints the ConfigMap that would be applied:

```bash
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- env set envdemo REGION us-west1 \
  --config cluster/examples/env-and-secrets/nagare/Config.hs --dry-run
```

Expected (abbreviated):

```text
--- ConfigMap (runtime) ---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nagare-env-envdemo-runtime
  namespace: personal
data:
  REGION: us-west1
```

Set a secret from stdin (the value never appears in argv) — prints the Secret with base64 data:

```bash
printf 'topsecret' | cabal --project-dir=cli/nagarectl run -v0 nagarectl -- \
  secret set envdemo API_KEY \
  --config cluster/examples/env-and-secrets/nagare/Config.hs --dry-run
```

Expected — `data.API_KEY` is `dG9wc2VjcmV0` (base64 of `topsecret`), proving the value was read
from stdin:

```text
--- Secret (runtime) ---
apiVersion: v1
kind: Secret
metadata:
  name: nagare-secret-envdemo-runtime
  namespace: personal
data:
  API_KEY: dG9wc2VjcmV0
```

Dry-run a reconcile-exact sync from the dotenv file — prints the ConfigMap that would *replace*
the store with exactly the file's keys:

```bash
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- env sync envdemo \
  --file cluster/examples/env-and-secrets/.env.production --reconcile-exact \
  --config cluster/examples/env-and-secrets/nagare/Config.hs --dry-run
```

Expected — the ConfigMap `data` is exactly `REGION`, `LOG_LEVEL`, `FEATURE_FLAGS` (any key not in
the file is dropped under reconcile-exact):

```text
--- ConfigMap (runtime) ---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nagare-env-envdemo-runtime
  namespace: personal
data:
  FEATURE_FLAGS: beta,fast
  LOG_LEVEL: info
  REGION: us-west1
```

### Fence-parity check (no untagged opening fence)

The repo convention is that an *opening* fence carries a language tag and the *closing* fence is
bare. Verify no opening fence was left untagged in the files this plan touches:

```bash
rg -n '^```$' docs/user/env-and-secrets.md cluster/examples/env-and-secrets/README.md \
  docs/plans/28-env-and-secret-management-docs-and-end-to-end-example.md
```

Every match must be a *closing* fence (the line is preceded somewhere above by a tagged opening
fence). If a code block has a bare *opening* fence, add the language tag.


## Validation and Acceptance

Acceptance is behavioral: a reader can run the documented commands and see the stated effects.

### Offline (always runnable, no cluster)

1. **The guide exists and is linked.** `docs/user/env-and-secrets.md` exists; `rg env-and-secrets
   docs/user/README.md docs/user/reference.md` shows it linked from both.
2. **The example renders.** The `deploy --dry-run` transcript above is reproducible: the inline
   `env:` contains `GREETING` and the `NAGARE_*` block, the `envFrom` references
   `nagare-env-envdemo-runtime`/`nagare-secret-envdemo-runtime`, and `BUILD_STAMP` is **absent**
   from the runtime manifest (`grep -c BUILD_STAMP` returns `0`).
3. **The CLI dry-runs match.** `env set --dry-run` prints the `nagare-env-envdemo-runtime`
   ConfigMap; `secret set --dry-run` (value piped on stdin) prints the
   `nagare-secret-envdemo-runtime` Secret whose `API_KEY` is base64 of the piped value;
   `env sync --reconcile-exact --dry-run` prints a ConfigMap whose `data` is exactly the dotenv
   file's keys.
4. **Fence parity** passes (Concrete Steps).

### Live walkthrough (against the cluster on `tan-nb-exp`, region `us-west1`)

Per `CLAUDE.md`, every cluster operation targets GCP project `tan-nb-exp`, region `us-west1`. Set
`KUBECONFIG` to the cluster's kubeconfig first (see `docs/user/accessing-the-host.md`). These legs
prove the observable effects; mark them deferred (and keep the guide's 🟡 badge) if `nagare-01` is
powered down.

**Deploy the example.**

```bash
export KUBECONFIG=/tmp/nagare-kubeconfig.yaml
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- deploy \
  --file cluster/examples/env-and-secrets/nagare/Config.hs \
  --base-domain "$(pulumi -C infra/pulumi stack output baseDomain)" \
  --project-dir cluster/examples/env-and-secrets
URL=https://envdemo.personal.$(pulumi -C infra/pulumi stack output baseDomain)
PUBLIC_IP=$(pulumi -C infra/pulumi stack output publicIp)
curl -s --resolve envdemo.personal.$(pulumi -C infra/pulumi stack output baseDomain):443:${PUBLIC_IP} "$URL"
```

Expected — `GREETING` and the `NAGARE_*` vars are set; `REGION` and `API_KEY` are still unset
(no managed store yet):

```text
NAGARE_SERVICE_URL=https://envdemo.personal.apps.example.com
NAGARE_SERVICE_NAME=envdemo
NAGARE_NAMESPACE=personal
NAGARE_RELEASE_ID=20260602-120000
GREETING=hello from Config.hs
REGION=(unset)
API_KEY=(unset)
```

**Set a managed env var, then redeploy and curl.** (Managed env is read by the pod via `envFrom`;
a new revision picks it up — redeploy, or trigger a new revision.)

```bash
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- env set envdemo REGION us-west1 \
  --config cluster/examples/env-and-secrets/nagare/Config.hs
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- deploy \
  --file cluster/examples/env-and-secrets/nagare/Config.hs \
  --base-domain "$(pulumi -C infra/pulumi stack output baseDomain)" \
  --project-dir cluster/examples/env-and-secrets
curl -s --resolve envdemo.personal.$(pulumi -C infra/pulumi stack output baseDomain):443:${PUBLIC_IP} "$URL"
```

Expected — `REGION` now shows the managed value:

```text
...
REGION=us-west1
API_KEY=(unset)
```

**Set a secret from stdin, then redeploy and curl.**

```bash
printf 'topsecret' | cabal --project-dir=cli/nagarectl run -v0 nagarectl -- \
  secret set envdemo API_KEY --config cluster/examples/env-and-secrets/nagare/Config.hs
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- secret list envdemo \
  --config cluster/examples/env-and-secrets/nagare/Config.hs
# prints: API_KEY   (name only, never the value)
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- deploy \
  --file cluster/examples/env-and-secrets/nagare/Config.hs \
  --base-domain "$(pulumi -C infra/pulumi stack output baseDomain)" \
  --project-dir cluster/examples/env-and-secrets
curl -s --resolve envdemo.personal.$(pulumi -C infra/pulumi stack output baseDomain):443:${PUBLIC_IP} "$URL"
```

Expected — `API_KEY` is now set (the app masks the value):

```text
...
REGION=us-west1
API_KEY=******** (set)
```

**Reconcile-exact sync, then observe a key disappear.** First set an extra managed key, confirm it
is present, then sync reconcile-exact from `.env.production` (which does **not** contain that key)
and watch it vanish:

```bash
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- env set envdemo TEMP_FLAG yes \
  --config cluster/examples/env-and-secrets/nagare/Config.hs
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- env list envdemo \
  --config cluster/examples/env-and-secrets/nagare/Config.hs
# shows REGION, TEMP_FLAG (runtime scope)
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- env sync envdemo \
  --file cluster/examples/env-and-secrets/.env.production --reconcile-exact \
  --config cluster/examples/env-and-secrets/nagare/Config.hs
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- env list envdemo \
  --config cluster/examples/env-and-secrets/nagare/Config.hs
```

Expected `env list` after the sync — `TEMP_FLAG` is gone; the store is exactly the file's keys:

```text
  SCOPE    KEY           VALUE
  runtime  FEATURE_FLAGS  beta,fast
  runtime  LOG_LEVEL      info
  runtime  REGION         us-west1
```

(With the default `--merge`, `TEMP_FLAG` would have been kept — that contrast is the point.)

**Preview overlay.** Write the preview-scoped store from `.env.preview`, deploy a preview, and curl
the preview URL: the overlaid `REGION` value appears in the preview while production keeps
`us-west1`.

```bash
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- env sync envdemo \
  --file cluster/examples/env-and-secrets/.env.preview --preview --reconcile-exact \
  --config cluster/examples/env-and-secrets/nagare/Config.hs
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- site preview deploy --name pr-1 \
  --file cluster/examples/env-and-secrets/nagare/Config.hs \
  --base-domain "$(pulumi -C infra/pulumi stack output baseDomain)" \
  --project-dir cluster/examples/env-and-secrets
PREVIEW_URL=https://envdemo-pr-1.personal.$(pulumi -C infra/pulumi stack output baseDomain)
curl -s --resolve envdemo-pr-1.personal.$(pulumi -C infra/pulumi stack output baseDomain):443:${PUBLIC_IP} "$PREVIEW_URL"
```

Expected — the preview serves the overlaid `REGION` (preview `envFrom` overrides runtime), while a
fresh `curl "$URL"` on production still shows `REGION=us-west1`:

```text
# preview:
REGION=us-west1-preview
LOG_LEVEL=debug
# production (unchanged):
REGION=us-west1
```

(If the preview surface for plain `Deployment` apps is not available, document this leg using the
`Preview`-scoped `envFrom` overlay directly — runtime `envFrom` first, preview `envFrom` second —
and note the gap; the `--dry-run` of the `--preview` sync still proves the store is written under
`nagare-env-envdemo-preview`.)

Capture the real transcripts into `docs/user/env-and-secrets.md` and the example README, replacing
the placeholder example values with observed output where they differ.


## Idempotence and Recovery

All documentation edits are safe to repeat. Every `--dry-run` command has no side effects and is
fully reproducible. The example's `nagare/Config.hs` is pure: re-rendering it produces identical
manifests.

The live walkthrough is idempotent: `nagarectl deploy` applies manifests with `kubectl apply`,
which updates the same resources on repeat; `nagarectl env set`/`secret set`/`env sync` read the
store, compute the desired state, and write it back, so re-running converges. `env sync --merge`
is non-destructive; only `--reconcile-exact` drops keys (used deliberately in the walkthrough).
Setting a managed value you did not intend is recovered with `nagarectl env delete envdemo KEY`
(or `secret delete`).

Cleanup — remove everything the walkthrough created (the example's Service, the preview, and the
managed ConfigMaps/Secrets across scopes), scoped to namespace `personal` on `tan-nb-exp`:

```bash
# Preview (if deployed):
cabal --project-dir=cli/nagarectl run -v0 nagarectl -- site preview delete pr-1 \
  --file cluster/examples/env-and-secrets/nagare/Config.hs || true

# The app's Service:
kubectl -n personal delete ksvc envdemo --ignore-not-found

# The managed env/secret stores (all scopes):
kubectl -n personal delete configmap \
  nagare-env-envdemo-runtime nagare-env-envdemo-build nagare-env-envdemo-preview \
  --ignore-not-found
kubectl -n personal delete secret \
  nagare-secret-envdemo-runtime nagare-secret-envdemo-build nagare-secret-envdemo-preview \
  envdemo-api-key \
  --ignore-not-found
```

Do not delete unrelated cluster resources during this validation. All `kubectl` calls target
`tan-nb-exp`/`us-west1` via the configured `KUBECONFIG` (per `CLAUDE.md`).


## Interfaces and Dependencies

This plan adds **documentation and an example**; it introduces no new code interfaces. It consumes
the surfaces the four sibling plans deliver.

**Artifacts this plan creates:**

- `docs/user/env-and-secrets.md` — the developer guide.
- `cluster/examples/env-and-secrets/` — the example project:
  - `nagare/Config.hs` (typed `Deployment` with Runtime literal, Build-scoped var, secret-ref),
  - `app.js` (the env-echoing Node server),
  - `Dockerfile` (reads the Build-scoped `--build-arg`),
  - `.env.production`, `.env.preview` (dotenv files for `env sync`),
  - `README.md`.
- Links added to `docs/user/README.md` and `docs/user/reference.md`.

**Surfaces consumed (do not redefine; use exactly as the sibling plans deliver them):**

- From EP-23 (`docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md`): the scoped env
  model in `Nagare.Dsl.Types` — `EnvScope = Runtime | Build | Preview`,
  `ScopedEnvVar { value, scopes }`, `runtimeScoped :: EnvVar -> ScopedEnvVar`,
  `scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar`; the managed-store names
  `nagare-env-<app>-<scope>` / `nagare-secret-<app>-<scope>`; the `envFrom optional:true` wiring
  and the `envFrom`-then-inline-`env` precedence.

- From EP-25 (`docs/plans/25-nagarectl-env-and-secret-cli-commands.md`): the `nagarectl env`
  (`list`/`set`/`delete`/`sync`) and `nagarectl secret` (`set`/`list`/`delete`) commands, with
  `-f/--config` for the typed config, `--file` for the dotenv path on `sync`, scope flags
  defaulting to `runtime`, `--merge`/`--reconcile-exact`, stdin-only `secret set`, names-only
  `secret list`, and `--dry-run` manifest printing. **Hard dependency** — required to run the
  walkthrough.

- From EP-26 (`docs/plans/26-generated-and-predefined-environment-variables.md`): the generated
  variable table `NAGARE_SERVICE_URL`, `NAGARE_SERVICE_NAME`, `NAGARE_NAMESPACE`,
  `NAGARE_BASE_DOMAIN`, `NAGARE_RELEASE_ID`, and `NAGARE_SOURCE` (the last only with `--source`, on
  the `site deploy` path), and the reserved-`NAGARE_`-prefix rule. **Soft dependency** — the table
  is documented regardless; the example shows these vars once EP-26's injection is wired.

- From EP-27 (`docs/plans/27-build-time-and-preview-scoped-env-application.md`): build-scoped env
  reaching `docker build` as `--build-arg` (with the `docker history` security caveat) and
  preview-scoped env overlaying runtime in previews (runtime `envFrom`, then preview `envFrom`).
  **Hard dependency** — required for the build-arg and preview legs of the walkthrough.

The example's `nagare/Config.hs` depends on the `nagare-dsl` library (built with Cabal/GHC 9.12
via the Nix flake), exactly as the existing `cluster/examples/*/nagare/Config.hs` files do, and is
loaded/rendered by `nagarectl` from `cli/nagarectl`. Live `kubectl`/`pulumi` calls target GCP
project `tan-nb-exp`, region `us-west1` per `CLAUDE.md`.
