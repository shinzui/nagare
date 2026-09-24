---
type: Term
title: managed database credential
description: A generated Kubernetes Secret that holds a managed database password and connection URL.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-30
status: current
tags: [data-recovery]
anchors:
  - kind: doc
    resource: docs/user/managed-databases.md
---

# managed database credential

A generated Kubernetes Secret that holds a managed database password and connection URL. `nagarectl db create` generates the password once. Applications consume the connection URL through a Secret reference rather than copying credentials into their config or image.

See [Managed databases](../../docs/user/managed-databases.md) for the full contract and operating procedure.
