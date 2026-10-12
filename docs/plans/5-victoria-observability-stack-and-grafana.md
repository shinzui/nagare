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

Full plan before trimming: [5-victoria-observability-stack-and-grafana.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/5-victoria-observability-stack-and-grafana.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

