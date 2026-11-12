---
type: Friction Entry
title: "mori registry refuses to start on a projection catalog mismatch"
description: "The mori CLI could not be used to find Kotei's checkout; every registry command exits before doing anything."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-12T16:52:13Z"
frictionId: FRIC-15
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/mori"
plan: "docs/plans/261-scope-an-app-s-managed-env-and-secrets-to-the-workloads-that-reference-them.md"
workaround: "Read Kotei at its conventional sibling path /Users/shinzui/Keikaku/bokuno/kotei; mori's database was left alone."
resolution: "mori's refusal is its own guard over its database; Kotei was read at its sibling path and mori's owner adopts the catalog."
amended:
  - by: "claude-code/claude-fable-5-2"
    at: "2026-11-12T17:05:18Z"
    change: "Status set to accepted."
---
# mori registry refuses to start on a projection catalog mismatch

## Attempted

mori registry show shinzui/kotei --full, to locate Kotei's nagare/Config.hs and release script for IR-44 AC-5

## Encountered

CatalogRegistrationRefused: rebuild group project_models is registered with slice fingerprint slice-v6:665e882a… but this binary declares slice-v6:804287ec…

```text
mori refused to start: the projection catalog does not match what this database has registered. Inspect the database before deploying, and adopt the new catalog deliberately rather than restarting.
```

## Workaround

Read Kotei at its conventional sibling path /Users/shinzui/Keikaku/bokuno/kotei; mori's database was left alone.
