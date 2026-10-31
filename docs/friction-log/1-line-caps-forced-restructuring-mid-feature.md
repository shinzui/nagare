---
type: Friction Entry
title: "Line caps forced restructuring mid-feature"
description: "Hard line caps on Inventory/Store.hs (1000), Cli/Dispatch.hs (200) and test Suite.hs (300) each failed the architecture check after a few added lines and forced a constructor merge, a re-export and a regrouping."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-10-31T16:08:48Z"
frictionId: FRIC-1
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare/scripts/check-cli-architecture.py"
plan: "docs/plans/236-expose-installed-platform-host-component-and-database-versions.md"
workaround: "Folded refresh into one PlatformVersions constructor, re-exported through Commands.Platform, grouped platform specs"
resolution: "The caps are the deliberate size ratchet; folding the constructor and grouping the platform specs were the intended responses, not a defect."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-10-31T18:45:43Z"
    change: "Status set to accepted."
---
# Line caps forced restructuring mid-feature

## Attempted

Adding one store accessor, two dispatch lines and one suite registration

## Encountered

check-cli-architecture.py and check-haskell-architecture.py refused the modules for exceeding their caps

```text
Nagare.Cli.Dispatch: exceeds 200 lines; separate its responsibilities
```

## Workaround

Folded refresh into one PlatformVersions constructor, re-exported through Commands.Platform, grouped platform specs
