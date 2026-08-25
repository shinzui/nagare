---
title: "Versioned Nix distribution and clone-free operation"
type: Capability
description: "Run a version-matched Nagare CLI and immutable platform payload from a semantic Git tag without a source checkout."
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
      Reviewed release consistency tests, native artifact assembly, the tag workflow, Nix payload
      checks, and clone-free operator documentation for version 0.1.0.
verified:
  by: process:openai-codex
  at: "2026-08-25T20:51:44Z"
capabilityId: CAP-19
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagarectl
  - nagare-platform
interface:
  - "nix run github:shinzui/nagare/vX.Y.Z#nagarectl"
  - "nix profile install github:shinzui/nagare/vX.Y.Z#nagare"
  - "nagarectl platform root|status|upgrade"
  - "nagare RECIPE"
evidence:
  - kind: module
    resource: flake.nix
    proves: The root flake exports the versioned CLI, immutable payload, operator launcher, and release checks for every supported system.
  - kind: test
    resource: scripts/test-release.sh
    proves: The release gate rejects inconsistent versions and tags and assembles deterministic native-system evidence.
  - kind: conformance
    resource: .github/workflows/release.yml
    proves: Native runners validate tagged outputs before the minimal-permission job publishes immutable attachments.
  - kind: guide
    resource: docs/user/installation.md
    proves: App developers, operators, and contributors have distinct pinned or source-based installation paths.
---

# Versioned Nix distribution and clone-free operation

A semantic tag selects one `nagarectl` closure and its matching immutable platform payload. The
installed CLI loads external typed app configuration; the full `nagare` package additionally runs
release-owned operator recipes from a content-addressed XDG workspace. Contexts, host inputs,
credentials, Pulumi state, and upgrade transactions remain mutable outside the release.

Release publication checks Cabal, CLI, payload, host-schema, compatibility-fixture, notes, source
revision, and supported-system consistency. GitHub attachments provide the release manifest, native
Nix output identities, notes, and checksums rather than claiming portable binary archives.

## Limits

- Nix is the only supported distribution channel in version 0.1.0.
- External cloud, Kubernetes, secret, and container clients remain operator prerequisites.
- A release tag appears only after explicit maintainer publication; default-branch source is not a
  substitute for a published semantic tag.
