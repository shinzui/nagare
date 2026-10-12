---
id: 6
slug: application-lifecycle-and-cli-for-nagare
title: "Application Lifecycle and CLI for Nagare"
kind: master-plan
created_at: 2026-06-10T00:33:29Z
intention: "intention_01ktqexbzyeb2bfka9q38w3gmx"
---

# Application Lifecycle and CLI for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This initiative implements **Phase 1 (Application Model and CLI Lifecycle)** of the PaaS
capability roadmap at `docs/roadmaps/paas-gap-roadmap.md`, specifically the two roadmap gap-matrix
rows "App lifecycle commands" and "Deployment history/logs", together with the Phase 1 application-model
extensions (health checks, resource limits, multiple domains). The remaining Phase 1 deliverable —
typed build modes — already shipped as its own initiative
(`docs/masterplans/4-application-build-modes-for-nagare.md`), so it is out of scope here. Environment
and secret management is Phase 2 and lives in `docs/masterplans/5-environment-and-secret-management-for-nagare.md`.

Full plan before trimming: [6-application-lifecycle-and-cli-for-nagare.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Vision & Scope

Today Nagare can *create* an application but it cannot *operate* one. A developer writes a typed
`nagare/Config.hs` that produces a `Deployment` value (the record defined in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), runs `nagarectl deploy`, and the CLI builds, pushes,
applies a Knative Service, waits for it to become Ready, and prints a URL. After that single command
there is nothing more the CLI can do: there is no way to list the apps that exist, inspect one,
tail its logs, restart it, take it offline, or remove it. Every day-2 action requires raw `kubectl`.
There is also no record of what was deployed when: unlike static sites — which already keep a
release history in a per-site Kubernetes ConfigMap via `cli/nagarectl/src/Nagare/Static/Release.hs`
and expose `nagarectl site releases` / `site rollback` — an app deploy leaves no Nagare-level trace.
Finally, the `Deployment` model is thinner than a general PaaS application: it has no health checks,
it can express resource *requests* but not *limits*, and it allows only a single optional custom
domain (`domain :: Maybe Domain`) rather than several.

After this initiative, an operator can manage an application's whole lifecycle from `nagarectl`,
without `kubectl`, and the typed model is rich enough to describe a real service:

- **Lifecycle commands.** `nagarectl app list` shows the Nagare-managed apps in a namespace with
  their URL and readiness; `nagarectl app get NAME` describes one (image, revision, URL, ready
  state, and — when present — its configured health check, domains, and resource limits);
  `nagarectl app logs NAME [--follow]` tails the running container's logs; `nagarectl app restart NAME`
  rolls a fresh revision; `nagarectl app stop NAME` takes the app offline; `nagarectl app delete NAME`
  removes the Service, its DomainMappings, and its deployment history.
- **Deployment history.** Every successful `nagarectl deploy` records a deployment in a per-app
  ConfigMap, exactly mirroring the static-site release log. `nagarectl deployments list NAME` shows
  the history (newest first, the live one marked), and `nagarectl deployments logs NAME [DEPLOYMENT_ID]`
  shows the logs for the live deployment or a specific past one (mapped to its Knative revision).
- **A richer typed model.** The `Deployment` record gains an optional typed `HealthCheck` (an HTTP
  readiness/liveness/startup probe with path, port, scheme, expected status, and timing), resource
  *limits* alongside the existing *requests*, and a list of domains (`domains :: [Domain]`, mirroring
  how `ServerSite` in `cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs` already models multiple domains)
  with one marked canonical for URL reporting. The renderer turns these into Knative `readinessProbe`/
  `livenessProbe`/`startupProbe`, `resources.limits`, and one `DomainMapping` per domain, and stamps
  every Service with a `nagare.dev/managed-by: nagarectl` label so `app list` can find Nagare apps.

What is **in scope**: the `Deployment` model extensions (health check, limits, multiple domains, the
managed-by label) and their renderer/JSON round-trip; the `app list/get/logs/restart/stop/delete`
command surface; per-app deployment-history recording and the `deployments list/logs` commands; and
user documentation with a runnable example. Throughout, the existing `webService` preset and every
existing config keep working unchanged — the new fields default to "absent / single behavior" so a
config that does not mention them renders exactly as it does today.

What is **out of scope** (covered elsewhere or deferred): typed build modes
(`docs/masterplans/4-application-build-modes-for-nagare.md`, already shipped); environment and secret
management including env scopes and `.env` sync (`docs/masterplans/5-environment-and-secret-management-for-nagare.md`,
Phase 2); dynamic-app preview deployments (roadmap Phase 7); a control API or `nagared` mutation
endpoints (roadmap Phase 8) — these commands stay CLI-first with direct `kubectl` shell-outs through
the existing `cradle` library; and any multi-cluster or context model. Hard HTTP redirect enforcement
between non-canonical and canonical domains is explicitly deferred: this initiative renders a
DomainMapping for every domain and records which is canonical for URL display, but does not install a
redirect; that is noted as future work in EP-29.

## Decomposition Strategy

The initiative splits into four child ExecPlans along the same functional seams the codebase already
uses for the static-hosting and build-modes initiatives: the typed *model and renderer* are one
concern (pure `cli/nagare-dsl` library work, verified with golden and round-trip tests), the *CLI
command surfaces* are separate concerns (each a thin parser over `kubectl` shell-outs in
`cli/nagarectl`, verified by running the commands and by unit-testing the pure helpers), and
*documentation* is its own final concern that describes behavior already proven to work. This mirrors
how `docs/masterplans/4-application-build-modes-for-nagare.md` separated EP-19 (model) from EP-20
(execution) from EP-22 (docs), and how `docs/masterplans/3-static-hosting-for-nagare.md` finished with
a dedicated docs-and-examples plan.

The four streams are:

- **EP-29 — Extended application model.** The `HealthCheck` type, resource limits, the
  `domain → domains` change with a canonical marker, the `nagare.dev/managed-by` label, the JSON
  round-trip, the renderer changes, and the preset/fixture updates. This is the foundation: it is the
  only plan that edits the DSL, and it owns the shape of `Deployment` that the CLI plans read.

- **EP-30 — App lifecycle CLI.** The `nagarectl app list/get/logs/restart/stop/delete` commands and a
  new `Nagare.App` module that holds the shared `kubectl` plumbing (list/describe/logs/restart/stop/delete
  operations) and the app-identity loader (load a `Deployment` from a config and return its name and
  namespace, mirroring the existing `siteIdentityOrDie` helper in `cli/nagarectl/app/Main.hs`).

- **EP-31 — Deployment history and `deployments` commands.** Recording a deployment on every
  successful `nagarectl deploy`, the `deployments list NAME` and `deployments logs NAME [DEPLOYMENT_ID]`
  commands, and the per-app history ConfigMap (generalized from `Nagare.Static.Release`).

- **EP-32 — Docs and end-to-end examples.** A user guide for the lifecycle commands and the new model
  fields, config-reference updates, and a runnable example exercised end-to-end.

The decomposition was guided by three principles from the MasterPlan specification. *Group by
functional concern, not by file*: EP-29 deliberately touches `Types.hs`, `Config.hs`, `Load.hs`,
`Render.hs`, `Presets.hs`, and `Deploy.hs` together because they form one coherent
model-and-round-trip, exactly as EP-19 and EP-23 do for their model changes. *Maximize independent
verifiability*: EP-29 is verified entirely by `cabal test` in `cli/nagare-dsl` with no cluster; EP-30
and EP-31 are each verified by running their commands against a cluster (or a `--dry-run`/unit path)
and are demonstrable on their own; EP-32 documents what already works. *Minimize cross-plan coupling*:
the two CLI plans share exactly two artifacts — the `Nagare.App` kubectl/identity helpers and the
`cli/nagarectl/app/Main.hs` command parser — and those are called out as Integration Points with a
single owning plan each, so neither plan re-derives the other's helpers.

Alternatives considered and rejected. **Folding the lifecycle CLI (EP-30) and deployment history
(EP-31) into one CLI plan**: rejected because they are two distinct, separately demonstrable
capabilities (the roadmap lists them as two separate High-priority gap rows), they touch different
storage (live Knative state vs. a history ConfigMap), and a combined plan would add eight commands
plus a storage module in one plan, exceeding the "five milestones / ten files" threshold the
MasterPlan specification uses to recommend splitting. They remain cleanly separable: every `app`
verb works with no history store, and the `deployments` commands work without the `app` verbs. **Splitting
EP-29's model from its renderer into two plans** (as the roadmap's "typed app model, renderer
changes" phrasing might suggest): rejected because model and renderer are a single round-trip — a
`HealthCheck` type with no probe rendering is not independently verifiable, and the golden tests that
verify the model *are* renderer tests. The proven precedent (EP-19, EP-23) keeps model and renderer
in one plan. **Including build modes or env scopes here**: rejected because both already have their
own MasterPlans (4 and 5); this plan implements only the Phase 1 remainder.

## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 29 | Extended application model: health checks, resource limits, multiple domains | docs/plans/29-extended-application-model-health-checks-resource-limits-multiple-domains.md | None | None | Complete |
| 30 | nagarectl app lifecycle commands | docs/plans/30-nagarectl-app-lifecycle-commands.md | None | EP-29 | Complete |
| 31 | Application deployment history and deployments commands | docs/plans/31-application-deployment-history-and-deployments-commands.md | None | EP-30 | Complete |
| 32 | Application lifecycle docs and end-to-end examples | docs/plans/32-application-lifecycle-docs-and-end-to-end-examples.md | EP-30, EP-31 | EP-29 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-29). The numbers continue the
repository's sequential plan numbering; the most recent existing plan is EP-28 (a child of MasterPlan 5).

