# Nagare / 流れ

> **Nagare / 流れ** means "flow." The name fits because the platform is designed
> around flows: code flows into deployments, traffic flows through Envoy/Kourier
> into Knative services, and telemetry flows into the Victoria observability
> stack. The goal is to make deploying and operating personal projects feel
> smooth, lightweight, and continuous.

Nagare is a cheap, single-node **personal PaaS** that runs on one GCP Compute
Engine instance. It lets you deploy many small projects without thinking about
servers, while staying simple enough to rebuild the entire system from scratch.

> **Status:** Early/spec stage. This repository currently contains the design
> spec ([`docs/initial-spec.md`](docs/initial-spec.md)); implementation has not
> started yet.

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
| **Cloud** | GCP Compute Engine, static IP, Cloud DNS, GCS backups — managed with [Pulumi](https://www.pulumi.com/) |
| **Host** | [NixOS](https://nixos.org/) — users, SSH, firewall, disks, Tailscale, sops-nix, backups |
| **Cluster** | [k3s](https://k3s.io/) (Traefik/servicelb disabled) |
| **Apps** | Knative Serving, scale-to-zero web services |
| **Ingress** | [Kourier](https://github.com/knative-extensions/net-kourier) / Envoy |
| **TLS** | cert-manager + Let's Encrypt, or host-level Caddy |
| **Observability** | [VictoriaMetrics](https://victoriametrics.com/), VictoriaLogs, VictoriaTraces, OpenTelemetry Collector |
| **Dashboards** | [Grafana](https://grafana.com/) |
| **Data** | SQLite + Litestream → GCS; host Postgres or Cloud SQL for important shared state |

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
```

Three flows define the system:

- **Code → deployments.** `nagarectl deploy` turns a repo into a running Knative service.
- **Traffic → services.** Requests flow through Envoy/Kourier into scale-to-zero Knative services.
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

Each app repo provides a `Dockerfile` and a `nagare.yaml`:

```yaml
name: notes
namespace: personal
image: us-docker.pkg.dev/my-project/nagare/notes
domain: notes.example.com

env:
  DATABASE_URL:
    secretRef: notes-db-url

resources:
  cpu: 250m
  memory: 512Mi

scale:
  min: 0
  max: 3
```

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
    observability/     # victoria-metrics / -logs / -traces, otel-collector, grafana
    examples/          # hello-knative-service
  cli/nagarectl/       # the deploy CLI
```

## Implementation phases

1. Provision GCP infrastructure with Pulumi.
2. Boot NixOS with k3s.
3. Install Knative Serving and Kourier.
4. Configure wildcard DNS and TLS.
5. Install VictoriaMetrics + Grafana.
6. Install VictoriaLogs.
7. Install VictoriaTraces + OpenTelemetry Collector.
8. Build `nagarectl deploy`.
9. Add backups (Litestream, sops, dashboards in Git).

The **MVP** is done when Pulumi provisions the VM, NixOS boots with k3s, Knative
+ Kourier are running, DNS and TLS work, a hello-world service deploys, the
Victoria stack collects metrics/logs/traces visible in Grafana, `nagarectl` can
deploy an app from `nagare.yaml`, and important data is backed up.

## Philosophy

The machine should be **disposable** — recovery is `pulumi up`,
`nixos-rebuild switch`, bootstrap the cluster, restore data, deploy apps. The
platform is successful if rebuilding it is boring.

Optimize for: **cheap, rebuildable, simple, observable, fun to use.**

## Non-goals (v1)

Multi-node Kubernetes, Istio / full service mesh, Argo CD, Flux, Crossplane,
External Secrets Operator, complex autoscaling, multi-tenant auth, running every
database inside Kubernetes, huge observability retention, production-grade HA.

---

See [`docs/initial-spec.md`](docs/initial-spec.md) for the full design spec.
