---
title: "Package the typed-config runtime with nagarectl"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/105-package-nagarectl-and-its-typed-config-runtime-with-nix.md
  - mori://garnix-io/cradle/packages/cradle
---

# ADR 3 — Package the typed-config runtime with nagarectl

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 105](../plans/105-package-nagarectl-and-its-typed-config-runtime-with-nix.md).

## Context

Nagare application configuration is a Haskell program that imports `Nagare.Dsl.*` and
runs under `runghc`. Contributor builds historically found the package through a
Cabal-generated `.ghc.environment.*` file or a source-checkout-relative fallback. A
standalone `nagarectl` executable therefore could not load an application-owned config
from an unrelated directory, even though the executable itself was portable.

The CLI also depends on the unpublished `mori://garnix-io/cradle/packages/cradle` source.
The old flake checks let Cabal fetch that source and Hackage metadata during the build,
so they were tests rather than reusable, hermetic packages.

## Decision

The Nix distribution owns one GHC 9.12 package set containing the exact locked Cradle
revision, the local `nagare-dsl`, and the local `nagarectl`. It exports `nagarectl` as a
wrapped application whose `PATH` contains a `ghcWithPackages` runtime with
`nagare-dsl` installed.

The installed runtime is the default typed-config compiler. Explicit `--ghc-env` and
`NAGARE_GHC_ENVIRONMENT` values remain supported and take precedence, and contributor
builds may continue to discover a checkout-local Cabal environment. Package derivations
remain separate from check-enabled variants so repository fixtures do not enter the
installed closure.

## Consequences

An installed `nagarectl` can compile and dry-run `nagare/Config.hs` outside a Nagare
checkout without Cabal, network access, or a generated package-environment file. The
flake can test the DSL, CLI, shipped examples, and isolated loader behavior through the
same immutable package graph users receive.

The application closure includes GHC and the DSL dependencies, making it larger than a
bare executable. That cost is intentional: typed config is executable Haskell, so the
compiler runtime is part of the CLI's functional distribution contract. Platform-owned
Pulumi, NixOS, manifest, and script assets remain a separate payload boundary.
