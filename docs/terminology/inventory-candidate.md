---
type: Term
title: inventory candidate
description: A digest-bound proposed resource inventory produced by composing declared scopes and explicit changes.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-42
status: current
tags: [security-operations]
related:
  - TERM-41
anchors:
  - kind: doc
    resource: docs/architecture/resource-inventory.md
---

# inventory candidate

A digest-bound proposed resource inventory produced by composing declared scopes and explicit changes. Its manifest records base generations and desired changes. Loading it verifies exact member bytes and recomposes the result before execution.

See [Resource inventory](../../docs/architecture/resource-inventory.md) for the full contract and operating procedure.
