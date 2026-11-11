---
type: Friction Entry
title: "Fixed line caps on the test suite assembler and CLI dispatch push new groups into unrelated modules"
description: "Nagare.Test.Suite is capped at 300 lines and Nagare.Cli.Dispatch at 200, both already at the cap, so each new test group or command had to be hooked into an unrelated spec module or squeezed by reformatting imports."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-11T06:02:33Z"
frictionId: FRIC-8
status: "accepted"
impact: detour
kind: process
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/247-review-a-bounded-namespace-delegation-for-a-named-deployer-and-record-who-applied-each-change.md"
workaround: "Hooked groups into InventoryAccessSpec, InventoryStoreOnceSpec and Static; collapsed one import list in Dispatch"
resolution: "The caps are the deliberate size ratchet (as FRIC-1 decided); moving the code to a cohesive module was the intended response."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-11T14:45:26Z"
    change: "Accepted at MasterPlan 33's completion triage; the recurrence with FRIC-1 is recorded in the MasterPlan for the operator."
---
# Fixed line caps on the test suite assembler and CLI dispatch push new groups into unrelated modules

## Attempted

Registering the Delegation, S3 store and layered builder test groups and the delegation and render commands

## Encountered

check-haskell-architecture.py and check-cli-architecture.py refused 302 and 202 lines

## Workaround

Hooked groups into InventoryAccessSpec, InventoryStoreOnceSpec and Static; collapsed one import list in Dispatch
