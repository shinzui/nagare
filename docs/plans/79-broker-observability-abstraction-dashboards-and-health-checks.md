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

Full plan before trimming: [79-broker-observability-abstraction-dashboards-and-health-checks.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/79-broker-observability-abstraction-dashboards-and-health-checks.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

