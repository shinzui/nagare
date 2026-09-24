---
type: Term
title: context guard
description: A preflight check that refuses cloud mutations when the active context, credentials, stack, or project disagree.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-8
status: current
tags: [platform-targets]
anchors:
  - kind: doc
    resource: docs/user/contexts.md
---

# context guard

A preflight check that refuses cloud mutations when the active context, credentials, stack, or project disagree. Run `nagarectl context guard` to inspect the selected target before infrastructure work. It prevents an ambient GCP setting from silently changing the project.

See [Contexts](../../docs/user/contexts.md) for the full contract and operating procedure.
