---
type: Term
title: backup store
description: The context-selected object store that holds Nagare database backups and volume snapshots.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-32
status: current
tags: [data-recovery]
related:
  - TERM-31
anchors:
  - kind: doc
    resource: docs/user/backups-and-disaster-recovery.md
---

# backup store

The context-selected object store that holds Nagare database backups and volume snapshots. Cloud mode uses GCS and local mode uses MinIO. A retained PVC stays on the host, whereas the backup store holds copies for recovery.

See [Backups and disaster recovery](../../docs/user/backups-and-disaster-recovery.md) for the full contract and operating procedure.
