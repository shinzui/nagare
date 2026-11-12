---
type: Friction Entry
title: "The artifact transport reports success after failing under macOS bash 3.2"
description: "nagarectl runs scripts/inventory-artifact-transport.sh with whatever bash is first on PATH; under /bin/bash 3.2 the image push fails and the apply stops ambiguous with a misleading reason."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-12T17:05:07Z"
frictionId: FRIC-16
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/261-scope-an-app-s-managed-env-and-secrets-to-the-workloads-that-reference-them.md"
workaround: "Put bash 5 first on PATH and run inventory resume; the transaction converged."
resolution: "The transport is written for bash 4.4 or newer, which the operator shell and the rehearsal driver provide; the cause was a hand-made env -i PATH. Promote if a packaged run meets it."
amended:
  - by: "claude-code/claude-fable-5-2"
    at: "2026-11-12T17:05:19Z"
    change: "Status set to accepted."
---
# The artifact transport reports success after failing under macOS bash 3.2

## Attempted

inventory apply of an app image-plan review on a local context, from an env -i shell whose PATH had no bash newer than /bin/bash

## Encountered

ambiguous: artifact transport returned success but the publication is absent. A trace showed scripts/inventory-artifact-transport.sh line 374 'auth_args[@]: unbound variable' (an empty array under set -u in bash 3.2), after which the script still ran observe and exited 0.

```text
inventory-artifact-transport.sh: line 374: auth_args[@]: unbound variable
```

## Workaround

Put bash 5 first on PATH and run inventory resume; the transaction converged.
