---
type: Term
title: ACME identity
description: The contact address and certificate authority endpoint a context uses for automated TLS issuance.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-37
status: current
tags: [security-operations]
anchors:
  - kind: doc
    resource: docs/user/contexts.md
---

# ACME identity

The contact address and certificate authority endpoint a context uses for automated TLS issuance. The active context owns the identity. Staging and production directories have different effects on certificate trust and issuance.

See [Contexts](../../docs/user/contexts.md) for the full contract and operating procedure.
