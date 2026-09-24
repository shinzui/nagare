---
type: Term
title: scheduled task
description: A named finite workload that Nagare runs on a cron schedule or on demand.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-23
status: current
tags: [background-work]
related:
  - TERM-22
  - TERM-24
  - TERM-25
anchors:
  - kind: doc
    resource: docs/user/scheduled-tasks.md
---

# scheduled task

A named finite workload that Nagare runs on a cron schedule or on demand. A `Task` renders to a CronJob; `nagarectl task run` creates one Job from its template. It can inherit an associated app's image and environment.

See [Scheduled tasks](../../docs/user/scheduled-tasks.md) for the full contract and operating procedure.
