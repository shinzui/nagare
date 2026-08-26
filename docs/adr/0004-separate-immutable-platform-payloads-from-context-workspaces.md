---
title: "Separate immutable platform payloads from context workspaces"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/106-make-nagare-platform-assets-resolvable-outside-a-source-checkout.md
  - docs/plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md
  - docs/plans/101-alerting-and-backup-freshness-monitoring.md
  - docs/adr/0003-package-the-typed-config-runtime-with-nagarectl.md
  - docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md
---

# ADR 4 — Separate immutable platform payloads from context workspaces

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 106](../plans/106-make-nagare-platform-assets-resolvable-outside-a-source-checkout.md).
Amended 2026-08-26 to make the already-decided credential exclusion concrete
for Kubernetes bootstrap Secrets used by ExecPlans 99 and 101.

## Context

Nagare operations need release-owned resources beyond the `nagarectl` executable and
typed-config runtime: the Pulumi program, cluster manifests, scripts, NixOS source,
operator recipes, and diagnostic documentation. These resources previously resolved
relative to the caller's current directory, which made a source checkout an implicit
runtime dependency.

Some tools also generate files beside those resources. A Nix-installed payload is
read-only, and sharing one mutable copy across target contexts would mix Pulumi stack
config and other projections between clusters.

## Decision

Nagare distributes those resources as one validated `nagare-platform` payload. Runtime
code resolves an explicit root, then the installed `NAGARE_PLATFORM_ROOT`, then a
validated source-checkout ancestor. A named invalid root is terminal and never falls
back to the current directory.

Commands that may write materialize the selected payload under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/platform/`. The workspace name
combines the manifest payload id with a SHA-256 digest over shipped asset paths and
contents. Preparation copies through a sibling staging directory and atomically
renames it; a matching completed workspace is reused without rewriting it, while a
changed digest selects a distinct directory. Generated source stack configurations
and contributor build outputs are excluded.

Encrypted Kubernetes bootstrap secrets are operator-owned configuration, not release payloads. They
live by default under
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/` and may be redirected with the
explicit `NAGARE_CLUSTER_SECRETS_DIR` override. A source checkout may use its tracked
`cluster/secrets/` directory as a compatibility fallback, but a packaged workspace never receives
that directory. Installers resolve this boundary and fail before mutation when a required encrypted
secret is absent.

Haskell command handlers, shared shell setup, and the packaged operator launcher use
the resolved workspace paths. The source ancestor fallback preserves contributor
workflows but is not used to recover from an invalid installed payload.

## Consequences

Installed init, status, Pulumi, IAP, cleanup, diagnostic, bootstrap, NixOS, and recipe
operations no longer require a Nagare checkout or depend on the caller's current
directory. Multiple contexts and multiple payload revisions receive separate writable
trees, and an earlier payload workspace remains available for later rollback policy.

The workspace duplicates platform assets per context and payload digest. Automatic
pruning is deliberately deferred because release rollback and retention semantics are
owned by later distribution work. Host-specific NixOS inputs use the separate
context-owned flake boundary recorded in
[ADR 5](0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md).
Context-owned encrypted cluster secrets must be backed up with the context and host configuration;
changing or removing a Nix release cannot remove them. Release checks assert that neither the
payload nor its materialized workspace contains `cluster/secrets`.
