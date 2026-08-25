---
title: "Scheduled and on-demand tasks"
type: Capability
description: "Declare CronJob-backed tasks with typed schedules and app inheritance, then list, run, inspect logs, or delete them through nagarectl."
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
capabilityId: CAP-13
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Dsl.Task"
  - "nagarectl task list|run|logs|delete"
requires:
  - CAP-6
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/Spec.hs
    proves: Task construction, schedule validation, encoding, loading, and CronJob rendering are tested.
  - kind: test
    resource: cli/nagarectl/test/Spec.hs
    proves: Discovery selectors, one-off Job naming, log arguments, image and environment inheritance, and resolved CronJob output are tested.
  - kind: example
    resource: cluster/examples/heartbeat-task/nagare/Config.hs
    proves: A shipped config declares a recurring application task.
  - kind: guide
    resource: docs/user/scheduled-tasks.md
    proves: Declaration, deploy-time provisioning, manual runs, logs, deletion, and inheritance are documented.
---

# Scheduled and on-demand tasks

A typed task carries its cron schedule, command, image policy, environment, and history settings.
Tasks declared by an application can inherit its resolved image and environment while receiving
task-specific `NAGARE_*` values. Deployment creates CronJobs; `nagarectl task run` derives an
on-demand Job from the same definition.

Provisioning through an application builds on
[typed application deployment](typed-application-deployment.md) (CAP-6).

## Limits

- The model and command construction are tested, but the operator guide still marks the live run as
  pending on a current cloud target.
- Kubernetes CronJob scheduling semantics and cluster clock behavior remain upstream concerns.
- Tasks are not a durable workflow engine: Nagare supplies scheduling and operations, not retries
  across a multi-step business process.
