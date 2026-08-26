---
title: "Mint role-scoped GitHub App tokens on the host"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/94-rotating-github-app-installation-token-credentials-for-runtime-pods.md
  - docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md
---

# ADR 8 — Mint role-scoped GitHub App tokens on the host

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 94](../plans/94-rotating-github-app-installation-token-credentials-for-runtime-pods.md).
Live GitHub registration and acceptance are context-owned operator steps described by the user
playbook.

## Context

Runtime workloads need GitHub access without embedding a human personal access token or holding a
long-lived GitHub App private key. A read-oriented mirror needs broad selected-repository access,
while a publisher needs write access to a much narrower boundary. Combining those permissions in one
identity would make compromise of either workload grant the other's authority.

Nagare already runs k3s and sops-nix on the same NixOS host. The host has root's k3s kubeconfig and
decrypts operator-owned context secrets at activation. Adding an in-cluster credential controller
would create another long-running privileged component and another home for long-lived forge keys.

## Decision

Nagare provides an optional host capability for two private, webhook-disabled GitHub Apps: a read
App with Contents read permission and a write App with Contents and Pull requests read/write
permissions. The capability is disabled by default. Each operator who enables it provisions their
own registrations, keys, installations, and selected-repository boundaries; those resources are
not owned by a Nagare release or maintainer account. Each role has exactly one installation on one
owning account. Runtime interfaces are the stable Kubernetes Secrets `nagare-forge-read` and
`nagare-forge-write` in the configured namespace, which defaults to `personal`; each contains
identical `token` and `GITHUB_TOKEN` values plus `expires_at`.

When enabled, the reusable NixOS host module declares each App ID, installation ID, and private key
as a root-only sops-nix input. Independent systemd timers invoke one Nagare-owned helper every thirty
minutes. The helper signs a short-lived GitHub App JWT, requests one installation token, validates
the response, and applies only its role Secret. It keeps authorization material in a root-only
runtime directory, emits sanitized errors, and does not apply on a failed or malformed response,
leaving the last valid Secret untouched. When disabled, the module declares none of these secrets,
services, or timers.

Live bootstrap values and the non-secret deployment record belong to the active context's
operator-owned configuration, consistent with [ADR 5](0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md).
The checked-in host configuration and encrypted YAML remain evaluation fixtures. Nagare's user
documentation is a reusable provisioning and operations playbook, not a record of one maintainer's
GitHub state. Consumers choose a role Secret through a Kubernetes Secret key reference; they do not
know App credentials or mint their own tokens.

## Consequences

Read and write compromise have separate installation boundaries, tokens rotate without restarting
consumers, and a GitHub outage or one role's bad configuration does not erase the other role or the
last valid credential. A host reboot restores the timers from declarative configuration without
manual token entry.

Operators who opt in must maintain two external GitHub registrations and installations, back up the
context age key, rotate App keys safely, and monitor timer failures and token expiry. Users who do
not opt in have no forge-specific secret or service requirements. One role cannot span multiple
GitHub owner accounts without a deliberate schema and service-fanout revision. GitHub UI state and
live least-privilege checks remain outside hermetic repository tests.
