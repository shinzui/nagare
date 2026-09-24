---
type: Term
title: multi-workload application
description: A typed application declaration that groups related workloads and services for one coordinated deploy.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-16
status: current
tags: [applications-delivery]
anchors:
  - kind: doc
    resource: docs/user/app-lifecycle.md
---

# multi-workload application

A typed application declaration that groups related workloads and services for one coordinated deploy. `nagarectl app deploy` can roll out a service together with workers, databases, and tasks. This grouping differs from a single HTTP `Deployment`.

See [App lifecycle](../../docs/user/app-lifecycle.md) for the full contract and operating procedure.
