---
id: 79
slug: broker-observability-abstraction-dashboards-and-health-checks
title: "Broker observability abstraction dashboards and health checks"
kind: exec-plan
created_at: 2026-06-21T15:31:24Z
intention: "intention_01kvncmnzweearjz953y6besqc"
master_plan: "docs/masterplans/15-cluster-messaging-broker-for-nagare.md"
---

# Broker observability abstraction dashboards and health checks

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds the observability abstraction requested in the MasterPlan prompt. After it lands, a
Nagare broker has a provider-neutral health and metrics surface in the existing VictoriaMetrics and
Grafana stack. Redpanda-specific metric names may feed the dashboard in v1, but the user-facing
dashboard, docs, labels, and CLI health output talk about Nagare brokers: ready status, broker up,
topic count, produce/consume throughput, storage usage, and consumer lag where available.

The visible result is a Grafana dashboard and CLI checks that answer: "Is my broker up, can clients
connect, are topics moving messages, and is storage or memory becoming a problem?"


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Define the provider-neutral broker observability contract and metric mapping.
- [x] M2: Add scrape configuration for broker metrics to the VictoriaMetrics stack.
- [x] M3: Add Grafana dashboard assets and datasource wiring.
- [x] M4: Add `nagarectl broker get` or `doctor` health checks for broker readiness and scrape status.
- [x] M5: Validate with Redpanda and document Tansu mapping requirements.

Update 2026-06-21: EP-79 is complete. The provider-neutral contract and Redpanda v1 mapping live in
`cluster/observability/brokers/README.md`; VMAgent scrapes Redpanda Services through
`cluster/observability/brokers/vmservicescrape.yaml`; `cluster/observability/install.sh` applies the
scrape object and the `Nagare Brokers` Grafana dashboard ConfigMap; and `nagarectl broker get` now
prints pod readiness, `/public_metrics` reachability, and VictoriaMetrics scrape status. The new
health records in `Nagare.Broker.Health` use strict unprefixed fields and derive `Generic`.

Live validation used a disposable Redpanda broker `events` in namespace `personal` with topic `jobs`.
VMAgent reported:

```text
job=serviceScrape/monitoring/nagare-brokers/0 (1/1 up)
  state=up, endpoint=http://10.42.0.247:9644/public_metrics,
  labels={job="nagare-brokers", nagare_broker="events", nagare_broker_provider="redpanda", ...}
```

`nagarectl broker get events --namespace personal` reported all health checks OK:

```text
Health:
  OK      readiness         pod/events-0 Ready
  OK      metrics endpoint  /public_metrics reachable
  OK      metrics scrape    VictoriaMetrics has up=1 for this broker
```

Direct VictoriaMetrics query returned one `up=1` sample for
`up{job="nagare-brokers",nagare_broker="events"}`. Cleanup removed the StatefulSet, Service, and PVC;
`broker list --namespace personal` returned `(no managed brokers)`.

Final validation 2026-06-21:

- `cabal test nagarectl-test` from `cli/nagarectl` passed: 315 tests.
- `jq empty cluster/observability/grafana/dashboards/nagare-brokers.json` passed.
- Live `VMServiceScrape`, Grafana dashboard ConfigMap, `broker get`, and VictoriaMetrics query passed.
- `nix fmt cluster/observability cli/nagarectl docs/user/observability.md` failed because the flake
  does not provide `formatter.aarch64-darwin`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-21: The live VictoriaMetrics stack already had `selectAllByDefault: true` on its VMAgent,
  but the committed values now make that explicit. The broker `VMServiceScrape` was selected
  immediately and reached `updateStatus: operational`.

- 2026-06-21: `VMServiceScrape.spec.jobLabel` did not make a stable Nagare job label because the
  selected broker Service has no `nagare.dev/component` label; VMAgent initially stored
  `job="events"`. Adding an endpoint relabel to set `job="nagare-brokers"` made the CLI,
  dashboard, and direct PromQL contract stable.

- 2026-06-21: The temporary kubectl wrapper executes on the VM, so local dashboard JSON is not
  available to remote `kubectl create configmap --from-file`. Live dashboard validation used a
  stdin-applied ConfigMap; the committed `install.sh` path remains correct for normal local kubectl
  use.


## Decision Log

Record every decision made while working on the plan.

- Decision: Make the observability contract Nagare-owned, not Redpanda-owned.
  Rationale: The user explicitly wants an observability abstraction and expects a future Tansu switch.
  A Redpanda-only dashboard would make that migration harder.
  Date: 2026-06-21

- Decision: Use VictoriaMetrics `VMServiceScrape` rather than Prometheus `ServiceMonitor`.
  Rationale: The installed stack is VictoriaMetrics Operator based; `VMServiceScrape` is its native
  service-discovery object and can select Nagare-labelled broker Services across namespaces.
  Date: 2026-06-21

- Decision: Normalize broker samples to `job="nagare-brokers"` and Nagare-owned labels.
  Rationale: Broker Service names should not leak into the dashboard contract as the job name. Stable
  labels (`nagare_broker`, `nagare_broker_provider`) let Redpanda and a later Tansu provider share
  the same dashboard and CLI scrape query.
  Date: 2026-06-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-79 is complete. Nagare brokers now have a provider-neutral observability surface in the Victoria
