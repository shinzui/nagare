---
title: "Single-node GCP substrate"
type: Capability
description: "Provision a rebuildable personal PaaS perimeter on GCP and configure its single NixOS k3s host from source."
generated:
  by: codex/gpt-5
  at: "2026-08-23T21:36:15Z"
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
evidence:
  - kind: module
    resource: infra/pulumi/index.ts
    proves: The Pulumi program composes the network, instance, disks, DNS, IAM, backup buckets, and optional CDN resources.
  - kind: module
    resource: nixos/hosts/nagare-01/configuration.nix
    proves: The host configuration imports storage, networking, security, users, Tailscale, registries, and k3s modules.
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
The NixOS configuration owns the host and k3s runtime, so replacement starts from source rather than
from an irreplaceable server image.

## Limits

- This is intentionally a single-node, non-HA substrate. Host maintenance interrupts workloads.
- Applying it creates billable GCP resources and requires a prepared project and credentials.
- Infrastructure protection and least-privilege changes exist on the default branch, but the latest
  revisions still await a live apply; the evidence is source and operator documentation rather than
  a hermetic infrastructure test.
- The repository has no release tags, so consumers must pin a commit.
