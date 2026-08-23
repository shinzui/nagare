---
title: "Victoria observability stack"
type: Capability
description: "Install low-overhead metrics, logs, traces, OpenTelemetry collection, and Grafana dashboards for a single-node Nagare cluster."
generated:
  by: codex/gpt-5
  at: "2026-08-23T21:36:15Z"
capabilityId: CAP-5
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: unreleased
packages:
  - cluster-observability
interface:
  - "just observability"
  - "cluster/observability/install.sh"
evidence:
  - kind: module
    resource: cluster/observability/install.sh
    proves: One installer deploys VictoriaMetrics, VictoriaLogs, VictoriaTraces, the OpenTelemetry Collector, Grafana, and broker monitoring.
  - kind: module
    resource: cluster/observability/opentelemetry-collector/values.yaml
    proves: The repository defines the collector receivers, processors, and Victoria backends.
  - kind: guide
    resource: docs/user/observability.md
    proves: Installation, validation, access, retention, and troubleshooting are documented.
---

# Victoria observability stack

Nagare installs the VictoriaMetrics, VictoriaLogs, and VictoriaTraces family with an OpenTelemetry
Collector and Grafana data sources. The configuration is sized for a personal single-node platform
and includes broker monitoring assets alongside the core stack.

## Limits

- The installation is operational shell plus Helm values, not a tested reusable chart or library.
- Retention and replica choices favor low cost over high availability and long forensic history.
- The repository does not contain an automated observability conformance test; live installation
  status is documented, while manifest drift is checked manually.
- Publishing Grafana safely is a separate access-enforcement concern.
