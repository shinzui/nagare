# PaaS Capability Roadmap for Nagare

Created: 2026-06-07
Last updated: 2026-06-10

This roadmap compares Nagare's current and planned capability set against common self-hosted and
developer-platform PaaS capabilities, then turns the gaps into future Nagare initiatives. It is not
an implementation plan. Each major roadmap phase below is intentionally shaped so it can become its
own MasterPlan or ExecPlan later.

Companion roadmaps under `docs/roadmaps/`: `kubernetes-controller-roadmap.md` (whether and when to
add a Kubernetes controller) and `ingress-networking-layer-roadmap.md` (whether and when to migrate
the Knative networking layer from Kourier to Envoy Gateway via the Gateway API — currently
postponed, Knative kept as a hard requirement).

## Implementation status (2026-06-10)

Status legend used throughout: ✅ **Done**, 🟡 **Partial**, ⬜ **Not started**, ⛔ **Out of scope**.

Delivered so far, each by a completed MasterPlan under `docs/masterplans/`:

- ✅ Static sites, previews, rollbacks, and Git webhook automation — MasterPlan 3.
- ✅ Application build modes (typed `BuildSpec`: `DockerfileBuild`, `PrebuiltImage`, `NixpacksBuild`)
  — MasterPlan 4.
- ✅ Environment and secret management (`nagarectl env` / `nagarectl secret`, runtime/build/preview
  scopes, `.env` sync) — MasterPlan 5.
- ✅ Application model and CLI lifecycle (health checks, resource limits, multiple domains, and the
  `nagarectl app …` / `nagarectl deployments …` commands) — MasterPlan 6.
- ✅ Persistent storage (typed volumes, PVC renderer, `nagarectl storage …`, app-volume snapshots to
  GCS with retention) — MasterPlan 7.
- ✅ Server and operations UX (`nagarectl server status` / `doctor` / `domains list` / `cleanup`) —
  MasterPlan 8.
- ✅ Managed databases (typed `Database` for Postgres/Redis/ClickHouse, StatefulSet/Service/PVC/Secret
  renderer, `nagarectl db …`, app connection-env injection, scheduled GCS backups + restore) —
  MasterPlan 9.

Still missing (future initiatives): scheduled tasks (Phase 5), curated service templates (Phase 6),
dynamic-app previews (Phase 7), a general control API and CLI contexts (Phase 8 — only the static
webhook runner `nagared` exists today), and an optional dashboard (Phase 10).

Sources used for the initial comparison. This list is intentionally incomplete and should be updated
as more PaaS platforms are researched:

- Coolify repository and docs: <https://github.com/coollabsio/coolify>, <https://coolify.io/docs>
- Coolify API and CLI surfaces: <https://raw.githubusercontent.com/coollabsio/coolify/v4.x/openapi.json>, <https://github.com/coollabsio/coolify-cli>
- Nagare static hosting plan: `docs/masterplans/3-static-hosting-for-nagare.md`


## Current Baseline

Nagare already has a strong core: one typed Haskell config produces one Knative Service, and
`nagarectl deploy` builds, pushes, applies, waits, and prints a URL. The type-safe DSL initiative
eliminated the old YAML surface and made illegal app deployment states much harder to write down.
On top of that, seven capability initiatives have now landed (see *Implementation status* above):
static hosting (Cloudflare Pages/Netlify-style static-site config, generated Nginx image packaging,
releases, rollback, previews, and Git webhook automation), typed application build modes, environment
and secret management, the application model and CLI lifecycle, persistent storage with app-volume
backups, and the operator-facing server/operations UX.

That leaves these broader PaaS gaps (managed databases with backups, Phase 4, is now delivered by
MasterPlan 9):

- scheduled tasks (Phase 5),
- curated service templates, and optionally Docker Compose-style services (Phase 6),
- dynamic-app preview deployments (Phase 7),
- a general control-plane API and CLI contexts beyond today's static webhook runner (Phase 8),
- and an optional dashboard or equivalent operator UI (Phase 10).

The roadmap below orders these by leverage for a single-node personal PaaS. It does not try to clone
any one platform's architecture. Nagare should stay Kubernetes/Knative-native and typed-config-first.


## Gap Matrix

