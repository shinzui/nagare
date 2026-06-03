---
id: 5
slug: victoria-observability-stack-and-grafana
title: "Victoria observability stack and Grafana"
kind: exec-plan
created_at: 2026-06-02T15:39:48Z
intention: "intention_01kt4f3svnekz80g94f2k4tthq"
master_plan: "docs/masterplans/1-bootstrap-nagare-personal-paas.md"
---

# Victoria observability stack and Grafana

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan installs the "observability stack" for Nagare — a single-node personal Platform-as-a-Service
(PaaS) running on one Google Cloud VM. **Observability** here means the ability to see what the machine
and the apps running on it are doing, using three kinds of data:

- **Metrics**: numeric measurements sampled over time, such as how much memory a node uses or how many
  requests a service handled. They answer "how much / how many / how fast" and are cheap to store.
- **Logs**: timestamped lines of text emitted by programs (for example the stdout/stderr of a
  container). They answer "what exactly happened, in words."
- **Traces**: records of a single request as it flows through one or more services, broken into timed
  "spans." They answer "where did this request spend its time / where did it fail."

After this plan is complete, the owner can open **Grafana** (a web dashboard UI for querying and
charting all three kinds of data) and:

1. Run a metrics query such as `up` or `node_memory_MemAvailable_bytes` and see live data from the
   `nagare-01` node and the Kubernetes cluster.
2. Search container logs (for example, all logs from namespace `personal`) and see real log lines with
   `namespace`, `pod`, and `container` labels attached.
3. View a trace that an application (or a test job) emitted, listed by service name, with its spans.

Concretely, the data flows like this. **VictoriaMetrics** stores metrics; a component called **VMAgent**
**scrapes** them (a "scrape" is an HTTP GET that pulls a metrics page from a target on a timer) from the
node, from the kube-state-metrics exporter, and from any app that exposes a Prometheus metrics endpoint.
**VictoriaLogs** stores logs; a **VictoriaLogs collector** (a Vector-based agent running on the node)
tails every container's log file and ships the lines to VictoriaLogs. **VictoriaTraces** stores traces;
apps send their traces in **OTLP** format (OpenTelemetry Protocol, the standard wire format for telemetry)
to an **OpenTelemetry Collector**, which forwards them to VictoriaTraces. Grafana reads from all three
stores via configured **datasources** (a datasource is Grafana's saved pointer to one backend: its type,
URL, and access settings).

Everything is installed with **Helm charts**. A Helm chart is a packaged, parameterized bundle of
Kubernetes manifests; you install it with `helm upgrade --install <release-name> <chart> -f values.yaml`,
where the `values.yaml` file overrides the chart's defaults. Re-running the same command updates the
release in place, which makes installs repeatable (idempotent).

