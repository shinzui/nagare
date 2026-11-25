---
type: Friction Entry
title: "The command audit's unregistered library call is hidden in the gate log again"
description: "just gate-commit printed only 'architecture-and-command-audit FAIL'; the audit's JSON error and the stale catalogue snapshot showed only when scripts/audit-managed-commands.py was run by hand, as in FRIC-21."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-25T03:23:16Z"
frictionId: FRIC-23
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare/scripts/audit-managed-commands.py"
plan: "docs/plans/282-resume-inventory-transactions-in-the-configured-local-object-store.md"
workaround: "Ran the audit script directly, added the name to LIBRARY_CALLS and ran it with --update-catalogue"
resolution: "A recurrence of FRIC-21's surface; scripts/audit-managed-commands.py prints the error and --update-catalogue refreshes the snapshot."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-25T05:11:33Z"
    change: "Accepted: the house rule removes steps rather than adding a check; the recurrence is recorded."
---
# The command audit's unregistered library call is hidden in the gate log again

## Attempted

Running just gate-commit after moving foundationResumeTarget into the library as selectResumeStore

## Encountered

The gate step failed with no message; the audit's errors list named 'unregistered inventory library call cli/nagarectl/app: selectResumeStore', then 'managed command catalogue snapshot is stale'

```text
gate-commit: architecture-and-command-audit FAIL (7 s)
```

## Workaround

Ran the audit script directly, added the name to LIBRARY_CALLS and ran it with --update-catalogue
