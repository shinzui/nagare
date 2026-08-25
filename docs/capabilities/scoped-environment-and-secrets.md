---
title: "Scoped environment and secret management"
type: Capability
description: "Manage runtime, build, and preview environment values separately, including stdin-only secrets and exact dotenv reconciliation."
generated:
  by: codex/gpt-5
  at: "2026-08-25T20:51:44Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-08-25T20:51:44Z"
    document_timestamp: "2026-08-25T20:51:44Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: codex/gpt-5
    effort: unspecified
    context: >-
      Reviewed the capability, compatibility promise, and repository evidence for inclusion in
      the version 0.1.0 Nix release.
verified:
  by: process:openai-codex
  at: "2026-08-25T20:51:44Z"
capabilityId: CAP-9
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "nagarectl env list|set|delete|sync"
  - "nagarectl secret list|set|delete"
requires:
  - CAP-6
evidence:
  - kind: test
    resource: cli/nagarectl/test/Spec.hs
    proves: Store operations, dotenv parsing, exact reconciliation, generated variables, build arguments, and preview overlays are tested.
  - kind: example
    resource: cluster/examples/env-and-secrets/nagare/Config.hs
    proves: A typed application consumes scoped literals and secret references.
  - kind: guide
    resource: docs/user/env-and-secrets.md
    proves: Scope selection, sync, secret input, generated NAGARE variables, and precedence are documented.
---

# Scoped environment and secret management

Environment values and secrets live in managed per-application stores with explicit runtime,
build, and preview scopes. Dotenv sync can merge or reconcile exactly. Secret values are read from
standard input instead of command-line arguments, and deploy-time generated values are resolved with
defined precedence before manifests or build arguments are produced.

The stores feed [typed application deployment](typed-application-deployment.md) (CAP-6).

## Limits

- Kubernetes Secrets are storage objects, not a complete external secret-management system.
- Build-scoped secret handling inherits the security properties of the selected container builder.
- The store and reconciliation logic is strongly tested offline; real cluster RBAC and secret-at-rest
  configuration remain operator responsibilities.
