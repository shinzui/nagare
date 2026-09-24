---
type: Term
title: Nix binary cache
description: An optional context-local service that distributes signed prebuilt Nix store closures to opted-in jobs.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-33
status: current
tags: [data-recovery]
anchors:
  - kind: doc
    resource: docs/user/nix-binary-cache.md
---

# Nix binary cache

An optional context-local service that distributes signed prebuilt Nix store closures to opted-in jobs. Nagare runs Attic for this cache. Consumers verify the signing key, and cache content is transport rather than the artifact source of truth.

See [Nix binary cache](../../docs/user/nix-binary-cache.md) for the full contract and operating procedure.
