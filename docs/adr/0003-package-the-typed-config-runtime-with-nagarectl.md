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

## Amendment: published configuration SDK and tooling-only systems

Date: 2026-11-09. Implemented by
[ExecPlan 253](../plans/253-package-a-native-arm64-linux-configuration-sdk-and-cli.md).

The runtime the wrapper puts on `PATH` is also a named flake output,
`packages.<system>.nagare-config-sdk`: the same `ghcWithPackages` runtime with `nagare-dsl`, the
same locked compiler and library versions, with no separate pins. Consumers that compile typed
configuration use this attribute and `packages.<system>.nagarectl`; they do not find a compiler by
inspecting the CLI wrapper.

A release system (`x86_64-linux`, `aarch64-darwin`, from `release.json` `supportedSystems`) has
every platform output. `flake.nix` lists `aarch64-linux` as a **tooling-only** system, read from the
`tooling-systems` flake input: it gets `nagarectl`, `nagare-config-sdk` and the
`nagare-config-sdk-consumer` check. It has no platform payload, so its `nagarectl` wrapper sets no
`NAGARE_PLATFORM_ROOT` and platform commands refuse there, and no host, image, release-image,
development-shell or Hydra output. A native Linux SDK is not production-host support, and
`release.json` is not changed by it.

The check needs a native `aarch64-linux` builder, which the landing gate does not have, so it runs
per release candidate in a native Apple container. The full gate validates and builds only
`release.json` systems instead of using `--all-systems`, and a release candidate builds the check by name.
