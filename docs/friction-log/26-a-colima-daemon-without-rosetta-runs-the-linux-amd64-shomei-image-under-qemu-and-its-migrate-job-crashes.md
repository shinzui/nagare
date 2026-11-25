---
type: Friction Entry
title: "A Colima daemon without Rosetta runs the linux/amd64 shomei image under QEMU and its migrate Job crashes"
description: "The drill's auth images are linux/amd64; on a profile started without --vz-rosetta the shomei-migrate container crashes at once, the Job reaches its backoff limit with its pod and logs deleted, and nothing names the architecture."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-25T04:40:09Z"
frictionId: FRIC-26
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare/scripts/site-access-drill.sh"
plan: "docs/plans/282-resume-inventory-transactions-in-the-configured-local-object-store.md"
workaround: "colima start --vz-rosetta, as the nagare-mp23 profile has"
resolution: "Start a disposable Colima profile with --vz-rosetta, as the warm nagare-mp23 profile is; the plan's substrate command now does."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-25T05:11:37Z"
    change: "Accepted: the auth images are linux/amd64 by design; the profile flag is recorded where the next run reads it."
---
# A Colima daemon without Rosetta runs the linux/amd64 shomei image under QEMU and its migrate Job crashes

## Attempted

Bootstrapping a disposable context with NAGARE_DRILL_BOOTSTRAP_ONLY=1 on a new Colima profile (vz, rosetta false)

## Encountered

Bootstrap op-500a8dc69738574d1a35a0b6 failed terminally twice: Job shomei-migrate-df55245e92ec BackoffLimitExceeded, Postgres saw no connection

```text
WARNING: The requested image's platform (linux/amd64) does not match the detected host platform (linux/arm64/v8)
```

## Workaround

colima start --vz-rosetta, as the nagare-mp23 profile has
