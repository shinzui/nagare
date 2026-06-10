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
| 30 | nagarectl app lifecycle commands | docs/plans/30-nagarectl-app-lifecycle-commands.md | None | EP-29 | Not Started |
| 31 | Application deployment history and deployments commands | docs/plans/31-application-deployment-history-and-deployments-commands.md | None | EP-30 | Not Started |
| 32 | Application lifecycle docs and end-to-end examples | docs/plans/32-application-lifecycle-docs-and-end-to-end-examples.md | EP-30, EP-31 | EP-29 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-29). The numbers continue the
repository's sequential plan numbering; the most recent existing plan is EP-28 (a child of MasterPlan 5).


## Dependency Graph

There are no hard dependencies between the child plans — every one is independently implementable
against the current working tree — and this is deliberate, to maximize parallelism. The relationships
are soft and integration dependencies that govern *coordination*, not *blocking*.

**EP-29** (the model) has no dependencies and is the natural starting point. It edits only the
`cli/nagare-dsl` package plus the deploy call sites in `cli/nagarectl` that the `domain → domains`
change forces to update (`renderDomainMapping` becomes plural, and `Nagare.Deploy.serviceUrl` must
pick the canonical domain). Nothing precedes it, and it can ship a complete, golden-tested model
without either CLI plan existing.

**EP-30** (the `app` commands) *soft-depends* on EP-29 for two reasons, but can proceed without it.
First, `nagarectl app list` filters Knative Services by the `nagare.dev/managed-by: nagarectl` label
that EP-29's renderer stamps; until EP-29 lands, `app list` lists every Knative Service in the
namespace and notes (in `--help` and output) that it is unfiltered. Second, `nagarectl app get` can
enrich its output with the configured health check, domains, and limits from EP-29's model; until
then it reports only what `kubectl get ksvc -o json` provides. Because the live-cluster operations
(list/get/logs/restart/stop/delete) read Knative state rather than the new DSL fields, EP-30 is fully
implementable and demonstrable before EP-29 — the dependency is about *completeness of output*, not
*compilation*.

**EP-31** (deployment history) *soft-depends* on EP-30 only so that `deployments logs NAME [ID]` can
reuse the `kubectl logs` helper and the app-identity loader that EP-30 places in the new `Nagare.App`
module (Integration Point IP2). If EP-31 is implemented first, it introduces those helpers itself and
EP-30 reuses them — the owning plan is whichever lands first, and the Integration Points section
records EP-30 as the intended owner. EP-31's deploy-time recording (the change to `runDeploy` in
`cli/nagarectl/app/Main.hs`) and `deployments list` are independent of EP-30 entirely.

**EP-32** (docs) *hard-depends* on EP-30 and EP-31 because a docs-and-examples plan must describe and
exercise commands that actually work end-to-end, exactly as
`docs/plans/17-static-hosting-docs-and-end-to-end-examples.md` waited on the static commands. It
*soft-depends* on EP-29 so the config-reference section can document the new health-check, limits, and
multiple-domain fields accurately; if EP-29 is not yet merged, EP-32 documents the commands and defers
the model-field reference to a follow-up note.

**Parallelism.** EP-29 and EP-30 can be implemented fully in parallel from day one (different
packages, no shared compile-time artifact). EP-31 is best started after EP-30 so it can reuse the
`Nagare.App` helpers, but its recording and `deployments list` halves can begin immediately. EP-32 is
last and gates on EP-30 and EP-31. The recommended order is EP-29 → EP-30 → EP-31 → EP-32, but
EP-29/EP-30 may overlap and only EP-32 is genuinely gated.


## Integration Points

These are the artifacts more than one child plan touches. Each is defined by one owning plan; later
plans consume it exactly as described and must not re-derive it.

**IP1 — The `Deployment` record shape and the managed-by label.** Owned by **EP-29** in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs` and `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`. EP-29 changes
the record in three ways and adds one renderer behavior:

```haskell
data Deployment = Deployment
  { name        :: !ServiceName
  , namespace   :: !Namespace
  , image       :: !ImageRef
  , build       :: !BuildSpec          -- unchanged (from EP-19)
  , domains     :: ![DomainSpec]        -- was:  domain :: !(Maybe Domain)
  , port        :: !Port
  , env         :: !(Map EnvName EnvVar)
  , resources   :: !(Maybe Resources)   -- now carries requests AND optional limits (see EP-29)
  , scale       :: !(Maybe Scale)
  , healthCheck :: !(Maybe HealthCheck)  -- new
  }
```

`DomainSpec` pairs a `Domain` with a `canonical :: Bool` flag (exactly one canonical when the list is
non-empty; EP-29 provides a smart constructor enforcing this). The renderer (`Nagare.Dsl.Render`)
emits one `DomainMapping` per domain (so `renderDomainMapping :: Deployment -> Maybe ByteString`
becomes `renderDomainMappings :: Deployment -> [ByteString]`), emits the probe and `resources.limits`
blocks, and adds `metadata.labels."nagare.dev/managed-by" = "nagarectl"` to every Service.
`Nagare.Deploy.serviceUrl` (in `cli/nagarectl/src/Nagare/Deploy.hs`) changes to select the canonical
domain (or the wildcard URL when there are no domains). EP-30 reads the label name from this contract
for `app list`; EP-30's `app get` may read `healthCheck`/`domains`/`resources` for enriched output;
EP-31 is unaffected by the model change but its `deployments` table reuses the same identity. **The
label string `nagare.dev/managed-by: nagarectl` is the contract**: EP-30 must match it exactly.

**IP2 — The `Nagare.App` kubectl/identity helper module.** Owned by **EP-30** in a new
`cli/nagarectl/src/Nagare/App.hs` (added to the library's exposed-modules in
`cli/nagarectl/nagarectl.cabal`). It exports the shared building blocks both CLI plans need:

```haskell
-- Load a Deployment config and return its (name, namespace), mirroring the existing
-- siteIdentityOrDie in cli/nagarectl/app/Main.hs but for the app (Deployment) path.
appIdentityOrDie :: FilePath -> IO (Text, Text)