This plan **hard-depends on EP-3** (`docs/plans/3-nixos-host-nagare-01-with-k3s.md`): you need a running
single-node k3s cluster with the data disk mounted at `/var/lib/nagare` and the k3s local-path storage
provisioner pointed at `/var/lib/nagare/local-path`. It **soft-depends on EP-4**
(`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`): if EP-4 is done you can expose
Grafana through ingress and you will see Knative request metrics; if not, the stack still installs and
shows node and Kubernetes metrics, and you reach Grafana with `kubectl port-forward`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Prerequisites confirmed: `KUBECONFIG` points at `nagare-01`; `kubectl get nodes` shows `Ready` (k3s v1.35.4); `helm version` works; data disk mounted at `/var/lib/nagare`; `local-path` is the default StorageClass (VMSingle PVC bound to it). Cluster reached via the EP-4 SSH local-forward to 127.0.0.1:6443 over the port-22 IAP tunnel. (2026-06-02)
- [x] Helm repos added: `vm` (VictoriaMetrics) and `open-telemetry` (OpenTelemetry); `helm repo update` run. (2026-06-02)
- [x] All values files + datasource provisioning + `install.sh` authored and validated offline with `helm template` against pinned charts (k8s-stack 0.81.0, logs-single 0.13.5, logs-collector 0.3.4, traces-single 0.1.6, otel-collector 0.158.0). Service-name URLs verified (e.g. `victoria-logs-victoria-logs-single-server`, not the draft's `vls-` guess). (2026-06-02)
- [x] M1: `victoria-metrics-k8s-stack` (vmks) installed in `monitoring`; all pods Running (vmsingle, vmagent 2/2, grafana 3/3, kube-state-metrics, node-exporter, operator). `up` query returns `success` with data (kubelet/node series = 1) and `node_memory_MemAvailable_bytes` returns node-exporter data. PVC `vmsingle-...` Bound to `local-path`, retention 30d. (Initial attempt on the 6 GB boot disk failed on DiskPressure — fixed by rebuilding the VM with a 100 GB boot disk, see Surprises; root now 8% used.) (2026-06-03)
- [x] M1: VMSingle service `vmsingle-vmks-victoria-metrics-k8s-stack.monitoring.svc:8429` (also exposes 8428); Grafana `vmks-grafana.monitoring.svc:80`. (2026-06-03)
- [x] M2: `victoria-logs-single` + `victoria-logs-collector` installed in `logging`; both Running. Container logs searchable; `_time:1h` returns data and the stream selector `{kubernetes.pod_namespace="monitoring"}` returns logs. **Field names are `kubernetes.pod_namespace` / `kubernetes.pod_name` / `kubernetes.container_name`** (this chart ships the VictoriaLogs-native `vlagent` collector, not Vector — see Surprises), not the draft's `namespace`/`pod`/`container`. Retention 7d confirmed (`-retentionPeriod=7d`). PVC 20Gi Bound to `local-path`. (2026-06-03)
- [x] M2: VictoriaLogs service `victoria-logs-victoria-logs-single-server.logging.svc:9428` (headless). (2026-06-03)
- [x] M3: `victoria-traces-single` + `opentelemetry-collector` installed in `tracing`; both Running. A test trace (`telemetrygen --service nagare-test --traces 5` → OTel Collector OTLP/gRPC 4317 → VictoriaTraces) is visible: the Jaeger services API returns `{"data":["nagare-test"],...,"total":1}`. Retention 3d confirmed. PVC 10Gi Bound to `local-path`. (2026-06-03)
- [x] M3: VictoriaTraces `victoria-traces-vt-single-server.tracing.svc:10428` (Jaeger API `/select/jaeger`, OTLP ingest `/insert/opentelemetry/v1/traces`); OTel Collector `otel-collector-opentelemetry-collector.tracing.svc` OTLP gRPC 4317 / HTTP 4318. (2026-06-03)
- [x] Grafana datasource provisioning files written under `cluster/observability/grafana/datasources/` (VictoriaLogs, VictoriaTraces) and mirrored inline in the metrics chart values (`grafana.additionalDataSources`); the VictoriaMetrics datasource is auto-provisioned by the k8s-stack chart. (2026-06-03)
- [x] Dashboards directory `cluster/observability/grafana/dashboards/` created with a README (load-via-sidecar + EP-7 backup note). (2026-06-03)
- [x] Grafana access method documented (`kubectl port-forward -n monitoring svc/vmks-grafana 3000:80`; Tailscale-only steady-state recommended) in install.sh notes and the plan's Final wiring. (2026-06-03)
- [x] All `helm` commands recorded in `cluster/observability/install.sh` (idempotent, pinned chart versions, includes the OTel collector) and the `observability` justfile target wraps it. (2026-06-03)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The `victoria-metrics-k8s-stack` chart changed the default VMSingle HTTP port from **8429** to
  **8428** in a recent release. The spec and the older Grafana datasource URL assume 8429. To avoid an
  unexpected VMSingle restart and to keep the datasource URL stable, this plan **pins the port back to
  8429** with `vmsingle.spec.port: "8429"`. If you instead accept the chart default, every datasource
  URL and verification command below must use `8428`. Always confirm the real port with
  `kubectl get svc -n monitoring` after install. (Evidence: VictoriaMetrics k8s-stack changelog notes
  the 8429→8428 default change and documents `.Values.vmsingle.spec.port` as the override.)
- **VictoriaTraces is pre-GA / beta.** The `victoria-traces-single` chart is at an early `0.x` version
  (observed `0.1.6`). Its Jaeger-compatible query API works for visualization in Grafana, but the
  Tempo-compatible API is still experimental/roadmap. Treat traces as the least stable pillar; if the
  chart or API misbehaves, the metrics (M1) and logs (M2) milestones still stand on their own.
- Helm-generated Kubernetes **service names depend on the release name and the chart version**, so they
  are NOT hardcoded in this plan. After each install you must run `kubectl get svc -n <namespace>` and
  copy the exact `vmsingle-...`, `vls-...`/`...-server`, `victoria-traces-...`, and collector service
  names into the Grafana datasource URLs. The plan gives the known naming patterns and ports so you can
  recognize them.

- **RESOLVED: the 6 GB boot-disk blocker was fixed by rebuilding the VM with a 100 GB boot disk.**
  Per the operator's choice, `infra/pulumi/src/components/NagareInstance.ts` now sets
  `bootDisk.initializeParams.size = 100`; `pulumi up` replaced only the instance (data disk, static
  IP, DNS, SA all unchanged — `+-1 replaced, 20 unchanged`), and NixOS `growPartition` grew the root
  to 99 G. After reinstall the root disk sits at **8 % used (88 G free)** with the full stack running.
  The boot-disk sizing belongs in EP-2's instance component so clean rebuilds are correctly sized from
  the start. (2026-06-03)

- **The VM rebuild surfaced a latent EP-3 DNS regression (now worked around).** The registered NixOS
  GCE image does **not** contain the `networking.nix` DNS fix (`grep nohook /etc/dhcpcd.conf` →
  absent; no `/etc/static/resolv.conf`), so on a clean boot dhcpcd's resolvconf hook writes the
  unreachable metadata resolver `169.254.169.254` into `/etc/resolv.conf`. k3s system images are
  airgap-baked so the node came up, but cert-manager/Knative/observability images (quay.io, ghcr.io)
  failed with `Temporary failure in name resolution`, and **coredns** (`forward . /etc/resolv.conf`)
  inherited the broken upstream so in-cluster external DNS failed too (the `letsencrypt-dns`
  ClusterIssuer reported `lookup acme-v02... server misbehaving`). Worked around live by writing a
  static `8.8.8.8/8.8.4.4` `/etc/resolv.conf`, locking it immutable (`chattr +i`), and restarting
  coredns. **This is not reboot-safe.** The `networking.nix` source is already correct; the durable
  fix is to rebuild + re-register the image (`just host-image`) so clean rebuilds boot with working
  DNS. Recorded as an EP-3 follow-up (see EP-3 Surprises and the MasterPlan). (2026-06-03)

- **Log field names are `kubernetes.pod_namespace` / `kubernetes.pod_name` / `kubernetes.container_name`,
  and queries use the LogsQL stream selector `{...}`.** This chart version ships the VictoriaLogs-native
  `vlagent` Kubernetes collector (configured with `streamFields=kubernetes.container_name,
  kubernetes.pod_name,kubernetes.pod_namespace`), **not** a Vector agent as the plan assumed. So the
  correct search is `{kubernetes.pod_namespace="monitoring"}` (returns 1000+ lines), not the plan's
  `{namespace="monitoring"}`. The dotted names are stream fields, so the `{field="value"}` selector
  works; a bare `field:value` filter does not match them. Grafana LogsQL queries, and EP-6/EP-7,
  should use these field names. (2026-06-03)

- **Knative request metrics are not scraped by default.** A query for Knative
  `*request*` series returns empty: VMAgent's default scrape config (kube components, node-exporter,
  kube-state-metrics, annotated pods) does not include Knative's metrics endpoints. M1 acceptance
  (node + cluster metrics) holds regardless; surfacing Knative request metrics is a later enhancement
  (add a VMServiceScrape for the Knative `controller`/`activator` metrics services, or pod annotations)
  and is not required by EP-5. (2026-06-03)

