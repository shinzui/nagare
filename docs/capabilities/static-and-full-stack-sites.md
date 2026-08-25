---
title: "Static and full-stack site releases"
type: Capability
description: "Build and publish static or server-rendered sites with typed routing policy, immutable releases, previews, and rollback commands."
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
capabilityId: CAP-8
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Dsl.Static"
  - "Nagare.Dsl.Server"
  - "nagarectl site deploy|releases|rollback|preview"
requires:
  - CAP-4
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/StaticSpec.hs
    proves: Static-site constructors, config loading, Nginx generation, Service rendering, and DomainMappings are golden tested.
  - kind: test
    resource: cli/nagare-dsl/test/ServerSpec.hs
    proves: Full-stack server-site loading and manifest rendering are tested separately from static hosting.
  - kind: test
    resource: cli/nagarectl/test/Spec.hs
    proves: Builds, release logs, previews, webhook verification, and cleanup policies are covered by the CLI suite.
  - kind: example
    resource: cluster/examples/tanstack-start/nagare/Config.hs
    proves: A full-stack TanStack Start deployment is represented with the shipped typed config.
  - kind: guide
    resource: docs/user/static-hosting.md
    proves: Deploy, preview, release inspection, rollback, redirects, headers, and webhook use are documented.
---

# Static and full-stack site releases

Static sites build into an Nginx image with checked redirects, headers, cache policy, 404 handling,
and DomainMappings. Full-stack server sites keep a runtime process while using the same release and
hostname model. `nagarectl site` records immutable releases, creates named previews, and selects an
older release for rollback.

The rendered sites run on the [Knative serving, ingress, and TLS bootstrap](knative-serving-ingress-and-tls.md)
(CAP-4), or an equivalent Knative target.

## Limits

- Release metadata is maintained by Nagare rather than by a transactional deployment controller.
- Static and server renderers are well tested offline, but the current release/preview command set
  has not been exercised end to end on the powered-down cloud target.
- Git webhook deployment requires a separately configured `nagared` endpoint and secret.
