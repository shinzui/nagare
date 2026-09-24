---
type: Term
title: build mode
description: The rule Nagare uses to obtain the container image deployed for an application.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-15
status: current
tags: [applications-delivery]
anchors:
  - kind: doc
    resource: docs/user/build-modes.md
---

# build mode

The rule Nagare uses to obtain the container image deployed for an application. The typed config chooses a prebuilt image, Dockerfile build, or Nixpacks build. A prebuilt image is neither built nor pushed by Nagare.

See [Build modes](../../docs/user/build-modes.md) for the full contract and operating procedure.
