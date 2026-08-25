---
title: "Application and platform day-2 operations"
type: Capability
description: "Inspect and operate applications and the single-node platform without assembling raw kubectl and gcloud queries by hand."
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
capabilityId: CAP-10
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagarectl
interface:
  - "nagarectl app list|get|logs|restart|stop|delete"
  - "nagarectl deployments list|logs"
  - "nagarectl doctor"
  - "nagarectl server status"
  - "nagarectl domains list"
  - "nagarectl cleanup"
evidence:
  - kind: test
    resource: cli/nagarectl/test/Spec.hs
    proves: App and deployment discovery, health grading, remediation hints, domain readiness, cleanup retention, and output formatting are tested from representative API responses.
  - kind: guide
    resource: docs/user/app-lifecycle.md
    proves: Application inventory, logs, restart, stop, deletion, and deployment history workflows are documented.
  - kind: guide
    resource: docs/user/troubleshooting.md
    proves: Diagnostic results are connected to concrete operator remediation.
---

# Application and platform day-2 operations

The day-2 command surface turns Kubernetes and GCP state into application inventory, revision
history, logs, restart/stop/delete operations, domain and certificate readiness, a one-screen server
report, graded health checks with repair hints, and bounded cleanup of images, previews, and releases.
These commands share Nagare's target selection and output/parsing layer rather than exposing one
thin wrapper per underlying tool invocation.

## Limits

- The CLI shells out to installed `kubectl`, `gcloud`, container, and Pulumi tools; it is not a
  direct Kubernetes or cloud API client.
- Parsers and decisions are covered by fixtures, but several live verbs remain pending a fresh
  cloud-target exercise.
- Cleanup is dry-run by default, but confirmed operation mutates cluster and host state and should be
  reviewed before use.
