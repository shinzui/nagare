---
title: "Single-node GCP substrate"
type: Capability
description: "Provision a rebuildable personal PaaS perimeter on GCP and configure each NixOS k3s host from context-owned operator inputs."
generated:
  by: codex/gpt-5
  at: "2026-08-25T18:36:00Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-08-25T18:45:12Z"
    document_timestamp: "2026-08-25T18:36:00Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: codex/gpt-5
    effort: unspecified
    context: >-
      Reviewed the updated capability claim against the reusable NixOS module,
      host renderer tests, two-context generated-flake evaluations, root Nix
      checks, and the revised operator guides.
capabilityId: CAP-2
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: unreleased
packages:
  - infra-pulumi
  - nixos-hosts
interface:
  - "just infra-preview"
  - "just infra-up"
  - "just host-image"
  - "just host-switch"
  - "nagarectl host init|show|path"
evidence:
  - kind: module
    resource: infra/pulumi/index.ts
    proves: The Pulumi program composes the network, instance, disks, DNS, IAM, backup buckets, and optional CDN resources.
  - kind: module
    resource: nixos/modules/nagare-host.nix
    proves: The reusable host option boundary composes storage, networking, security, users, Tailscale, registries, and k3s without embedding operator identity.
  - kind: test
    resource: cli/nagarectl/test/HostSpec.hs
    proves: Host rendering validates public keys and keeps two contexts' identities and registries isolated.
  - kind: guide
    resource: docs/user/provisioning-with-pulumi.md
    proves: Operators can preview, apply, and inspect the cloud perimeter.
  - kind: guide
    resource: docs/user/host-image-and-boot.md
    proves: The image build, registration, first-boot, and host update path is documented end to end.
---

# Single-node GCP substrate

Nagare's Pulumi program owns the GCP perimeter: network and firewall rules, static address, DNS,
service identity, Artifact Registry, durable disks, backup buckets, and the Compute Engine instance.
The NixOS configuration owns the host and k3s runtime, so replacement starts from a pinned Nagare
module plus a context-owned generated flake rather than from an irreplaceable server image or mutable
source checkout. Operator SSH keys, registry identity, sops file, and on-host age-key path remain
separate for every context.

## Limits

- This is intentionally a single-node, non-HA substrate. Host maintenance interrupts workloads.
- Applying it creates billable GCP resources and requires a prepared project and credentials.
- Infrastructure protection and least-privilege changes exist on the default branch, but the latest
  revisions still await a live apply; the evidence is source and operator documentation rather than
  a hermetic infrastructure test.
- The repository has no release tags, so consumers must pin a commit.
