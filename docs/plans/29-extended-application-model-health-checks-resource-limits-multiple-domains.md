---
id: 29
slug: extended-application-model-health-checks-resource-limits-multiple-domains
title: "Extended application model: health checks, resource limits, multiple domains"
kind: exec-plan
created_at: 2026-06-10T00:33:39Z
intention: "intention_01ktqexbzyeb2bfka9q38w3gmx"
master_plan: "docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md"
---

# Extended application model: health checks, resource limits, multiple domains

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the first child of the MasterPlan at
`docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md`. It is self-contained: you do
not need to read the MasterPlan or any sibling plan to implement it. Where it defines an artifact
that a sibling plan consumes, that is noted, but nothing here depends on a sibling.

Full plan before trimming: [29-extended-application-model-health-checks-resource-limits-multiple-domains.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/29-extended-application-model-health-checks-resource-limits-multiple-domains.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today a Nagare application is described by a single Haskell record, `Deployment`, defined in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`. An app author writes a `nagare/Config.hs` that constructs a
`Deployment` (usually via the `webService` preset in `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs`) and
emits it as JSON; `nagarectl deploy` loads that JSON, renders a Knative `Service` (and at most one
`DomainMapping`), applies them, and waits for readiness. That model is thinner than a real PaaS
application in three ways that this plan fixes:

1. **No health checks.** Knative can run an HTTP *readiness probe* (don't send traffic to a pod until
   it answers), a *liveness probe* (restart a pod that stops answering), and a *startup probe* (give a
   slow-booting pod extra grace before the other probes apply). Nagare cannot express any of these, so
   every app uses Knative's default TCP readiness check only.

2. **Resource requests but not limits.** A Kubernetes container can declare *requests* (the CPU/memory
   it is guaranteed and scheduled against) and *limits* (the ceiling it may not exceed). Nagare's
   `Resources` type today carries only requests; the renderer emits `resources.requests` and never
   `resources.limits`. An app cannot cap its memory.

3. **At most one custom domain.** `Deployment` has `domain :: Maybe Domain`, so an app can have one
   custom hostname or none. Real apps often serve several (`app.example.com`, `www.example.com`,
   `example.com`), and one of them is "canonical" — the address you advertise and redirect toward.

After this plan, an app author can write — entirely in the typed config, with illegal states rejected
at construction — an optional HTTP health check, both resource requests and limits, and a list of
domains with exactly one marked canonical. The renderer turns these into Knative `readinessProbe`/
`livenessProbe`/`startupProbe` blocks, a `resources.limits` block, and one `DomainMapping` per domain;
and it stamps every Service with a label `nagare.dev/managed-by: nagarectl` so other Nagare commands
can recognize Nagare-managed apps. **Crucially, every existing config keeps working unchanged**: a
config that mentions none of the new fields renders byte-for-byte as it does today, because health
checks default to absent, limits default to absent, and the domain list defaults to empty.

You can see it working by running the package's golden tests (`cabal test` in `cli/nagare-dsl`), which
compare the rendered YAML against committed fixture files, and by a `nagarectl deploy --dry-run` that
now prints probe and `limits` blocks and multiple DomainMapping documents for a config that declares
them.

## Progress

- [x] M1: `HealthCheck` type + `Resources` limits added with smart constructors and unit tests. (2026-06-10)
- [x] M2: `domain → domains :: [DomainSpec]` with `mkDomains` canonical-enforcing constructor; presets/fixtures/examples updated to compile. (2026-06-10)
- [x] M3: JSON emission (`Config.hs`) and decoding (`Load.hs`) round-trip the new fields; round-trip test passes. (2026-06-10)
- [x] M4: Renderer emits probes, `resources.limits`, per-domain DomainMappings, and the managed-by label; `serviceUrl` and deploy call sites updated; golden fixtures regenerated; `cabal test` green in both packages. (2026-06-10)

## Surprises & Discoveries

- EP-23 (scoped env, a child of MasterPlan 5) had already landed before this plan
  started, contrary to MasterPlan 6's IP5 expectation that EP-29 would land first. The
  `Deployment.env` field is therefore already `Map EnvName ScopedEnvVar` (not
  `Map EnvName EnvVar` as this plan's Context section assumed), and `Resources` literals
  now also live in the env-scope-aware codebase. The changes were fully orthogonal as IP5
  predicted: health/limits/domains touched different fields, and EP-29 rebased onto the
  pluralized env model with no conflict. Evidence: `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`
  already defined `ScopedEnvVar`, `runtimeScoped`, `scopedEnv`, and the recent commits
  baf4c92–1469785 are EP-25..EP-28 (MasterPlan 5). (2026-06-10)

- The `nagare.dev/managed-by: nagarectl` label is rendered on **every** Service
  unconditionally, so all four existing Deployment service goldens (`hello`, `build-only`,
  `preset-app-a`, `preset-app-b`) changed — each gained exactly the two-line `labels:` block
  and nothing else (verified by `git diff`). The plan's "existing goldens unchanged" invariant
  holds for the probe/limits/domain blocks (a config declaring none of those renders no probe
  or limits YAML — proven by a dedicated test) but **not** for the label, which is a deliberate
  universal addition. The server-site and static-site service goldens are rendered by separate
  renderers (`Nagare.Dsl.Server.Render`, `Nagare.Dsl.Static.Render`) that this plan did not
  touch, so they did not get the label and stayed byte-for-byte identical. (2026-06-10)

- `Resources` is shared by `ServerSite` as well as `Deployment`, and `Nagare.Dsl.Server.Render`
  has its **own** `resourcesField` that reads only `cpu`/`memory`. Adding `cpuLimit`/`memoryLimit`
  (defaulting to `Nothing`) to `Resources` therefore required updating every `Resources {…}`
  literal across the workspace (presets, both loaders, three fixtures, two test specs) but did
  **not** change server-site rendering output. (2026-06-10)

## Decision Log

- Decision: Model the three Knative probes with a single `HealthCheck` value that describes one HTTP
  GET check, and apply it as the readiness probe always, and as the liveness and startup probes when
  the author opts in via booleans on the record.
  Rationale: A single HTTP endpoint (e.g. `/healthz`) is almost always the same for readiness,
  liveness, and startup; one shared description with opt-in flags avoids three near-identical records
  while still letting the renderer emit all three Knative probe keys. Keeps the common case (just a
  readiness check) a one-liner.
  Date: 2026-06-10

- Decision: Represent domains as `domains :: [DomainSpec]` where `DomainSpec = DomainSpec { domain ::
  Domain, canonical :: Bool }`, constructed through `mkDomains :: [(Text, Bool)] -> Either Text
  [DomainSpec]` which rejects a list with zero or more-than-one canonical entries (an empty list is
  allowed and means "no custom domain").
  Rationale: Mirrors the existing `ServerSite.domains :: [Domain]` while adding the canonical marker
  the roadmap asks for, and makes "two canonical domains" or "a non-empty list with no canonical"
  unrepresentable after construction. The wildcard Knative URL is still used when the list is empty.
  Date: 2026-06-10

- Decision: Carry limits inside the existing `Resources` record by adding `cpuLimit`/`memoryLimit`
  fields, rather than introducing a separate `limits :: Maybe Resources` field on `Deployment`.
  Rationale: Keeps all resource quantities in one place, keeps the `Deployment` record changes
  minimal, and lets the renderer emit `requests` and `limits` from one source. The existing
  `cpu`/`memory` fields become the requests; the new fields are the optional limits.
  Date: 2026-06-10

- Decision: Render the `nagare.dev/managed-by: nagarectl` label unconditionally on every
  Deployment Service and accept the resulting change to the four existing service goldens, after
  confirming via `git diff` that the *only* change to each is the added two-line `labels:` block.
  Rationale: `app list` (EP-30) needs every Nagare-managed app to carry the label; a conditional
  label would defeat its purpose. The regenerated goldens are a reviewed, understood change — not
  a blind `--accept` — and a separate test asserts a label-free probe/limits surface for configs
  that declare none of the new fields, preserving the real backward-compat guarantee.
  Date: 2026-06-10

- Decision: Add committed `rich.service.yaml` / `rich.domainmapping.yaml` golden fixtures rendered
  from a single `richDep` (liveness+startup health check, both requests and limits, two domains
  with one canonical) instead of (or in addition to) relying on a manual `--dry-run` transcript.
  Rationale: A committed golden is a reviewable, regression-proof artifact that exercises the exact
  same `renderService`/`renderDomainMappings` code path the dry-run prints, so it subsumes the
  manual check and proves Validation point 3 in CI.
  Date: 2026-06-10

- Decision: Decode `JsonDomainSpec.canonical` with a `.!= False` default and `JsonHealthCheck`
  fields with `.!=` defaults mirroring `httpHealthCheck`, and report a non-empty domain list with
  no/too-many canonical entries as `MarshalError "domains"` (re-running `mkDomains` on decode).
  Rationale: Keeps the loader's defence-in-depth contract — every field is re-validated through the
  same smart constructor the in-process model uses — while letting partial/hand-written JSON decode
  to documented defaults rather than failing with an opaque aeson parse error.
  Date: 2026-06-10

## Outcomes & Retrospective

Completed 2026-06-10. All four milestones landed; both `cli/nagare-dsl` (165 tests) and
`cli/nagarectl` (89 tests) build and test green.

What exists now that did not before:

- `HealthCheck`/`HealthScheme` types with `mkHealthCheck` (validates an assembled record) and
  `httpHealthCheck` (path → defaulted check) in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`.
- `Resources` carries optional `cpuLimit`/`memoryLimit` alongside the existing `cpu`/`memory`
  requests.
- `Deployment.domain :: Maybe Domain` is now `domains :: [DomainSpec]` with `mkDomains`
  (enforces exactly one canonical in a non-empty list) and `canonicalDomain`. `healthCheck ::
  Maybe HealthCheck` added.
- The renderer (`Nagare.Dsl.Render`) emits `readinessProbe` (always when a check is present) plus
  `livenessProbe`/`startupProbe` (opt-in), a `resources.limits` block, one `DomainMapping` per
  domain via `renderDomainMappings`, and the `nagare.dev/managed-by: nagarectl` label on every
  Service. `Nagare.Deploy.serviceUrl` reports the canonical domain.
- JSON emit (`Config.hs`) and decode (`Load.hs`) round-trip all new fields; backward-compatible
  defaults mean old JSON (no `domains`/`healthCheck`/limits keys) still decodes.

Verification artifacts: the `rich.service.yaml` / `rich.domainmapping.yaml` goldens show the full
new surface; the `extendedModelTests` group asserts the round-trip, label, probes, limits, and the
label-free/probe-free rendering for a bare config; `mkHealthCheck`/`mkDomains` validation cases
cover the rejection paths.

Note for the EP-30 implementer: the integration contract label string is exactly
`nagare.dev/managed-by: nagarectl` (see `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`
`serviceValue`). The hard HTTP redirect between non-canonical and canonical domains remains
deferred as stated in the MasterPlan scope — a `DomainMapping` is rendered for every domain and
the canonical one drives `serviceUrl`, but no redirect rule is installed.

