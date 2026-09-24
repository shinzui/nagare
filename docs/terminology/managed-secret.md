---
type: Term
title: managed secret
description: An app-scoped secret value stored in Kubernetes and injected into a workload by reference.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-36
status: current
tags: [security-operations]
anchors:
  - kind: doc
    resource: docs/user/env-and-secrets.md
---

# managed secret

An app-scoped secret value stored in Kubernetes and injected into a workload by reference. `nagarectl secret` manages these values. A typed app config names the reference without embedding the secret bytes.

See [Env and secrets](../../docs/user/env-and-secrets.md) for the full contract and operating procedure.