- **BLOCKER (infra, RESOLVED above): the node's 6 GB boot disk was too small for the observability stack.** On the
  first live install attempt (2026-06-02), `helm upgrade --install vmks` failed with
  `context deadline exceeded` and node-exporter was repeatedly `Evicted` with reason
  `The node had condition: [DiskPressure]`. Root cause: `nagare-01`'s **boot disk is 6 GB**
  (`gcloud compute disks describe nagare-01` → `sizeGb=6`), exposed to Kubernetes as
  `ephemeral-storage` capacity ~6105644Ki. On the VM, `df -h /` showed `/dev/sdb1 5.9G 5.1G 93%` and
  rose to **99% (65 M free)** during the install — the root disk holds both the NixOS `/nix/store`
  and the containerd image store (`/var/lib/rancher/k3s/agent/containerd` = 2.0 G), leaving no room
  for the stack's images (Grafana, VictoriaMetrics, node-exporter, kube-state-metrics, operator,
  vmagent). Memory was fine (5.9 G free). The 100 GB data disk at `/var/lib/nagare` was 1% used and
  the VMSingle PVC bound to it correctly — the problem is image/ephemeral storage, NOT PVC storage.
  The disk pressure also destabilized EP-4's Knative pods (readiness failures, evictions).
  **This is an EP-2/EP-3 infra fix, not an EP-5 values fix:** `infra/pulumi/src/components/NagareInstance.ts`
  sets `bootDisk: { initializeParams: { image } }` with **no `size`**, so GCE defaults the boot disk
  to the NixOS image's ~6 GB minimum. EP-3's `nixos/flake.nix` imports
  `google-compute-image.nix` (which enables `growPartition`), so the root partition **auto-grows to
  fill a larger boot disk on reboot** — an in-place `gcloud compute disks resize` + reboot is
  sufficient; no manual `growpart` needed. The failed `vmks` release was uninstalled and its (empty)
  PVC deleted to relieve the node; EP-4 recovered to one healthy replica per Deployment and the hello
  ksvc is `READY=True`. EP-5 M1–M3 are blocked until the boot disk is enlarged. (2026-06-02)


## Decision Log

Record every decision made while working on the plan.

- Decision: Install three Victoria components plus an OpenTelemetry Collector and Grafana, using the
  official VictoriaMetrics Helm repo `https://victoriametrics.github.io/helm-charts/` (repo alias `vm`)
  and the OpenTelemetry Helm repo `https://open-telemetry.github.io/opentelemetry-helm-charts` (alias
  `open-telemetry`).
  Rationale: These are the upstream-recommended charts for a single-node deployment and match the spec's
  "Why Victoria Stack" choice (cheaper than Prometheus+Loki+Tempo for one small box). Grafana ships
  inside `victoria-metrics-k8s-stack`, so no separate Grafana install is needed.
  Date: 2026-06-02

- Decision: Enable `vmsingle` and explicitly set `vmcluster.enabled: false`.
  Rationale: `vmsingle` (one process holding all metrics) and `vmcluster` (a distributed deployment) are
  **mutually exclusive** in this chart; a single 8 GB VM has no use for the cluster topology. Enabling
  both is an error.
  Date: 2026-06-02

- Decision: Pin VMSingle HTTP port to `8429` via `vmsingle.spec.port: "8429"`.
  Rationale: Newer chart defaults moved to 8428; pinning keeps the datasource URL stable and matches the
  spec's documented URL. See Surprises & Discoveries.
  Date: 2026-06-02

- Decision: Put metrics/logs/traces storage on PersistentVolumeClaims that bind to the k3s `local-path`
  StorageClass (the default), which EP-3 configured to write under `/var/lib/nagare/local-path` on the
  attached data disk (Integration Point 3).
  Rationale: That is the only persistent, backup-eligible storage on the box. We do not request a custom
  StorageClass; leaving `storageClassName` unset lets the PVC bind to the cluster default `local-path`.
  Date: 2026-06-02

- Decision: Retention is 30 days for metrics, 7 days for logs, and 3 days for traces.
  Rationale: Matches the spec's "Starting retention" (metrics 30d, logs 7d, traces 3–7d). Traces grow
  fastest and are the least stable pillar, so start at the low end (3d).
  Date: 2026-06-02

- Decision: Reach Grafana via `kubectl port-forward` during this plan, and document Tailscale-only
  exposure as the recommended steady-state access.
  Rationale: The spec's "Grafana Exposure" open question recommends "Tailscale-only at first." A public
  Grafana ingress is out of scope for v1; port-forward is sufficient to validate, and the Tailscale path
  (reach the node's Tailscale IP) keeps the UI private without extra TLS work.
  Date: 2026-06-02

- Decision: Apps send traces to the **OpenTelemetry Collector's** OTLP endpoint (gRPC 4317 / HTTP 4318);
  the Collector exports to VictoriaTraces on **10428** at `/insert/opentelemetry/v1/traces`. The
  4317/4318 ports belong to the Collector, not to VictoriaTraces.
  Rationale: This corrects the spec, which listed 4317/4318 under VictoriaTraces. VictoriaTraces ingests
  OTLP/HTTP on 10428; the Collector is the front door for app telemetry (consumed conceptually by EP-6
  apps). Keeping the Collector in front lets us add batching, sampling, and metrics/logs pipelines later
  without touching apps.
  Date: 2026-06-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Status (2026-06-03): COMPLETE — all three pillars installed and verified live.** Against the Purpose:

- **Metrics (M1):** `victoria-metrics-k8s-stack` (vmks) in `monitoring`; VMSingle (30d, port 8429,
  20Gi on `local-path`), VMAgent, node-exporter, kube-state-metrics, the operator, and Grafana (with
  the VictoriaLogs + VictoriaTraces datasources and the logs-datasource plugin). `up` and
  `node_memory_MemAvailable_bytes` return live data.
- **Logs (M2):** `victoria-logs-single` (7d, 20Gi) + the `victoria-logs-collector` DaemonSet in
  `logging`. Container logs are searchable; the correct query is the stream selector
  `{kubernetes.pod_namespace="<ns>"}` with fields `kubernetes.pod_namespace`/`.pod_name`/
  `.container_name` (this chart ships VictoriaLogs' native `vlagent`, not Vector).
- **Traces (M3):** `victoria-traces-single` (beta, 3d, 10Gi) + the OpenTelemetry Collector in
  `tracing`. A test trace sent to the Collector's OTLP endpoint is queryable via VictoriaTraces' Jaeger
  API (service `nagare-test` listed). The Collector OTLP endpoint
  `otel-collector-opentelemetry-collector.tracing.svc:4317/4318` is the address EP-6 apps target.

All PVCs are Bound to `local-path` on the 100 GB data disk; `helm list -A` shows all five releases
`deployed`; the install is reproducible via `cluster/observability/install.sh` (`just observability`).
Grafana is reached by `kubectl port-forward` (Tailscale-only recommended for steady state).

**What changed during implementation vs the draft:** (1) the boot disk had to be enlarged from 6 GB to
100 GB (a VM rebuild via Pulumi) before the stack would fit — boot-disk sizing should live in EP-2;
(2) the VM rebuild surfaced that the registered image lacks EP-3's DNS fix, worked around live but
needing an image rebuild for reproducibility (EP-3 follow-up); (3) the log collector is VictoriaLogs'
`vlagent` with `kubernetes.pod_*` field names, not Vector; (4) net of pins: charts k8s-stack 0.81.0,
logs-single 0.13.5, logs-collector 0.3.4, traces-single 0.1.6, otel-collector 0.158.0.

**Gaps / follow-ups (non-blocking for EP-5):** Knative request metrics are not scraped yet (add a
VMServiceScrape); Grafana datasource "Save & test" was not exercised through the UI (backends verified
directly instead, which is stronger); the Grafana admin password is a placeholder pending EP-7
secrets; the host DNS fix is a manual immutable resolv.conf + coredns restart that is not reboot-safe
until the image is rebuilt.


## Context and Orientation

You are working in the Nagare repository at `/Users/shinzui/Keikaku/bokuno/nagare`. This plan touches only
the `cluster/observability/` subtree and runs `helm`/`kubectl` against the cluster; it creates no cloud
resources and changes no host configuration.

**What already exists when you start (from EP-3).** A single-node k3s cluster on a Google Cloud VM named
`nagare-01`. k3s is a small, single-binary Kubernetes distribution. The VM has a second "data disk"
mounted at `/var/lib/nagare`, with these subdirectories already created:
`/var/lib/nagare/victoria-metrics`, `/var/lib/nagare/victoria-logs`, `/var/lib/nagare/victoria-traces`,
and `/var/lib/nagare/local-path`. k3s's built-in **local-path-provisioner** (the component that turns a
PersistentVolumeClaim into a real directory on disk) was configured by EP-3 to write under
`/var/lib/nagare/local-path` using the k3s server flag `--default-local-storage-path`. That provisioner
backs a StorageClass named `local-path`, which is the cluster's **default** StorageClass. So any
PersistentVolumeClaim (PVC — a request for a chunk of persistent disk) you create without naming a
StorageClass lands on the data disk automatically.

**How you reach the cluster (Integration Point 7).** EP-3 writes the cluster's kubeconfig (the file that
tells `kubectl` how to authenticate to the cluster) at `/etc/rancher/k3s/k3s.yaml` on the VM. You copy
that file to your workstation, rewrite its `server:` field from `https://127.0.0.1:6443` to the VM's
Tailscale name or public IP, and export `KUBECONFIG` to point at it. **Tailscale** is a private mesh VPN;
the VM joins it so you can reach it by a stable private name without opening firewall ports. Concretely:

