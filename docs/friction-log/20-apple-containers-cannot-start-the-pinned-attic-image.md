---
type: Friction Entry
title: "Apple containers cannot start the pinned Attic image"
description: "Apple container 1.5.0 unpacks the Nix-built Attic image without its read-only /bin and /nix/store contents, so the local reseed rehearsal needed the layer extracted and bind-mounted by hand."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-23T05:48:11Z"
frictionId: FRIC-20
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/278-let-a-context-choose-the-attic-nar-size-threshold-so-gcs-cache-hits-redirect.md"
workaround: "extract the layer with GNU tar --delay-directory-restore, mount its nix/ at /nix and bin/ at /attic-bin, and use --entrypoint /attic-bin/atticd"
---
# Apple containers cannot start the pinned Attic image

## Attempted

container run of ghcr.io/zhaofengli/attic@sha256:18574aba... (amd64 and arm64) for the M2 reseed rehearsal

## Encountered

the process fails before start; the layer's directories are mode r-x, and the unpacked rootfs lacks /bin/atticd and the glibc interpreter

```text
vmexec error: internalError: "failed to find target executable /bin/atticd"
```

## Workaround

extract the layer with GNU tar --delay-directory-restore, mount its nix/ at /nix and bin/ at /attic-bin, and use --entrypoint /attic-bin/atticd
