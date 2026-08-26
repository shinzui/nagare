---
title: "Rotating role-scoped forge credentials"
type: Capability
description: "Publish independently rotating, role-scoped GitHub App installation tokens to Kubernetes workloads without exposing App private keys."
generated:
  by: codex/gpt-5
  at: "2026-08-26T03:07:31Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-08-26T03:07:31Z"
    document_timestamp: "2026-08-26T03:07:31Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: codex/gpt-5
    effort: unspecified
    context: >-
      Reviewed the opt-in host module, disabled and enabled NixOS evaluations, refresh-helper
      tests, operator playbook, and explicit context-owned live-verification boundary.
verified:
  by: process:openai-codex
  at: "2026-08-26T03:07:31Z"
capabilityId: CAP-20
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nixos-hosts
interface:
  - "nagare.host.forgeCredentials.enable|namespace"
  - "nagare-forge-read|nagare-forge-write Kubernetes Secrets"
  - "nagare-forge-read-refresh|nagare-forge-write-refresh systemd units"
requires:
  - CAP-2
evidence:
  - kind: module
    resource: nixos/hosts/nagare-01/forge-credentials.nix
    proves: The opt-in host module declares role-scoped sops inputs, independent refresh services and timers, and stable Kubernetes Secret names.
  - kind: test
    resource: nixos/flake.nix
    proves: NixOS evaluation proves the disabled-by-default boundary and the enabled namespace, timers, and root-only secret declarations.
  - kind: test
    resource: scripts/test-forge-credentials-refresh.sh
    proves: Focused tests cover successful publication and preservation of the prior Secret after malformed or failed GitHub responses.
  - kind: guide
    resource: docs/user/forge-credentials.md
    proves: Operators have a reusable provisioning, acceptance, rotation, recovery, and disablement playbook.
---

# Rotating role-scoped forge credentials

An operator can opt a context-owned Nagare host into publishing the stable Kubernetes Secrets
`nagare-forge-read` and `nagare-forge-write`. Independent host timers mint short-lived installation
tokens from two operator-owned GitHub Apps every thirty minutes and publish `token`, `GITHUB_TOKEN`,
and `expires_at` without exposing an App private key to a workload. A failed refresh leaves the last
valid Secret untouched.

The capability builds on the context-owned host configuration provided by
[single-node GCP substrate](single-node-gcp-substrate.md) (CAP-2). App registrations, installations,
repository selections, and encrypted bootstrap values remain operator-owned context state rather
than release-owned configuration.

## Limits

- The capability is disabled by default and requires the operator to provision, scope, install, and
  maintain two private GitHub Apps before enabling it.
- Each role supports one installation and therefore one owning GitHub user or organization account.
- Installation tokens are bearer credentials stored in Kubernetes Secrets; cluster RBAC,
  encryption at rest, workload isolation, and expiry monitoring remain operator responsibilities.
- Repository tests prove module shape and refresh failure behavior, but live GitHub permission,
  rotation, denial, and reboot acceptance belong to each context that opts in.
