---
type: Term
title: one-shot job
description: A finite Nagare workload declared for a single bounded execution without a recurring schedule.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-24
status: current
tags: [background-work]
related:
  - TERM-22
  - TERM-23
anchors:
  - kind: doc
    resource: docs/user/one-shot-jobs.md
---

# one-shot job

A finite Nagare workload declared for a single bounded execution without a recurring schedule. A `Job` can carry a unique run ID, deadline, resource bounds, scratch space, and a default-deny network policy. It is separate from a scheduled `Task`.

See [One shot jobs](../../docs/user/one-shot-jobs.md) for the full contract and operating procedure.
