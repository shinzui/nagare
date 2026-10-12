---
id: 26
slug: generated-and-predefined-environment-variables
title: "Generated and predefined environment variables"
kind: exec-plan
created_at: 2026-06-09T23:52:37Z
intention: "intention_01ktqcj5aseb1rx94fh6npnydv"
master_plan: "docs/masterplans/5-environment-and-secret-management-for-nagare.md"
---

# Generated and predefined environment variables

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [26-generated-and-predefined-environment-variables.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/26-generated-and-predefined-environment-variables.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this change, every app and server site that Nagare deploys automatically receives a
small, documented set of environment variables that describe the deployment's own identity:
its public URL, its service name, its Kubernetes namespace, the apps base domain, the
release id (the image tag), and — when the deploy was triggered from a git source — the
source branch or commit. The names all start with the prefix `NAGARE_` (for example
`NAGARE_SERVICE_URL`). An application can read these at runtime to self-configure instead of
hard-coding values that only the deploy step knows. A Node server that needs to build a link
back to itself can read `process.env.NAGARE_SERVICE_URL`; a script that wants to tag logs
with the running release can read `process.env.NAGARE_RELEASE_ID`. None of this is possible
today: the running container has no idea what URL it answers on or what release it is.

You can see it working by running a deploy in dry-run mode and reading the rendered Knative
`Service` manifest. A **Knative `Service`** is the single YAML resource Nagare applies for an
app; its container spec carries an inline `env:` list (variables written directly into the
manifest) and an `envFrom:` block (variables pulled from external Kubernetes ConfigMaps and
Secrets). Before this change, the inline `env:` shows only what the config author wrote.
After this change, the same `env:` additionally contains the generated `NAGARE_*` variables.

Concretely, deploying a server site named `notes` into namespace `personal` with base domain
`apps.example.com`, image tag `20260602-120000`, and `--source main` renders this difference
in the container's inline `env:` (the user wrote only `API_BASE`):

```diff
         env:
         - name: API_BASE
           value: https://api.example.com
+        - name: NAGARE_BASE_DOMAIN
+          value: apps.example.com
+        - name: NAGARE_NAMESPACE
+          value: personal
+        - name: NAGARE_RELEASE_ID
+          value: "20260602-120000"
+        - name: NAGARE_SERVICE_NAME
+          value: notes
+        - name: NAGARE_SERVICE_URL
+          value: https://notes.personal.apps.example.com
+        - name: NAGARE_SOURCE
+          value: main
         envFrom:
         - configMapRef:
             name: nagare-env-notes-runtime
             optional: true
         - secretRef:
             name: nagare-secret-notes-runtime
             optional: true
```

The generated variables are injected as **inline `env:` entries scoped `{Runtime}`** at
deploy time. This matters for two reasons that this plan relies on. First, the env entries in
a Knative container are sorted by variable name when rendered (the renderer uses
`Data.Map.toAscList`), which is why `NAGARE_*` appears after `API_BASE` and the `NAGARE_*`
entries are themselves alphabetical above. Second, **Kubernetes applies `envFrom` first and
the inline `env:` list second, so an inline variable overrides a managed one of the same
name** (this is the precedence the dependency plan EP-23 establishes; see "Context and
Orientation"). Because the generated variables are inline, they are authoritative: they win
over anything in the managed ConfigMap/Secret store, and — by deliberate design in this plan
— they also win over a user-declared variable of the same `NAGARE_*` name. The `NAGARE_`
prefix is therefore **reserved**: a config author who writes `NAGARE_SERVICE_URL` themselves
will see it silently replaced by the generated value.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Created `cli/nagarectl/src/Nagare/Env/Generated.hs` with `GeneratedContext`,
      `generatedEnv`, and `mergeGenerated`; added it to `nagarectl.cabal`
      `exposed-modules` (not `other-modules` — the test suite imports it). (2026-06-09)
- [x] M1: `containers` already present in the `nagarectl` library stanza (no change
      needed). (2026-06-09)
- [x] M1: Added a pure unit-test group `Nagare.Env.Generated` to
      `cli/nagarectl/test/Spec.hs` (6 cases): the six keys + alphabetical order,
      `NAGARE_SOURCE` only when `source` is `Just`, every value an `EnvLiteral` scoped
      `{Runtime}`, and `mergeGenerated` left-biased (generated overrides user; unrelated
      user vars kept). (2026-06-09)
- [x] M1: `cabal build && cabal test` green. (2026-06-09)
- [x] M2: Wired `generatedEnv`/`mergeGenerated` into `runDeploy` (prebuilt-image path),
      merging into `dep`'s `env` to form `dep'` before `renderService`. (2026-06-09)
- [x] M2: Wired into `deployServer`: merge generated env into the `ServerSite`'s `env`
      before building `ServerDeployInputs`; `serverUrl site0 bd` is reused so the
      generated `NAGARE_SERVICE_URL` matches the rendered Service URL, and `--source`
      flows into `NAGARE_SOURCE`. (2026-06-09)
- [x] M2: Documented (code comment on `deployStatic` + Decision Log) that the **static**
      deploy path is skipped — `StaticSite` has no `env`. (2026-06-09)
- [x] M2: Added a render-level demonstration group `EP-26 render demonstration`
      (2 HUnit cases) proving a rendered Service's inline `env:` contains the
      `NAGARE_*` vars and the preserved user var, and that `NAGARE_SOURCE` is absent
      without a source. (2026-06-09)
- [x] M2: `cabal test` green (81 tests); `--dry-run` deploy shows the injected
      `NAGARE_*` block on both the app path (no `NAGARE_SOURCE`) and the server path
      (`NAGARE_SOURCE=main` with `--source main`). (2026-06-09)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `GeneratedContext`'s field names (`namespace`, `releaseId`, `source`, `serviceUrl`,
  `baseDomain`) collide, under `DuplicateRecordFields`, with existing bare selectors and
  a top-level function in the consuming modules: in `Spec.hs` the static-release tests
  use `releaseId`/`source` as bare selectors, and in `Main.hs` `Nagare.Deploy.serviceUrl`
  is a function. Importing `GeneratedContext (..)` made those ambiguous (GHC-87543). Fix:
  import the type/functions plainly but construct the record through a qualified alias
  (`import Nagare.Env.Generated qualified as Gen`; `Gen.GeneratedContext { Gen.serviceUrl
  = ... }`), so the field labels never enter the bare namespace. EP-28 (and any other
  consumer) should construct `GeneratedContext` the same qualified way.

- A record *update* on `env` (`dep { env = ... }` / `site { env = ... }`) is ambiguous
  because both `Deployment` and `ServerSite` have an `env` field. In `Main.hs` the
  generic-lens form `dep & #env %~ f` sidesteps it; in `Spec.hs` (no generic-lens) the
  demo Deployment is built by a constructor function `mkDemoDep envMap` (record
  *construction* names the type and is unambiguous) instead of a record update.

## Decision Log

Record every decision made while working on the plan.

- Decision: Inject generated variables as **inline `{Runtime}` env merged into the app's env
  map at the deploy call site**, via a pure function `generatedEnv :: GeneratedContext ->
  Map EnvName ScopedEnvVar`, rather than changing the `nagare-dsl` renderer's signature
  (`renderService :: Deployment -> Text -> ByteString`).
  Rationale: keeps the renderer a pure function of the typed model and leaves EP-23's
  contract untouched; the CLI is the only place that knows the resolved URL, the release id,
  and the `--source` provenance, so it is the natural place to assemble them. Inline env also
  gives the generated values overriding precedence over the managed `envFrom` store (EP-23
  IP3: inline `env` wins), which is exactly what we want for self-describing identity vars.
  Date: 2026-06-09

- Decision: Reserve the `NAGARE_` name prefix and make `mergeGenerated` **left-biased toward
  the generated map** so a generated variable overrides any user-declared variable of the
  same name.
  Rationale: the generated values are the ground truth about the deployment's identity; a
  user override would be either redundant or wrong. A single, predictable rule ("generated
  wins; `NAGARE_*` is reserved") is easier to document (EP-28 will cite it) than a
  per-variable policy. The reserved prefix is documented in the variable table below.
  Date: 2026-06-09

- Decision: **Skip the static-site deploy path.** Static sites (`Nagare.Dsl.Static.Types`)
  have no `env` field and serve a folder of files through Nginx; there is no application
  process to read environment variables.
  Rationale: there is no place to inject runtime env, and EP-23 IP3 already states static
  sites carry no env and emit no `envFrom`. Injecting generated vars there would be
  meaningless. The static deploy functions in `cli/nagarectl/app/Main.hs` are therefore left
  unchanged, with a comment recording why.
  Date: 2026-06-09

- Decision: Emit `NAGARE_SOURCE` **only when `source` is `Just`**; omit it entirely when the
  deploy carried no provenance (the prebuilt-image `nagarectl deploy` path has no `--source`
  flag, so it always omits it).
  Rationale: an empty `NAGARE_SOURCE=""` is more confusing than an absent one; "the variable
  is not set" is the honest signal that this deploy had no recorded source.
  Date: 2026-06-09

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-09): complete, both milestones.** `Nagare.Env.Generated` produces
the reserved `NAGARE_*` identity variables as inline `{Runtime}` `EnvLiteral`s and
`mergeGenerated` (a left-biased `Map.union`) makes them authoritative over user and
managed env. Both deploy paths that have an `env` field inject them: `runDeploy`
(prebuilt-image, `source=Nothing`) and `deployServer` (server, `--source` →
`NAGARE_SOURCE`). The static path is intentionally untouched.

**Against the purpose:** verified end-to-end via `--dry-run`:
- App: the hello deploy renders inline `env:` with `NAGARE_BASE_DOMAIN`,
  `NAGARE_NAMESPACE`, `NAGARE_RELEASE_ID`, `NAGARE_SERVICE_NAME`, `NAGARE_SERVICE_URL`
  (alphabetical, before `envFrom`), the user's `TARGET` preserved, and no
  `NAGARE_SOURCE`.
- Server: the server fixture with `--source main` additionally renders
  `NAGARE_SOURCE: main`, with user vars `API_BASE`/`HOSTNAME` preserved.
The reserved-prefix override and the `NAGARE_SOURCE`-only-when-`Just` rules are proven
by unit tests; 81 tests pass.

**Notes / lessons:** see Surprises & Discoveries for the two
`DuplicateRecordFields` ambiguities (field-name collisions and `env` record-update) and
their fixes — qualified `GeneratedContext` construction and a constructor function for
the demo Deployment. `NAGARE_SERVICE_URL` correctly honors a config's custom domain
(e.g. `https://hello.example.com`) because it is computed from `serviceUrl`/`serverUrl`,
which prefer the custom domain over the wildcard.

