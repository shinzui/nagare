---
type: Term
title: host flake
description: A context-owned Nix flake that defines the NixOS configuration for a Nagare host.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-10
status: current
tags: [platform-targets]
anchors:
  - kind: doc
    resource: docs/user/host-image-and-boot.md
---

# host flake

A context-owned Nix flake that defines the NixOS configuration for a Nagare host. The generated flake binds host settings to the selected context and release. Operators retain its editable host and secret inputs outside the immutable payload.

See [Host image and boot](../../docs/user/host-image-and-boot.md) for the full contract and operating procedure.
