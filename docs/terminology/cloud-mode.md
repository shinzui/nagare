---
type: Term
title: cloud mode
description: The Nagare operating mode that provisions a GCP VM and uses its NixOS and k3s platform.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-3
status: current
tags: [platform-targets]
anchors:
  - kind: doc
    resource: docs/user/contexts.md
---

# cloud mode

The Nagare operating mode that provisions a GCP VM and uses its NixOS and k3s platform. A cloud context names its GCP project and zone. Project guards compare those values with credentials and command targets before mutation.

See [Contexts](../../docs/user/contexts.md) for the full contract and operating procedure.
