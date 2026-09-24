---
type: Term
title: volume snapshot
description: An object-store copy of an app volume used for later restore.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-31
status: current
tags: [data-recovery]
related:
  - TERM-26
  - TERM-32
anchors:
  - kind: doc
    resource: docs/user/persistent-storage.md
---

# volume snapshot

An object-store copy of an app volume used for later restore. Snapshots are separate from the live PVC and require a restore operation. Cloud contexts use GCS; local contexts use MinIO.

See [Persistent storage](../../docs/user/persistent-storage.md) for the full contract and operating procedure.