## Progress

Track milestone-level progress across all child plans. Each entry names the child plan and milestone.

- [x] EP-29: `HealthCheck` type and `Resources` limits added to the model; smart constructors with tests. (2026-06-10)
- [x] EP-29: `domain → domains :: [DomainSpec]` with canonical marker; preset/fixtures/examples updated. (2026-06-10)
- [x] EP-29: JSON round-trip (Config emit / Load decode) carries the new fields; golden + round-trip tests pass. (2026-06-10)
- [x] EP-29: Renderer emits probes, `resources.limits`, per-domain DomainMappings, and the managed-by label; `serviceUrl` uses canonical domain; deploy call sites updated; `cabal test` green in `cli/nagare-dsl`. (2026-06-10)
- [x] EP-30: `Nagare.App` module with `appIdentityOrDie` and `streamServiceLogs`; unit tests for pure helpers. (2026-06-10)
- [x] EP-30: `app list` and `app get` implemented (label-filtered list, formatted get with EP-29 enrichment); `--help` verified. **Live run VERIFIED 2026-06-10** against `nagare-01`: `app list` filters to nagarectl-managed apps (hides the unmanaged `hello`), `--all` shows every ksvc, `app get` prints the enriched detail (revision, image, canonical URL). (2026-06-10)
- [x] EP-30: `app logs [--follow]`, `app restart`, `app stop`, `app delete` implemented; `nagarectl-test` green (102). **Live VERIFIED 2026-06-10** against `nagare-01`: `app logs` streamed the running pod's request log; `app restart` patched + reached `condition met`; `app stop` flipped the URL to `svc.cluster.local` and public curl returned **404**; `app delete` removed the Service, DomainMappings, and the `nagare-app-deployments-*` history ConfigMap (confirmed absent after). (2026-06-10)
- [x] EP-31: `recordDeploymentFor` wired into `runDeploy` (non-fatal); per-app history ConfigMap `nagare-app-deployments-<app>`; `--source` added. (2026-06-10)
- [x] EP-31: `deployments list NAME` prints the history table; `deployments logs NAME [ID]` streams revision logs (id→revision via `resolveRevisionForTag`). **Live VERIFIED 2026-06-10**: two real deploys produced a 2-row history table with the active release `*`-marked and the `--source` provenance (`demo-v2`) recorded. (2026-06-10)
- [x] EP-31: pure-layer unit tests (store name, `revisionForTag`) green; static-release tests unchanged. (2026-06-10)
- [x] EP-32: `docs/user/app-lifecycle.md` written and linked from `deploying-apps.md`/`README.md`; `config-reference.md` updated for health check, limits, multiple domains; stale `deploying-apps.md` config/YAML corrected. (2026-06-09)
- [x] EP-32: runnable example `cluster/examples/app-lifecycle-demo/` verified by `nagarectl deploy --dry-run` (probes, limits, two DomainMappings, managed-by label, canonical URL); live walk-through captured in the example README. **End-to-end run VERIFIED 2026-06-10**: with `nagare-01` up, a real `nagarectl deploy` served HTTP 200 and the full `app`/`deployments` verb set was exercised live (see EP-30/EP-31 entries above). (2026-06-09; live 2026-06-10)