stack: broker Services are scraped through Nagare labels, Grafana loads a source-controlled
`Nagare Brokers` dashboard, and `broker get` reports readiness, metrics endpoint reachability, and
VictoriaMetrics scrape status without requiring Grafana. The Redpanda v1 mapping is documented, and
the Tansu requirement is reduced to a clear provider obligation: expose Prometheus-format HTTP metrics
and map them onto the same Nagare concepts.

Remaining caveat: consumer lag panels are empty until Redpanda consumer group lag metrics are enabled
for a broker. This is a provider/runtime setting, not a gap in the scrape contract.


## Context and Orientation

Nagare's observability stack lives in `cluster/observability/`. `cluster/observability/install.sh`
installs VictoriaMetrics, VictoriaLogs, VictoriaTraces, OpenTelemetry Collector, and Grafana.
`cluster/observability/victoria-metrics/values.yaml` enables VMAgent scraping and Grafana dashboard
sidecars. Dashboard JSON belongs under `cluster/observability/grafana/dashboards/`. User docs live in
`docs/user/observability.md`.

Redpanda's Kubernetes docs describe monitoring through a ServiceMonitor when monitoring is enabled.
Nagare currently uses VictoriaMetrics' k8s stack, not a standalone Prometheus. The implementation must
verify whether a `ServiceMonitor` is enough with the installed Victoria stack, or whether Nagare should
use VMAgent scrape configuration or pod annotations. Tansu's README shows a broker option for
`--prometheus-listener-url` / `PROMETHEUS_LISTENER_URL`, so the abstraction should support any provider
that exposes Prometheus-format metrics over HTTP.

A **metric mapping** is the translation from provider-specific metric names into dashboard panels and
health concepts. It does not necessarily rename metrics in storage; it documents which provider metric
backs each Nagare concept.


## Plan of Work

M1 writes the contract in this plan and, if appropriate, a short checked-in reference such as
`cluster/observability/brokers/README.md`. The contract has concepts: broker up, ready replicas,
storage used, memory, CPU, request/produce/consume rates, topic count, partition count, and consumer
lag if provider metrics expose it.

M2 adds scrape config. If EP-75/EP-78 use Redpanda's Helm chart and it can emit a ServiceMonitor that
Victoria's operator discovers, add values or labels to make that happen. If not, add VMAgent scrape
configuration in `cluster/observability/victoria-metrics/values.yaml` or provider pod annotations.
Every scrape target must be selected by Nagare labels (`nagare.dev/broker`, `nagare.dev/broker-provider`).

M3 adds dashboards. Commit dashboard JSON under `cluster/observability/grafana/dashboards/`, with a
folder or dashboard title that says "Nagare Brokers." Panels should be useful on a single small node:
broker up, CPU/memory, disk, messages in/out, consumer lag, and scrape errors. Avoid panels that only
make sense for multi-node clusters unless clearly labelled as future/empty.

M4 adds CLI health integration. Extend `Nagare.Broker.Get` output or `Nagare.Ops.Doctor` to report
whether broker pods are ready and metrics are scrapeable. Do not require Grafana to be reachable for
CLI health.

M5 validates with live Redpanda. Query VictoriaMetrics directly or port-forward Grafana/Victoria and
capture a concise transcript showing metrics exist.


## Concrete Steps

Run initial inspection:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
sed -n '1,180p' cluster/observability/install.sh
sed -n '1,220p' cluster/observability/victoria-metrics/values.yaml
```

After changes:

```bash
nix fmt cluster/observability cli/nagarectl
cabal test nagarectl-test
```

Live scrape validation after a broker exists:

```bash
kubectl -n monitoring port-forward svc/vmsingle-vmks-victoria-metrics-k8s-stack 8429:8429
curl 'http://127.0.0.1:8429/api/v1/targets'
```

The exact service name may differ; use `kubectl get svc -n monitoring` to confirm.


## Validation and Acceptance

Acceptance requires:

- broker metrics are scraped into VictoriaMetrics using Nagare labels;
- the Grafana dashboard is loaded by the sidecar and has panels for broker up, resource usage,
  storage, and message/topic activity;
- CLI health output reports pod readiness and metrics scrape status;
- docs explain the provider-neutral observability concepts and the Redpanda v1 mapping; and
- the plan records what a future Tansu provider must expose to satisfy the same dashboard.


## Idempotence and Recovery

Observability installation is already idempotent through `cluster/observability/install.sh`. Re-running
`just observability` should update dashboards and scrape config in place. If a scrape config breaks
VMAgent, revert only the new broker scrape values or disable the broker-specific selector, then rerun
the installer.


## Interfaces and Dependencies

Files likely touched:

- `cluster/observability/victoria-metrics/values.yaml`
- `cluster/observability/grafana/dashboards/nagare-brokers.json`
- `cluster/observability/brokers/README.md`
- `docs/user/observability.md`
- `cli/nagarectl/src/Nagare/Broker/Get.hs`
- `cli/nagarectl/src/Nagare/Ops/Doctor.hs`

Provider requirements:

- Redpanda v1 must expose Prometheus-format metrics from the broker pod or service.
- Tansu later must expose Prometheus-format metrics through its Prometheus listener.
- Both providers must carry the Nagare broker labels on scrapeable Kubernetes resources.


## Revision Notes

2026-06-21: Completed EP-79 by adding the Nagare broker observability contract, VMServiceScrape,
Grafana dashboard asset, `broker get` health checks, user docs, parser tests, and live Redpanda
scrape validation against a disposable broker.
