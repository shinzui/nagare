# PaaS Capability Roadmap for Nagare

Created: 2026-06-07

This roadmap compares Nagare's current and planned capability set against common self-hosted and
developer-platform PaaS capabilities, then turns the gaps into future Nagare initiatives. It is not
an implementation plan. Each major roadmap phase below is intentionally shaped so it can become its
own MasterPlan or ExecPlan later.

Sources used for the initial comparison. This list is intentionally incomplete and should be updated
as more PaaS platforms are researched:

- Coolify repository and docs: <https://github.com/coollabsio/coolify>, <https://coolify.io/docs>
- Coolify API and CLI surfaces: <https://raw.githubusercontent.com/coollabsio/coolify/v4.x/openapi.json>, <https://github.com/coollabsio/coolify-cli>
- Nagare static hosting plan: `docs/masterplans/3-static-hosting-for-nagare.md`


## Current Baseline

Nagare already has a strong narrow core: one typed Haskell config produces one Knative Service, and
`nagarectl deploy` builds, pushes, applies, waits, and prints a URL. The type-safe DSL initiative
eliminated the old YAML surface and made illegal app deployment states much harder to write down.
The static hosting MasterPlan adds the Cloudflare Pages/Netlify-style side of the platform:
static-site config, generated Nginx image packaging, releases, rollback, previews, and Git webhook
automation.

That leaves these broader PaaS gaps outside static hosting:

- project/environment organization,
- richer application build/deploy modes,
- lifecycle and log commands,
- first-class env and secret management,
- persistent storage,
- managed databases with backups,
- Docker Compose-style services and one-click templates,
- scheduled tasks,
- server/resource inventory and operational maintenance,
- API/control-plane automation,
- and a dashboard or equivalent operator UI.

The roadmap below orders these by leverage for a single-node personal PaaS. It does not try to clone
any one platform's architecture. Nagare should stay Kubernetes/Knative-native and typed-config-first.


## Gap Matrix

| PaaS capability | Nagare status | Recommended Nagare shape | Priority |
|---|---|---|---|
| Static sites, previews, rollbacks | Planned in `docs/masterplans/3-static-hosting-for-nagare.md` | Containerized Nginx image deployed as Knative Service | Already planned |
| Application build modes | Partial: Docker build only | Typed `BuildSpec`: Dockerfile, prebuilt image, buildpacks/Nixpacks-style builder later | High |
| App lifecycle commands | Minimal: deploy only | `nagarectl app list/get/logs/restart/stop/delete` | High |
| Deployment history/logs | Partial through Kubernetes/Grafana | Release/deployment records plus `nagarectl deployments ...` | High |
| Env vars and secrets | Partial in DSL, no management commands | `nagarectl env` and `nagarectl secret`, build/runtime/preview scopes | High |
| Persistent storage | Examples only | Typed volume mounts and PVC renderer | High |
| Managed databases | Backup scripts and examples, not productized | First-class Postgres and Redis resources, generated env injection | High |
| Database backups | Scripts exist, no app-level UX | Scheduled backup resources, restore commands, retention policy | High |
| Services/templates | Not present | Curated Kubernetes/Helm/Compose-derived templates with typed inputs | Medium |
| Docker Compose apps | Not present | Either decompose to typed resources or run Compose-compatible services in a constrained namespace | Medium |
| Scheduled tasks | Not present | Kubernetes CronJob renderer and `nagarectl task` commands | Medium |
| Preview deployments for dynamic apps | Not present | Branch/PR suffixes over existing Knative Service renderer | Medium |
| Git provider integration | Planned for static only | Generalize webhook receiver for app and database workflows | Medium |
| Server inventory | Mostly Pulumi/NixOS docs | `nagarectl server status`, disk, cluster, ingress, domain, backup health | Medium |
| API automation | Not present | Small `nagared` API exposing typed operations, initially local/cluster-authenticated | Low-to-medium |
| Dashboard UI | Not present | Optional thin UI over `nagared`; not needed before CLI/API maturity | Low |
| Multi-server management | Out of scope today | Defer; Nagare is intentionally single-node | Low |
| One-click 200+ service marketplace | Not present | Start with 5-10 high-value curated templates; avoid large marketplace early | Low-to-medium |


## Phase 1: Application Model and CLI Lifecycle

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


## Phase 2: Environment and Secret Management

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


## Phase 3: Persistent Storage

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


## Phase 4: Managed Databases and Backups

PaaS platforms commonly provide managed or semi-managed databases such as PostgreSQL, MySQL/MariaDB,
MongoDB, Redis-compatible stores, and analytical databases. Nagare should start smaller and make the
first two excellent.

Deliverables:

- First-class `Database` resources in the DSL or project config.
- Initial engines: PostgreSQL and Redis.
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


## Phase 5: Scheduled Tasks and One-Off Jobs

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


## Phase 6: Service Templates

Many PaaS platforms offer user-defined service stacks and one-click service templates. Nagare should
not chase a large template marketplace early. It should start with a small curated set that matches
personal infrastructure needs.

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


## Phase 7: Preview Deployments for Dynamic Apps

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


## Phase 8: Control API and Contexts

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


## Phase 9: Server and Operations UX

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


## Phase 10: Optional Dashboard

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

1. Finish `docs/masterplans/3-static-hosting-for-nagare.md`.
2. Application model and CLI lifecycle.
3. Environment and secret management.
4. Persistent storage.
5. Managed PostgreSQL and Redis with backups.
6. Scheduled tasks.
7. Service templates.
8. Dynamic app previews.
9. Control API and contexts.
10. Server/operator UX.
11. Optional dashboard.

This order keeps Nagare pragmatic: first make individual apps and static sites pleasant, then add
stateful resources, then templates, then automation and UI. It also preserves the existing principle
that Nagare is a typed, Kubernetes-native personal PaaS rather than a clone of any one platform.


## Candidate MasterPlans to Create Next

The next useful planning artifacts would be:

1. **Application Lifecycle for Nagare**: app model, build modes, health checks, lifecycle CLI,
   deployment logs.
2. **Nagare Environment and Secret Management**: env scopes, `.env` sync, Kubernetes Secret/ConfigMap
   rendering, secret CLI.
3. **Stateful Resources for Nagare**: persistent volumes, Postgres, Redis, backups, restores.
4. **Scheduled Tasks and Service Templates**: CronJobs, one-off Jobs, curated service registry.
5. **Nagare Control Plane API**: `nagared`, contexts, auth, read-only API, mutation API.
