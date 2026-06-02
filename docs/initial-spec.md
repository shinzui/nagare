# Nagare: Personal PaaS on GCP with NixOS, k3s, Knative, Envoy, Victoria Stack, and Grafana

## Project Name

**Nagare** / **流れ**

Meaning: “flow.”

Why it fits:

* Traffic flows through Envoy/Kourier.
* Deployments flow from local projects into Knative services.
* Metrics, logs, and traces flow into the Victoria observability stack.
* The project is a lightweight personal platform for running many small services.

Suggested naming:

```text
Repository: nagare
Host: nagare-01
CLI: nagarectl
Domain: apps.example.com
```

---

# Goal

Build a cheap single-node personal PaaS on one GCP Compute Engine instance.

The stack should support:

* Deploying many personal projects cheaply.
* Running mostly scale-to-zero web services.
* Managing the machine declaratively with NixOS.
* Managing cloud resources with Pulumi.
* Running applications on k3s.
* Using Knative Serving for serverless-style deployments.
* Using Kourier / Envoy for Knative ingress.
* Using the Victoria stack instead of Prometheus, Loki, and Tempo.
* Using Grafana as the observability UI.
* Keeping the system simple enough to rebuild from scratch.

---

# High-Level Architecture

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

---

# Core Design Principle

Do not expose raw Kubernetes as the deployment interface.

The deployment unit should be:

```text
One personal project = one Knative Service
```

A small CLI, `nagarectl`, should hide the Kubernetes details.

Example:

```bash
nagarectl deploy
```

Under the hood, it should:

1. Build the container image.
2. Push the image.
3. Render a Knative Service.
4. Apply secrets/config.
5. Apply a DomainMapping if needed.
6. Wait until the service is ready.
7. Print the service URL.

---

# Final Stack

## Cloud

```text
GCP Compute Engine
Static external IP
Cloud DNS
GCS backup bucket
Dedicated service account
GCP firewall rules
Persistent data disk
```

## Host

```text
NixOS
k3s
Tailscale
OpenSSH
sops-nix
backup tools
local persistent disk mounts
```

## Runtime

```text
k3s
Knative Serving
Kourier / Envoy
cert-manager
```

## Observability

```text
VictoriaMetrics single-node
VMAgent
VMAlert, optional
VictoriaLogs single-node
VictoriaLogs collector
VictoriaTraces single-node
OpenTelemetry Collector
Grafana
```

## Data

```text
SQLite + Litestream for small apps
Host Postgres or Cloud SQL for important shared state
GCS for backups
```

---

# Why Victoria Stack Instead of Prometheus, Loki, and Tempo

VictoriaMetrics, VictoriaLogs, and VictoriaTraces are a better fit for a cheap single-node personal platform.

Reasons:

* Lower operational overhead.
* Lower memory usage.
* Good single-node story.
* Grafana-compatible.
* Prometheus-compatible metrics querying.
* Simple deployment model.
* Better fit for limited retention and personal projects.

The goal is not to build a huge production observability platform. The goal is to have enough visibility to debug personal projects without wasting RAM and disk.

---

# Recommended GCP Instance

Start with:

```text
Machine type: e2-standard-2 or e2-standard-4
RAM: preferably 8GB
Boot disk: 30–50GB
Data disk: 100–200GB balanced persistent disk
```

Minimum possible:

```text
2 vCPU / 4GB RAM
```

Recommended starting point:

```text
2 vCPU / 8GB RAM
```

Reason:

Knative, k3s, Grafana, VictoriaMetrics, VictoriaLogs, VictoriaTraces, cert-manager, and several services can get tight on 4GB.

---

# Pulumi Responsibilities

Pulumi should own the cloud perimeter.

Pulumi manages:

```text
GCP project config
VPC or default network
Static external IP
Compute Engine instance
Firewall rules
Cloud DNS records
Service account
IAM bindings
Persistent disk
GCS backup bucket
Pulumi stack outputs
```

Pulumi should output:

```text
publicIp
sshCommand
baseDomain
instanceName
serviceAccountEmail
dataDiskName
```