| PaaS capability | Recommended Nagare shape | Status |
|---|---|---|
| Static sites, previews, rollbacks | Containerized Nginx image deployed as Knative Service | ✅ Done — MasterPlan 3 |
| Application build modes | Typed `BuildSpec`: `DockerfileBuild`, `PrebuiltImage`, `NixpacksBuild` | ✅ Done — MasterPlan 4 |
| App lifecycle commands | `nagarectl app list/get/logs/restart/stop/delete` | ✅ Done — MasterPlan 6 |
| Deployment history/logs | Release/deployment records plus `nagarectl deployments ...` | ✅ Done — MasterPlan 6 |
| App model knobs (health checks, limits, domains) | `HealthCheck`, request+limit `Resources`, multiple `DomainSpec` | ✅ Done — MasterPlan 6 |
| Env vars and secrets | `nagarectl env` and `nagarectl secret`, build/runtime/preview scopes, `.env` sync | ✅ Done — MasterPlan 5 |
| Persistent storage | Typed volume mounts and PVC renderer, `nagarectl storage ...` | ✅ Done — MasterPlan 7 |
| App-volume backups | Snapshot to GCS with retention and backup ownership | ✅ Done — MasterPlan 7 |
| Server inventory & operations UX | `nagarectl server status` / `doctor` / `domains list` / `cleanup` | ✅ Done — MasterPlan 8 |
| Managed databases | First-class Postgres/Redis/ClickHouse `Database` resources, generated env injection | ✅ Done — MasterPlan 9 |
| Managed-database backups | Scheduled CronJob + on-demand `db backup`, `db restore`, keep-last-N retention | ✅ Done — MasterPlan 9 |
| Scheduled tasks | Kubernetes CronJob renderer and `nagarectl task` commands | ⬜ Not started — Phase 5 |
| Service templates | Curated typed templates (Postgres admin, MinIO, etc.) | ⬜ Not started — Phase 6 |
| Docker Compose apps | Decompose to typed resources, or run in a constrained namespace | ⬜ Not started — Phase 6 (low interest) |
| Preview deployments for dynamic apps | Branch/PR suffixes over the Knative Service renderer | ⬜ Not started — Phase 7 (static-site previews already done) |
| Git provider integration | Generalize the webhook receiver beyond static deploys | 🟡 Partial — `nagared` webhook runner does static production/preview deploys |
| Control API and contexts | `nagared` control API + `nagarectl context ...` | 🟡 Partial — `nagared` exists as a static webhook runner; no general API or contexts — Phase 8 |
| Dashboard UI | Optional thin UI over `nagared` | ⬜ Not started — Phase 10 |
| Multi-server management | Defer; Nagare is intentionally single-node | ⛔ Out of scope |


## Phase 1: Application Model and CLI Lifecycle — ✅ Done

**Status: delivered by MasterPlan 4 (build modes) and MasterPlan 6 (app model + CLI lifecycle).** The
typed `BuildSpec` (`DockerfileBuild` / `PrebuiltImage` / `NixpacksBuild`), `HealthCheck`, request+limit
`Resources`, multiple `DomainSpec`, and the `nagarectl app …` / `nagarectl deployments …` commands all
shipped. The original deliverables below are retained for historical context.

General-purpose PaaS application models expose more knobs than Nagare's current `Deployment`: build
command, start command, base directory, publish directory, Dockerfile path/content, pre/post deploy
commands, health checks, ports, domains, resource limits, and lifecycle actions. Nagare should add
the parts that fit Knative and keep Kubernetes internals hidden.

Deliverables:

- Extend the DSL from a single `Deployment` record toward an `App` or `Project` model while
  preserving the existing simple web-service preset.
- Add a typed `BuildSpec` with at least `DockerfileBuild`, `PrebuiltImage`, and a placeholder for a
  future buildpack/Nixpacks-style builder.
- Add `HealthCheck` with path, method, scheme, expected status, interval, timeout, retries, and
  startup period where Knative/Kubernetes can support it.
- Add resource limits in addition to current resource requests.
- Add multiple domains and canonical/redirect settings, not only `Maybe Domain`.
- Add CLI commands:

```text
nagarectl app list
nagarectl app get NAME
nagarectl app logs NAME --follow
nagarectl app restart NAME
nagarectl app stop NAME
nagarectl app delete NAME
nagarectl deployments list NAME
nagarectl deployments logs NAME [DEPLOYMENT_ID]
```

Suggested plan shape: one MasterPlan with child plans for the typed app model, renderer changes,
CLI lifecycle commands, and user docs.

Why first: it improves every app workflow and creates the vocabulary that later phases reuse.


## Phase 2: Environment and Secret Management — ✅ Done

**Status: delivered by MasterPlan 5.** Typed env scopes (runtime/build/preview), literal/multiline
semantics, generated/predefined variables, `.env` sync, deterministic Secret/ConfigMap rendering with
reconcile modes, and the `nagarectl env …` / `nagarectl secret …` commands all shipped. The original
deliverables below are retained for historical context.

