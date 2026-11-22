---
type: Friction Entry
title: "The upgrade rehearsal cannot run a candidate's own service images"
description: "release-rehearse runs the service images release.json names, so an unreleased revision's rehearsal runs the last published admin API image as its lifecycle worker and cannot exercise a worker change."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-22T18:17:43Z"
frictionId: FRIC-19
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/276-publish-lifecycle-events-for-the-changes-failures-backups-and-upgrades-an-admin-needs-to-see.md"
workaround: "the lifecycle check is proved by a release candidate whose release.json names an image with this code, or on a drill root whose context pins the image built from this tree"
resolution: "A release candidate's release.json names the images built from it, so the opt-in rehearsal check runs at the first candidate; an unreleased revision's worker is proved on a drill root that pins this tree's image."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-22T20:22:23Z"
    change: "Accepted: the rehearsal proves releases, and pinning service images there would change what a release rehearsal proves."
---
# The upgrade rehearsal cannot run a candidate's own service images

## Attempted

adding the opt-in platform.upgraded check to the EP-172 rehearsal for this plan's revision

## Encountered

release.json at this revision pins v0.26.0's nagare-admin-api digest, which runs nagare-events and refuses the new event types; the drill scrubs every NAGARE_ override but NAGARE_REHEARSAL_*

## Workaround

the lifecycle check is proved by a release candidate whose release.json names an image with this code, or on a drill root whose context pins the image built from this tree