Suggested Pulumi layout:

```text
infra/
  pulumi/
    Pulumi.yaml
    Pulumi.dev.yaml
    package.json
    src/
      index.ts
      instance.ts
      firewall.ts
      dns.ts
      disks.ts
      service-account.ts
      outputs.ts
```

---

# NixOS Responsibilities

NixOS should own the machine.

NixOS manages:

```text
Users
SSH
Firewall
k3s service
Mounted disks
Base packages
Tailscale
sops-nix
Backup utilities
Host security hardening
```

NixOS should not own every Kubernetes object. Keep the boundary clean:

```text
NixOS owns the node.
Kubernetes/Helm owns the cluster workloads.
Pulumi owns GCP resources.
```

Suggested NixOS layout:

```text
nixos/
  hosts/
    nagare-01/
      configuration.nix
      hardware-configuration.nix
      k3s.nix
      networking.nix
      storage.nix
      users.nix
      security.nix
      tailscale.nix
```

---

# k3s Configuration

Use k3s as the lightweight Kubernetes distribution.

Disable Traefik because Knative/Kourier should own ingress.

Suggested k3s config:

```nix
services.k3s = {
  enable = true;
  role = "server";
  extraFlags = toString [
    "--disable=traefik"
    "--disable=servicelb"
    "--write-kubeconfig-mode=0644"
  ];
};
```

Start simple:

```text
Use containerd
Use flannel
Use single-node control plane
Avoid custom CNI at first
Avoid service mesh at first
```

---

# Knative and Ingress

Use:

```text
Knative Serving
Kourier / Envoy
```

Kourier is the lightweight Knative ingress layer backed by Envoy.

Prefer:

```text
Knative Serving + Kourier
```

Instead of:

```text
Knative Serving + raw custom Envoy config
```

Reason:

Kourier already handles the Knative routing model. Raw Envoy gives more control but creates more work.

---

# DNS Model

Use one wildcard domain for automatic app domains.

Example:

```text
*.apps.example.com -> static GCP IP
```

Then Knative can generate service URLs like:

```text
notes.default.apps.example.com
wiki.default.apps.example.com
search.default.apps.example.com
```

For nicer public domains, use Knative DomainMapping:

```text
notes.example.com -> notes.default.apps.example.com
wiki.example.com -> wiki.default.apps.example.com
```

Two-level domain model:

```text
Automatic internal app domains:
  service.namespace.apps.example.com

Manual public domains:
  notes.example.com
  wiki.example.com
  photos.example.com
```

---

# TLS Strategy

There are two good options.

## Option 1: Kubernetes-native TLS

Use:

```text
cert-manager
Knative/Kourier TLS configuration
Let's Encrypt
```

Pros:

* More Kubernetes-native.
* Cleaner long-term setup.

Cons:

* More moving parts.

## Option 2: Host-level Caddy in front of Kourier

Use:

```text
Internet
  -> Caddy on host :443
  -> Kourier NodePort HTTP
  -> Knative Service
```

Pros:

* Very simple.
* Caddy handles Let’s Encrypt well.
* Nice for single-node personal infra.

Cons:

* Less Kubernetes-native.
* More host-level ingress wiring.

Recommended v1:

```text
Start with Caddy if you want the fastest reliable TLS.
Move to cert-manager-only later if needed.
```

---

# Observability Architecture

```text
Applications
  ├── Metrics
  │     └── VMAgent / Prometheus scrape
  │           └── VictoriaMetrics
  │
  ├── Logs
  │     └── VictoriaLogs collector
  │           └── VictoriaLogs
  │
  └── Traces
        └── OpenTelemetry Collector
              └── VictoriaTraces

Grafana
  ├── VictoriaMetrics datasource
  ├── VictoriaLogs datasource/plugin
  └── VictoriaTraces via Jaeger-compatible datasource
```

---

# Metrics

Use:

```text
VictoriaMetrics single-node
VMAgent
kube-state-metrics
node-exporter
VMAlert, optional
```

