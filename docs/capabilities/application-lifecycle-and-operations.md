---
title: "Application and platform day-2 operations"
type: Capability
description: "Inspect and operate applications and the single-node platform without assembling raw kubectl and gcloud queries by hand."
generated:
  by: process:openai-codex
  at: "2026-10-10T05:03:04Z"
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
  - kind: test
    resource: cli/nagarectl/test/InventoryCleanupSpec.hs
    proves: Reviewed history cleanup preserves current releases and unrelated scopes and refuses stale bytes or missing ownership.
  - kind: guide
    resource: docs/user/resource-inventory.md
    proves: Accepted ownership, live observation, retained resources, and reviewed lifecycle are explained.
---

# Application and platform day-2 operations

The day-2 command surface turns Kubernetes and GCP state into application inventory, revision
history, logs, restart/stop/delete operations, domain and certificate readiness, a one-screen server
report, graded health checks with repair hints, and bounded cleanup of images, previews, and releases.
These commands share Nagare's target selection and output/parsing layer rather than exposing one
thin wrapper per underlying tool invocation.

In 0.4.0, managed mutations use the [reviewed operation ledger](reviewed-operation-ledger.md)
(CAP-22). Application deletion saves a retirement review; applying it retains members. Physical
collection requires its own eligible review. Inventory status and explain add ownership,
incarnation, dependency, and lifecycle findings through
[resource identity and reviewed lifecycle](resource-identity-and-lifecycle.md) (CAP-23).

## Limits

- Commands use native executors and provider transports; the inventory coordinates their evidence
  rather than replacing Kubernetes reconciliation or Pulumi state.
- Read-only inspection is not deletion authority. Legacy confirmed cleanup refuses after
  substantive inventory history; current image, release, and preview cleanup uses saved reviews.
- Durable members and retained consumers may block collection. Full-context physical teardown is
  outside the 0.4.0 inventory contract.