## Surprises & Discoveries

- **IP5 resolved in the opposite order than expected.** EP-23 (env scopes, MasterPlan 5's child)
  had already landed before EP-29 started, so `Deployment.env` is already
  `Map EnvName ScopedEnvVar` and EP-29 rebased onto it rather than the other way around. The two
  changes were fully orthogonal as IP5 predicted — no semantic conflict — but the EP-23-first
  ordering means EP-29's Context section (which described `env :: Map EnvName EnvVar`) was already
  stale on arrival. No action needed for downstream plans; recorded so the history is clear.
  (EP-29, 2026-06-10)

- **The `nagare.dev/managed-by: nagarectl` label is rendered unconditionally on every Deployment
  Service** (IP1). This changed all four existing Deployment service goldens — each gained exactly
  the `labels:` block and nothing else. **EP-30's `app list` must match this exact string**; it is
  now committed in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` (`serviceValue`) and proved by the
  `rich.service.yaml` golden and a dedicated `renderService emits the managed-by label` test.
  Server-site and static-site Services are rendered by separate renderers and do **not** carry the
  label, so `app list` filtering by it will correctly exclude them. (EP-29, 2026-06-10)

- **`Nagare.Dsl.Render.renderDomainMapping :: Deployment -> Maybe ByteString` is now
  `renderDomainMappings :: Deployment -> [ByteString]`** (IP1). Any sibling plan that renders a
  Deployment's DomainMappings must use the plural list form; `cli/nagarectl/app/Main.hs`'s
  `runDeploy` already does. (EP-29, 2026-06-10)

- **IP2 is live: `Nagare.App` now exists** (`cli/nagarectl/src/Nagare/App.hs`) with the exact
  signatures the Integration Points section names — `appIdentityOrDie :: FilePath -> IO (Text, Text)`
  (Deployment-only) and `streamServiceLogs :: LogTarget -> IO ()` (with `data LogTarget = LogTarget {
  ltNamespace, ltService, ltRevision :: Maybe Text, ltFollow :: Bool, ltTail :: Maybe Int }`). **EP-31
  consumes these as-is** — pass a `Just <revision>` `ltRevision` for `deployments logs`. EP-31 must
  *not* re-derive them. (EP-30, 2026-06-10)

- **A pre-existing `appIdentityOrDie` in `app/Main.hs` (added by EP-25, site-aware) was renamed to
  `configIdentityOrDie`** so the IP2 Deployment-only `Nagare.App.appIdentityOrDie` could own the name.
  Nothing outside `app/Main.hs`'s env/secret handlers used the old one. EP-31 should use
  `Nagare.App.appIdentityOrDie`. (EP-30, 2026-06-10)

- **`deleteApp` (EP-30) already removes the history ConfigMap named `nagare-app-deployments-<app>`**
  with `--ignore-not-found` (IP3). EP-31 must use exactly that ConfigMap name so the two agree; the
  name is now committed in `cli/nagarectl/src/Nagare/App.hs`. (EP-30, 2026-06-10)

- **IP3 resolved by generalizing, not copying.** EP-31 parameterized `Nagare.Static.Release` by a
  ConfigMap-name prefix (`*With` functions; the original functions fix `"nagare-static-releases-"`,
  static tests unchanged) and added `Nagare.App.Deployments` wrapping it under
  `"nagare-app-deployments-"` — whose `appConfigMapName` matches EP-30's `deleteApp` name exactly. The
  `deployments logs` revision path reuses EP-30's `Nagare.App.streamServiceLogs`/`LogTarget` (IP2). The
  recorded deployment id is the resolved `imageTag`; for prebuilt-image deploys `deployments logs <id>`
  reports a clear "no live revision" message (the running image carries the prebuilt tag, not the
  deploy id). (EP-31, 2026-06-10)

- **App `deploy` gained `--source`** (provenance recorded with the deployment and surfaced as
  `NAGARE_SOURCE`), matching the site deploy path. `DeployOpts` previously had no source field. (EP-31,
  2026-06-10)

- **The docs plan (EP-32) had to repair pre-existing drift in `deploying-apps.md`, not just add a link.**
  That page's "verbatim" `hello` config and "byte-for-byte golden" Service YAML had been silently
  invalidated by EP-29 (the `nagare.dev/managed-by` label, `domains`, resource limits, `healthCheck`) and
  by MasterPlan 5's EP-25 (`ScopedEnvVar`, the `envFrom` store). EP-32 corrected the config block, the
  rendered YAML, and the surrounding prose so the page matches the current example file and golden. Lesson
  for future model-changing plans (IP1/IP5): updating `config-reference.md` is not enough — `deploying-apps.md`
  embeds copies of configs and goldens that also drift. (EP-32, 2026-06-09)

- **EP-32 verified the render path live via `nagarectl deploy --dry-run`, deferring only the cluster verbs.**
  The new `cluster/examples/app-lifecycle-demo/` renders all three probes, `resources.limits`, two
  DomainMappings, the managed-by label, and `URL: https://demo.example.com` (the canonical of two) — proving
  EP-29's renderer contract end-to-end without a cluster. The `app`/`deployments` verbs that read/patch live
  Knative state were documented-but-deferred until `nagare-01` was powered on; that live run was
**executed and VERIFIED on 2026-06-10** — every verb (`app list`/`get`/`logs`/`restart`/`stop`/`delete`,
`deployments list`) ran against the live cluster, evidence in the EP-30/EP-31 checklist entries above.
(EP-32, 2026-06-09; live verbs 2026-06-10)

## Decision Log

- Decision: Scope this MasterPlan to the Phase 1 remainder — application-model extensions (health
  checks, resource limits, multiple domains), the `app` lifecycle CLI, and deployment history/logs —
  and explicitly exclude build modes and env/secret management.
  Rationale: Build modes shipped as `docs/masterplans/4-application-build-modes-for-nagare.md` and
  env/secret is `docs/masterplans/5-environment-and-secret-management-for-nagare.md` (Phase 2). MP4's
  own scope statement names "the broader Phase 1 app-lifecycle CLI (`app list/get/logs/restart`),
  health checks, multiple-domain support, and resource limits" as "separate initiatives" — this is
  that initiative. Grouping them matches the roadmap's "Suggested plan shape" for Phase 1 (one
  MasterPlan with child plans for the typed app model, renderer changes, CLI lifecycle commands, and
  user docs).
  Date: 2026-06-10