Modern PaaS environment-variable surfaces are broader than Nagare's current `EnvLiteral` versus
`EnvSecretRef`: they commonly include build-time flags, preview flags, literal/multiline options,
predefined variables, and bulk sync from `.env` files. Nagare should not copy any specific UI, but it
should support the operational capability.

Deliverables:

- Add a typed env model with scope: runtime, build-time, preview, or combinations where meaningful.
- Add multiline and literal semantics.
- Add generated/predefined variables such as service URL, branch name, commit SHA, release id, and
  resource names.
- Add `.env` sync:

```text
nagarectl env list APP
nagarectl env set APP KEY VALUE
nagarectl env delete APP KEY
nagarectl env sync APP --file .env.production --runtime --preview
nagarectl secret set APP KEY
nagarectl secret list APP
nagarectl secret delete APP KEY
```

- Render Kubernetes Secrets and ConfigMaps deterministically and support "do not delete unmentioned
  keys" versus "reconcile exactly" modes.
- Document how build-time env is passed to local Docker builds and future builders.

Suggested plan shape: one ExecPlan if scoped to CLI and Kubernetes Secret/ConfigMap management; a
MasterPlan if build-time env integration and preview env overlays are included.

Why second: apps and databases become much more usable once configuration can be managed without
editing Haskell and redeploying everything.


## Phase 3: Persistent Storage — ✅ Done

**Status: delivered by MasterPlan 7.** Typed `Volume`/`Mount` types with retention policy, the PVC and
Knative volume-mount renderer, the `nagarectl storage list/inspect/snapshot` commands, app-volume
snapshots to GCS with retention, and the backup-ownership rule (included or explicitly excluded with a
warning) all shipped. The original deliverables below are retained for historical context.

PaaS platforms commonly let applications and databases attach persistent storage. Nagare has k3s
local-path storage and examples, but no typed app-level storage surface.

Deliverables:

- Add `Volume`/`Mount` types to the DSL: name, size, mount path, access mode, read-only flag, and
  retention policy.
- Render PVCs and Knative/Kubernetes volume mounts.
- Add CLI helpers:

```text
nagarectl storage list APP
nagarectl storage inspect APP VOLUME
nagarectl storage snapshot APP VOLUME
```

- Define backup ownership: app volumes should either be included in the existing GCS backup flow or
  explicitly excluded with a warning.
- Add docs for SQLite/Litestream and uploaded-file use cases.

Suggested plan shape: one MasterPlan if backup integration is included; otherwise one ExecPlan.

Why third: persistent storage is a prerequisite for many "service" and "database" templates.


## Phase 4: Managed Databases and Backups — ✅ Done

**Status: delivered by MasterPlan 9** (`docs/masterplans/9-managed-databases-for-nagare.md`,
EP-43–EP-48). A typed `Database` (Postgres/Redis/ClickHouse) renders a single-replica StatefulSet +
ClusterIP Service + `local-path` PVC + managed Secret; `nagarectl db list/create/get/shell/restart/
delete` operate it; an app references databases by name and receives per-engine connection env
(`DATABASE_URL`/`REDIS_URL`/`CLICKHOUSE_URL` + components, passwords as Secret references);
`nagarectl db backup/restore` plus a daily self-pruning CronJob handle backups to
`gs://tan-nb-exp-nagare-backups/databases/<name>/` with keep-last-N retention. User guide:
`docs/user/managed-databases.md`; three end-to-end examples under `cluster/examples/`. The scope went
beyond the original Phase 4 (Postgres + Redis) by adding **ClickHouse** as an analytical store. The
in-pod GCS auth that backups rely on required a node networking fix (a `/32` metadata route +
`hostAliases`), now in `nixos/hosts/nagare-01/networking.nix`.

The original Phase 4 deliverables, all met, were:

- First-class `Database` resources in the DSL or project config.
- Initial engines: PostgreSQL and Redis (plus ClickHouse, added).
- Generated Kubernetes resources using either direct manifests or a chosen operator/Helm chart.
- Generated secrets and app env injection:

```text
DATABASE_URL
REDIS_URL
POSTGRES_HOST
POSTGRES_USER
POSTGRES_PASSWORD
```

- CLI:

```text
nagarectl db list
nagarectl db create postgres NAME
nagarectl db get NAME
nagarectl db shell NAME
nagarectl db backup NAME
nagarectl db restore NAME BACKUP_ID
nagarectl db restart NAME
```

- Scheduled backups with cron, retention, local storage, and GCS upload.
- Restore drills documented and tested against disposable databases.