```bash
# On your workstation, from the repo root. Replace <vm-tailscale-or-ip> appropriately.
mkdir -p ~/.kube
gcloud compute scp nagare-01:/etc/rancher/k3s/k3s.yaml ~/.kube/nagare-01.yaml \
  --project=tan-nb-exp --zone=us-west1-a --tunnel-through-iap
sed -i '' 's#https://127.0.0.1:6443#https://<vm-tailscale-or-ip>:6443#' ~/.kube/nagare-01.yaml
export KUBECONFIG=~/.kube/nagare-01.yaml
kubectl get nodes
```

Expected output of the last command (one node, `Ready`):

```text
NAME        STATUS   ROLES                  AGE   VERSION
nagare-01   Ready    control-plane,master   1d    v1.31.x+k3s1
```

All `helm` and `kubectl` commands in this plan assume `KUBECONFIG` is exported like this. Every command
targets the `tan-nb-exp` GCP project per the repo isolation policy; observability itself makes no GCP
calls, but the `gcloud compute scp` above does.

**The namespaces this plan owns (Integration Point 5).** A Kubernetes **namespace** is a named partition
that groups related objects. This plan creates and uses exactly three: `monitoring` (VictoriaMetrics +
Grafana), `logging` (VictoriaLogs + its collector), and `tracing` (VictoriaTraces + the OpenTelemetry
Collector). EP-6 apps live in `personal`; their logs and metrics show up in this stack automatically once
running.

**The files this plan creates.** All under `cluster/observability/`:

- `cluster/observability/victoria-metrics/values.yaml` — Helm values for `victoria-metrics-k8s-stack`
  (VictoriaMetrics single + VMAgent + node-exporter + kube-state-metrics + Grafana). This file also
  carries the Grafana datasource definitions and the Grafana sidecar settings.
- `cluster/observability/victoria-logs/values.yaml` — Helm values for `victoria-logs-single`.
- `cluster/observability/victoria-logs/collector-values.yaml` — Helm values for `victoria-logs-collector`.
- `cluster/observability/victoria-traces/values.yaml` — Helm values for `victoria-traces-single`.
- `cluster/observability/opentelemetry-collector/values.yaml` — Helm values for the OpenTelemetry
  Collector.
- `cluster/observability/grafana/datasources/*.yaml` — Grafana datasource provisioning files kept under
  version control (also referenced from the metrics chart values so Grafana loads them on boot).
- `cluster/observability/grafana/dashboards/` — directory for dashboards committed to Git (EP-7 owns the
  backup/restore of these).
- `cluster/observability/install.sh` — a small idempotent script running every `helm upgrade --install`
  in order (a convenience so the whole stack reinstalls with one command).

**Ports you will use (embedded knowledge — confirm with `kubectl get svc`).**

- VictoriaMetrics (VMSingle) HTTP: **8429** (pinned; chart default may otherwise be 8428).
- VictoriaLogs HTTP (ingest + query + UI): **9428**.
- VictoriaTraces HTTP (ingest + query + Jaeger API + UI): **10428**. OTLP/HTTP ingest path:
  `/insert/opentelemetry/v1/traces`. Jaeger query base for Grafana: `/select/jaeger`.
- OpenTelemetry Collector OTLP receivers: gRPC **4317**, HTTP **4318** (these are the Collector's ports,
  the ones apps target).
- Grafana web UI: **3000**.


## Plan of Work

The work is three milestones, each independently verifiable, followed by wiring the Grafana datasources
and documenting access. Do them in order; each leaves the stack in a working, observable state.

Before any milestone, add the Helm repositories once:

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

A Helm **repository** is a catalog of charts; `repo add` registers it under a short alias (`vm`,
`open-telemetry`) and `repo update` refreshes the local index. This is safe to re-run.

### Milestone M1 — Metrics and Grafana

Scope: install `victoria-metrics-k8s-stack` in `monitoring`. At the end you will have VictoriaMetrics
storing metrics on the data disk, VMAgent scraping the node and Kubernetes, node-exporter and
kube-state-metrics producing host and cluster metrics, and Grafana running with the VictoriaMetrics
datasource already wired. You will confirm pods are healthy, reach Grafana, and run a query that returns
data.

