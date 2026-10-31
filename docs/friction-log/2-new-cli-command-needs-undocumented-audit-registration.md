---
type: Friction Entry
title: "New CLI command needs undocumented audit registration"
description: "A new Command constructor must be registered in scripts/audit-managed-commands.py with a coverage family and a catalogue row; nothing at build or style time says so, and the fast gate went red only at architecture-and-command-audit with a log that hides the error."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-10-31T16:08:51Z"
frictionId: FRIC-2
status: "accepted"
impact: detour
kind: process
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare/scripts/test-managed-command-audit.sh"
plan: "docs/plans/236-expose-installed-platform-host-component-and-database-versions.md"
workaround: "Ran scripts/audit-managed-commands.py directly to see the error, registered the route as bounded and added a coverage row"
resolution: "Running scripts/audit-managed-commands.py prints the unregistered constructor; the house rule is to remove steps, not add a check for this."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-10-31T18:45:44Z"
    change: "Status set to accepted."
---
# New CLI command needs undocumented audit registration

## Attempted

Gating the commit that added platform versions

## Encountered

gate step architecture-and-command-audit FAIL whose log ends with passing unit tests

```text
unregistered constructor Command.PlatformVersions
```

## Workaround

Ran scripts/audit-managed-commands.py directly to see the error, registered the route as bounded and added a coverage row
