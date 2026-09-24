---
type: Term
title: static site
description: A Nagare site whose built files are served from a small Nginx image.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-17
status: current
tags: [applications-delivery]
anchors:
  - kind: doc
    resource: docs/user/static-hosting.md
---

# static site

A Nagare site whose built files are served from a small Nginx image. The `StaticSite` declaration names an output directory and site behavior such as redirects and headers. It runs as a Knative Service.

See [Static hosting](../../docs/user/static-hosting.md) for the full contract and operating procedure.
