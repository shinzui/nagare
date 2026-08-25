---
title: "Separate immutable platform payloads from context workspaces"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/106-make-nagare-platform-assets-resolvable-outside-a-source-checkout.md
  - docs/adr/0003-package-the-typed-config-runtime-with-nagarectl.md
  - docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md
---

# ADR 4 — Separate immutable platform payloads from context workspaces

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 106](../plans/106-make-nagare-platform-assets-resolvable-outside-a-source-checkout.md).

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
