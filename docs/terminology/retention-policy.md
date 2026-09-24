---
type: Term
title: retention policy
description: The rule deciding whether a workload data disk is kept or deleted when its owning resource is removed.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-28
status: current
tags: [data-recovery]
related:
  - TERM-26
  - TERM-27
  - TERM-31
anchors:
  - kind: doc
    resource: docs/user/persistent-storage.md
---

# retention policy

The rule deciding whether a workload data disk is kept or deleted when its owning resource is removed. `Retain` keeps the PVC by default; `Delete` destroys it. This choice is independent of whether backups exist in GCS or MinIO.

See [Persistent storage](../../docs/user/persistent-storage.md) for the full contract and operating procedure.
