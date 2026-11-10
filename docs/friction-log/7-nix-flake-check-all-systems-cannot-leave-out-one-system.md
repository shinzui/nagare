---
type: Friction Entry
title: "nix flake check --all-systems cannot leave out one system"
description: "Nix's flake check has no way to skip a system, so publishing tooling for a system the landing gate cannot build forces a flake input the gate overrides."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-10T05:53:14Z"
frictionId: FRIC-7
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-flake-check"
affectedVersion: "Determinate Nix 3.23.0 (Nix 2.35.2)"
plan: "docs/plans/253-package-a-native-arm64-linux-configuration-sdk-and-cli.md"
workaround: "Make the tooling-systems list a flake input and have the gate override it to the empty list."
tags:
  - "nix"
  - "gate"
resolution: "The gate evaluates and builds only release.json systems, so no flake input or override is needed (545182fe, 22ab49b5)."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-10T18:34:30Z"
    change: "Status set to resolved."
---
# nix flake check --all-systems cannot leave out one system

## Attempted

Add aarch64-linux to flake-parts systems while the full gate keeps running nix flake check on all systems from a Mac with only an x86_64-linux builder.

## Encountered

The all-systems mode evaluates every system's packages and checks, whose import-from-derivation needs an aarch64-linux builder; the command offers no system filter, and selecting one system would make Nix build x86_64-linux locally.

```text
Error on the Mac for an aarch64-linux derivation: Required system: 'aarch64-linux', Current system: 'aarch64-darwin'.
```

## Workaround

Make the tooling-systems list a flake input and have the gate override it to the empty list.
