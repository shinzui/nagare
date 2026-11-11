---
type: Friction Entry
title: "The 1000-line cap on Nagare.Target turned a 17-line fix red at the fast gate"
description: "Nagare.Target sat 11 lines under the architecture check's 1000-line cap, so adding one documented function failed the fast gate and forced a second commit and two more packaged builds during a live run."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-11T13:42:52Z"
frictionId: FRIC-9
status: "accepted"
impact: detour
kind: process
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
affectedVersion: "unreleased"
plan: "docs/plans/251-keep-a-local-context-s-inventory-store-in-its-in-cluster-object-store-so-an-in-cluster-deployer-can-apply.md"
workaround: "Moved the function into Nagare.Inventory.Store.ObjectTarget (2ee5ced8) and rebuilt the darwin nagarectl and the arm64 Pod image at the new revision."
tags:
  - "line-caps"
resolution: "The caps are the deliberate size ratchet (as FRIC-1 decided); moving the code to a cohesive module was the intended response."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-11T14:45:27Z"
    change: "Accepted at MasterPlan 33's completion triage; the recurrence with FRIC-1 is recorded in the MasterPlan for the operator."
---
# The 1000-line cap on Nagare.Target turned a 17-line fix red at the fast gate

## Attempted

Fixing the object-store migration found by the MP-33 local confirmation run: added objectInventoryStoreUrl beside defaultGcsInventoryStoreUrl in cli/nagarectl/src/Nagare/Target.hs, committed 9568cc5e and ran just gate-fast.

## Encountered

architecture-and-command-audit failed: cli/nagarectl/src/Nagare/Target.hs: 1006 lines exceeds 1000; separate responsibilities. The local style check, cabal build and the targeted tests had all passed.

```text
gate: architecture-and-command-audit   FAIL (1.5 s)
cli/nagarectl/src/Nagare/Target.hs: 1006 lines exceeds 1000; separate responsibilities
```

## Workaround

Moved the function into Nagare.Inventory.Store.ObjectTarget (2ee5ced8) and rebuilt the darwin nagarectl and the arm64 Pod image at the new revision.
