---
title: "Target contexts and project onboarding"
type: Capability
description: "Select an isolated cloud or local target by name and seed a fresh GCP project without relying on ambient project state."
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
capabilityId: CAP-1
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagarectl
interface:
  - "nagarectl context create|list|show|use|current|delete"
  - "nagarectl --context NAME"
  - "nagarectl init"
evidence:
  - kind: test
    resource: cli/nagarectl/test/Spec.hs
    proves: Context precedence, persistence, cloud/local decoding, per-context Pulumi state, and onboarding command construction are tested offline.
  - kind: guide
    resource: docs/user/contexts.md
    proves: The complete create, select, inspect, and isolate workflow for named targets.
  - kind: guide
    resource: docs/user/onboarding-bring-your-own-project.md
    proves: The ordered bring-your-own-project flow centered on nagarectl init.
---

# Target contexts and project onboarding

A context is a named target bundle containing the project, region, domain, registry, object-store,
Pulumi backend, and operating mode. `nagarectl --context NAME` selects one command without changing
the saved default; `nagarectl context use NAME` changes the default. Cloud commands fail closed when
ambient GCP state disagrees with the selected target.

`nagarectl init` checks a fresh project, enables the required APIs, writes the target configuration,
and seeds Pulumi inputs. Local contexts carry the equivalent loopback and MinIO settings without a
GCP project.

## Limits

- The older `nagare.target.env` and `nagare.local.env` files remain fallback paths, so context use is
  not yet the only configuration route.
- Most context and onboarding evidence is hermetic command construction. Enabling APIs and seeding a
  real project still require operator credentials, billing, and network access.
- The context format and CLI remain experimental and may change in a later release.
