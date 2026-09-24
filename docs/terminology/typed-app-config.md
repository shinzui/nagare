---
type: Term
title: typed app config
description: An application-authored Haskell configuration file that emits a validated Nagare workload declaration.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-12
status: current
tags: [applications-delivery]
anchors:
  - kind: doc
    resource: docs/user/deploying-apps.md
---

# typed app config

An application-authored Haskell configuration file that emits a validated Nagare workload declaration. The conventional path is `nagare/Config.hs`. `nagarectl` loads it and renders Kubernetes resources; invalid names, quantities, and combinations fail before apply.

See [Deploying apps](../../docs/user/deploying-apps.md) for the full contract and operating procedure.
