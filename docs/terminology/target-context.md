---
type: Term
title: target context
description: A named set of settings that selects the Nagare project, cluster, domain, registry, and operating mode for a command.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-2
status: current
tags: [platform-targets]
anchors:
  - kind: doc
    resource: docs/user/contexts.md
---

# target context

A named set of settings that selects the Nagare project, cluster, domain, registry, and operating mode for a command. A context lives in the operator's XDG configuration directory. Selecting `labs` directs commands to that target without switching source checkouts; `--context` selects one command.

See [Contexts](../../docs/user/contexts.md) for the full contract and operating procedure.
