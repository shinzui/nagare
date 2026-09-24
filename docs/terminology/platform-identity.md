---
type: Term
title: platform identity
description: The set of release versions reported by the CLI, payload, context, host, and cluster for compatibility checks.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-7
status: current
tags: [platform-targets]
anchors:
  - kind: doc
    resource: docs/user/upgrades.md
---

# platform identity

The set of release versions reported by the CLI, payload, context, host, and cluster for compatibility checks. `nagarectl platform status` compares these identities. A missing or unreachable identity can produce `legacy-unknown`; it does not prove compatibility.

See [Upgrades](../../docs/user/upgrades.md) for the full contract and operating procedure.
