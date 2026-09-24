---
type: Term
title: worker
description: A continuously running Nagare workload with a fixed replica count and no HTTP ingress.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-22
status: current
tags: [background-work]
related:
  - TERM-13
  - TERM-23
  - TERM-24
anchors:
  - kind: doc
    resource: docs/user/workers.md
---

# worker

A continuously running Nagare workload with a fixed replica count and no HTTP ingress. A `Worker` renders to a Kubernetes `apps/v1` Deployment. Use it for queue consumers and similar processes that must keep running without requests.

See [Workers](../../docs/user/workers.md) for the full contract and operating procedure.