Author `cluster/observability/victoria-metrics/values.yaml` (shown fully in Concrete Steps). Key choices:
`vmsingle.enabled: true`, `vmcluster.enabled: false`, `vmsingle.spec.retentionPeriod: "30d"`,
`vmsingle.spec.port: "8429"`, a 20Gi PVC for VMSingle bound to the default `local-path` StorageClass,
`grafana.enabled: true`, `prometheus-node-exporter.enabled: true`, `kube-state-metrics.enabled: true`,
and `alertmanager.enabled: false`. Grafana gets its admin password from a value (you will set a real
secret) and its additional datasources (VictoriaLogs and VictoriaTraces, added in M2/M3) declared inline
under `grafana.additionalDataSources` so they survive chart upgrades.

Acceptance: `kubectl get pods -n monitoring` shows all pods `Running`/`Completed`; port-forwarding Grafana
and querying `up` in Explore returns one or more series.

### Milestone M2 — Logs

Scope: install `victoria-logs-single` (the log store) and `victoria-logs-collector` (the Vector-based
DaemonSet that tails container logs) in `logging`, then add the VictoriaLogs datasource to Grafana. A
**DaemonSet** runs one pod per node; on a single node that is one collector pod tailing every container's
log file under `/var/log/containers`. At the end, container logs are searchable in Grafana with
`namespace`, `pod`, and `container` labels and a 7-day retention.

Author `cluster/observability/victoria-logs/values.yaml` (retention 7d, 20Gi PVC on `local-path`) and
`cluster/observability/victoria-logs/collector-values.yaml` (point `remoteWrite` at the VictoriaLogs
service on port 9428). Add the VictoriaLogs datasource (plugin id `victoriametrics-logs-datasource`) to
the Grafana values from M1 and `helm upgrade` the metrics release so Grafana picks it up; also drop a
provisioning file under `cluster/observability/grafana/datasources/` for version control.

Acceptance: in Grafana Explore, select the VictoriaLogs datasource and run a query like
`{namespace="monitoring"}` (LogsQL); recent log lines appear with the expected labels.

### Milestone M3 — Traces

Scope: install `victoria-traces-single` (the trace store, beta) in `tracing`, install the OpenTelemetry
Collector in `tracing` configured to receive OTLP and export to VictoriaTraces, add the Jaeger datasource
to Grafana, then emit a test trace and see it. At the end, an app (or a one-shot test job) that sends OTLP
to the Collector results in a trace visible in Grafana.

Author `cluster/observability/victoria-traces/values.yaml` (retention 3d, small PVC on `local-path`) and
`cluster/observability/opentelemetry-collector/values.yaml` (deployment mode; OTLP gRPC/HTTP receivers;
an `otlphttp` exporter whose `traces_endpoint` is the VictoriaTraces service on 10428 at
`/insert/opentelemetry/v1/traces`; a traces pipeline only for v1). Add the Jaeger datasource to Grafana
pointing at `http://<victoria-traces-svc>.tracing.svc:10428/select/jaeger`. Emit a test trace with the
OpenTelemetry `telemetrygen` tool or a `curl` of OTLP/HTTP to the Collector on 4318.

Acceptance: in Grafana Explore, select the Jaeger datasource, pick the test service from the Service
dropdown, and see at least one trace with spans. Flag in Surprises/Decision Log that VictoriaTraces is
beta.

### Final wiring

Collect the three datasources into `cluster/observability/grafana/datasources/`, ensure the metrics chart
loads them, create `cluster/observability/grafana/dashboards/` with a README, write
`cluster/observability/install.sh`, and document the Grafana access method.


## Concrete Steps

Run everything from the repo root `/Users/shinzui/Keikaku/bokuno/nagare` with `KUBECONFIG` exported as in
Context and Orientation. Create directories first:

```bash
mkdir -p cluster/observability/victoria-metrics
mkdir -p cluster/observability/victoria-logs
mkdir -p cluster/observability/victoria-traces
mkdir -p cluster/observability/opentelemetry-collector
mkdir -p cluster/observability/grafana/datasources
mkdir -p cluster/observability/grafana/dashboards
```

Add Helm repos (see Plan of Work). Then proceed milestone by milestone.

### M1 — write `cluster/observability/victoria-metrics/values.yaml`

```yaml
# Helm values for the chart vm/victoria-metrics-k8s-stack, installed in the `monitoring` namespace.
# This bundles: VictoriaMetrics single-node (VMSingle), VMAgent (scraper), node-exporter,
# kube-state-metrics, the victoria-metrics-operator, and Grafana.

# --- Metrics store: VMSingle (one process holds all metrics). ---
vmsingle:
  enabled: true
  spec:
    # Keep metrics for 30 days, then drop the oldest.
    retentionPeriod: "30d"
    # Pin the HTTP port to 8429. Newer chart versions default to 8428; pinning keeps the
    # Grafana datasource URL stable and avoids an unexpected restart on upgrade.
    port: "8429"
    # Persist on a PVC. Leaving storageClassName unset binds to the cluster default
    # StorageClass `local-path`, which writes under /var/lib/nagare/local-path on the data disk.
    storage:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 20Gi

# VMSingle and VMCluster are mutually exclusive. We use single only.
vmcluster:
  enabled: false

# VMAgent scrapes node-exporter, kube-state-metrics, and any annotated app endpoints,
# then writes the samples into VMSingle. Defaults are fine for one node.
vmagent:
  enabled: true

# No alerting in v1.
alertmanager:
  enabled: false
vmalert:
  enabled: false

# Host-level metrics (CPU, memory, disk, network) for the node.
prometheus-node-exporter:
  enabled: true

# Kubernetes object state (deployments, pods, nodes) as metrics.
kube-state-metrics:
  enabled: true

# --- Grafana (the dashboard UI). ---
grafana:
  enabled: true
  # CHANGE THIS before installing. For a private (Tailscale-only) Grafana this can be simple,
  # but do not commit a real production password to Git; prefer an existing Secret in steady state.
  adminPassword: "change-me-nagare"
  service:
    type: ClusterIP
    port: 3000
  # The chart auto-provisions the in-cluster VictoriaMetrics (prometheus-type) datasource.
  # We declare the other two datasources here so they persist across chart upgrades.
  # NOTE: fill in the real service names after install (see "Discover service names" below);
  #   the values shown are the expected patterns for release name `vmks`.
  additionalDataSources:
    - name: VictoriaLogs
      type: victoriametrics-logs-datasource   # official Grafana-signed plugin
      access: proxy
      url: http://vls-victoria-logs-single-server.logging.svc:9428
      jsonData: {}
    - name: VictoriaTraces
      type: jaeger
      access: proxy
      url: http://victoria-traces-vt-single-server.tracing.svc:10428/select/jaeger
  # Install the VictoriaLogs datasource plugin into Grafana so the type above is recognized.
  plugins:
    - victoriametrics-logs-datasource
  # Allow Grafana to load dashboard JSON committed under cluster/observability/grafana/dashboards/
  # via the sidecar (optional in v1; EP-7 manages dashboard backups).
  sidecar:
    dashboards:
      enabled: true
```