- Decision: Four child plans — model (EP-29), `app` CLI (EP-30), deployment history (EP-31), docs
  (EP-32) — rather than three or fewer.
  Rationale: The model is pure library work with golden tests; the two CLI surfaces are distinct
  High-priority roadmap rows with different storage and verification; docs describe working behavior.
  Each is independently verifiable and within the size guidance. Merging the two CLI plans would
  exceed the five-milestone/ten-file threshold.
  Date: 2026-06-10

- Decision: No hard dependencies between child plans; all relationships are soft/integration. EP-30's
  reliance on EP-29 is limited to output completeness (the managed-by label for `app list` filtering
  and richer `app get`), not compilation.
  Rationale: The lifecycle commands read live Knative state via `kubectl`, not the new DSL fields, so
  they compile and run before the model lands. Keeping dependencies soft maximizes parallelism and
  lets either CLI plan be demonstrated first.
  Date: 2026-06-10

- Decision: Change `domain :: Maybe Domain` to `domains :: [DomainSpec]` with a `canonical` flag, and
  render one DomainMapping per domain plus a `nagare.dev/managed-by: nagarectl` label, but defer hard
  HTTP redirect enforcement between non-canonical and canonical domains.
  Rationale: Mirrors the existing `ServerSite.domains :: [Domain]` model, satisfies the roadmap's
  "multiple domains and canonical/redirect settings" deliverable for the parts Knative supports
  natively (multiple mappings, a canonical for URL reporting), and avoids the disproportionate
  complexity of installing redirect rules on a single-node Knative/Kourier ingress in this initiative.
  The managed-by label is the minimal mechanism that lets `app list` distinguish Nagare apps from
  other Knative Services.
  Date: 2026-06-10