Recommended Helm chart:

```text
victoria-metrics-k8s-stack
```

Install:

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update

helm upgrade --install vmks vm/victoria-metrics-k8s-stack \
  --namespace monitoring \
  --create-namespace \
  -f cluster/observability/victoria-metrics/values.yaml
```

Suggested values:

```yaml
vmsingle:
  enabled: true
  spec:
    retentionPeriod: "30d"
    storage:
      resources:
        requests:
          storage: 20Gi

vmcluster:
  enabled: false

grafana:
  enabled: true

prometheus-node-exporter:
  enabled: true

kube-state-metrics:
  enabled: true

alertmanager:
  enabled: false
```

Recommended metrics retention:

```text
30 days
```

---

# Logs

Use:

```text
VictoriaLogs single-node
VictoriaLogs collector
```

Install:

```bash
helm upgrade --install victoria-logs vm/victoria-logs-single \
  --namespace logging \
  --create-namespace \
  -f cluster/observability/victoria-logs/values.yaml

helm upgrade --install victoria-logs-collector vm/victoria-logs-collector \
  --namespace logging \
  -f cluster/observability/victoria-logs/collector-values.yaml
```

Suggested starting config:

```yaml
server:
  retentionPeriod: 7d
  persistentVolume:
    size: 20Gi
```

Recommended logs retention:

```text
7 days
```

Reason:

Logs grow faster than metrics. Start small and increase only if needed.

---

# Traces

Use:

```text
VictoriaTraces single-node
OpenTelemetry Collector
```

Flow:

```text
App
  -> OTLP gRPC or HTTP
  -> OpenTelemetry Collector
  -> VictoriaTraces
  -> Grafana
```

Recommended ports:

```text
OTLP gRPC: 4317
OTLP HTTP: 4318
VictoriaTraces query: 10428
```

Recommended trace retention:

```text
3–7 days
```

Reason:

Traces can grow quickly, especially if every small request emits spans.

---

# Grafana

Grafana should be installed by the VictoriaMetrics k8s stack or deployed separately.

Datasources:

```text
VictoriaMetrics:
  type: prometheus
  url: http://vmsingle-vmks-victoria-metrics-k8s-stack.monitoring.svc:8429

VictoriaLogs:
  type: VictoriaLogs datasource/plugin
  url: http://victoria-logs.logging.svc:9428

VictoriaTraces:
  type: Jaeger datasource
  url: http://victoria-traces.tracing.svc:10428/select/jaeger
```

Optional later:

```text
VictoriaTraces via Tempo-compatible datasource
```

But use the Jaeger-compatible path first because it is the safer initial integration.

---

# OpenTelemetry Collector

For v1, use the collector primarily for traces.

Responsibilities:

```text
Receive OTLP traces from apps
Batch traces
Export traces to VictoriaTraces
```

Later, it can also handle:

```text
OTLP metrics
OTLP logs
Sampling
Attribute enrichment
Multi-destination export
```

Simple initial flow:

```text
VMAgent handles metrics.
VictoriaLogs collector handles container logs.
OpenTelemetry Collector handles traces.
```

This keeps responsibilities clean.

---

# Storage Layout

Use a separate persistent disk mounted on the host.

Example host layout:

```text
/var/lib/nagare
  /victoria-metrics
  /victoria-logs
  /victoria-traces
  /postgres
  /sqlite
  /backups
```

Inside k3s, use either:

```text
local-path-provisioner backed by the mounted disk
```

or:

```text
static local PersistentVolumes
```

Starting disk recommendation:

```text
Boot disk: 30–50GB
Data disk: 100–200GB
```

Starting retention:

```text
VictoriaMetrics: 30 days
VictoriaLogs: 7 days
VictoriaTraces: 3–7 days
```

---

# Application Deployment Model

Each app repo should provide:

```text
Dockerfile
nagare.yaml
```

Example `nagare.yaml`:

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

`nagarectl deploy` should:

```text
Build image
Push image
Render Knative Service
Apply Kubernetes secrets/config refs
Apply DomainMapping
Wait for Ready condition
Print final URL
```

Example generated Knative Service:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: notes
  namespace: personal
spec:
  template:
    spec:
      containers:
        - image: us-docker.pkg.dev/my-project/nagare/notes:latest
          ports:
            - containerPort: 8080
```

