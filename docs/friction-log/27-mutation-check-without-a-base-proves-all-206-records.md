---
type: Friction Entry
title: "mutation-check without a base proves all 206 records"
description: "just mutation-check REV with no BASE selects every mutation record (a full remote sweep of many hours), not the records the commit touched; the plan's Concrete Steps omitted the base."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-25T14:53:41Z"
frictionId: FRIC-27
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/277-make-the-vm-resize-path-and-store-status-work-on-inventory-contexts.md"
workaround: "stopped it, deleted its four mutation-proof branches, reran just mutation-check HEAD 9d961dc3: 0 of 206 records"
resolution: "Plan 277's Concrete Steps now pass the base; CLAUDE.md already documents just mutation-check REV BASE."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-25T14:54:03Z"
    change: "Resolved: the cause was the plan's command, now corrected"
---
# mutation-check without a base proves all 206 records

## Attempted

just mutation-check HEAD, expecting no records to be selected

## Encountered

nagare-harness mutations prove started remote proofs of every record; after 32 minutes it was still on the early ADR25/ADR26 records

```text
selectRecords _ Nothing entries = pure entries (cli/nagare-harness/src/Nagare/Harness/Mutation.hs)
```

## Workaround

stopped it, deleted its four mutation-proof branches, reran just mutation-check HEAD 9d961dc3: 0 of 206 records
