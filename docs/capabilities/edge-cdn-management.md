---
title: "Edge CDN management"
type: Capability
description: "Front Nagare hostnames with Cloudflare or Google Cloud CDN using typed cache policy, provider provisioning, status, purge, and disable operations."
generated:
  by: codex/gpt-5
  at: "2026-08-23T21:36:15Z"
capabilityId: CAP-17
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: unreleased
packages:
  - nagare-dsl
  - nagarectl
  - infra-pulumi
interface:
  - "Nagare.Dsl.Cdn.Types"
  - "nagarectl cdn list|status|purge|disable"
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/CdnSpec.hs
    proves: Provider and cache-rule validation plus config encoding and decoding are tested.
  - kind: test
    resource: cli/nagarectl/test/Spec.hs
    proves: Cloudflare requests, Google command plans, DNS changes, cache configuration, status formatting, purge, and dry-run output are tested.
  - kind: module
    resource: infra/pulumi/src/components/NagareCdn.ts
    proves: The standing Google Cloud CDN load-balancer resources are defined as an opt-in component.
  - kind: example
    resource: cluster/examples/static-cdn-site/nagare/Config.hs
    proves: A shipped static-site configuration declares an edge provider and path-specific cache rules.
  - kind: guide
    resource: docs/user/cdn.md
    proves: Provider setup, DNS, origin TLS, deployment, status, purge, disable, and cost caveats are documented.
---

# Edge CDN management

A typed `cdn` field selects Cloudflare or Google Cloud CDN and carries default and path-specific
cache policy. Nagare provisions the provider resources, points DNS at the edge, preserves origin TLS,
reports edge readiness, purges all or selected paths, and can return DNS to the VM. The Google path
uses an opt-in standing Pulumi component; the Cloudflare path uses its HTTP API.

## Limits

- Provider credentials, delegated DNS, and provider-specific permissions are required.
- Google Cloud CDN resources can incur standing costs even when application traffic is low.
- Both provider plans and request shapes are tested offline, but the operator guide still records a
  live edge deployment as pending.
- Cache invalidation and propagation timing are controlled by the provider, not Nagare.