---

# Secrets

Start simple.

Recommended v1:

```text
sops-nix for host secrets
sops + age for Kubernetes secrets
encrypted secrets committed to Git
```

Later option:

```text
External Secrets Operator + GCP Secret Manager
```

Do not start there unless needed. For personal infra, `sops` is simpler and easier to rebuild.

---

# Data Strategy

Use three tiers.

## Tier 1: Stateless Services

```text
Knative Service only
No persistent volume
Scale to zero
```

Best for:

```text
Small APIs
Web apps
Static-ish tools
Internal utilities
```

## Tier 2: Small Stateful Services

```text
SQLite
PVC or host-mounted path
Litestream backup to GCS
```

Best for:

```text
Personal apps
Small tools
Low-write workloads
Experiments
```

## Tier 3: Important Shared State

Use one of:

```text
Host Postgres with backups
Cloud SQL
Neon
Supabase
```

Best for:

```text
Important apps
Shared state
Higher write volume
Data you really do not want to lose
```

Avoid running a serious shared database inside Kubernetes at first unless backup and restore are already solved.

---

# Backup Strategy

The machine should be disposable.

Back up:

```text
NixOS config: Git
Pulumi infra: Git
Pulumi state: Pulumi Cloud or GCS backend
Kubernetes manifests: Git
Secrets: sops-encrypted in Git
SQLite: Litestream to GCS
Postgres: pg_dump or WAL archive to GCS
Victoria data: optional, usually not critical
Grafana dashboards: Git
```

Recovery should look like:

```text
pulumi up
nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01
bootstrap cluster
restore data
deploy apps
```

The platform is successful if rebuilding it is boring.

---

# Suggested Repository Layout

```text
nagare/
  README.md
  flake.nix
  justfile

  infra/
    pulumi/
      Pulumi.yaml
      Pulumi.dev.yaml
      package.json
      src/
        index.ts
        instance.ts
        firewall.ts
        dns.ts
        disks.ts
        service-account.ts
        outputs.ts

  nixos/
    hosts/
      nagare-01/
        configuration.nix
        hardware-configuration.nix
        k3s.nix
        networking.nix
        storage.nix
        security.nix
        users.nix
        tailscale.nix

  cluster/
    bootstrap/
      cert-manager/
      knative-serving/
      kourier/
      config-domain/

    observability/
      victoria-metrics/
        values.yaml
      victoria-logs/
        values.yaml
        collector-values.yaml
      victoria-traces/
        values.yaml
      opentelemetry-collector/
        values.yaml
      grafana/
        dashboards/
        datasources/

    examples/
      hello-knative-service/

  cli/
    nagarectl/
      package.json
      src/
        deploy.ts
        render.ts
        build.ts
        domain.ts
        secrets.ts
```

---

# Suggested `justfile`

```make
infra-up:
	cd infra/pulumi && pulumi up

infra-preview:
	cd infra/pulumi && pulumi preview

host-switch:
	nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01

cluster-bootstrap:
	kubectl apply -f cluster/bootstrap/cert-manager
	kubectl apply -f cluster/bootstrap/knative-serving
	kubectl apply -f cluster/bootstrap/kourier
	kubectl apply -f cluster/bootstrap/config-domain

observability:
	helm repo add vm https://victoriametrics.github.io/helm-charts/
	helm repo update

	helm upgrade --install vmks vm/victoria-metrics-k8s-stack \
	  --namespace monitoring \
	  --create-namespace \
	  -f cluster/observability/victoria-metrics/values.yaml

	helm upgrade --install victoria-logs vm/victoria-logs-single \
	  --namespace logging \
	  --create-namespace \
	  -f cluster/observability/victoria-logs/values.yaml

	helm upgrade --install victoria-logs-collector vm/victoria-logs-collector \
	  --namespace logging \
	  -f cluster/observability/victoria-logs/collector-values.yaml

	helm upgrade --install victoria-traces vm/victoria-traces-single \
	  --namespace tracing \
	  --create-namespace \
	  -f cluster/observability/victoria-traces/values.yaml

deploy-hello:
	kubectl apply -f cluster/examples/hello-knative-service

status:
	kubectl get pods -A
	kubectl get ksvc -A
```

