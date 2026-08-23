# Nagare / 流れ

> **Nagare / 流れ** means "flow." The name fits because the platform is designed
> around flows: code flows into deployments, traffic flows through Envoy/Kourier
> into Knative services, and telemetry flows into the Victoria observability
> stack. The goal is to make deploying and operating personal projects feel
> smooth, lightweight, and continuous.

Nagare is a cheap, single-node **personal PaaS** that runs on one GCP Compute
Engine instance. It lets you deploy many small projects without thinking about
servers, while staying simple enough to rebuild the entire system from scratch.

> **Status:** Active personal-PaaS implementation. The cloud path provisions a
> single GCP/NixOS/k3s host; local mode can now run the app platform on k3d with a
> local registry and MinIO backup backend. Current operator docs start at
> [`docs/user/README.md`](docs/user/README.md), goal-oriented walkthroughs start
> at [`docs/guides/README.md`](docs/guides/README.md), and the full design
> rationale is in [`docs/initial-spec.md`](docs/initial-spec.md).

---

## What it is

One personal project = one [Knative](https://knative.dev/) Service. A small CLI,
`nagarectl`, hides the Kubernetes details so deploying an app is a single
command:

```bash
nagarectl deploy
```

Under the hood that builds the image, pushes it, renders and applies a Knative
Service, wires up secrets and domains, waits for readiness, and prints the URL.

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
| **Data** | PVC-backed app volumes, managed Postgres/Redis/ClickHouse, Redpanda brokers, GCS or MinIO backups |

The Victoria stack replaces Prometheus + Loki + Tempo because it has lower
operational overhead and memory usage — a better fit for a cheap single-node
box where the goal is "enough visibility to debug personal projects" rather than
a production observability platform.

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

Three flows define the system:

- **Code → deployments.** `nagarectl deploy` turns a repo into a running Knative service; `nagarectl app deploy` can roll out a service, workers, databases, and tasks together.
- **Traffic → services.** Requests flow through Envoy/Kourier into scale-to-zero Knative services.
- **Data → object store.** Database backups and volume snapshots go to GCS in cloud mode or MinIO in local mode.
- **Telemetry → Grafana.** Metrics, logs, and traces flow into the Victoria stack and surface in Grafana.

## Ownership boundaries

The design keeps a clean separation of concerns:

```text
Pulumi owns cloud resources.
NixOS owns the host.
k3s owns the cluster.
Knative owns app deployment.
Victoria stack owns observability.
Grafana owns visibility.
nagarectl owns the developer experience.
```

Raw Kubernetes is intentionally *not* the deployment interface.

## Recommended GCP instance

```text
Machine type: e2-standard-2 or e2-standard-4
RAM: preferably 8GB (4GB minimum, but tight)
Boot disk: 30–50GB
Data disk: 100–200GB balanced persistent disk
```

## Deploying an app

Each app repo provides a build mode (Dockerfile, Nixpacks, or prebuilt image) and a typed, compile-checked
`nagare/Config.hs` (the config-as-program substrate — no YAML). It imports the
`nagare-dsl` library and binds a top-level `Deployment` value through
maximal-safety smart constructors, so a non-DNS name, a `max < min` scale, a
malformed CPU/memory quantity, or an env var that is both a literal and a secret
reference is a compile-time error rather than a silent cluster rejection:

```haskell
module Main (main) where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types

deployment :: Either String Deployment
deployment = do
  name' <- first show (mkServiceName "notes")
  ns' <- first show (mkNamespace "personal")
  img' <- first show (mkImageRef "notes")
  dom' <- first show (mkDomain "notes.example.com")
  port' <- first show (mkPort 8080)
  dbUrl <- first show (mkEnvName "DATABASE_URL")
  secret <- first show (mkSecretName "notes-db-url")
  sc <- first show (mkScale 0 3)
  cpuQ <- first show (mkQuantity "250m")
  memQ <- first show (mkQuantity "512Mi")
  Right
    Deployment
      { name = name', namespace = ns', image = img', domain = Just dom'
      , port = port', env = Map.singleton dbUrl (EnvSecretRef secret)
      , resources = Just Resources {cpu = Just cpuQ, memory = Just memQ}
      , scale = Just sc
      }

main :: IO ()
main = either (ioError . userError) emitDeployment deployment
```

`nagarectl deploy` compiles-and-runs that file to obtain the validated
`Deployment`, qualifies short image names through the active target profile,
renders the Knative manifests, and applies them. (The former
untyped `nagare.yaml` contract was replaced by this typed DSL; see
`docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md`.)

Apps get automatic internal domains (`service.namespace.apps.example.com`) via
wildcard DNS, and optional public domains (`notes.example.com`) via Knative
DomainMapping.

## Repository layout

```text
nagare/
  flake.nix
  justfile
  infra/pulumi/        # GCP resources (VM, IP, DNS, disks, IAM, backups)
  nixos/hosts/         # NixOS host config for nagare-01
  cluster/
    bootstrap/         # cert-manager, knative-serving, kourier, config-domain
    local/             # local-only MinIO and local-mode support manifests
    observability/     # victoria-metrics / -logs / -traces, otel-collector, grafana
    examples/          # app, site, database, broker, worker, and task examples
  cli/nagarectl/       # deploy and operations CLI
  cli/nagare-dsl/      # typed config DSL and manifest renderers
  cli/nagare-access/   # shared forward-auth enforcer for protected apps
```

## Current capabilities

- Bring your own GCP project with `nagarectl init`, then provision the cloud
  perimeter with Pulumi.
- Boot or update the NixOS/k3s host, bootstrap Knative/Kourier/cert-manager, and
  install the Victoria observability stack.
- Run the platform locally with `just local-up`, `just local-bootstrap`, and
  `just local-minio`.
- Deploy Knative apps from typed `nagare/Config.hs` configs using prebuilt,
  Dockerfile, or Nixpacks build modes.
- Operate app env/secrets, app lifecycle, static/full-stack sites, CDN plans,
  persistent volumes, managed databases, scheduled tasks, workers, Redpanda
  brokers, and identity-aware access through `nagarectl`.
- Back up managed databases and app volumes to GCS in cloud mode or MinIO in
  local mode, with scratch-first restore commands.

## Philosophy

The machine should be **disposable** — cloud recovery is `pulumi up`,
`nixos-rebuild switch`, bootstrap the cluster, restore data, deploy apps. Local
mode keeps that same operational shape on a laptop so core paths can be tested
without a cloud bill.

Optimize for: **cheap, rebuildable, simple, observable, fun to use.**

## Non-goals (v1)

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
to run Nagare locally. Planning status, standalone plans, retired successors,
and cross-project lineage are indexed in
[`docs/plan-registry.md`](docs/plan-registry.md).
