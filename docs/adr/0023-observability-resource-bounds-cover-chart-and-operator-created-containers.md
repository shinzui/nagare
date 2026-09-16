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
passed its ten-minute stability gate. Long-term sizing and startup-memory
acceptance remain tracked in ExecPlan 100.

## Context

The first labs observability installation exposed eight containers without memory
limits despite explicit resources on the metrics, logs, and traces stores. Grafana,
its two sidecars, the exporters, and the operator inherited unbounded chart defaults.
Two config-reloaders were created by the operator and therefore absent from ordinary
Helm-rendered Pod templates. A successful render and Helm installation did not prove
the intended protection against a single container exhausting node memory.

Metrics and logs also experienced startup OOMs before becoming Ready. A later stable
sample cannot establish clean startup or size resources for a week of actual traffic.

## Decision

Observability resource coverage includes every regular and init container emitted
by the enabled charts and every container subsequently created by their operators.
Set explicit CPU and memory requests and a memory limit. New bounds use CPU floors
without adding CPU limits; this decision does not change the collector's existing
CPU limit. Initial sizes use observed usage plus headroom and remain subject to
measurement under representative traffic.

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
Live rollout checks must still inspect generated reloaders and their actual limits.
Changes to enabled components or operator resource semantics require updating both
the configuration and its coverage checks.

Single-node rollouts may briefly interrupt dashboards, scraping, or rule evaluation.
They use a bounded operator-approved sequence with readiness and restart gates.
Startup OOMs remain unresolved until observed evidence supports a correction; neither
an increased memory limit nor a later Ready snapshot alone closes that finding.
