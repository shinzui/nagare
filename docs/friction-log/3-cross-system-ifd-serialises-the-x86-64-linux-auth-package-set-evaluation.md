---
type: Friction Entry
title: "Cross-system IFD serialises the x86_64-linux auth package set evaluation"
description: "Evaluating the x86_64-linux release-image outputs from the aarch64-darwin workstation runs every callCabal2nix import-from-derivation as a separate remote build, one at a time, before any package compiles."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-10-31T20:03:08Z"
frictionId: FRIC-3
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/237-publish-release-images-for-the-auth-plane-and-admin-api.md"
workaround: "none needed once the IFD outputs are in the store; a cold store pays it again"
---
# Cross-system IFD serialises the x86_64-linux auth package set evaluation

## Attempted

nix build --max-jobs 0 .#packages.x86_64-linux.release-images-manifest from the Mac

## Encountered

roughly 120 cabal2nix derivations were built and copied back serially on ssh://builder@nix-gcp-builder (about 25 minutes) before the first Haskell library build started

## Workaround

none needed once the IFD outputs are in the store; a cold store pays it again
