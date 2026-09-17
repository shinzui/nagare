---
title: "Observability resource bounds cover chart and operator-created containers"
status: accepted
date: 2026-09-16
authors: [shinzui]
related:
  - docs/plans/100-bound-and-harden-cluster-workloads.md
  - docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
---

# ADR 23 — Observability resource bounds cover chart and operator-created containers

## Status

Accepted, 2026-09-16. Configuration and rendering checks are implemented. The
operator-approved labs rollout applied the additional bounds on the same day and
passed its ten-minute stability gate. A repository correction now limits the two
store cache budgets to 40% of their 512Mi cgroups. The separately approved staged
rollout completed on 2026-09-17: both stores retained their PVCs, started once with
zero restarts, and passed independent ten-minute stability and query gates.
Long-term sizing acceptance remains tracked in ExecPlan 100.

## Context

The first labs observability installation exposed eight containers without memory
limits despite explicit resources on the metrics, logs, and traces stores. Grafana,
its two sidecars, the exporters, and the operator inherited unbounded chart defaults.
Two config-reloaders were created by the operator and therefore absent from ordinary
Helm-rendered Pod templates. A successful render and Helm installation did not prove
the intended protection against a single container exhausting node memory.

Metrics and logs also experienced startup OOMs before becoming Ready. A later stable
sample cannot establish clean startup or size resources for a week of actual traffic.
Both processes correctly detected their 512Mi cgroup but used the upstream default
60% cache budget, reserving 307.2Mi for internal caches and leaving 204.8Mi for the
Go runtime and transient startup work. Kernel evidence put the killed processes at
about 509–510Mi anonymous RSS. The metrics store failed three times within its first
minute and the logs store once within its first 22 seconds; both later ran normally.

## Decision

Observability resource coverage includes every regular and init container emitted
by the enabled charts and every container subsequently created by their operators.
Set explicit CPU and memory requests and a memory limit. New bounds use CPU floors
without adding CPU limits; this decision does not change the collector's existing
CPU limit. Initial sizes use observed usage plus headroom and remain subject to
measurement under representative traffic.

Treat a Victoria `memory.allowedPercent` setting as an internal cache budget, not
as a total-process memory limit. Under the 512Mi hard caps, set both VMSingle and
VictoriaLogs to 40%, leaving 60% (307.2Mi) for the runtime, query/ingest work, and
startup allocations. Prefer reducing this bounded cache reservation before raising
the cgroup cap: the observed failures occurred immediately after default cache
sizing on otherwise empty stores, while both steady-state processes recovered under
the existing cap. A lower cache budget can trade memory for cache misses, CPU, and
disk I/O, so live clean-start and representative-history checks remain mandatory.

Use the chart's resource interfaces for direct workloads and the Victoria operator's
global reloader resource defaults for its generated sidecars. Keep notification
configuration independent: shared resource defaults must not enable Alertmanager or
change its delivery policy. Inspect pinned chart sources and verify the running
operator supports its settings before relying on them.

Validation has distinct obligations: exact-chart rendering checks direct containers
and custom-resource inputs; server dry runs establish admission; live inventories
establish operator reconciliation; restart observations establish stability over the
recorded interval; representative history informs sizing. None substitutes for the
others. Record node reservation headroom as well as individual limits, preserving
capacity for an application and database to schedule.

## Consequences

Chart upgrades must pass `scripts/test-observability-resources.sh`, which reads the
installer's version pins and rejects missing resource bounds across all five charts.
The check also requires both store cache budgets to remain at the accepted 40% while
their memory caps remain 512Mi. A future limit or workload change must reconsider the
percentage and preserve explicit non-cache headroom rather than inheriting the
upstream default silently.
Live rollout checks must still inspect generated reloaders and their actual limits.
Changes to enabled components or operator resource semantics require updating both
the configuration and its coverage checks.

Single-node rollouts may briefly interrupt dashboards, scraping, or rule evaluation.
They use a bounded operator-approved sequence with readiness and restart gates.
The cache-budget correction closed the labs startup finding only after each store
was deliberately restarted with its PVC retained, reached Ready without OOM/restart,
and remained stable for more than ten minutes while its query path passed. That
acceptance completed on 2026-09-17. Seven days of retained history remain a separate
sizing gate; neither this clean-start result nor a later Ready snapshot substitutes
for representative memory, CPU, cache-miss, and I/O observations.