Install it:

```bash
helm upgrade --install vmks vm/victoria-metrics-k8s-stack \
  --namespace monitoring \
  --create-namespace \
  -f cluster/observability/victoria-metrics/values.yaml \
  --wait --timeout 10m
```

`--wait` makes Helm block until the resources are ready; `--create-namespace` makes the `monitoring`
namespace if it is missing. Expected (abbreviated) success:

```text
Release "vmks" does not exist. Installing it now.
NAME: vmks
STATUS: deployed
NAMESPACE: monitoring
```

Discover the real service names and ports (do this after every install; names depend on release name and
chart version):

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

Expected `svc` output includes a VMSingle service on 8429 and a Grafana service on 80→3000, e.g.:

```text
NAME                                       TYPE        PORT(S)
vmsingle-vmks-victoria-metrics-k8s-stack   ClusterIP   8429/TCP
vmks-grafana                               ClusterIP   80/TCP
...
```

If the VMSingle service name differs from `vmsingle-vmks-victoria-metrics-k8s-stack`, the chart-provisioned
prometheus datasource still points at the right place automatically; you only need the exact name when you
hand-write a datasource. Record the name in Progress.

Reach Grafana and verify metrics:

```bash
kubectl port-forward -n monitoring svc/vmks-grafana 3000:80
```

Open `http://localhost:3000`, log in as `admin` with the `adminPassword` you set, go to Explore, select
the VictoriaMetrics datasource (the default prometheus-type one), and run:

```text
up
```

You should see one or more series with value `1`. Also try `node_memory_MemAvailable_bytes` to confirm
node-exporter metrics flow. M1 is done when both return data.

### M2 — write `cluster/observability/victoria-logs/values.yaml`

```yaml
# Helm values for vm/victoria-logs-single, installed in the `logging` namespace.
# VictoriaLogs is the log store; it listens on HTTP 9428 for ingest, query, and its UI.
server:
  retentionPeriod: 7d           # keep logs for 7 days
  persistentVolume:
    enabled: true
    size: 20Gi                  # binds to the default local-path StorageClass on the data disk
```

Write `cluster/observability/victoria-logs/collector-values.yaml`:

```yaml
# Helm values for vm/victoria-logs-collector, installed in the `logging` namespace.
# This is a Vector-based DaemonSet (one pod per node) that tails every container log file
# and ships the lines to VictoriaLogs. Point it at the VictoriaLogs service on port 9428.
# IMPORTANT: set the host to the actual service name discovered after installing victoria-logs-single
#   (expected: vls-victoria-logs-single-server when the release is named `victoria-logs`).
remoteWrite:
  - url: http://vls-victoria-logs-single-server.logging.svc:9428
```

Install both:

```bash
helm upgrade --install victoria-logs vm/victoria-logs-single \
  --namespace logging \
  --create-namespace \
  -f cluster/observability/victoria-logs/values.yaml \
  --wait --timeout 5m

helm upgrade --install victoria-logs-collector vm/victoria-logs-collector \
  --namespace logging \
  -f cluster/observability/victoria-logs/collector-values.yaml \
  --wait --timeout 5m
```

Discover the VictoriaLogs service name/port (the collector and Grafana must point at the exact name):

```bash
kubectl get pods -n logging
kubectl get svc -n logging
```

Expected: a `...victoria-logs-single-server` service on 9428 and a running collector DaemonSet pod. If the
service name is not `vls-victoria-logs-single-server`, update both `collector-values.yaml`'s
`remoteWrite.url` and the Grafana VictoriaLogs datasource URL to match, then `helm upgrade` the affected
release(s).

