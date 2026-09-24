---
type: Term
title: app volume
description: A durable disk mounted at a declared path in a Nagare app container.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-26
status: current
tags: [data-recovery]
related:
  - TERM-27
  - TERM-28
  - TERM-31
anchors:
  - kind: doc
    resource: docs/user/persistent-storage.md
---

# app volume

A durable disk mounted at a declared path in a Nagare app container. Files under the mount path survive pod replacement; files elsewhere in the container do not. A volume-bearing Knative service is pinned to one replica.

See [Persistent storage](../../docs/user/persistent-storage.md) for the full contract and operating procedure.
