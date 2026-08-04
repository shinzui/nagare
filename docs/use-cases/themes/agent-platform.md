---
title: "Theme — Agent Platform"
type: Use Case Theme
description: "Nagare as a place agents run: the storage, identity, and data primitives an autonomous coding agent needs in order to work on real projects from inside the cluster."
generated:
  by: claude-code/2.1.221
  at: "2026-08-04T14:22:54Z"
---

# Theme: agent platform

Use cases in which the actor is an **agent running on Nagare** rather than a person deploying an
application to it.

Agents have infrastructure needs that ordinary web workloads do not. They read far more than they
write, and they read across project boundaries rather than within one deployment. They need
durable, shared, read-mostly access to code and knowledge that no single application owns. And the
substrate they read has to be reproducible, because an agent that reads a stale or partial corpus
produces confidently wrong work rather than failing loudly.

Use cases under this theme record what Nagare must supply for that, and — as important — what it
deliberately does not: this theme is not a mandate for general multi-writer shared storage, which
Nagare's single-node model excludes by design.
