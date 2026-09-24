---
type: Term
title: CDN origin
description: The Nagare hostname or service to which an edge cache forwards requests it cannot serve itself.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-21
status: current
tags: [applications-delivery]
anchors:
  - kind: doc
    resource: docs/user/cdn.md
---

# CDN origin

The Nagare hostname or service to which an edge cache forwards requests it cannot serve itself. A CDN hostname has its own DNS and TLS path to the origin. The edge cache changes delivery, while the Nagare service remains the source for uncached responses.

See [Cdn](../../docs/user/cdn.md) for the full contract and operating procedure.
