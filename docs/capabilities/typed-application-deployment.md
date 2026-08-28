---
title: "Typed application deployment"
type: Capability
description: "Describe an application as checked Haskell data, build or select its image, render Knative resources, apply them, and wait for a reachable revision with one command."
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
capabilityId: CAP-6
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "nagare/Config.hs"
  - "Nagare.Dsl"
  - "nagarectl deploy"
requires:
  - CAP-4
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/Spec.hs
    proves: Smart constructors, typed loading, presets, build modes, volume rendering, and golden Knative manifests are exercised together.
  - kind: test
    resource: cli/nagarectl/test/Spec.hs
    proves: Build-mode selection, image qualification, deploy support functions, and target-aware command construction are tested offline.
  - kind: test
    resource: scripts/local-smoke.sh
    proves: The actual CLI builds, pushes, deploys, reaches, and tears down a typed application on the local platform.
  - kind: guide
    resource: docs/user/deploying-apps.md
    proves: The consumer path from Config.hs through readiness and URL output is documented.
---

# Typed application deployment

A project exports checked deployment data from `nagare/Config.hs`. The DSL rejects invalid names,
scaling ranges, environment combinations, and paths before YAML exists. `nagarectl deploy` loads the
program, chooses a prebuilt, Dockerfile, or Nixpacks image path, pushes when necessary, renders
Knative resources, applies them, waits for readiness, and prints the URL.

This capability consumes the [Knative serving, ingress, and TLS bootstrap](knative-serving-ingress-and-tls.md)
(CAP-4), or an equivalent compatible Knative target.

## Limits

- Configuration is executed with `runghc`; it is code, not a sandboxed data file. The loader applies
  time and output bounds, but consumers should still treat project configuration as trusted code.
- The local end-to-end path is exercised. The latest cloud deployment path has not been rerun since
  the live VM was powered down.
- The `nagare-dsl` and `nagarectl` interfaces remain experimental in 0.1.0; later pre-1.0 releases
  may require an explicit platform upgrade.