Suggested plan shape: one MasterPlan with child plans for database model, Postgres, Redis, backups,
and app env integration.

Why fourth: this is the biggest remaining PaaS gap after app lifecycle and env management. It should
not be started until storage and secrets have a stable shape.


## Phase 5: Scheduled Tasks and One-Off Jobs — ⬜ Not started

**Status: not started.** No `Task` model, CronJob renderer, or `nagarectl task` commands exist yet.

Scheduled tasks are a common PaaS feature for applications and services. Nagare can map this cleanly
to Kubernetes CronJobs and one-off Jobs.

Deliverables:

- Typed `Task` model: name, schedule, command, image/app reference, env inheritance, timeout,
  concurrency policy, and retry policy.
- Render Kubernetes CronJobs for scheduled tasks.
- Add one-off execution:

```text
nagarectl task list APP
nagarectl task run APP TASK
nagarectl task logs APP TASK [RUN_ID]
nagarectl task delete APP TASK
```

- Wire task logs into the existing VictoriaLogs/Grafana story where possible.

Suggested plan shape: one ExecPlan or small MasterPlan if one-off Jobs and CronJobs are split.

Why fifth: scheduled jobs are important, but they depend on env, secrets, storage, and database
connections being stable.


## Phase 6: Service Templates — ⬜ Not started

**Status: not started.** No template schema, registry, or `nagarectl service …` commands exist yet.

Nagare offers a small, curated set of service templates that match personal infrastructure needs —
deliberately a handful of high-value, version-pinned templates, not a sprawling catalog.

Initial template candidates:

- Uptime Kuma,
- Plausible or Umami,
- MinIO,
- Ghost,
- Meilisearch,
- NATS,
- Postgres admin UI,
- Redis admin UI.

Deliverables:

- A template schema with typed inputs, generated secrets, storage requirements, domains, and health
  checks.
- A local template registry under `cluster/templates/` or `cli/nagare-dsl/src/Nagare/Dsl/Templates/`.
- CLI:

```text
nagarectl service templates
nagarectl service create TEMPLATE NAME
nagarectl service list
nagarectl service logs NAME
nagarectl service restart NAME
nagarectl service delete NAME
```

- A policy for updates: templates should pin image tags and require explicit upgrade commands.

Suggested plan shape: one MasterPlan with a spike first, because template packaging can go in several
directions: raw Kubernetes manifests, Helm, generated Knative Services, or Compose translation.

Why sixth: templates are attractive, but without storage, secrets, domains, and database primitives
they become brittle copy-paste.


## Phase 7: Preview Deployments for Dynamic Apps — ⬜ Not started

**Status: not started.** Static-site previews shipped with MasterPlan 3 (`nagarectl site preview …`),
but dynamic applications have no preview model yet (no `PreviewPolicy`, no `nagarectl app preview …`).

The static hosting plan adds previews for static sites. Dynamic applications should gain the same
branch and pull-request preview model, including separate preview env. Nagare should generalize the
preview mechanism to dynamic apps.

Deliverables:

- Add `PreviewPolicy` to the app DSL: enabled, branch/PR naming, env overlay, domain template, TTL,
  cleanup behavior.
- Add `nagarectl app preview deploy/list/delete`.
- Reuse Git webhook automation from static hosting.
- Ensure preview services do not mutate production release metadata.
- Add cleanup for stale previews.

Suggested plan shape: one ExecPlan if static preview foundations exist; otherwise fold into the app
lifecycle MasterPlan.

Why seventh: valuable for Git workflows, but not essential before core app lifecycle is solid.


## Phase 8: Control API and Contexts — 🟡 Partial

**Status: partial.** The `nagared` service exists today as a **static-hosting webhook runner** (it
verifies GitHub HMAC signatures and drives the static production/preview deploy path; introduced with
MasterPlan 3). There is no general control API exposing typed operations, no authentication model
beyond the webhook secret, and no `nagarectl context …` management yet.

Many platforms expose an API and a CLI context model. Nagare is currently CLI-first with direct
shell-outs to Docker, gcloud, and kubectl. A small API becomes useful once webhooks, dashboards, or
remote clients need a stable control surface.

Deliverables:

- Define a local/cluster API service, likely the same `nagared` service introduced by static
  webhooks.
- Add authentication appropriate for a single-tenant deployment: local token, mTLS, Tailscale-only,
  or Kubernetes ServiceAccount-based access.
- Add context management:

```text
nagarectl context list
nagarectl context add NAME URL TOKEN
nagarectl context use NAME
nagarectl context verify
```

