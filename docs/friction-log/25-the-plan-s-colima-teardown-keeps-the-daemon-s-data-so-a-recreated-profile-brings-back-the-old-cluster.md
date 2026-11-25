---
type: Friction Entry
title: "The plan's Colima teardown keeps the daemon's data, so a recreated profile brings back the old cluster"
description: "colima delete --profile P --force (0.10.3) keeps the container runtime data disk; a new profile of the same name started with the previous k3d cluster, registry and failed Job; only --data removes it."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-25T04:22:25Z"
frictionId: FRIC-25
status: logged
impact: slowdown
kind: environment
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare/docs/plans/282-resume-inventory-transactions-in-the-configured-local-object-store.md"
plan: "docs/plans/282-resume-inventory-transactions-in-the-configured-local-object-store.md"
workaround: "colima delete --profile ir54 --data --force"
---
# The plan's Colima teardown keeps the daemon's data, so a recreated profile brings back the old cluster

## Attempted

Replacing the disposable ir54 substrate with colima delete --profile ir54 --force and colima start --profile ir54

## Encountered

docker ps -a on the new daemon listed k3d-nagare-local-server-0 and k3d-registry.localhost created an hour earlier

## Workaround

colima delete --profile ir54 --data --force
