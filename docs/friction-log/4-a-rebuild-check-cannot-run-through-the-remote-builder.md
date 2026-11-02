---
type: Friction Entry
title: "A rebuild check cannot run through the remote builder"
description: "nix build --rebuild of x86_64-linux image derivations from the aarch64-darwin workstation fails with 'local builds are disabled (max-jobs = 0)' although the builder is running, so a determinism check needs a shell on the builder."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-10-31T21:20:28Z"
frictionId: FRIC-4
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/237-publish-release-images-for-the-auth-plane-and-admin-api.md"
workaround: "compared the layout conversion's digest on the builder and on the workstation; the clean-cache rebuild moves to M5"
---
# A rebuild check cannot run through the remote builder

## Attempted

nix build --max-jobs 0 --rebuild of the four release-image layouts and their docker archives

## Encountered

every derivation refused: platform mismatch, local builds disabled; the remote builder does not take check builds

```text
error: Cannot build '/nix/store/0r933xk41n0p7ff156bspayfmh55il3v-nagare-en.tar.gz.drv'. Reason: local builds are disabled (max-jobs = 0)
```

## Workaround

compared the layout conversion's digest on the builder and on the workstation; the clean-cache rebuild moves to M5
