---
type: Friction Entry
title: "mori refuses to start on a projection catalog fingerprint mismatch"
description: "mori registry show failed for the whole session because the local database's registered catalog fingerprint differs from the installed mori-cli 7.1.0.0, so Kotei's checkout was found by path."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-12T06:53:43Z"
frictionId: FRIC-13
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/mori"
affectedVersion: "7.1.0.0"
plan: "docs/plans/257-declare-an-app-owned-postgresql-app-database-and-keep-apps-apart.md"
workaround: "read the Kotei checkout at its known local path"
---
# mori refuses to start on a projection catalog fingerprint mismatch

## Attempted

mori registry show shinzui/kotei --full

## Encountered

CatalogRegistrationRefused: rebuild group project_models is registered with slice fingerprint d58460d7... but this binary declares 804287ec...

## Workaround

read the Kotei checkout at its known local path