Make sure Grafana has the VictoriaLogs datasource (declared in M1's `additionalDataSources`). If you
edited the URL, re-apply the metrics release:

```bash
helm upgrade --install vmks vm/victoria-metrics-k8s-stack \
  --namespace monitoring -f cluster/observability/victoria-metrics/values.yaml --wait --timeout 10m
```

Also write a standalone provisioning file for version control,
`cluster/observability/grafana/datasources/victoria-logs.yaml`:

```yaml
# Grafana datasource provisioning file (Grafana "provisioning/datasources" format).
# Kept in Git for reproducibility; the live datasource is also declared in the metrics chart values.
apiVersion: 1
datasources:
  - name: VictoriaLogs
    type: victoriametrics-logs-datasource
    access: proxy
    url: http://vls-victoria-logs-single-server.logging.svc:9428
    editable: true
```

Verify logs: port-forward Grafana again (if not still running), open Explore, choose the **VictoriaLogs**
datasource, and run a LogsQL query (**LogsQL** is VictoriaLogs' query language):

```text
{namespace="monitoring"}
```

Recent log lines from the monitoring pods appear, each carrying `namespace`, `pod`, and `container`
labels. Try `{namespace="logging"}` too. M2 is done when log lines with those labels return.

### M3 — write `cluster/observability/victoria-traces/values.yaml`

```yaml
# Helm values for vm/victoria-traces-single, installed in the `tracing` namespace.
# VictoriaTraces is the trace store (BETA, chart ~0.1.x). It listens on HTTP 10428 for OTLP
# ingest (path /insert/opentelemetry/v1/traces), query, the Jaeger API (/select/jaeger), and its UI.
server:
  retentionPeriod: 3d           # traces grow fast; start at the low end of 3-7d
  persistentVolume:
    enabled: true
    size: 10Gi                  # binds to the default local-path StorageClass on the data disk
```

Write `cluster/observability/opentelemetry-collector/values.yaml`:

```yaml
# Helm values for open-telemetry/opentelemetry-collector, installed in `tracing`.
# The Collector RECEIVES OTLP from apps (gRPC 4317 / HTTP 4318) and EXPORTS traces to
# VictoriaTraces on 10428 at /insert/opentelemetry/v1/traces. The 4317/4318 ports are the
# COLLECTOR's, not VictoriaTraces'.
mode: deployment              # one long-running Collector pod (not a per-node DaemonSet)

# Use the contrib image so the otlphttp exporter and common processors are available.
image:
  repository: otel/opentelemetry-collector-contrib

# Expose the OTLP receiver ports as a Service so apps in other namespaces can reach them.
ports:
  otlp:
    enabled: true
    containerPort: 4317
    servicePort: 4317
    protocol: TCP
  otlp-http:
    enabled: true
    containerPort: 4318
    servicePort: 4318
    protocol: TCP

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  processors:
    batch: {}
  exporters:
    # Forward traces to VictoriaTraces over OTLP/HTTP.
    # Set traces_endpoint to the actual VictoriaTraces service name discovered after install
    #   (expected: victoria-traces-vt-single-server when the release is named `victoria-traces`).
    otlphttp/victoriatraces:
      traces_endpoint: http://victoria-traces-vt-single-server.tracing.svc:10428/insert/opentelemetry/v1/traces
  service:
    pipelines:
      # v1: traces only. Metrics are handled by VMAgent, logs by the VictoriaLogs collector.
      traces:
        receivers: [otlp]
        processors: [batch]
        exporters: [otlphttp/victoriatraces]
```

Install both:

```bash
helm upgrade --install victoria-traces vm/victoria-traces-single \
  --namespace tracing \
  --create-namespace \
  -f cluster/observability/victoria-traces/values.yaml \
  --wait --timeout 5m

helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace tracing \
  -f cluster/observability/opentelemetry-collector/values.yaml \
  --wait --timeout 5m
```

Discover service names/ports:

```bash
kubectl get pods -n tracing
kubectl get svc -n tracing
```

Expected: a VictoriaTraces service on 10428 and an `otel-collector-opentelemetry-collector` service
exposing 4317/4318. If the VictoriaTraces service name differs from
`victoria-traces-vt-single-server`, update the Collector's `traces_endpoint` and the Grafana Jaeger
datasource URL, then `helm upgrade` accordingly.

Add the Jaeger datasource provisioning file
`cluster/observability/grafana/datasources/victoria-traces.yaml`:

```yaml
# Grafana datasource provisioning file. Jaeger type points at VictoriaTraces' Jaeger-compatible API.
apiVersion: 1
datasources:
  - name: VictoriaTraces
    type: jaeger
    access: proxy
    url: http://victoria-traces-vt-single-server.tracing.svc:10428/select/jaeger
    editable: true
```

Ensure the same datasource is in the metrics chart values (M1 `additionalDataSources`) and `helm upgrade`
`vmks` if you changed the URL.

Emit a test trace. The simplest approach is the OpenTelemetry `telemetrygen` tool run as a one-shot
Kubernetes Job that targets the Collector's OTLP/gRPC port 4317 inside the cluster:

```bash
kubectl run telemetrygen --rm -i --restart=Never -n tracing \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest -- \
  traces --otlp-insecure \
  --otlp-endpoint otel-collector-opentelemetry-collector.tracing.svc:4317 \
  --service nagare-test --traces 5
```

(If the Collector service name differs, substitute it.) Expected: the pod runs, prints that it generated
5 traces, and exits. Alternatively, send one OTLP/HTTP trace with `curl` to port 4318 from a temporary
pod:

```bash
kubectl run curlpod --rm -i --restart=Never -n tracing --image=curlimages/curl:latest -- \
  -sS -X POST http://otel-collector-opentelemetry-collector.tracing.svc:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"nagare-test"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b173","name":"test-span","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000000100000000"}]}]}]}'
```

Verify in Grafana: Explore -> VictoriaTraces (Jaeger) datasource -> the Service dropdown should list
`nagare-test`; selecting it and running the query shows the trace and its span(s). M3 is done when the
test trace appears.

### Final wiring

Create `cluster/observability/grafana/dashboards/README.md` explaining that dashboard JSON committed here
is loaded by Grafana's sidecar and backed up by EP-7. Create `cluster/observability/install.sh`:

```bash
#!/usr/bin/env bash
# Idempotent installer for the Nagare observability stack. Re-running updates releases in place.
# Assumes KUBECONFIG points at nagare-01 (see the plan's Context and Orientation).
set -euo pipefail

helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm upgrade --install vmks vm/victoria-metrics-k8s-stack \
  --namespace monitoring --create-namespace \
  -f "$ROOT/victoria-metrics/values.yaml" --wait --timeout 10m

helm upgrade --install victoria-logs vm/victoria-logs-single \
  --namespace logging --create-namespace \
  -f "$ROOT/victoria-logs/values.yaml" --wait --timeout 5m

helm upgrade --install victoria-logs-collector vm/victoria-logs-collector \
  --namespace logging \
  -f "$ROOT/victoria-logs/collector-values.yaml" --wait --timeout 5m

helm upgrade --install victoria-traces vm/victoria-traces-single \
  --namespace tracing --create-namespace \
  -f "$ROOT/victoria-traces/values.yaml" --wait --timeout 5m

helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace tracing \
  -f "$ROOT/opentelemetry-collector/values.yaml" --wait --timeout 5m

echo "Observability stack installed. Discover service names with: kubectl get svc -A | grep -E 'vmsingle|victoria|otel|grafana'"
```

Make it executable: `chmod +x cluster/observability/install.sh`.

**Grafana access (steady state).** During this plan you used `kubectl port-forward -n monitoring
svc/vmks-grafana 3000:80`. For ongoing private access the recommended option (per the spec's "Grafana
Exposure" open question, "Tailscale-only at first") is to reach Grafana over the VM's Tailscale network
rather than exposing it publicly. Two simple ways: keep using port-forward from a workstation that is on
Tailscale and can reach the cluster, or (if EP-4 ingress is present) add a Knative/Kourier route bound to
a Tailscale-only hostname. Do NOT make Grafana a public LoadBalancer in v1.


## Validation and Acceptance

The stack is accepted when all of the following are observable. Each is phrased as a concrete check.

Pods and releases healthy:

```bash
kubectl get pods -n monitoring
kubectl get pods -n logging
kubectl get pods -n tracing
helm list -A
```

Expected: every pod in `monitoring`, `logging`, and `tracing` is `Running` (or `Completed` for one-shot
jobs); `helm list -A` shows the releases `vmks` (monitoring), `victoria-logs` + `victoria-logs-collector`
(logging), and `victoria-traces` + `otel-collector` (tracing), each with `STATUS: deployed`.

Datasource health checks: in Grafana, Connections -> Data sources, open each of VictoriaMetrics,
VictoriaLogs, and VictoriaTraces and click "Save & test". Each must report success ("Data source is
working" or equivalent).

Metrics query returns data (M1): in Explore on the VictoriaMetrics datasource, `up` returns one or more
series; `node_memory_MemAvailable_bytes` returns a numeric series. If EP-4 is installed, Knative request
metrics (series names containing `revision_app_request` or `activator_request`) also appear, confirming
the soft dependency value.

Log search returns lines (M2): in Explore on the VictoriaLogs datasource, `{namespace="monitoring"}`
returns recent log lines with `namespace`, `pod`, and `container` fields. Confirm retention is 7 days:

```bash
kubectl -n logging get pod -l app.kubernetes.io/name=victoria-logs-single -o yaml | grep -i retention
```

Expected to show `-retentionPeriod=7d` (or `7d`) in the container args/flags.

A trace appears (M3): after running the `telemetrygen`/`curl` step, the VictoriaTraces (Jaeger) datasource
in Explore lists service `nagare-test` and shows at least one trace with spans. Confirm retention 3d:

```bash
kubectl -n tracing get pod -l app.kubernetes.io/name=victoria-traces-single -o yaml | grep -i retention
```

Expected to show `3d`.

Storage on the data disk (Integration Point 3): confirm the PVCs bound to `local-path`:

```bash
kubectl get pvc -A | grep -E 'monitoring|logging|tracing'
```

Expected: each PVC shows `STATUS: Bound` and `STORAGECLASS: local-path`. The bound volumes correspond to
directories under `/var/lib/nagare/local-path` on the VM.


## Idempotence and Recovery

Every install uses `helm upgrade --install`, which is idempotent: running it again with the same values is
a no-op or an in-place update, never a duplicate. Re-running `cluster/observability/install.sh` is safe and
is the normal way to apply a values change. Adding the Helm repos again is also safe.

PVCs are NOT deleted by `helm uninstall`, so metrics/logs/traces data survives a chart removal and
reinstall. This is intentional (the data lives on the durable data disk).

To remove a single component (for example, to recover from a broken traces install without touching
metrics):

```bash
helm uninstall otel-collector -n tracing
helm uninstall victoria-traces -n tracing
```

To wipe a component's data too (destructive — only when you intend to lose it):

```bash
kubectl delete pvc -n tracing --all
```

To rebuild the whole stack from scratch on a fresh cluster: ensure `KUBECONFIG` points at the cluster,
then run `cluster/observability/install.sh`. If a `helm upgrade` fails midway (for example a timeout while
images pull), re-run the same command; Helm resumes toward the desired state. If a release is stuck in a
`pending-upgrade` state, `helm rollback <release> -n <namespace>` returns it to the last good revision,
after which you can re-run the upgrade.

If the VictoriaTraces beta chart fails to install or its API misbehaves, M1 and M2 remain fully
functional; you can skip M3 temporarily by removing the traces datasource from the Grafana values and
re-running the `vmks` upgrade, then revisit traces when the chart stabilizes. Record any such deferral in
the Decision Log and the MasterPlan's Surprises section.


## Interfaces and Dependencies

**Hard dependency: EP-3** (`docs/plans/3-nixos-host-nagare-01-with-k3s.md`) — provides the running k3s
cluster, the kubeconfig (Integration Point 7), the data disk mounted at `/var/lib/nagare`, and the
`local-path` default StorageClass pointed at `/var/lib/nagare/local-path` (Integration Point 3). Without
these, nothing in this plan can run.

**Soft dependency: EP-4** (`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`) —
when present, Knative emits request metrics that VMAgent scrapes (visible in Grafana) and provides an
ingress path that could expose Grafana over a Tailscale-only hostname. Absent, the stack still installs
and shows node + Kubernetes metrics; Grafana is reached by port-forward.

**Charts and Helm repos (embedded so a novice needs nothing external):**

- `vm/victoria-metrics-k8s-stack` from `https://victoriametrics.github.io/helm-charts/` — metrics +
  Grafana, installed in `monitoring` as release `vmks`. Values:
  `cluster/observability/victoria-metrics/values.yaml`.
- `vm/victoria-logs-single` (release `victoria-logs`) and `vm/victoria-logs-collector` (release
  `victoria-logs-collector`) in `logging`. Values: `cluster/observability/victoria-logs/values.yaml` and
  `cluster/observability/victoria-logs/collector-values.yaml`.
- `vm/victoria-traces-single` (release `victoria-traces`, **beta 0.1.x**) in `tracing`. Values:
  `cluster/observability/victoria-traces/values.yaml`.
- `open-telemetry/opentelemetry-collector` from
  `https://open-telemetry.github.io/opentelemetry-helm-charts` (release `otel-collector`) in `tracing`.
  Values: `cluster/observability/opentelemetry-collector/values.yaml`.

**In-cluster service URLs and ports (the contract Grafana and apps use).** Service names are
release-name/chart-version dependent — discover the exact names with `kubectl get svc -n <namespace>` and
substitute them. Known patterns and ports:

- VictoriaMetrics (VMSingle): `http://vmsingle-vmks-victoria-metrics-k8s-stack.monitoring.svc:8429`,
  Grafana datasource type `prometheus`. (Auto-provisioned by the chart.)
- VictoriaLogs: `http://vls-victoria-logs-single-server.logging.svc:9428`, Grafana datasource plugin id
  `victoriametrics-logs-datasource`.
- VictoriaTraces: `http://victoria-traces-vt-single-server.tracing.svc:10428/select/jaeger`, Grafana
  datasource type `jaeger`. OTLP/HTTP ingest path on 10428 is `/insert/opentelemetry/v1/traces`.
- OpenTelemetry Collector: `otel-collector-opentelemetry-collector.tracing.svc` on OTLP gRPC `4317` and
  OTLP HTTP `4318`. **This is the endpoint EP-6 applications target to emit traces.** Apps set their OTLP
  exporter to this address; the Collector forwards to VictoriaTraces. EP-6 will document this as the trace
  destination its deployed apps use.

**Grafana datasource provisioning files** (committed for reproducibility):
`cluster/observability/grafana/datasources/victoria-logs.yaml` and
`cluster/observability/grafana/datasources/victoria-traces.yaml`; the VictoriaMetrics datasource is
auto-provisioned by the metrics chart and mirrored in `additionalDataSources`.

**Namespaces established (Integration Point 5):** `monitoring`, `logging`, `tracing`. EP-6's apps in
`personal` are observed automatically (logs via the collector, metrics via VMAgent, traces via the
Collector endpoint).