-- Tail (or print) a Knative service's user-container logs:
--   kubectl logs -l serving.knative.dev/service=<name> -n <ns> [-f] -c user-container --tail=<n>
-- When a revision is given, the label selector also pins serving.knative.dev/revision=<rev>.
streamServiceLogs :: LogTarget -> IO ()
```

EP-31's `deployments logs NAME [DEPLOYMENT_ID]` consumes `streamServiceLogs` (passing a revision
target) and `appIdentityOrDie`. If EP-31 is implemented before EP-30, EP-31 creates `Nagare.App` with
these exact signatures and EP-30 reuses them. The signatures are the contract; whichever plan lands
first writes them.

**IP3 — The per-app deployment-history ConfigMap and record schema.** Owned by **EP-31**. EP-31
generalizes the pure layer of `cli/nagarectl/src/Nagare/Static/Release.hs` (the `StaticRelease`/
`StaticReleaseLog` types, `addRelease`, `findRelease`, `formatReleasesTable`, ConfigMap render/extract,
and the `readReleaseLog`/`writeReleaseLog`/`recordReleaseFor` IO) so the same machinery can store app
deployments under a distinct ConfigMap name (e.g. `nagare-app-deployments-<app>` rather than
`nagare-static-releases-<site>`). EP-31 decides whether to parameterize the existing module by a name
prefix or introduce a thin `Nagare.App.Deployments` wrapper around the shared pure core; the Decision
Log below records the recommendation (parameterize/reuse, do not copy). EP-30's `app delete` consumes
this: when deleting an app it must also delete the history ConfigMap, so EP-30 imports the
`configMapName`/equivalent from EP-31's module (or, if EP-30 lands first, deletes by the documented
name and EP-31 confirms the name matches). EP-32 documents the record fields.

**IP4 — The `cli/nagarectl/app/Main.hs` command parser.** Both EP-30 and EP-31 add a top-level
subcommand here using the existing `optparse-applicative` `subparser` structure (which today has
`deploy` and `site`). EP-30 adds the `app` subparser (with `list/get/logs/restart/stop/delete`); EP-31
adds the `deployments` subparser (with `list/logs`) and modifies `runDeploy` to record a deployment on
success. These are additive and touch different regions of the file, so conflict risk is low; each
plan adds its own `Command` constructors and `runX` handlers. The owning concern is shared — each plan
owns the constructors it adds.

**IP5 — Cross-MasterPlan coordination with EP-23 (env scopes).** EP-29 edits the same files
(`Types.hs`, `Config.hs`, `Load.hs`, `Render.hs`) that
`docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md` (a child of MasterPlan 5) will edit.
Both add fields to `Deployment` and change the renderer and loader. They do not conflict semantically
(env scopes vs. health/limits/domains are orthogonal), but whichever lands second must rebase its
record-literal and JSON changes onto the first. The roadmap order puts this initiative (Phase 1)
before Phase 2, so the expectation is EP-29 lands first; EP-23 then extends the already-pluralized
`domains` model. This is recorded so the EP-23 implementer is not surprised.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan and milestone.

- [x] EP-29: `HealthCheck` type and `Resources` limits added to the model; smart constructors with tests. (2026-06-10)
- [x] EP-29: `domain → domains :: [DomainSpec]` with canonical marker; preset/fixtures/examples updated. (2026-06-10)
- [x] EP-29: JSON round-trip (Config emit / Load decode) carries the new fields; golden + round-trip tests pass. (2026-06-10)
- [x] EP-29: Renderer emits probes, `resources.limits`, per-domain DomainMappings, and the managed-by label; `serviceUrl` uses canonical domain; deploy call sites updated; `cabal test` green in `cli/nagare-dsl`. (2026-06-10)
- [ ] EP-30: `Nagare.App` module with `appIdentityOrDie` and `streamServiceLogs`; unit tests for pure helpers.
- [ ] EP-30: `app list` and `app get` working against the cluster (label-filtered list, formatted get).
- [ ] EP-30: `app logs [--follow]`, `app restart`, `app stop`, `app delete` working; `nagarectl-test` green.
- [ ] EP-31: `recordReleaseFor`-style recording wired into `runDeploy`; per-app history ConfigMap.
- [ ] EP-31: `deployments list NAME` prints the history table; `deployments logs NAME [ID]` streams revision logs.
- [ ] EP-31: pure-layer unit tests (record/round-trip/find/format) green.
- [ ] EP-32: `docs/user/app-lifecycle.md` written; `config-reference.md`/`deploying-apps.md` updated for new fields.
- [ ] EP-32: runnable example exercised end-to-end (deploy → list → get → logs → deployments → restart → stop → delete).


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

(To be filled during and after implementation.)
</content>
</invoke>
