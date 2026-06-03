# Observability

> **Status:** 🔭 Planned (EP-5) — **not built yet.**
>
> Target runbook. The `cluster/observability/` manifests and Helm values do not
> exist on disk yet, and `just observability` references chart values EP-5 will
> create. Treat commands here as the intended design until EP-5 lands.

Nagare's observability is the **Victoria stack** — VictoriaMetrics (metrics),
VictoriaLogs (logs), and VictoriaTraces (traces) — plus an **OpenTelemetry
Collector** and **Grafana**. It deliberately replaces Prometheus + Loki + Tempo
because the Victoria components have lower memory and operational overhead, which
matters on a single cheap node. The goal is "enough visibility to debug personal
projects," not a production observability platform.

---

## The pieces

| Component | Namespace | Role |
| --- | --- | --- |
| **VictoriaMetrics** (`victoria-metrics-k8s-stack`, `vmsingle`) | `monitoring` | Metrics storage + scraping (vmagent), node-exporter, kube-state-metrics. |
| **VictoriaLogs** (`victoria-logs-single`) | `logging` | Log storage. |
| **VictoriaLogs collector** (`victoria-logs-collector`, Vector-based) | `logging` | Ships pod logs into VictoriaLogs. |
| **VictoriaTraces** (`victoria-traces-single`) | `tracing` | Trace storage. **Pre-GA / beta — treat as experimental.** |
| **OpenTelemetry Collector** | (with the stack) | Receives OTLP from apps (`4317`/`4318`), exports traces to VictoriaTraces on `:10428`. |
| **Grafana** (bundled with the metrics stack) | `monitoring` | Dashboards over all three pillars. |

Data persists under the data disk: `/var/lib/nagare/victoria-metrics`,
`/var/lib/nagare/victoria-logs`, `/var/lib/nagare/victoria-traces` (created by
the host's `nagare-data-layout` unit).

## Install

```bash
just observability
```

which adds the VictoriaMetrics Helm repo and installs each chart with the values
under `cluster/observability/`:

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update
helm upgrade --install vmks vm/victoria-metrics-k8s-stack \
  --namespace monitoring --create-namespace \
  -f cluster/observability/victoria-metrics/values.yaml
helm upgrade --install victoria-logs vm/victoria-logs-single \
  --namespace logging --create-namespace \
  -f cluster/observability/victoria-logs/values.yaml
helm upgrade --install victoria-logs-collector vm/victoria-logs-collector \
  --namespace logging \
  -f cluster/observability/victoria-logs/collector-values.yaml
helm upgrade --install victoria-traces vm/victoria-traces-single \
  --namespace tracing --create-namespace \
  -f cluster/observability/victoria-traces/values.yaml
```

> In the `victoria-metrics-k8s-stack` chart, `vmsingle` and `vmcluster` are
> **mutually exclusive** — enable `vmsingle` only. Grafana, node-exporter,
> kube-state-metrics are enabled; alertmanager can stay off for personal use.

## How apps emit telemetry

- **Metrics** — apps expose Prometheus metrics; vmagent scrapes them into
  VictoriaMetrics.
- **Logs** — stdout/stderr from every pod is collected by the Vector-based
  collector into VictoriaLogs (no app changes needed).
- **Traces** — apps send **OTLP to the OpenTelemetry Collector** (`4317` gRPC /
  `4318` HTTP). The Collector exports to VictoriaTraces on **`:10428`** at
  `/insert/opentelemetry/v1/traces`.

> Common confusion: ports `4317`/`4318` belong to the **OTel Collector**, not
> VictoriaTraces. Apps talk to the Collector; the Collector talks to
> VictoriaTraces on `10428`.

## Grafana

Grafana ships with the metrics stack. Configure three datasources:

| Pillar | Datasource type | URL |
| --- | --- | --- |
| Metrics | Prometheus (VictoriaMetrics) | the `vmsingle` service in `monitoring` |
| Logs | `victoriametrics-logs-datasource` (official signed plugin) | the VictoriaLogs service in `logging` |
| Traces | **Jaeger** | `http://<victoria-traces>.tracing.svc:10428/select/jaeger` |

Dashboards live in Git so they're reproducible (see
[Backups and disaster recovery](backups-and-disaster-recovery.md)).

### Exposing Grafana

Reach Grafana over the **tailnet** (the host trusts `tailscale0`) or a
short-lived [IAP/Tailscale port-forward](accessing-the-host.md) rather than
exposing it publicly. Publishing Grafana on the wildcard domain with auth is a
later option, not the default — it's listed as an open question in the spec.

## Verify

- All pods in `monitoring`, `logging`, `tracing` are `Running`.
- Grafana loads and its three datasources test green.
- A deployed app's metrics appear, its logs are searchable, and a trace shows
  up end-to-end after a request.

## Next

Deploy applications onto the platform:
**[Deploying apps →](deploying-apps.md)**