---

# Implementation Order

## Phase 1: Provision GCP Infrastructure

Pulumi creates:

```text
GCP VM
Static IP
Firewall rules
Cloud DNS records
Service account
Persistent disk
GCS backup bucket
```

Success criteria:

```text
The VM exists.
The static IP is attached.
SSH or Tailscale access works.
DNS resolves to the static IP.
```

---

## Phase 2: Boot NixOS

Configure:

```text
Users
SSH
Firewall
Mounted data disk
Base packages
Tailscale
k3s
```

Success criteria:

```text
nixos-rebuild switch works.
k3s starts.
kubectl get nodes works.
```

---

## Phase 3: Install Knative Serving and Kourier

Install:

```text
Knative Serving
Kourier / Envoy
Knative config-domain
```

Success criteria:

```text
Knative Serving pods are healthy.
Kourier pods are healthy.
A sample Knative service deploys.
```

---

## Phase 4: Configure DNS and TLS

Configure:

```text
Wildcard DNS
Knative domain config
cert-manager or host-level Caddy
```

Success criteria:

```text
hello.default.apps.example.com resolves.
HTTPS works.
```

---

## Phase 5: Install VictoriaMetrics and Grafana

Install:

```text
victoria-metrics-k8s-stack
VMSingle
VMAgent
node-exporter
kube-state-metrics
Grafana
```

Success criteria:

```text
Grafana is accessible.
Node metrics are visible.
Kubernetes metrics are visible.
Knative service metrics are visible.
```

---

## Phase 6: Install VictoriaLogs

Install:

```text
VictoriaLogs single-node
VictoriaLogs collector
Grafana datasource/plugin
```

Success criteria:

```text
Container logs are searchable in Grafana.
Logs have namespace, pod, container, and app labels.
Retention is limited to 7 days.
```

---

## Phase 7: Install VictoriaTraces and OpenTelemetry Collector

Install:

```text
VictoriaTraces
OpenTelemetry Collector
Grafana Jaeger datasource
```

Success criteria:

```text
A test app emits OTLP traces.
Traces appear in Grafana.
Trace retention is limited to 3–7 days.
```

---

## Phase 8: Build `nagarectl deploy`

Implement:

```text
Read nagare.yaml
Build image
Push image
Render Knative Service
Apply service
Apply DomainMapping
Wait for readiness
Print URL
```

Success criteria:

```text
A new project can be deployed with one command.
The app gets a Knative URL.
The app can scale to zero.
Logs, metrics, and traces are visible.
```

---

## Phase 9: Add Backups

Add:

```text
GCS bucket
Litestream for SQLite apps
Postgres backup job if using Postgres
sops-encrypted secrets
Grafana dashboards in Git
```

Success criteria:

```text
Important data is backed up.
A restore procedure is documented.
The machine can be rebuilt from Git + backups.
```

---

# Open Questions

## TLS

Choose one:

```text
Option A: cert-manager + Knative/Kourier TLS
Option B: host-level Caddy in front of Kourier
```

Recommendation:

```text
Start with Caddy if speed and reliability matter more.
Use cert-manager-only if Kubernetes purity matters more.
```

## Database

Choose one:

```text
SQLite + Litestream
Host Postgres
Cloud SQL
```

Recommendation:

```text
SQLite + Litestream for most personal apps.
Cloud SQL or host Postgres only for important shared state.
```

## Grafana Exposure

Choose one:

```text
Public with auth
Tailscale-only
Basic auth through Caddy
```

Recommendation:

```text
Tailscale-only at first.
```

## Observability Retention

