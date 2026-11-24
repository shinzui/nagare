---
type: Friction Entry
title: "The command audit's failure is hidden in the gate log, again for a library call and the catalogue snapshot"
description: "gate-commit's architecture-and-command-audit step failed three times in a row (a 1000-line module cap, an unregistered Inventory library call, a stale catalogue snapshot), and the last two print no error in the gate log; each needed a direct run of scripts/audit-managed-commands.py and a gate rerun."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-24T06:04:54Z"
frictionId: FRIC-21
status: "accepted"
impact: detour
kind: process
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare/scripts/test-managed-command-audit.sh"
plan: "docs/plans/280-make-out-of-band-kubernetes-edits-a-plan-time-decision-instead-of-a-mid-release-refusal.md"
workaround: "Ran scripts/audit-managed-commands.py directly, registered the call in LIBRARY_CALLS, then ran it with --update-catalogue"
resolution: "A recurrence of FRIC-2's surface; running scripts/audit-managed-commands.py prints the error and --update-catalogue refreshes the snapshot."
amended:
  - by: "claude-code/claude-fable-5-2"
    at: "2026-11-24T07:12:12Z"
    change: "Accepted: the house rule is to remove steps, not add a check; the recurrence is recorded."
---
# The command audit's failure is hidden in the gate log, again for a library call and the catalogue snapshot

## Attempted

Gating the commit that added the plan-time foreign-owner refusal and a new Inventory.Command entry point

## Encountered

architecture-and-command-audit FAIL whose log ends with passing unit tests; the errors were only in the JSON that scripts/audit-managed-commands.py prints when run alone

```text
unregistered inventory library call cli/nagarectl/app: inventoryCandidateRefusalWithRetirementsPayload; then: managed command catalogue snapshot is stale
```

## Workaround

Ran scripts/audit-managed-commands.py directly, registered the call in LIBRARY_CALLS, then ran it with --update-catalogue
