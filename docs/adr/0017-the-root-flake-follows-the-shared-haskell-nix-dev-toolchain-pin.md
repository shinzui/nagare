---
title: "The root flake follows the shared haskell-nix-dev toolchain pin"
status: accepted
date: 2026-09-13
authors: [shinzui]
related:
  - docs/plans/120-modularize-the-root-flake-and-align-it-with-the-shared-haskell-nix-dev-toolchain-pins.md
  - mori://shinzui/haskell-nix-dev/repos/haskell-nix-dev
  - mori://shinzui/seihou-modules/templates/nix-haskell-flake
  - mori://hercules-ci/flake-parts/packages/flake-parts
---

# ADR 17 — The root flake follows the shared haskell-nix-dev toolchain pin

## Status

Accepted, 2026-09-13. Implemented by
[ExecPlan 120](../plans/120-modularize-the-root-flake-and-align-it-with-the-shared-haskell-nix-dev-toolchain-pins.md).

## Context

Nagare's root flake is both its development environment and its release definition. It builds three
Haskell packages, packages the platform payload, exposes operator applications, runs repository and
native-system checks, and defines a networked Hydra job. Its independently locked nixpkgs and Haskell
toolchain had drifted from the shared toolchain in
`mori://shinzui/haskell-nix-dev/repos/haskell-nix-dev`, losing the shared GHC and HLS cache.

The `nix-haskell-flake` template at
`mori://shinzui/seihou-modules/templates/nix-haskell-flake` selects the organization-wide
`haskell-nix-dev` revision. Generating Nagare's root flake from that Seihou module is not appropriate,
however: the generated module owns `flake.nix`, `.envrc`, and `nix/`, assumes one root Cabal package,
and does not model Nagare's release metadata, extra `cradle` input, multiple packages, custom checks,
Hydra output, or context-resolving direnv setup.

The NixOS host under `nixos/` is a separate flake with its own activation safety model and upgrade
cadence. Coupling its pins to the root development and release flake would broaden an otherwise
source-only toolchain change into host infrastructure.

## Decision

The root flake rev-pins `haskell-nix-dev`. Its `nixpkgs` and
`mori://hercules-ci/flake-parts/packages/flake-parts` inputs follow the corresponding inputs carried
by that revision. The carried `treefmt-nix` input's nixpkgs edge also follows
`haskell-nix-dev/nixpkgs`, preserving a single nixpkgs node in the lock graph.

Nagare moves its shared Nix/Haskell toolchain only by bumping the `haskell-nix-dev` revision to the
revision shipped by the current `nix-haskell-flake` template. The root flake consumes the shared
`mkDevShell` interface for GHC 9.12.4, Cabal, HLS, pkg-config, and zlib, while retaining Nagare's
project-specific development tools. Seihou remains the authority for choosing the shared revision,
but does not generate or manage Nagare's root flake.

The root flake is organized as flake-parts modules under `nix/`, with checks grouped by domain under
`nix/checks/`. Repository source passed to packages, checks, and Hydra excludes `flake.nix`,
`flake.lock`, and `nix/`. Nix-wiring-only edits therefore do not invalidate source-based checks or
enter the release payload. Scripts used by Nix checks are referenced separately from the filtered
source so changes to a script rebuild the owning check.

The `nixos/flake.nix` and `nixos/flake.lock` host pins remain independent and are changed only through
the host's own reviewed upgrade path.

## Consequences

Nagare shares the pinned GHC, Cabal, HLS, nixpkgs, and flake-parts graph used by other Haskell
projects, so compatible toolchain closures can come from the shared Cachix cache. Updating that
graph is one deliberate revision change, and the lock retains exactly one nixpkgs node.

The root flake remains hand-maintained because it describes a multi-package platform release rather
than the single-package project contract of the Seihou module. Maintainers must preserve the module
boundary and follow the current template revision manually. The host flake can evolve on its own
schedule, and wiring refactors no longer cause broad source-check rebuilds.
