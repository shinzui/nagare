---
type: Term
title: persistent volume claim
description: The Kubernetes request for durable storage backing a Nagare app volume or stateful service.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-27
status: current
tags: [data-recovery]
related:
  - TERM-26
  - TERM-28
  - TERM-31
anchors:
  - kind: doc
    resource: docs/user/persistent-storage.md
---

# persistent volume claim

The Kubernetes request for durable storage backing a Nagare app volume or stateful service. On Nagare's single node, the local-path StorageClass places PVC data on the host data disk. A PVC is storage, not an object-store backup.

See [Persistent storage](../../docs/user/persistent-storage.md) for the full contract and operating procedure.