Starting values:

```text
Metrics: 30 days
Logs: 7 days
Traces: 3–7 days
```

Tune after watching disk usage.

---

# MVP Definition

The MVP is done when:

```text
Pulumi provisions the GCP VM.
NixOS boots with k3s.
Knative Serving and Kourier are installed.
Wildcard DNS works.
TLS works.
A hello-world Knative service deploys.
VictoriaMetrics collects node and Kubernetes metrics.
VictoriaLogs collects container logs.
VictoriaTraces receives test traces.
Grafana shows metrics, logs, and traces.
nagarectl can deploy one app from nagare.yaml.
Backups exist for important app data.
```

---

# Non-Goals for v1

Avoid these at first:

```text
Multi-node Kubernetes
Istio
Full service mesh
Argo CD
Flux
Crossplane
External Secrets Operator
Complex autoscaling policy
Multi-tenant auth
Running every database inside Kubernetes
Huge observability retention
Production-grade HA
```

This is personal infrastructure. Optimize for:

```text
Cheap
Rebuildable
Simple
Observable
Fun to use
```

---

# Guiding Philosophy

Nagare should feel like a tiny personal cloud.

It should let me deploy many small projects without thinking about servers, but it should still be understandable enough that I can rebuild the entire system from scratch.

The important boundary:

```text
Pulumi owns cloud resources.
NixOS owns the host.
k3s owns the cluster.
Knative owns app deployment.
Victoria stack owns observability.
Grafana owns visibility.
nagarectl owns the developer experience.
```

---

# Spec Accuracy Corrections (2026-06-02)

This appendix records corrections made to the spec above after fact-checking against current upstream
documentation, the authoritative `mori` project identity, the sibling `load-testing-infra` reference
repository, and explicit user decisions. The MasterPlan at
`docs/masterplans/1-bootstrap-nagare-personal-paas.md` and its child ExecPlans implement the corrected
behavior. Where the prose above conflicts with a correction here, the correction wins.

## Decisions that override the spec

* **`nagarectl` is written in Haskell, not TypeScript.** The "Suggested Repository Layout" and CLI
  section above show `cli/nagarectl/package.json` and `.ts` files; that is wrong. The authoritative
  `mori` identity declares `nagarectl` as a Haskell tool and the user confirmed it. The CLI is a Cabal
  project under `cli/nagarectl/` using Haskell libraries available in the local `mori` corpus:
  `optparse-applicative` (argument parsing), `aeson` + the `yaml` package (parse `nagare.yaml`),
  `brendanhay/gogol` (GCP / Artifact Registry), `codedownio/kubernetes-api` or shelling out to
  `kubectl` via `garnix-io/cradle` (apply Knative manifests), and optionally
  `iand675/hs-opentelemetry`.
* **TLS uses cert-manager + Kourier, not host-level Caddy.** The user chose the Kubernetes-native
  option. This has a hard consequence: a wildcard certificate for `*.apps.example.com` requires a
  Let's Encrypt **DNS-01** challenge (HTTP-01 cannot issue wildcards), so cert-manager needs a Google
  Cloud DNS solver authorized by `roles/dns.admin` on the VM's service account, and the wildcard is
  wired into Knative via the `net-certmanager` bridge with `external-domain-tls: Enabled`.
* **All cloud work targets the `tan-nb-exp` GCP project, region `us-west1`, zone `us-west1-a`.** The
  spec used `apps.example.com` / `my-project` placeholders with no fixed project. Per the user and the
  reference repo's isolation policy, every resource and every `gcloud`/`gsutil`/`pulumi` call targets
  `tan-nb-exp` only. The Artifact Registry path is therefore `us-west1-docker.pkg.dev/tan-nb-exp/nagare`,
  not `us-docker.pkg.dev/my-project/nagare`.