- Expose read-only endpoints first: health, version, resources, apps, releases, database status.
- Add mutation endpoints only after CLI operations are factored into reusable library functions.

Suggested plan shape: one MasterPlan with security and API design up front.

Why later: an API before stable app/db/service primitives would freeze immature shapes.


## Phase 9: Server and Operations UX — ✅ Done

**Status: delivered by MasterPlan 8.** `nagarectl server status` (one-screen inventory), `nagarectl
doctor` (graded checklist with remediation hints, non-zero exit on FAIL), `nagarectl domains list`
(DNS + certificate readiness), and `nagarectl cleanup` (dry-run-by-default disk reclamation) all
shipped, with the `docs/runbooks/server-operations.md` guide and the cluster-access /
disaster-recovery runbook integration. The original deliverables below are retained for historical
context.

PaaS operator interfaces commonly surface servers, resources, domains, proxy status, and
update/cleanup actions. Nagare's operator story is currently spread across Pulumi outputs, NixOS
docs, `kubectl`, Grafana, and runbooks.

Deliverables:

- `nagarectl server status`: VM, k3s, Knative, Kourier, cert-manager, base domain, disk usage,
  Artifact Registry auth, backup freshness.
- `nagarectl doctor`: actionable checks with remediation hints.
- `nagarectl cleanup`: image prune guidance, old preview cleanup, old release pruning.
- `nagarectl domains list`: show configured domains and readiness.
- Integrate with existing docs and disaster recovery runbook.

Suggested plan shape: one ExecPlan for `doctor/status`, then follow-up plans for cleanup and domain
inspection.

Why later: it is easiest to build good health checks once the resources they inspect are standardized.


## Phase 10: Optional Dashboard — ⬜ Not started

**Status: not started** (and intentionally deferred until the control API and most core resources are
stable).

A web UI is a common advantage of mature PaaS products. Nagare can remain CLI-first for a long time,
but a small single-tenant dashboard could eventually improve day-2 operations.

Deliverables:

- Read-only dashboard first: apps, static sites, databases, services, deploy history, logs links,
  backup status.
- Mutations only after the control API is stable.
- No multi-tenant auth in the first version; put it behind Tailscale or another private access path.

Suggested plan shape: defer until the control API exists and most core resources are stable.

Why last: a dashboard built too early would either duplicate CLI logic or force premature API design.


## Recommended Initiative Order

1. ✅ Finish `docs/masterplans/3-static-hosting-for-nagare.md`.
2. ✅ Application model and CLI lifecycle (MasterPlans 4 & 6).
3. ✅ Environment and secret management (MasterPlan 5).
4. ✅ Persistent storage (MasterPlan 7).
5. ✅ Server/operator UX (MasterPlan 8) — pulled forward ahead of the items below, since its health
   checks are useful now and the resources they inspect are already standardized.
6. ⬜ Managed PostgreSQL and Redis with backups. ← **next**
7. ⬜ Scheduled tasks.
8. ⬜ Service templates.
9. ⬜ Dynamic app previews.
10. 🟡 Control API and contexts (today only the static webhook runner `nagared` exists).
11. ⬜ Optional dashboard.

This order keeps Nagare pragmatic: first make individual apps and static sites pleasant, then add
stateful resources, then templates, then automation and UI. It also preserves the existing principle
that Nagare is a typed, Kubernetes-native personal PaaS rather than a clone of any one platform.


## Candidate MasterPlans to Create Next

Already created and completed: **Application Lifecycle** (MasterPlan 6), **Environment and Secret
Management** (MasterPlan 5), **Application Build Modes** (MasterPlan 4), **Persistent Storage**
(MasterPlan 7), and **Server Inventory and Operations UX** (MasterPlan 8).

The next useful planning artifacts to create would be:

1. **Managed Databases for Nagare**: first-class Postgres and Redis resources, generated env
   injection (`DATABASE_URL`/`REDIS_URL`), scheduled backups, restore commands, and restore drills.
   (Persistent volumes already shipped in MasterPlan 7; this builds the database layer on top.)
2. **Scheduled Tasks for Nagare**: a typed `Task` model, the Kubernetes CronJob/one-off Job renderer,
   and `nagarectl task` commands.
3. **Service Templates for Nagare**: a curated typed template schema and registry, with
   `nagarectl service …` commands — a small, version-pinned curated set.
4. **Dynamic App Previews for Nagare**: `PreviewPolicy` on the app DSL, `nagarectl app preview …`,
   reusing the static-hosting webhook automation.
5. **Nagare Control Plane API**: generalize `nagared` beyond the static webhook runner — contexts,
   auth, a read-only API, then mutation endpoints.
