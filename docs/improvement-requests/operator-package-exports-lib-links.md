---
type: Improvement Request
title: Keep lib/links out of the installed nagare package so it installs beside other Nix profiles
description: The nagare and nagarectl packages expose the Darwin GHC lib/links dylib directory, which collides with home-manager and other profile entries on nix profile install.
timestamp: "2026-09-13T23:42:08Z"
generated:
  by: process:claude-code
  at: "2026-09-13T23:42:08Z"
requestId: IR-10
status: proposed
origin: mori://shinzui/nagare
---

# Improvement Request: keep `lib/links` out of the installed nagare package

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout on `v0.2.1`
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** proposed.
**Created:** 2026-09-13.


## Why

The documented install, `nix profile install "github:shinzui/nagare/v0.2.1#nagare"`, failed on an
aarch64-darwin workstation whose profile holds a home-manager environment:

```text
error: An existing package already provides the following file:
  /nix/store/…-home-manager-path/lib/links/libgmpxx.4.dylib
This is the conflicting file from the new package:
  /nix/store/km7lka8sabznhpbzw8ba5zyqsii2afs0-nagare-0.2.1/lib/links/libgmpxx.4.dylib
```

It installed with `--priority 6`. Every operator with home-manager, or with any other Haskell
executable in their profile, will hit this on the first step of `docs/user/installation.md`, which
does not mention it.


## What is missing

The installed output contains `bin/`, `nix-support/` and `lib/links/`, a directory of symlinks to
`libiconv`, `libffi`, `gmp`, `ncurses`, `compiler-rt` and similar dylibs. That is the Darwin
Haskell build's dynamic-library link farm, carried into the user-facing package because `nagare` is
a `symlinkJoin` over `nagarectl` and the launcher (`nix/haskell-packages.nix:94-96`, and `nagarectl`
itself at `:62-64`) without restricting what it exposes. The executables do not need a profile copy
of those links; their store references are absolute.


## Requested change

- Build the user-facing `nagarectl` and `nagare` packages so they expose `bin/` (plus any share data
  the launcher needs) and not `lib/links/`, e.g. `symlinkJoin { … postBuild = "rm -rf $out/lib"; }`
  or a `pathsToLink`-limited `buildEnv`.
- Until that ships, add the `--priority` workaround to `docs/user/installation.md`.


## Required verification

- A flake check asserting the `nagare` and `nagarectl` outputs contain no `lib/links` directory on
  Darwin.
- The installed binaries still run (`nagarectl version --json`) from a profile without those links.


## Acceptance

`nix profile install "…#nagare"` succeeds next to a home-manager profile without `--priority`.


## Non-goals

Static linking or changes to the Haskell toolchain.
