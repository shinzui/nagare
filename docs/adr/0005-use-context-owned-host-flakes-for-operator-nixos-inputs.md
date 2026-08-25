---
title: "Use context-owned host flakes for operator NixOS inputs"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/107-externalize-per-operator-nixos-and-host-configuration.md
  - docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md
---

# ADR 5 — Use context-owned host flakes for operator NixOS inputs

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 107](../plans/107-externalize-per-operator-nixos-and-host-configuration.md).

## Context

Nagare's distributable NixOS tree previously combined reusable host behavior with one operator's SSH
identity, a fixed hostname, a worked-example registry, and a generated registry override beside the
source modules. Image builds and day-2 rebuilds consumed that tree directly. Multiple contexts could
therefore overwrite shared inputs, a released payload could not be treated as immutable, and a
published image could accidentally authorize the maintainer rather than its operator.

Nix flakes also evaluate purely: a released module cannot safely reach from an immutable payload into
arbitrary files under an operator's XDG configuration tree. The operator-owned files must themselves
form a flake that imports the released Nagare module.

## Decision

The nested Nagare NixOS flake exports `nixosModules.nagare-host` and
`lib.mkNagareSystem`. The `nagare.host` option namespace supplies hostname and instance identity,
registry host, deploy user, a non-empty SSH authorized-key list, an encrypted sops file, and the
on-host age-private-key path. The shared constructor includes the pinned nixpkgs, sops-nix, reusable
Nagare modules, and GCE image module so image and day-2 outputs use one `nixosSystem`.

Each target context owns a generated flake under
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/hosts/<context>/`. Its `flake.nix` pins the Nagare NixOS
input, `host.nix` contains only public operator intent, and `secrets.yaml` remains sops-encrypted.
`nagarectl host init` validates public keys, rejects private-key and plaintext Tailscale-token
material, Nix-evaluates a staging flake, and installs or replaces it atomically. Regeneration preserves
the existing encrypted file unless the operator explicitly supplies another one. The age private key
is never read or copied; only its path on the host is rendered.

Image and rebuild scripts resolve `NAGARE_HOST_FLAKE` when explicitly set and otherwise use
`nagarectl host path` for the active context. The checked-in `nagare-01` configuration is an
evaluation-only compatibility fixture with a synthetic key, not an operational identity fallback.

## Consequences

Two contexts can evaluate, build, and update hosts concurrently without writing Nagare source or
sharing SSH keys, registry settings, encrypted secrets, or generated lock files. A released payload
remains immutable, while operator intent survives payload replacement and can pin a different Nagare
revision during a staged upgrade.

Operators must create and back up one small host flake and encrypted secrets file per context before
building an image. Changing reusable platform behavior still requires a new Nagare payload or source
revision; changing operator identity requires regenerating only that context's host flake. The current
generator targets one x86_64-linux GCE host per context, matching Nagare's single-node scope.