- Decision: Reuse/generalize the pure layer of `Nagare.Static.Release` for app deployment history
  rather than writing a parallel module from scratch.
  Rationale: The static release log is already a proven, unit-tested ConfigMap-as-JSON store with
  `recordReleaseFor` written to be runtime-agnostic; app deployments need the same newest-first,
  capped, current-marked history. Reuse keeps behavior and tests consistent. EP-31 parameterizes the
  ConfigMap name so app and static histories live in distinct ConfigMaps.
  Date: 2026-06-10

- Decision: Define `nagarectl app stop` as taking the app offline via a documented `kubectl`
  mechanism finalized in EP-30, not as a synonym for delete.
  Rationale: Knative has no native "pause", so EP-30 must choose and document a concrete, honest
  mechanism (e.g. patching the Service so it cannot serve, or removing its route) and state the
  reversal (`nagarectl deploy`/`app restart` brings it back). The MasterPlan fixes the *semantics*
  (offline but recoverable, history preserved); EP-30's Decision Log records the exact mechanism.
  Date: 2026-06-10

## Outcomes & Retrospective

All four child ExecPlans are Complete. The initiative delivered the Phase 1 remainder: Nagare can now
*operate* an app, not just *create* one, and the typed model is rich enough to describe a real service.

**What shipped.**

