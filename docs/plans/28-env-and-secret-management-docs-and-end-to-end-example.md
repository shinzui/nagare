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

Full plan before trimming: [28-env-and-secret-management-docs-and-end-to-end-example.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/28-env-and-secret-management-docs-and-end-to-end-example.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

