---
title: "Victoria observability stack"
type: Capability
description: "Install low-overhead metrics, logs, traces, OpenTelemetry collection, and Grafana dashboards for a single-node Nagare cluster."
generated:
  by: codex/gpt-5
  at: "2026-08-25T20:51:44Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-08-25T20:51:44Z"
    document_timestamp: "2026-08-25T20:51:44Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: codex/gpt-5
    effort: unspecified
    context: >-
      Reviewed the capability, compatibility promise, and repository evidence for inclusion in
      the version 0.1.0 Nix release.
verified:
  by: process:openai-codex
  at: "2026-08-25T20:51:44Z"
capabilityId: CAP-5
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - cluster-observability
interface:
  - "nagare observability"
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