- **EP-29 (model + renderer).** `Deployment` gained `healthCheck :: Maybe HealthCheck`, resource *limits*
  (`cpuLimit`/`memoryLimit` on `Resources`), and `domains :: [DomainSpec]` (a canonical-marked list)
  replacing `domain :: Maybe Domain`, plus the `nagare.dev/managed-by: nagarectl` label on every app
  Service. The renderer emits `readinessProbe`/`livenessProbe`/`startupProbe`, `resources.limits`, and one
  DomainMapping per domain; `serviceUrl` reports the canonical domain. Verified by golden + round-trip
  tests with no cluster.
- **EP-30 (`app` CLI).** `nagarectl app list/get/logs/restart/stop/delete`, backed by a new `Nagare.App`
  module (`appIdentityOrDie`, `streamServiceLogs`/`LogTarget`, and the live-state + lifecycle helpers).
  `stop` is recoverable (cluster-local visibility), `restart` rolls a fresh revision and un-stops, `delete`
  removes Service + DomainMappings + history.
- **EP-31 (deployment history).** Every successful `deploy` records to `nagare-app-deployments-<app>` (the
  static-release store generalized by a name prefix), with `deployments list/logs` and a `--source`
  provenance flag.
- **EP-32 (docs + example).** `docs/user/app-lifecycle.md`, config-reference updates for the new fields, a
  runnable `app-lifecycle-demo` example proven by dry-run, and link wiring — plus a correction of stale
  pre-existing content in `deploying-apps.md`.

**What went well.** The soft-dependency decomposition held: EP-29 and EP-30 were genuinely independent at
compile time, and the Integration Points (the managed-by label string, the `Nagare.App` signatures, the
ConfigMap name) were consumed exactly as written with no re-derivation. Reusing `Nagare.Static.Release`'s
pure core for app history (IP3) kept behavior and tests consistent instead of forking a parallel store.

**Surprises worth carrying forward.** (1) IP5 resolved EP-23-first, so EP-29 rebased onto `ScopedEnvVar`
rather than the reverse — orthogonal as predicted. (2) A model change ripples into more docs than the
config reference: `deploying-apps.md` embedded a "verbatim" config and a "byte-for-byte" golden that EP-29
and EP-25 had quietly invalidated, and EP-32 had to repair them. Future model-changing MasterPlans should
treat embedded configs/goldens in *every* user page as part of the blast radius.

**Deferred / future work.** The live end-to-end cluster run (all `app`/`deployments` verbs against
`nagare-01`) was **executed and VERIFIED on 2026-06-10** once the host was powered back on — the render
path (already proven by dry-run) plus every cluster verb now have live evidence (see the EP-30/EP-31/EP-32
checklist entries). Hard HTTP redirects from
non-canonical to canonical domains remain explicitly out of scope (EP-29 Decision Log), recorded as future
work in the config reference and the lifecycle guide.
</content>
</invoke>
