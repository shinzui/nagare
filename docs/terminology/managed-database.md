---
type: Term
title: managed database
description: A Nagare-operated single-replica database with typed configuration, persistent storage, and an internal service address.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-29
status: current
tags: [data-recovery]
anchors:
  - kind: doc
    resource: docs/user/managed-databases.md
---

# managed database

A Nagare-operated single-replica database with typed configuration, persistent storage, and an internal service address. Postgres, Redis, and ClickHouse are supported engines. A database runs as a StatefulSet and does not scale to zero or provide high availability.

See [Managed databases](../../docs/user/managed-databases.md) for the full contract and operating procedure.