* **NixOS is provisioned by building a GCE image on a remote x86_64-linux Nix builder, then booting
  the VM from it.** The spec's recovery flow implies `nixos-rebuild switch` provisions the box. Because
  the workstation is aarch64-darwin, the image is built on an on-demand GCP Linux builder, uploaded to
  GCS, and registered as a GCE image (the `load-testing-infra` `setup-nix-builder.sh` /
  `upload-images.sh` pattern). `nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01 --sudo`
  is used for day-2 changes over Tailscale; note the added `--sudo` for the non-root deploy user.
* **Keep k3s's built-in ServiceLB enabled; only disable Traefik.** The spec's k3s config disables both
  Traefik and servicelb. But Kourier's gateway Service is `type: LoadBalancer`, and on k3s the only
  thing that satisfies a LoadBalancer Service is ServiceLB (Klipper). Disabling servicelb would leave
  Kourier with no external IP. On a single node, ServiceLB binds host ports 80/443 directly to Kourier,
  which is the simplest reliable path, so the corrected k3s flags are `--disable=traefik
  --write-kubeconfig-mode=0644 --default-local-storage-path=/var/lib/nagare/local-path` (servicelb left
  enabled).

## Factual corrections (verified against upstream docs)

* **VictoriaTraces is pre-GA / beta** (chart `victoria-traces-single` at an early `0.x` version), not a
  mature component. Treat it as experimental; the Tempo-compatible query API is still on its roadmap.
* **OTLP ports 4317/4318 belong to the OpenTelemetry Collector, not VictoriaTraces.** VictoriaTraces
  ingests OTLP/HTTP on its own port **10428** at `/insert/opentelemetry/v1/traces` (and OTLP/gRPC on
  4317 only if explicitly enabled). Apps send OTLP to the OTel Collector (4317/4318); the Collector
  exports to VictoriaTraces on 10428.
* **The Grafana trace datasource is the Jaeger type**, with the connection URL pointing at
  `http://<victoria-traces>.tracing.svc:10428/select/jaeger` (the spec's `/select/jaeger` path is
  correct; the Jaeger-compatible path is the right initial integration, not Tempo).
* **The VictoriaLogs Grafana datasource plugin id is `victoriametrics-logs-datasource`** (an official,
  Grafana-signed plugin), not an unnamed "datasource/plugin."
* **`vmsingle` and `vmcluster` are mutually exclusive** in the `victoria-metrics-k8s-stack` chart;
  enable `vmsingle` only. The listed values keys (`vmsingle.enabled`, `vmsingle.spec.retentionPeriod`,
  `grafana.enabled`, `prometheus-node-exporter.enabled`, `kube-state-metrics.enabled`,
  `alertmanager.enabled`) are otherwise correct.
* **`victoria-logs-collector` is Vector-based by default** (fluent-bit optional). The chart name in the
  spec is correct.
* **Knative/Kourier current versions are ~v1.22** (the spec did not pin; install the current release
  from `knative/serving` and `knative-extensions/net-kourier`). The Kourier ingress class key in
  `config-network` is `ingress-class: kourier.ingress.networking.knative.dev`.
* **DomainMapping** uses `serving.knative.dev/v1beta1` and is enabled by default — no feature flag is
  required (older docs implied one).
* **`net-certmanager` release artifacts are no longer published on GitHub past v1.14.0**; pull the
  current `release.yaml` from the Knative GCS bucket (`storage.googleapis.com/knative-.../net-certmanager/...`)
  as the official install docs now direct.
* **Pulumi has no single "IAM bindings" resource.** Use scoped resources and prefer the
  non-authoritative `*IAMMember` variants (`gcp.projects.IAMMember`, `gcp.storage.BucketIAMMember`) to
  avoid clobbering existing bindings. The service-account module is lowercase `gcp.serviceaccount`.
* **`e2-medium` is 2 shared-core (burstable) vCPU / 4 GB**; `e2-standard-2` is 2 vCPU / 8 GB;
  `e2-standard-4` is 4 vCPU / 16 GB. The recommended starting point is `e2-standard-2`.
* **k3s local-path-provisioner must be pointed at the data disk with the `--default-local-storage-path`
  server flag**, not by editing the `local-path-config` ConfigMap (k3s overwrites that on restart).

