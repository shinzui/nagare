---
type: Term
title: replacement cutover
description: A guarded upgrade that moves service from an old host to a separately prepared candidate host.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-40
status: current
tags: [security-operations]
anchors:
  - kind: doc
    resource: docs/user/upgrades.md
---

# replacement cutover

A guarded upgrade that moves service from an old host to a separately prepared candidate host. The procedure reserves rollback time, controls write admission, and verifies the candidate before context promotion. It is distinct from an in-place host switch.

See [Upgrades](../../docs/user/upgrades.md) for the full contract and operating procedure.
