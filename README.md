# Nagare / 流れ

> **Nagare / 流れ** means "flow." The name fits because the platform is designed
> around flows: code flows into deployments, traffic flows through Envoy/Kourier
> into Knative services, and telemetry flows into the Victoria observability
> stack. The goal is to make deploying and operating many small services feel
> smooth, lightweight, and continuous.

Nagare is a cheap, single-node **PaaS** that runs on one GCP Compute Engine
instance. It began as a personal PaaS and now also runs a small team's workplace
**intranet**. It lets you deploy many small projects without thinking about
servers, while staying simple enough to rebuild the entire system from scratch.

## Status

The current release is [**Nagare 0.9.0**](https://github.com/shinzui/nagare/releases/tag/v0.9.0)
([release notes](docs/releases/v0.9.0.md)), and the work intranet runs on it. An app database can
declare privileges inside its own databases, such as `CREATE` in PGMQ's schema, and name the
workloads that run its migrations, and a ClickHouse server restart no longer blocks its app
databases' reviews. [0.8.0](docs/releases/v0.8.0.md) added reviewed grant exceptions and limits, a
maintenance window for one app with an on-demand backup, and read-only reader users that other apps
bind. Notes for every earlier release are in [`docs/releases/`](docs/releases/).

- Every capability is still `experimental`; the shipped surface is cataloged in
  [`docs/capabilities/`](docs/capabilities/index.md).
- The [production readiness checklist](docs/releases/production-readiness-checklist.md) records the
  recovery and upgrade drills behind each release.
- Nagare is operated by one person at a time. Multi-operator coordination is planned in
  [MasterPlan 24](docs/masterplans/24-operate-nagare-as-a-team-run-workplace-intranet-paas.md).

Operator docs start at [`docs/user/README.md`](docs/user/README.md), goal-oriented walkthroughs at
[`docs/guides/README.md`](docs/guides/README.md), and the original design rationale is in the
[initial spec](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/initial-spec.md).

---

## What it is

An application can combine a [Knative](https://knative.dev/) web Service,
workers, scheduled tasks, and managed data resources. The `nagarectl` CLI
compiles typed Haskell declarations into independently revisioned ownership
scopes, checks them against the context's inventory, and executes reviewed
changes through native tools.

Once an image publication is accepted, a standard single-Service deployment
can review and apply its change in one command:

```bash
nagarectl deploy --file nagare/Config.hs \
  --tag "$TAG" --image-resource "$IMAGE_RESOURCE_ID"
```

Image building and reviewed publication happen before deployment. Use
`--save-plan DIR` to inspect a saved review before applying it. The durable
journal lets interrupted execution resume from proven completion evidence.
See [Deploying an app](#deploying-an-app) below for the publication workflow.

## The stack

| Layer | Choice |
| --- | --- |
| **Cloud** | GCP Compute Engine, static IP, Cloud DNS, Artifact Registry, GCS backups — managed with [Pulumi](https://www.pulumi.com/) |
| **Local dev** | [k3d](https://k3d.io/) cluster, local registry, loopback app domain, MinIO object store |
| **Host** | [NixOS](https://nixos.org/) — users, SSH, firewall, disks, Tailscale, sops-nix, backups |
| **Cluster** | [k3s](https://k3s.io/) (Traefik disabled; built-in ServiceLB kept for Kourier) |
| **Apps** | Knative Serving web services, static/full-stack sites, workers, scheduled tasks |
| **Ingress** | [Kourier](https://github.com/knative-extensions/net-kourier) / Envoy |
| **TLS** | cert-manager + Let's Encrypt (wildcard via DNS-01) |
| **Observability** | [VictoriaMetrics](https://victoriametrics.com/), VictoriaLogs, VictoriaTraces, OpenTelemetry Collector |
| **Dashboards** | [Grafana](https://grafana.com/) |
| **Data** | PVC-backed app volumes, managed Postgres/Redis/ClickHouse (dedicated or shared between apps), Redpanda brokers, optional in-cluster Attic, GCS or MinIO backups |

The Victoria stack replaces Prometheus + Loki + Tempo because it has lower
operational overhead and memory usage — a better fit for a cheap single-node
box where the goal is "enough visibility to debug the services it runs" rather
than a large-scale production observability platform.

## Architecture

```text
GCP
  └── Compute Engine VM
        └── NixOS
              ├── k3s
              │    ├── Knative Serving
              │    ├── Kourier / Envoy
              │    ├── cert-manager
              │    ├── VictoriaMetrics
              │    ├── VictoriaLogs
              │    ├── VictoriaTraces
              │    ├── OpenTelemetry Collector
              │    └── Grafana
              │
              ├── Tailscale / SSH
              ├── sops-nix
              ├── backup tooling
              └── mounted persistent data disk

Local mode
  └── Docker
        └── k3d / k3s
              ├── local registry
              ├── Knative Serving + Kourier
              ├── local-path storage
              └── MinIO backup store
```

Four flows define the system:

- **Code → deployments.** Build an image, publish it through a review, then deploy its accepted image resource. `nagarectl app deploy` can roll out a service, workers, databases, and tasks together.
- **Traffic → services.** Requests flow through Envoy/Kourier into scale-to-zero Knative services.
- **Data → object store.** Database backups and volume snapshots go to GCS in cloud mode or MinIO in local mode.
- **Telemetry → Grafana.** Metrics, logs, and traces flow into the Victoria stack and surface in Grafana.

## Ownership boundaries

Each context has one composed inventory of cloud, host, cluster, data,
credential, artifact, and release resources. Platform components and
applications own independent scopes; updating one preserves the others.
Composition rejects conflicting resource claims and unauthorized contributions
to shared platform objects before mutation.

Pulumi manages cloud resources, NixOS configures the host, and Kubernetes,
Knative, and Helm reconcile cluster workloads. Nagare coordinates their
ownership, dependencies, review, and execution history through `nagarectl`.
Desired declarations, live observations, and the operation ledger remain
separate. Raw Kubernetes is not the application deployment interface.

Local contexts keep private filesystem history; cloud contexts use shared GCS
history with conditional writes and an explicit single-writer claim. Retirement
retains resources; physical collection requires a separate eligible review.
Data is retained by default. See
[Resource inventory and operation ledger](docs/user/resource-inventory.md) for
identity, drift, status, and recovery semantics.

## Install a pinned release

Nix builds `nagarectl` together with the GHC runtime required to load an app's
typed `nagare/Config.hs`; no Cabal package environment or Nagare checkout is
needed. Select a reviewed release explicitly:

```bash
export NAGARE_VERSION=0.9.0
nix run "github:shinzui/nagare/v${NAGARE_VERSION}#nagarectl" -- version
nix profile install "github:shinzui/nagare/v${NAGARE_VERSION}#nagarectl"
```

For a multi-workload `Application` config, validation needs no context or
provider access:

```bash
nagarectl app check --file nagare/Config.hs
```

Platform operators install the full `nagare` package instead. Its `nagare`
launcher runs Pulumi, NixOS, bootstrap, and other recipes from the matching
immutable payload while keeping contexts and generated host configuration under
the user's XDG directories:

```bash
nix profile install "github:shinzui/nagare/v${NAGARE_VERSION}#nagare"
nagare --list
```

See [Installing Nagare](docs/user/installation.md) for temporary, persistent,
operator, and contributor workflows.

## Upgrade an installed context

Changing the workstation package does not move a context. With the new release installed and the
context selected, move it through a reviewed transition. A release's `transitionsFrom` (in
[`release.json`](release.json)) lists the releases it accepts; 0.9.0 accepts 0.4.0, 0.5.0, and
0.6.1 through 0.8.0.

```bash
nagarectl inventory status --json          # no active transaction
nagarectl platform transition plan --out transition-1
nagarectl inventory apply transition-1 --yes
# plan and apply again in a new directory until the review has no operations
nagarectl platform transition commit --yes
nagarectl platform status
```

A stopped stage keeps the transition open; resume, recover, or close it with the new release's
`nagarectl`. Each release's notes list the config changes it needs. See
[Upgrades](docs/user/upgrades.md) for node (NixOS/k3s) and PostgreSQL major upgrades.

## Recommended GCP instance

```text
Machine type: e2-standard-2 or e2-standard-4
RAM: preferably 8GB (4GB minimum, but tight)
Boot disk: 30–50GB
Data disk: 100–200GB balanced persistent disk
```

## Deploying an app

Each app repo provides a typed `nagare/Config.hs` using `nagare-dsl`: a
`Deployment` for a single web Service or an `Application` for multiple workloads.
Haskell checks the types, smart constructors validate field values, and the
loader checks the whole configuration before provider mutation. For example,
this preset creates a small stateless Service in the `personal` namespace:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment)

deployment :: Either String Deployment
deployment = first show (webService "notes" "notes")

main :: IO ()
main = either (ioError . userError) emitDeployment deployment
```

Select an initialized context and build the image separately with Dockerfile,
Nixpacks, or another builder. For the config above, set `REGISTRY` to that
context's registry prefix so `notes:v1` resolves to the publication destination.
Export and publish the built image through a review:

```bash
export IMAGE_REF="${REGISTRY}/notes:v1"
docker save "$IMAGE_REF" -o "$PWD/notes-v1.tar"
nagarectl app image-plan --archive "$PWD/notes-v1.tar" \
  --destination "$IMAGE_REF" --key notes-v1 --save-plan image-review
cat image-review/review.json
nagarectl inventory apply image-review --yes
```

Keep the archive at the same absolute path until publication completes. Copy
the image resource ID printed by `image-plan` into `IMAGE_RESOURCE_ID`, then
save, inspect, and apply the Service review:

```bash
nagarectl deploy --file nagare/Config.hs --tag v1 \
  --image-resource "$IMAGE_RESOURCE_ID" --save-plan service-review
cat service-review/review.json
nagarectl inventory apply service-review --yes
nagarectl inventory status --json
```

Deployment uses the accepted publication and does not rebuild the source tree.
A deployment `--dry-run` also needs the accepted image and context inventory;
it prints the public resource scope. Use `nagarectl app deploy` with an
`Application` config for multiple workloads. See
[Build modes](docs/user/build-modes.md) and
[Deploying apps](docs/user/deploying-apps.md) for build inputs, data recovery
bindings, hooks, and protected routes.

Apps get automatic internal domains (`service.namespace.apps.example.com`) via
wildcard DNS, and optional public domains (`notes.example.com`) via Knative
DomainMapping.

## Repository layout

```text
nagare/
  flake.nix             # flake-parts entry point and shared input pins
  flake.lock
  nix/                  # package, app, shell, Hydra, and source modules
    checks/             # checks grouped by domain, with extracted scripts
  justfile
  infra/pulumi/        # GCP resources (VM, IP, DNS, disks, IAM, backups)
  nixos/hosts/         # NixOS host config for nagare-01
  cluster/
    bootstrap/         # cert-manager, knative-serving, kourier, config-domain
    local/             # local-only MinIO and local-mode support manifests
    observability/     # victoria-metrics / -logs / -traces, otel-collector, grafana
    examples/          # app, site, database, broker, worker, and task examples
  cli/nagarectl/          # deploy and operations CLI
  cli/nagare-dsl/         # typed config DSL and manifest renderers
  cli/nagare-access/      # shared forward-auth enforcer for protected apps
  cli/nagare-contract/    # versioned JSON document contract for CLI output
  cli/nagare-api/         # route types and OpenAPI document of the admin API
  cli/nagare-api-server/  # read-only admin API server
  cli/nagare-harness/     # local gate and acceptance harness
```

## Current capabilities

The evidence-backed catalog at [`docs/capabilities/`](docs/capabilities/index.md) records the
shipped surface with stable `CAP-N` handles, compatibility promises, interfaces, and verifiable
source, test, example, and guide evidence. The summary below is the short orientation.

The [terminology catalog](docs/terminology/index.md) defines Nagare's platform, workload,
data, and operations vocabulary with stable `TERM-N` handles.

- Bring your own GCP project with `nagarectl init`, then provision the cloud
  perimeter through context-bound Pulumi reviews.
- Boot or update the NixOS/k3s host, bootstrap Knative/Kourier/cert-manager, and
  install the Victoria observability stack.
- Run the platform locally with `nagare local-up`, `nagare local-bootstrap`, and
  `nagare local-minio`.
- Publish images built with Dockerfile, Nixpacks, or another builder, then deploy
  accepted publications from typed `nagare/Config.hs` configs.
- Inspect resource ownership, dependencies, drift, health, and retained members;
  apply saved reviews and resume or close stopped transactions through the
  inventory ledger.
- Operate app env/secrets, app lifecycle, static/full-stack sites, CDN plans,
  persistent volumes, managed databases, scheduled tasks, workers, Redpanda
  brokers, and identity-aware access through `nagarectl`.
- Let many apps share one PostgreSQL or ClickHouse server, each with its own
  databases, users, grants, credentials, and backups; declare reviewed grant
  exceptions and limits, read-only readers that other apps bind, and a
  maintenance window that quiesces one app without touching the others.
- Back up managed databases and app volumes to GCS in cloud mode or MinIO in
  local mode, on a schedule, with signed receipts and isolated restores.
  Freshness is graded against an hourly or daily recovery-point objective.
  Scheduled runs are kept for 48 hours, then one a day for 30 days, and pruned
  through review; the newest verified run is always kept.
- Rebuild a lost database or volume as a new incarnation from its verified
  recovery point.
- Protect any deploy or site behind passkey login over HTTPS, grant or revoke a
  user's or team's access by email through review, and check one user's access.
- Serve a context's recorded state through an optional read-only admin API behind
  login; CLI JSON output follows a versioned contract.
- Move an installed context to a newer release through a reviewed, resumable
  transition.
- Apply reviewed, self-reverting NixOS/k3s host changes and follow the rehearsed
  side-by-side PostgreSQL major-upgrade procedure.

## Philosophy

The machine should be **disposable**. Rebuildable declarations, off-cluster
backups, escrowed recovery credentials, and durable history make recovery
reviewable. MP-23 proved isolated data recovery after cluster loss, and 0.5.0
rebuilds a lost database or volume from its recovery point. A timed rebuild of a
whole installation in service ([ADR 28](docs/adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md)'s
four-hour objective) is not yet proven. Follow the
[backup and recovery procedures](docs/user/backups-and-disaster-recovery.md)
and [production readiness checklist](docs/releases/production-readiness-checklist.md).
Local mode keeps the same operational shape on a laptop so core paths can be
tested without a cloud bill.

Optimize for: **cheap, rebuildable, simple, observable, fun to use.**

## Non-goals

Full-context physical collection, live database/PVC overwrite, and interactive
mutating maintenance sessions are outside the inventory contract. Each release's
notes list its known limits; see [0.9.0's](docs/releases/v0.9.0.md#known-limitations).

Multi-node Kubernetes, Istio / full service mesh, Argo CD, Flux, Crossplane,
External Secrets Operator, complex autoscaling, multi-tenant auth, huge
observability retention, and production-grade HA. (Nagare does run single-replica
managed databases in-cluster — Postgres/Redis/ClickHouse via `nagarectl db`, see
[`docs/user/managed-databases.md`](docs/user/managed-databases.md) — but
**replicated/HA databases are out of scope**; use Cloud SQL / Neon / Supabase for
those.)

---

Start with [`docs/user/README.md`](docs/user/README.md) for the operator manual,
[`docs/guides/README.md`](docs/guides/README.md) for end-to-end operating
patterns, or [`docs/user/local-development.md`](docs/user/local-development.md)
to run Nagare locally. Execution plans live in [`docs/plans/`](docs/plans/), and
coordinated initiatives keep their child-plan status in
[`docs/masterplans/`](docs/masterplans/).
