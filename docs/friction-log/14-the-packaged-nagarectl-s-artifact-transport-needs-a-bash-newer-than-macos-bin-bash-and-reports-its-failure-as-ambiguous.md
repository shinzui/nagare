---
type: Friction Entry
title: "The packaged nagarectl's artifact transport needs a bash newer than macOS /bin/bash, and reports its failure as ambiguous"
description: "Under a PATH whose first bash is macOS /bin/bash 3.2, inventory-artifact-transport.sh aborts the skopeo copy on an empty array under set -u, then exits 0 with its observe reading the image missing, so the publish stops as ambiguous instead of failing."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-12T13:58:42Z"
frictionId: FRIC-14
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
affectedVersion: "0.19.2"
plan: "docs/plans/260-confirm-an-app-owned-database-with-kotei-s-unchanged-privilege-script-and-release-it.md"
workaround: "Put a Nix bash 5 first on the scrubbed PATH and resume the transaction; it converged."
tags:
  - "artifact-transport"
---
# The packaged nagarectl's artifact transport needs a bash newer than macOS /bin/bash, and reports its failure as ambiguous

## Attempted

nagarectl --context transition inventory apply <app image-plan review> from env -i with a curated PATH (EP-260 M1)

## Encountered

ambiguous ... artifact transport returned success but the publication is absent; nothing reached the registry

```text
inventory-artifact-transport.sh: line 374: auth_args[@]: unbound variable
```

## Workaround

Put a Nix bash 5 first on the scrubbed PATH and resume the transaction; it converged.
